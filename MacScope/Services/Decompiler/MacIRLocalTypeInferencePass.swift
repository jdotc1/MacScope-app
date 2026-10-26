import Foundation

/// A conservative, single-forward-pass type-inference refinement for recovered
/// locals and register temporaries.
///
/// The builder already assigns each stack slot and scratch register a width-only
/// default type (`int64_t` for an x-register spill, `int32_t` for a w-register
/// spill, the sized element type for a `ldrb`/`ldrsh`/... access). That default
/// is faithful but coarse: it cannot distinguish a signed byte from an unsigned
/// one, a pointer from a 64-bit integer, or a boolean from a 32-bit integer.
///
/// This pass walks the lifted IR once, gathering *hard* evidence (signedness from
/// `ldrs*`/`sdiv`/`udiv`/`asr`/`lsr`, boolean-ness from `cset`, pointer-ness from
/// a load through a base register, exact C types from matched call-argument
/// signatures and cast intrinsics) and *soft* evidence (the builder's width-only
/// defaults). It meets the evidence per slot and rewrites a slot/register type
/// ONLY when the result is strictly more specific and never clobbers an already
/// hard, narrower builder type.
///
/// GOVERNING RULE: correctness over coverage. When the meet is `unknown` or
/// merely a looser/wider type than what the builder already wrote, the existing
/// string is kept verbatim. The pass is idempotent: running it on its own output
/// produces no further change.
struct LocalTypeInferencePass: Sendable {
    private static func accessFact(_ access: MacIRMemoryAccess?) -> InferredLocalTypeFact? {
        guard let access, access.extensionKind != .none else { return nil }
        return InferredLocalTypeFact(lattice: .integer(bits: access.byteWidth * 8, signed: access.extensionKind == .sign), confidence: true)
    }

