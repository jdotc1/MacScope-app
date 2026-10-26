import Foundation

struct ObjCSignatureDeclarationBatch {
    var generation = UUID()
    var binaryID: UUID
    var imageUUID: UUID
    var selectedSliceIndex: Int?
    var machOSelectedSliceFact: MachOSelectedSliceFact? = nil
    var architecture: String
    var sdkVersion: String?
    var documentInstallationID: UUID
    var seal: DSYMDebugArtifactSeal
    var declarations: [UInt64: DWARFFunctionDeclaration]
}

extension WorkspaceStore {
    /// Formats only facts held by the slot's image, independently of candidate ownership.
    func objcCandidateSliceLabel(in slot: ImageSlot) -> String {
        guard let binary = snapshot.binary(in: slot) else { return "unavailable" }
        let slice = binary.machOSelectedSliceFact?.displayLabel ?? "slice unknown"
        guard let architecture = binary.artifactIdentity?.architectureVariant else { return slice }
        return "\(architecture.rawValue) · \(slice)"
    }

    /// Copies one validated candidate into the editor-local draft. This is deliberately not a
    /// persistence operation: the existing Save action remains the only undoable authoring seam.
    func applyObjCSignatureCandidate(
        _ candidate: ObjCSignatureCandidate,
        to draft: inout SignatureEditorRequest
    ) {
        guard objcSignatureCandidatePresentationIsCurrent(candidate, draft: draft),
              candidate.canAccept,
              let currentContext = objcSignatureCandidateContext(
                  at: draft.address,
                  in: draft.imageSlot
              ),
              ObjCSignatureCandidateService.validateCurrentContext(
                  candidate,
                  current: currentContext
              ) == nil,
              case .unique(let match) = objcMethod(at: draft.address, in: draft.imageSlot),
              match.owner == candidate.context.methodOwner,
              match.method.selector == candidate.selector,
              match.owner.isClassMethod == candidate.isClassMethod
        else {
            lastIssue = "The Objective-C signature candidate is invalid or no longer belongs to this image and method."
            return
        }
        guard let returnType = candidate.returnField.type else { return }
        draft.appliedObjCCandidateContext = candidate.context
        draft.returnType = returnType
        draft.args = candidate.parameters.map { parameter in
            ArgDraft(
                index: parameter.index,
                name: parameter.name,
                type: parameter.field.type ?? "",
                provenance: .user
            )
        }
        draft.parameterListIntent = .authoritative
        draft.variadicState = .fixed
    }

    func objcSignatureCandidates(
        at address: UInt64,
        in slot: ImageSlot,
        hypothesis: ObjCSignatureHypothesis? = nil
    ) -> [ObjCSignatureCandidate] {
        guard case .unique(let match) = objcMethod(at: address, in: slot),
              let context = objcSignatureCandidateContext(at: address, in: slot) else {
            return []
        }
        let method = match.method
        let catalog = snapshot.typeCatalog(in: slot)
        let knownNominalTypes = Set(catalog.entries.map(\.name))
            .union(Set(["NSObject", "NSString", "NSError", "NSArray", "NSDictionary", "NSNumber"]))
        let declaration = qualifiedObjCDeclaration(context: context)
        let sites = objcCallSites(selector: method.selector, in: slot)
        var candidate = ObjCSignatureCandidateService.makeCandidate(.init(
            context: context,
            method: method,
            knownNominalTypes: knownNominalTypes,
            declaration: declaration,
            hypothesis: hypothesis,
            observations: sites.map {
                .init(position: .returnValue, type: $0.returnShape.type,
                      widthBits: $0.returnShape.widthBits, source: $0.source,
                      address: $0.address, context: context)
            }
        ))
        candidate.evidence += sites.map { site in
            .init(id: "call-\(site.address)", kind: "Observation",
                  source: "\(site.source) · \(site.address.hexAddress)",
                  detail: "Selector \(site.selector) at selref \(site.selrefAddress.hexAddress); receiver: \(site.receiverShape ?? "Unknown"); explicit argument shapes: \(site.argumentShapes.map { $0.value ?? "Unknown" }.joined(separator: ", ")); return type: Unknown")
        }
        if sites.isEmpty {
            candidate.evidence.append(.init(id: "calls", kind: "Observation", source: "Structured MacIR",
                detail: "No matching call-site evidence in the bounded caller set"))
        }
        return [candidate]
    }

