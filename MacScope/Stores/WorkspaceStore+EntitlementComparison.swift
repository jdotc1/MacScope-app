import Foundation

extension WorkspaceStore {
    var entitlementComparisonArchitectures: [String] {
        Set(snapshot.binaries.compactMap(entitlementArchitecture)).sorted()
    }

    private func entitlementArchitecture(_ binary: BinaryImage) -> String? {
        if let artifact = binary.artifactIdentity {
            return artifact.architectureVariant == .other ? nil : artifact.architectureVariant.rawValue
        }
        // Without artifact evidence only exact known architecture labels are eligible.
        return ["arm64", "arm64e", "x86_64", "x86_64h"].contains(binary.architecture) ? binary.architecture : nil
    }

    func entitlementComparisonContext(_ selection: EntitlementComparisonSelection) -> EntitlementComparisonContext {
        func source(_ slot: ImageSlot?) -> EntitlementComparisonSource? {
            guard let slot, let binary = snapshot.binary(in: slot),
                  let generation = phase2ReadLedger.imageIdentity(in: slot, snapshot: snapshot) else { return nil }
            return .init(slot: slot, path: binary.path,
                         imageUUID: binary.artifactIdentity?.uuid,
                         sliceDigest: binary.artifactIdentity?.selectedSliceSHA256,
                         architecture: entitlementArchitecture(binary),
                         generation: generation)
        }
        return .init(selection: selection, workspace: phase2ReadLedger.workspace,
                     sourceRevision: nativeDecompilerSnapshotRevision,
                     previous: source(selection.previous), current: source(selection.current),
                     loading: isImporting || isReanalyzing,
                     openRequest: binaryOpenState?.id)
    }

    func captureEntitlementComparison(_ selection: EntitlementComparisonSelection) -> EntitlementComparisonCapture {
        let context = entitlementComparisonContext(selection)
        return .init(context: context,
                     previous: context.previous.map { entitlementSnapshot($0, architecture: selection.architecture) },
                     current: context.current.map { entitlementSnapshot($0, architecture: selection.architecture) })
    }

    private func entitlementSnapshot(_ source: EntitlementComparisonSource,
                                     architecture: String) -> EntitlementSnapshot {
        func unavailable(_ reason: String) -> EntitlementSnapshot {
            .init(source: source, requestedArchitecture: architecture,
                  declarations: .init(state: .unavailable, values: nil, reason: reason, format: nil))
        }
        guard !architecture.isEmpty else { return unavailable("Select a common architecture explicitly.") }
        guard source.architecture == architecture else {
            return unavailable("The loaded image slot does not contain the selected architecture \(architecture).")
        }
        guard let bytes = snapshot.analysis(in: source.slot)?.imageBytes, !bytes.isEmpty else {
            return unavailable("Selected-slice bytes are unavailable.")
        }
        // Retained bytes must be a thin Mach-O. Never let the parser choose a fat-container slice.
        guard bytes.starts(with: [0xcf, 0xfa, 0xed, 0xfe]) else {
            return unavailable("The retained input is not a supported thin Mach-O slice.")
        }
        do {
            let file = try MachOParser().parse(bytes, options: .init(
                recoverStringLiterals: false, recoverObjectiveCMetadata: false, recoverSwiftMetadata: false))
            let variant = MachOSliceArchitectureVariant.classify(
                rawCPUType: file.header.cpuType, rawCPUSubtype: file.header.cpuSubtype)
            guard variant != .other, variant.rawValue == architecture else {
                return unavailable("The retained slice architecture differs from the requested architecture.")
            }
            let declarations: ExactDeclaredEntitlements
            if file.codeSignature == nil && !file.loadCommands.contains(where: {
                $0.command == MachOConstants.loadCommandCodeSignature
            }) {
                declarations = .init(state: .notPresent, values: nil, reason: nil, format: nil)
            } else {
                declarations = EntitlementValueReader.readExact(signature: file.codeSignature, sliceBytes: bytes)
            }
            return .init(source: source, requestedArchitecture: architecture, declarations: declarations)
        } catch {
            return unavailable("The retained Mach-O slice could not be parsed: \(error.localizedDescription)")
        }
    }
}