    static func infer(
        function: MacIRFunction,
        userSlotOverrides: [Int64: String] = [:]
    ) -> MacIRFunction {
        var function = function
        let parameterGroups = Dictionary(grouping: function.parameters.compactMap { parameter in
            parameter.bindingID.map { ($0, parameter.type) }
        }, by: \.0)
        let parameterTypes = parameterGroups.compactMapValues { entries in
            entries.count == 1 ? entries[0].1 : nil
        }

        // ── Step 1: seed each slot's existing type as a fact. ────────────────
        // The builder string is the baseline; its confidence (hard vs soft) is
        // recovered from the spelling via `typeStringToLattice`.
        var seededSlotFact: [Int64: InferredLocalTypeFact] = [:]
        for local in function.localVariables {
            seededSlotFact[local.offset] = typeStringToLattice(local.type)
        }

        // ── Step 2: single forward pass collecting evidence. ─────────────────
        var slotEvidence: [Int64: [InferredLocalTypeFact]] = [:]
        var registerEvidence: [MacIRValue: InferredLocalTypeFact] = [:]
        // One-hop backward trace: a value -> the stack slot it was stored into or
        // loaded out of. Lets call-argument evidence reach the originating slot.
        var storeMap: [MacIRValue: Int64] = [:]

        func addSlotEvidence(_ fact: InferredLocalTypeFact, to offset: Int64) {
            slotEvidence[offset, default: []].append(fact)
        }

        for instruction in function.instructions {
            let mnemonic = instruction.source.mnemonic
            if let fp = instruction.scalarFP, case let .intrinsic(destination?, _, _) = instruction.operation {
                registerEvidence[destination] = typeStringToLattice(fp.storageResultType.cType)
            }
            switch instruction.operation {
            case let .store(source, address):
                guard case let .stackSlot(offset) = address else { break }
                storeMap[source] = offset
                // A register fact about the stored value flows onto the slot.
                if let regFact = registerEvidence[source] {
                    addSlotEvidence(regFact, to: offset)
                }
                // The store width itself is soft integer evidence (signedness
                // unknown from a plain str); sized stores already encoded their
                // element type into the builder's slot type, captured at seed.

            case let .stackSlotRead(destination, slot, value):
                guard case let .stackSlot(offset) = slot else { break }
                // Both the reloaded destination and the original stored value map
                // back to this slot, so evidence on either reaches it.
                storeMap[destination] = offset
                storeMap[value] = offset
                // A sized reload (ldrsb/ldrb/ldrsh/ldrh/ldrsw) names the slot's
                // exact element type and signedness from the encoding.
                if let fact = Self.accessFact(instruction.memoryAccess) ?? Self.sizedAccessFact(mnemonic: mnemonic) {
                    addSlotEvidence(fact, to: offset)
                }

            case let .load(destination, address):
                // A sized load names the loaded register's type.
                if let fact = Self.accessFact(instruction.memoryAccess) ?? Self.sizedAccessFact(mnemonic: mnemonic) {
                    registerEvidence[destination] = fact
                    // A sized load straight from a stack slot (no intervening
                    // store, so the builder lifted a plain `.load`) names that
                    // slot's element signedness too. The width-match write-back
                    // gate keeps this from fighting a wider builder type.
                    if case let .stackSlot(offset) = address {
                        addSlotEvidence(fact, to: offset)
                    }
                }
                // A load through a register base that is NOT the stack (the
                // address is not a literal stack slot) makes that base a pointer.
                if case let .stackSlot(offset) = address {
                    _ = offset // stack loads carry no pointer evidence about a base
                } else if let baseSlot = Self.baseSlot(of: address, storeMap: storeMap) {
                    addSlotEvidence(
                        InferredLocalTypeFact(lattice: .pointer, confidence: true),
                        to: baseSlot
                    )
                }

            case let .loadWriteback(destination, _, _, _, _):
                if let fact = Self.accessFact(instruction.memoryAccess) ?? Self.sizedAccessFact(mnemonic: mnemonic) {
                    registerEvidence[destination] = fact
                }

            case let .binary(destination, op, _, _):
                // Division carries signedness in the mnemonic; the rendered op is
                // the signedness-agnostic "/", so we consult the source mnemonic.
                if op == "/" {
                    if mnemonic == "sdiv" {
                        registerEvidence[destination] = InferredLocalTypeFact(
                            lattice: .integer(bits: Self.bits(of: destination), signed: true),
                            confidence: true
                        )
                    } else if mnemonic == "udiv" {
                        registerEvidence[destination] = InferredLocalTypeFact(
                            lattice: .integer(bits: Self.bits(of: destination), signed: false),
                            confidence: true
                        )
                    }
                } else if op == ">>" {
                    // asr is arithmetic (signed) shift; lsr is logical (unsigned).
                    if mnemonic == "asr" {
                        registerEvidence[destination] = InferredLocalTypeFact(
                            lattice: .integer(bits: Self.bits(of: destination), signed: true),
                            confidence: true
                        )
                    } else if mnemonic == "lsr" {
                        registerEvidence[destination] = InferredLocalTypeFact(
                            lattice: .integer(bits: Self.bits(of: destination), signed: false),
                            confidence: true
                        )
                    }
                }

            case let .intrinsic(_, name, arguments) where name == "restore_pair" || name == "restore_pair_writeback":
                if arguments.count >= 2, let fact = Self.accessFact(instruction.memoryAccess) {
                    registerEvidence[arguments[0]] = fact
                    registerEvidence[arguments[1]] = fact
                }

            case let .intrinsic(destination?, name, _) where name.hasPrefix("a64_sdiv") || name.hasPrefix("a64_udiv") || name.hasPrefix("a64_srem") || name.hasPrefix("a64_urem"):
                registerEvidence[destination] = InferredLocalTypeFact(
                    lattice: .integer(bits: name.hasSuffix("32") ? 32 : 64, signed: name.hasPrefix("a64_s")), confidence: true)

            case let .compareToBool(destination, _, _, _):
                registerEvidence[destination] = InferredLocalTypeFact(
                    lattice: .bool,
                    confidence: true,
                    exactTypeString: "BOOL"
                )

            case let .assign(destination, source):
                switch source {
                case let .argument(bindingID):
                    // Copy the incoming argument's type one hop.
                    if let type = parameterTypes[bindingID] {
                        registerEvidence[destination] = typeStringToLattice(type)
                    }
                case let .argumentFragment(rowID, _, size):
                    // The validated HFA carrier is a double, while its source
                    // declaration remains one aggregate row.
                    if size == 8,
                       function.parameters.contains(where: { $0.id == rowID && $0.richLocation != nil }) {
                        registerEvidence[destination] = typeStringToLattice("double")
                    }
                case let .unary(op, _):
                    // A width/sign-extension cast intrinsic ("(int8_t)", ...)
                    // names the destination's exact type.
                    if let fact = Self.castFact(op: op) {
                        registerEvidence[destination] = fact
                    }
                default:
                    // A plain register-to-register copy forwards any known fact.
                    if let fact = registerEvidence[source] {
                        registerEvidence[destination] = fact
                    }
                }

            case let .call(frame, _):
                if let rich = frame.richArguments {
                    for argument in rich {
                        for piece in argument.pieces where piece.size == 8 {
                            guard case .simd(_, 64) = piece.register,
                                  let offset = storeMap[piece.value] else { continue }
                            addSlotEvidence(typeStringToLattice("double"), to: offset)
                        }
                    }
                }
                guard let signature = frame.knownSignature else { break }
                for parameter in signature.parameters {
                    guard let expectedLocation = MacIRCallArgumentLocation(register: parameter.register),
                          let argument = frame.arguments.fixedArgument(at: parameter.index),
                          argument.location == expectedLocation else {
                        continue
                    }
                    // Trace the argument back to its originating slot (one hop).
                    guard let offset = storeMap[argument.value] else { continue }
                    addSlotEvidence(typeStringToLattice(parameter.type), to: offset)
                }

            default:
                break
            }
        }

        // A phi is typed by compatible facts from every predecessor. Loop
        // backedge inputs can name values defined later in source order, so
        // resolve these finite links after the instruction pass with a bound.
        // Missing or incompatible evidence leaves the builder's width-only
        // type in place rather than inventing signedness or a pointer type.
        for _ in 0..<function.phis.count {
            var changed = false
            for phi in function.phis {
                let facts: [InferredLocalTypeFact] = phi.incoming.compactMap { input in
                    switch input.value {
                    case let .argument(bindingID):
                        return parameterTypes[bindingID].map(typeStringToLattice)
                    case .immediate where phi.bitWidth <= 64:
                        return InferredLocalTypeFact(lattice: .integer(bits: phi.bitWidth,
                                                                        signed: true),
                                                     confidence: false)
                    default:
                        return registerEvidence[input.value]
                    }
                }
                guard facts.count == phi.incoming.count, let first = facts.first else { continue }
                let met = facts.dropFirst().reduce(first, Self.meet)
                guard met.lattice != .unknown,
                      registerEvidence[phi.destination] != met else { continue }
                registerEvidence[phi.destination] = met
                changed = true
            }
            if !changed { break }
        }

        // ── Step 3: meet evidence per slot. ──────────────────────────────────
        var resolvedSlotFact: [Int64: InferredLocalTypeFact] = [:]
        for (offset, seed) in seededSlotFact {
            var met = seed
            for fact in slotEvidence[offset] ?? [] {
                met = Self.meet(met, fact)
            }
            resolvedSlotFact[offset] = met
        }
        // Slots that appear only in evidence (never seeded) are ignored: the pass
        // only refines locals the builder already recovered.

        // ── Step 4: write back, conservatively. ──────────────────────────────
        function.localVariables = function.localVariables.map { local in
            var local = local
            if let userType = userSlotOverrides[local.offset] {
                // Hook for a future user override; unused by current callers.
                local.type = userType
                return local
            }
            guard let resolved = resolvedSlotFact[local.offset] else { return local }
            if let refined = Self.refinedString(from: resolved, existing: local.type) {
                local.type = refined
            }
            return local
        }

        // Mirror refined slot types onto the stack-local name bindings and refine
        // register-temporary bindings from register evidence.
        function.nameBindings = function.nameBindings.map { binding in
            var binding = binding
            switch binding.target {
            case let .stackSlot(offset):
                if let resolved = resolvedSlotFact[offset], let existing = binding.type,
                   let refined = Self.refinedString(from: resolved, existing: existing) {
                    binding.type = refined
                }
            case let .register(name, version):
                let value = MacIRValue.register(name: name, version: version)
                if let fact = registerEvidence[value], let existing = binding.type,
                   let refined = Self.refinedString(from: fact, existing: existing) {
                    binding.type = refined
                }
            }
            return binding
        }

        // ── Step 5: return. ──────────────────────────────────────────────────
        return function
    }