    func objcMethod(at address: UInt64, in slot: ImageSlot) -> ObjCMethodOwnerLookup {
        guard let analysis = snapshot.analysis(in: slot) else { return .none }
        struct Key: Hashable {
            var owner: ObjCMethodOwner
            var selector: String
        }
        var seen: Set<Key> = []
        var matches: [ObjCMethodOwnerLookup.Match] = []
        func collect(_ methods: [ObjCMethod], owner: ObjCMethodOwner) {
            for var method in methods where method.implementation == address {
                guard seen.insert(Key(owner: owner, selector: method.selector)).inserted else { continue }
                // The container's method list determines the dispatch side.
                method.isClassMethod = owner.isClassMethod
                matches.append(.init(owner: owner, method: method))
            }
        }
        for objcClass in analysis.objcClasses {
            let container = ObjCMethodOwner.Container.objcClass(name: objcClass.name)
            collect(objcClass.classMethods, owner: .init(container: container, isClassMethod: true))
            collect(objcClass.instanceMethods, owner: .init(container: container, isClassMethod: false))
        }
        for category in analysis.objcCategories {
            let container = ObjCMethodOwner.Container.category(name: category.name, className: category.className)
            collect(category.classMethods, owner: .init(container: container, isClassMethod: true))
            collect(category.instanceMethods, owner: .init(container: container, isClassMethod: false))
        }
        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0])
        default: return .ambiguous(matches)
        }
    }

    func objcSignatureCandidateContext(
        at address: UInt64,
        in slot: ImageSlot
    ) -> ObjCSignatureCandidate.Context? {
        guard let binary = snapshot.binary(in: slot),
              case .unique(let match) = objcMethod(at: address, in: slot) else { return nil }
        let method = match.method
        return ObjCSignatureCandidate.Context(
            target: ImageAddress(slot: slot, address: address),
            ownerBinaryID: binary.id,
            architecture: binary.architecture,
            imageUUID: binary.metadata.uuid,
            imageSDKVersion: binary.metadata.sdkVersion,
            methodSelector: method.selector,
            methodIsClassMethod: method.isClassMethod,
            methodTypeEncoding: method.typeEncoding,
            selectedSliceIndex: binary.selectedSliceIndex,
            machOSelectedSliceFact: binary.machOSelectedSliceFact,
            declarationSourceGeneration: objcDeclarationSourceGenerations[slot],
            documentInstallationID: documentInstallationID,
            analysisGeneration: nativeDecompilerSnapshotRevision,
            methodOwner: match.owner
        )
    }

    func retainObjCSignatureDeclarations(_ result: DSYMImportResult, in slot: ImageSlot) {
        // Retire an earlier source even when the replacement lacks usable qualification.
        let generation = UUID()
        objcDeclarationSourceGenerations[slot] = generation
        objcSignatureDeclarations.removeValue(forKey: slot)
        cancelObjCSignatureInference()
        guard let binary = snapshot.binary(in: slot),
              let imageUUID = binary.metadata.uuid.flatMap(UUID.init(uuidString:)),
              UUID(uuidString: result.matchedUUID) == imageUUID,
              result.matchedSliceArchitecture == binary.architecture,
              let seal = result.debugArtifactSeal, seal.uuid == imageUUID else { return }
        objcSignatureDeclarations[slot] = .init(
            generation: generation, binaryID: binary.id, imageUUID: imageUUID, selectedSliceIndex: binary.selectedSliceIndex,
            machOSelectedSliceFact: binary.machOSelectedSliceFact,
            architecture: binary.architecture, sdkVersion: binary.metadata.sdkVersion,
            documentInstallationID: documentInstallationID, seal: seal,
            declarations: result.signatureDeclarations
        )
    }

    private func qualifiedObjCDeclaration(
        context: ObjCSignatureCandidate.Context
    ) -> ObjCSignatureDeclaration? {
        guard let batch = objcSignatureDeclarations[context.target.slot],
              batch.generation == context.declarationSourceGeneration,
              batch.binaryID == context.ownerBinaryID,
              batch.imageUUID == context.imageUUID.flatMap(UUID.init(uuidString:)),
              batch.selectedSliceIndex == context.selectedSliceIndex,
              batch.machOSelectedSliceFact == context.machOSelectedSliceFact,
              batch.architecture == context.architecture,
              batch.sdkVersion == context.imageSDKVersion,
              batch.documentInstallationID == documentInstallationID,
              let declaration = batch.declarations[context.target.address] else { return nil }
        let arity = context.methodSelector.filter { $0 == ":" }.count
        guard let parameters = declaration.explicitObjectiveCParameters(selectorArity: arity) else {
            return nil
        }
        return .init(source: .dwarf, selector: context.methodSelector,
                     returnType: declaration.returnType,
                     parameterTypes: parameters.map(\.type),
                     parameterNames: parameters.map { $0.name ?? "" },
                     sdkVersion: batch.sdkVersion, context: context,
                     sourceIdentity: "DWARF UUID \(batch.imageUUID.uuidString) · \(batch.architecture) · \(batch.machOSelectedSliceFact?.displayLabel ?? "slice unknown") · artifact \(batch.seal.selectedMachOSHA256)")
    }

    private func objcCallSites(selector: String, in slot: ImageSlot) -> [ObjCSignatureCallSiteEvidence.Site] {
        guard let analysis = snapshot.analysis(in: slot) else { return [] }
        let selrefs = Set(analysis.objcSelectors.filter { $0.value == selector }.map(\.key))
        guard !selrefs.isEmpty else { return [] }
        var functions: [MacIRFunction] = []
        var seen: Set<UInt64> = []
        var linkageNames: [UInt64: String] = [:]
        for symbol in analysis.symbols {
            if let address = symbol.address, let linkage = symbol.rawLinkageName {
                linkageNames[address] = linkage
            }
        }
        for symbol in analysis.indirectSymbols where !symbol.isLocal && !symbol.isAbsolute {
            if let name = symbol.symbolName { linkageNames[symbol.address] = name }
        }
        let symbolizer = BranchTargetSymbolizer(namesByAddress: linkageNames)
        for xref in analysis.xrefs where selrefs.contains(xref.to) {
            guard let function = snapshot.enclosingFunction(for: xref.from, in: slot),
                  seen.insert(function.startAddress).inserted else { continue }
            let body = analysis.exportInstructionIndex().instructions(
                start: function.startAddress, end: function.endAddress
            )
            guard body.count <= ObjCSignatureCallSiteEvidence.maximumInstructionsPerFunction else { continue }
            // Loader linkage names only: user edits to display names cannot create dispatch facts.
            functions.append(PseudocodePrinter().buildFunction(
                functionName: function.name, startAddress: function.startAddress,
                objcSelectors: analysis.objcSelectors, constantStrings: analysis.constantStrings,
                instructions: body.map { symbolizer.symbolized($0, callsOnly: true) }
            ))
            if functions.count == ObjCSignatureCallSiteEvidence.maximumFunctions { break }
        }
        return ObjCSignatureCallSiteEvidence.collect(functions: functions, selector: selector)
    }

    func cancelObjCSignatureInference() {
        objcSignatureInferenceTask?.cancel()
        objcSignatureInferenceTask = nil
        if signatureEditorRequest?.objcCandidates.first?.hypothesisState == .pending {
            signatureEditorRequest?.objcCandidates[0].hypothesisState = .unavailable
        }
    }

    func cancelStaleObjCSignatureInference() {
        guard let request = signatureEditorRequest, let candidate = request.objcCandidates.first else { return }
        if candidate.context != objcSignatureCandidateContext(at: request.address, in: request.imageSlot) {
            cancelObjCSignatureInference()
        }
    }

    func startObjCSignatureInference(coordinator: (any Phase2AssistantInferenceCoordinating)?) {
        guard var presentation = signatureEditorRequest,
              let candidate = presentation.objcCandidates.first,
              candidate.hypothesisState == .unavailable,
              let coordinator else { return }
        cancelObjCSignatureInference()
        presentation.objcCandidates[0].hypothesisState = .pending
        signatureEditorRequest = presentation
        let selection = selectedImageAddress
        let context = candidate.context
        let evidence = "Image \(context.ownerBinaryID), UUID \(context.imageUUID ?? "unknown"), architecture \(context.architecture), \(context.machOSelectedSliceFact?.displayLabel ?? "slice unknown"), SDK \(context.imageSDKVersion ?? "unknown"), declaration generation \(context.declarationSourceGeneration?.uuidString ?? "none"), selector \(candidate.displayName), encoding \(context.methodTypeEncoding ?? "unknown").\n"
            + candidate.evidence.map { "\($0.kind) — \($0.source): \($0.detail)" }.joined(separator: "\n")
        let workspace = phase2ReadLedger.workspace
        let revision = phase2ReadLedger.workspaceRevision
        let presentationID = presentation.id
        objcSignatureInferenceTask = Task { [weak self] in
            let result: ObjCSignatureHypothesisInference.Result
            do {
                let request = try ObjCSignatureHypothesisInference.makeRequest(
                    document: workspace.document, workspace: workspace, lifecycleRevision: revision,
                    evidence: evidence
                )
                result = await ObjCSignatureHypothesisInference().run(request: request, coordinator: coordinator)
            } catch {
                result = .failed("The bounded request could not be prepared.")
            }
            guard !Task.isCancelled, let self,
                  self.signatureEditorRequest?.id == presentationID,
                  self.selectedImageAddress == selection,
                  self.objcSignatureCandidateContext(at: context.target.address, in: context.target.slot) == context else { return }
            switch result {
            case .available(let hypothesis):
                self.signatureEditorRequest?.objcCandidates = self.objcSignatureCandidates(
                    at: context.target.address, in: context.target.slot, hypothesis: hypothesis
                )
            case .unavailable, .cancelled:
                self.signatureEditorRequest?.objcCandidates[0].hypothesisState = .unavailable
            case .failed(let reason):
                self.signatureEditorRequest?.objcCandidates[0].hypothesisState = .failed(reason)
            }
            self.objcSignatureInferenceTask = nil
        }
    }
}
