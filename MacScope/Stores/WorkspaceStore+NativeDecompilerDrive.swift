import Foundation

@MainActor
final class WorkspaceNativeDecompilerDriveContext {
    var machine = NativeDecompilerDriveStateMachine()
    var session: (any NativeDecompilerWorkspaceSessionHandling)?
    var sessionIdentity: ObjectIdentifier?
    var bindingID: NativeDriveHandlerBindingID?
    var driveGeneration: UInt64 = 0
    var readinessEpoch: UInt64?
    var readinessOwner: NativeDriveImageOwner?
    var pendingProjectionFailure: (
        diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    )?
    var isCounterExhausted = false
}

@MainActor
extension WorkspaceStore {
    func noteNativePatchMutation(imageSlots: Set<ImageSlot>) {
        guard let target = nativeDriveTarget().resolved,
              imageSlots.contains(target.owner.imageSlot) else { return }
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.patchedBytesChanged)) ?? []
        )
    }

    func noteNativeSemanticAuthoringMutation(
        imageSlots: Set<ImageSlot>,
        schedulesStructuralReanalysis: Bool
    ) {
        guard let target = nativeDriveTarget().resolved,
              imageSlots.contains(target.owner.imageSlot) else { return }
        updateNativeSemanticInput(
            for: target,
            deferUntilStructuralLanding: schedulesStructuralReanalysis
        )
    }

    func requestNativeDecompiler() {
        ensureNativeDriveContext()
        let target = nativeDriveTarget()
        if let resolved = target.resolved {
            updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
        }
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.request)) ?? []
        )
    }

    func retryNativeDecompiler() {
        ensureNativeDriveContext()
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.retry)) ?? []
        )
    }

    func refreshNativeDecompiler() {
        ensureNativeDriveContext()
        let target = nativeDriveTarget()
        if let resolved = target.resolved {
            updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
        }
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.refresh)) ?? []
        )
    }

    func cancelNativeDecompiler() {
        ensureNativeDriveContext()
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.cancel)) ?? []
        )
    }

    static func nativeDecompilerSemanticOverrideChanged(
        from previous: AddressOverride?,
        to value: AddressOverride?
    ) -> Bool {
        previous?.customName != value?.customName
            || previous?.signature != value?.signature
            || previous?.appliedTypeName != value?.appliedTypeName
    }

    func establishNativeDriveContext(origin: NativeDriveOrigin) {
        let drive = nativeDecompilerDriveContext
        guard !drive.isCounterExhausted else { return }
        let advanced = drive.driveGeneration.addingReportingOverflow(1)
        guard !advanced.overflow, advanced.partialValue != 0 else {
            drive.isCounterExhausted = true
            interpretNativeDriveEffects(
                (try? drive.machine.handle(.counterExhausted(.drive))) ?? []
            )
            return
        }
        drive.driveGeneration = advanced.partialValue
        drive.readinessEpoch = nil
        drive.readinessOwner = nil
        drive.pendingProjectionFailure = nil
        drive.session?.cancelOutstanding()
        let context = NativeDriveContext(
            documentID: documentID,
            workspaceID: workspaceID,
            driveGeneration: drive.driveGeneration,
            origin: origin
        )
        interpretNativeDriveEffects(
            (try? drive.machine.handle(.establish(context))) ?? []
        )
    }

    func finishNativeDriveInstallation() {
        ensureNativeDriveContext()
        let target = nativeDriveTarget()
        nativeDecompilerDriveContext.readinessEpoch = nativeDecompilerRehydrationEpoch
        nativeDecompilerDriveContext.readinessOwner = target.seed?.owner

        if let resolved = target.resolved {
            updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
            interpretNativeDriveEffects(
                (try? nativeDecompilerDriveContext.machine.handle(
                    .installTarget(seed: target.seed, resolved: resolved, waitReason: nil)
                )) ?? []
            )
        } else if let seed = target.seed {
            interpretNativeDriveEffects(
                (try? nativeDecompilerDriveContext.machine.handle(
                    .installTarget(
                        seed: seed,
                        resolved: nil,
                        waitReason: .selectedOwnerNeedsRehydration
                    )
                )) ?? []
            )
        } else {
            // No restored selection is an explicit abstention, not an invitation to choose the
            // first function on the user's behalf.
            interpretNativeDriveEffects(
                (try? nativeDecompilerDriveContext.machine.handle(
                    .installTarget(seed: nil, resolved: nil, waitReason: nil)
                )) ?? []
            )
        }
    }

    func bindNativeDecompilerSession(
        _ session: any NativeDecompilerWorkspaceSessionHandling
    ) {
        let drive = nativeDecompilerDriveContext
        let identity = ObjectIdentifier(session)
        guard drive.sessionIdentity != identity else { return }

        drive.session?.terminateSession()
        drive.session = session
        drive.sessionIdentity = identity
        let bindingID = NativeDriveHandlerBindingID(rawValue: UUID())
        drive.bindingID = bindingID
        ensureNativeDriveContext()
        interpretNativeDriveEffects(
            (try? drive.machine.handle(.bind(bindingID))) ?? []
        )
        if let pending = drive.pendingProjectionFailure,
           nativeDriveSubmissionIsCurrent(pending.ticket) {
            session.publishAuthoredProjectionFailure(
                pending.diagnostic,
                ticket: pending.ticket
            )
            drive.pendingProjectionFailure = nil
        }
        if case .installing = drive.machine.state {
            finishNativeDriveInstallation()
        }
    }

    func acceptNativeReadiness(
        imageSlot: ImageSlot,
        binaryID: UUID,
        rehydrationEpoch: UInt64
    ) {
        let drive = nativeDecompilerDriveContext
        let owner = NativeDriveImageOwner(imageSlot: imageSlot, binaryID: binaryID)
        guard rehydrationEpoch == nativeDecompilerRehydrationEpoch,
              drive.readinessEpoch == rehydrationEpoch,
              drive.readinessOwner == owner,
              let resolved = nativeDriveTarget().resolved,
              resolved.owner == owner,
              nativeDriveContextIsCurrent(resolved.context) else { return }

        updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
        interpretNativeDriveEffects(
            (try? drive.machine.handle(.selectedOwnerReady(resolved))) ?? []
        )
    }

    func rejectNativeReadiness(
        imageSlot: ImageSlot,
        binaryID: UUID,
        rehydrationEpoch: UInt64,
        failure: NativeDriveReadinessFailure
    ) {
        let drive = nativeDecompilerDriveContext
        let owner = NativeDriveImageOwner(imageSlot: imageSlot, binaryID: binaryID)
        guard rehydrationEpoch == nativeDecompilerRehydrationEpoch,
              drive.readinessEpoch == rehydrationEpoch,
              drive.readinessOwner == owner,
              nativeDriveCurrentContextIsCurrent else { return }
        interpretNativeDriveEffects(
            (try? drive.machine.handle(.selectedOwnerFailed(failure))) ?? []
        )
    }

    func reconcileNativeDecompilerDrive(reason: NativeDriveReconcileReason) {
        ensureNativeDriveContext()
        let target = nativeDriveTarget()
        let drive = nativeDecompilerDriveContext

        switch reason {
        case .acceptedStructuralAnalysis:
            if let resolved = target.resolved {
                updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
            }
            // A zero or ambiguous exact match must abstain with .noExactFunction.
            interpretNativeDriveEffects(
                (try? drive.machine.handle(.acceptedStructuralLanding(target.resolved))) ?? []
            )
        case .selectionOrFocusChanged:
            interpretNativeDriveEffects(
                (try? drive.machine.handle(
                    .targetChanged(seed: target.seed, resolved: target.resolved)
                )) ?? []
            )
            if let resolved = target.resolved {
                updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
            }
        case .installationCompleted:
            finishNativeDriveInstallation()
        case .handlerBound:
            if let bindingID = drive.bindingID {
                interpretNativeDriveEffects(
                    (try? drive.machine.handle(.bind(bindingID))) ?? []
                )
            }
        case .selectedOwnerReady:
            if let owner = drive.readinessOwner, let epoch = drive.readinessEpoch {
                acceptNativeReadiness(
                    imageSlot: owner.imageSlot,
                    binaryID: owner.binaryID,
                    rehydrationEpoch: epoch
                )
            }
        case .semanticAuthoring:
            if let resolved = target.resolved {
                updateNativeSemanticInput(for: resolved, deferUntilStructuralLanding: false)
            }
        case .manualRequest:
            interpretNativeDriveEffects((try? drive.machine.handle(.request)) ?? [])
        case .manualRefresh:
            interpretNativeDriveEffects((try? drive.machine.handle(.refresh)) ?? [])
        }
    }

    func retireNativeDecompilerDrive(reason: NativeDriveRetirementReason) {
        interpretNativeDriveEffects(
            (try? nativeDecompilerDriveContext.machine.handle(.retire(reason))) ?? []
        )
    }

    func terminateNativeDecompilerSession() {
        retireNativeDecompilerDrive(reason: .sessionTerminated)
        nativeDecompilerDriveContext.session?.terminateSession()
        nativeDecompilerDriveContext.session = nil
        nativeDecompilerDriveContext.sessionIdentity = nil
        nativeDecompilerDriveContext.bindingID = nil
    }

    private func ensureNativeDriveContext() {
        if case .idle = nativeDecompilerDriveContext.machine.state {
            establishNativeDriveContext(origin: .interactiveAdoption)
        }
    }

    private var nativeDriveCurrentContextIsCurrent: Bool {
        switch nativeDecompilerDriveContext.machine.state {
        case .exhausted:
            return false
        case let .installing(context),
             let .waitingForReadiness(context, _, _),
             let .ready(context, _),
             let .retired(context, _):
            return nativeDriveContextIsCurrent(context)
        case let .submitted(ticket):
            return nativeDriveContextIsCurrent(ticket.target.context)
        case .idle:
            return false
        }
    }

    private func nativeDriveContextIsCurrent(_ context: NativeDriveContext) -> Bool {
        context.documentID == documentID
            && context.workspaceID == workspaceID
            && context.driveGeneration == nativeDecompilerDriveContext.driveGeneration
    }

    private func nativeDriveTarget() -> (
        seed: NativeDriveTargetSeed?,
        resolved: NativeDriveResolvedTarget?
    ) {
        let pending = nativeDecompilerPendingSelection
        let selection = selectedImageAddress ?? pending.map {
            ImageAddress(slot: $0.slot, address: $0.address)
        }
        guard let context = nativeDriveContext,
              let selection,
              selection.slot == focusedImageSlot,
              let binary = snapshot.binary(in: selection.slot) else {
            return (nil, nil)
        }
        if let pending, pending.binaryID != binary.id {
            return (nil, nil)
        }
        let owner = NativeDriveImageOwner(imageSlot: selection.slot, binaryID: binary.id)
        let seed = NativeDriveTargetSeed(
            context: context,
            owner: owner,
            selectedAddress: selection.address
        )
        guard pending == nil,
              let analysis = snapshot.analysis(in: selection.slot),
              !nativeDriveOwnerNeedsRehydration(analysis),
              let fingerprint = analysis.analysisInputFingerprint?.overallSHA256,
              let function = NativeDecompilerExactFunctionResolver.resolve(
                selectedAddress: selection.address,
                functions: analysis.functions
              ) else {
            return (seed, nil)
        }
        return (
            seed,
            NativeDriveResolvedTarget(
                context: context,
                owner: owner,
                functionID: function.id,
                functionStart: function.startAddress,
                analysisFingerprintSHA256: fingerprint
            )
        )
    }

    private var nativeDriveContext: NativeDriveContext? {
        switch nativeDecompilerDriveContext.machine.state {
        case .exhausted:
            return nil
        case let .installing(context),
             let .waitingForReadiness(context, _, _),
             let .ready(context, _),
             let .retired(context, _):
            return context
        case let .submitted(ticket):
            return ticket.target.context
        case .idle:
            return nil
        }
    }

    private func nativeDriveOwnerNeedsRehydration(_ analysis: ImageAnalysis) -> Bool {
        !analysis.imageBytes.isEmpty
            && analysis.sections.isEmpty
            && analysis.machOMetadata == nil
    }

    private func updateNativeSemanticInput(
        for target: NativeDriveResolvedTarget,
        deferUntilStructuralLanding: Bool
    ) {
        let semantic = NativeDecompilerAuthoredInputProjector.project(
            workspace: snapshot,
            imageSlot: target.owner.imageSlot,
            functionID: target.functionID
        )
        let drive = nativeDecompilerDriveContext
        let effects =
            (try? drive.machine.handle(
                .semanticInputChanged(
                    semantic,
                    deferUntilStructuralLanding: deferUntilStructuralLanding
                )
            )) ?? []
        if case .valid = semantic {
            // A queued diagnostic belongs to an older semantic generation. It must not survive
            // long enough to publish beside the valid replacement when a session binds later.
            drive.pendingProjectionFailure = nil
        }
        interpretNativeDriveEffects(effects)
    }

    private func interpretNativeDriveEffects(_ effects: [NativeDriveEffect]) {
        let drive = nativeDecompilerDriveContext
        for effect in effects {
            switch effect {
            case .invalidateOutstanding, .cancelOutstanding:
                drive.session?.cancelOutstanding()
            case let .submit(ticket, cacheLookupPolicy):
                guard let session = drive.session,
                      nativeDriveSubmissionIsCurrent(ticket) else { continue }
                session.submit(
                    NativeDecompilerWorkspaceSubmission(
                        ticket: ticket,
                        snapshot: snapshot,
                        snapshotRevision: nativeDecompilerSnapshotRevision,
                        imageSlot: ticket.target.owner.imageSlot,
                        functionID: ticket.target.functionID,
                        cacheLookupPolicy: cacheLookupPolicy
                    )
                )
            case let .retry(frozenTicket):
                guard let session = drive.session,
                      nativeDriveSubmissionIsCurrent(frozenTicket),
                      case let .submitted(currentTicket) = drive.machine.state,
                      currentTicket == frozenTicket else { continue }
                session.retry(
                    NativeDecompilerWorkspaceRetry(
                        frozenTicket: frozenTicket,
                        snapshot: snapshot,
                        snapshotRevision: nativeDecompilerSnapshotRevision,
                        imageSlot: frozenTicket.target.owner.imageSlot,
                        functionID: frozenTicket.target.functionID
                    )
                )
            case let .publishProjectionFailure(diagnostic, ticket):
                guard nativeDriveSubmissionIsCurrent(ticket) else { continue }
                if let session = drive.session {
                    session.publishAuthoredProjectionFailure(diagnostic, ticket: ticket)
                } else {
                    drive.pendingProjectionFailure = (diagnostic, ticket)
                }
            case let .publishReadinessFailure(failure):
                drive.session?.cancelOutstanding()
                switch failure {
                case .analysisUnavailable:
                    lastIssue = "Native decompilation is unavailable because analysis could not be restored."
                case let .rehydrationFailed(code):
                    lastIssue = "Native decompilation is unavailable because analysis restore failed (\(code))."
                case .counterExhausted:
                    // D retains the typed fail-closed fact. E3A owns its eventual public copy and
                    // presentation-state mapping, so this lane deliberately publishes no banner.
                    break
                }
            }
        }
    }

    private func nativeDriveSubmissionIsCurrent(_ ticket: NativeDriveSubmissionTicket) -> Bool {
        guard nativeDriveContextIsCurrent(ticket.target.context),
              let current = nativeDriveTarget().resolved else { return false }
        return current.owner == ticket.target.owner
            && current.functionID == ticket.target.functionID
            && current.functionStart == ticket.target.functionStart
            && current.analysisFingerprintSHA256 == ticket.target.analysisFingerprintSHA256
    }
}