    // MARK: - Evidence helpers

    /// Hard element-type fact from a sized load/store mnemonic, or nil for the
    /// plain register-width forms that carry no signedness signal.
    private static func sizedAccessFact(mnemonic: String) -> InferredLocalTypeFact? {
        switch mnemonic {
        case "ldrsb":
            return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: true), confidence: true)
        case "ldrb", "strb":
            return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: false), confidence: true)
        case "ldrsh":
            return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: true), confidence: true)
        case "ldrh", "strh":
            return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: false), confidence: true)
        case "ldrsw":
            return InferredLocalTypeFact(lattice: .integer(bits: 32, signed: true), confidence: true)
        default:
            return nil
        }
    }

    /// Hard fact from a width/sign-extension cast intrinsic op string.
    private static func castFact(op: String) -> InferredLocalTypeFact? {
        switch op {
        case "(int8_t)":
            return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: true), confidence: true)
        case "(uint8_t)":
            return InferredLocalTypeFact(lattice: .integer(bits: 8, signed: false), confidence: true)
        case "(int16_t)":
            return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: true), confidence: true)
        case "(uint16_t)":
            return InferredLocalTypeFact(lattice: .integer(bits: 16, signed: false), confidence: true)
        case "(int32_t)":
            return InferredLocalTypeFact(lattice: .integer(bits: 32, signed: true), confidence: true)
        default:
            return nil
        }
    }

    /// Register width in bits from the destination value (x -> 64, w -> 32).
    private static func bits(of value: MacIRValue) -> Int {
        guard case let .register(name, _) = value else { return 64 }
        return name.lowercased().hasPrefix("w") ? 32 : 64
    }

    /// If `address` is (or traces back through `storeMap` to) a slot, return that
    /// slot offset; used to attribute pointer evidence to a base held in a local.
    private static func baseSlot(of address: MacIRValue, storeMap: [MacIRValue: Int64]) -> Int64? {
        if let offset = storeMap[address] {
            return offset
        }
        return nil
    }

    // MARK: - Lattice meet

    /// Test-only hook exposing the otherwise-private `meet` so the order
    /// independence of the lattice can be asserted directly (the builder's seed is
    /// itself order-sensitive, so a black-box test cannot isolate `meet`).
    static func meetForTesting(
        _ a: InferredLocalTypeFact,
        _ b: InferredLocalTypeFact
    ) -> InferredLocalTypeFact {
        meet(a, b)
    }

    /// Conservative meet of two facts. Order-independent. `unknown` is the
    /// identity. Conflicts that cannot be reconciled resolve to `unknown`, which
    /// the write-back step treats as "keep the existing string".
    private static func meet(
        _ a: InferredLocalTypeFact,
        _ b: InferredLocalTypeFact
    ) -> InferredLocalTypeFact {
        // unknown meets X -> X
        if a.lattice == .unknown { return b }
        if b.lattice == .unknown { return a }
        // Identical lattice -> prefer the more confident / more-specifically-spelled.
        if a.lattice == b.lattice {
            if a.confidence == b.confidence {
                // Order-independent exact-spelling resolution:
                //  - exactly one side names an exact spelling -> take that side;
                //  - both name the SAME exact spelling -> either (use `a`);
                //  - both name DIFFERENT exact spellings (e.g. "size_t" vs
                //    "uint64_t") -> the choice cannot be justified, so drop to the
                //    lattice default spelling (no exact string). This makes the
                //    result depend only on the unordered pair, not evidence order.
                switch (a.exactTypeString, b.exactTypeString) {
                case let (sa?, sb?):
                    return sa == sb
                        ? a
                        : InferredLocalTypeFact(lattice: a.lattice, confidence: a.confidence)
                case (.some, nil):
                    return a
                case (nil, .some):
                    return b
                case (nil, nil):
                    return a
                }
            }
            return a.confidence ? a : b
        }

        switch (a.lattice, b.lattice) {
        case let (.integer(ba, sa), .integer(bb, sb)):
            if ba == bb {
                // same-bits, different sign. (Reaching here means sa != sb; the
                // equal-lattice branch above already handled matching signs.)
                if a.confidence != b.confidence {
                    // hard-vs-soft -> the hard side wins (it names signedness).
                    return a.confidence ? a : b
                }
                if a.confidence {
                    // HARD-vs-HARD conflicting signedness: neither side can be
                    // trusted to override the other, so picking either could render
                    // a WRONG signedness. Correctness over coverage: resolve to
                    // unknown and keep the builder's existing string.
                    return InferredLocalTypeFact(lattice: .unknown, confidence: false)
                }
                // both soft: deterministic, order-independent default -> signed.
                return InferredLocalTypeFact(lattice: .integer(bits: ba, signed: true), confidence: false)
            } else {
                // different bits -> prefer hard-narrow, else the wider.
                if a.confidence != b.confidence {
                    return a.confidence ? a : b
                }
                let wider = ba >= bb ? a : b
                return wider
            }
        case (.pointer, .integer(64, _)), (.integer(64, _), .pointer):
            // pointer vs 64-bit integer -> pointer (preserve the pointer's exact
            // spelling, e.g. "const char *").
            return a.lattice == .pointer ? a : b
        case (.bool, .integer(32, _)), (.integer(32, _), .bool):
            // bool vs 32-bit integer -> bool.
            return a.lattice == .bool ? a : b
        case (.floatingPoint, .integer), (.integer, .floatingPoint):
            // float vs integer -> irreconcilable.
            return InferredLocalTypeFact(lattice: .unknown, confidence: false)
        default:
            // Any other conflict -> unknown (keep existing).
            return InferredLocalTypeFact(lattice: .unknown, confidence: false)
        }
    }

    // MARK: - Write-back gate

    /// The refined C spelling to write, or nil to keep `existing`.
    ///
    /// Writes only when the met type is non-unknown AND strictly more specific
    /// than the existing string AND does not widen/loosen an already-hard,
    /// already-narrower builder type.
    private static func refinedString(
        from fact: InferredLocalTypeFact,
        existing: String
    ) -> String? {
        guard fact.lattice != .unknown else { return nil }
        let existingFact = typeStringToLattice(existing)

        // Already identical lattice: only rewrite to carry a more-specific exact
        // spelling (e.g. size_t / const char *) we did not already have. Never
        // rewrite when the spelling would be unchanged or less specific.
        if existingFact.lattice == fact.lattice {
            let candidate = fact.exactTypeString ?? latticeToTypeString(fact.lattice)
            guard let candidate, candidate != existing else { return nil }
            // Do not overwrite a hard builder type with a wider/looser spelling.
            if existingFact.confidence, !fact.confidence { return nil }
            // Only adopt the exact spelling; otherwise keep existing.
            return fact.exactTypeString != nil ? candidate : nil
        }

        // Integer -> integer refinement: ONLY change signedness at the SAME
        // bit-width the builder already chose. The builder's width is treated as
        // authoritative (a register-spilled `strh` deliberately keeps the wider
        // register width over the 2-byte encoding); the pass must never widen or
        // narrow it. A signedness refinement therefore requires a hard fact whose
        // width matches the existing width exactly.
        if case let .integer(eb, _) = existingFact.lattice,
           case let .integer(fb, _) = fact.lattice {
            guard fact.confidence, eb == fb else { return nil }
            return fact.exactTypeString ?? latticeToTypeString(fact.lattice)
        }

        // Cross-kind refinement (integer -> pointer / integer -> bool) requires a
        // hard fact; never act on soft cross-kind evidence.
        guard fact.confidence else { return nil }
        return fact.exactTypeString ?? latticeToTypeString(fact.lattice)
    }
}
