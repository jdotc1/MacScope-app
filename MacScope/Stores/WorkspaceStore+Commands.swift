import Foundation

/// One immutable resolution of the current interactive command owner. Selection-dependent command
/// enablement and execution consume this same value, so a sibling image's colliding bare address
/// can never supply evidence or receive the mutation.
private struct WorkspaceCommandExecutionTarget {
    let location: ImageAddress?
    let ownerBinaryID: UUID?
    let instruction: InstructionRow?
    let enclosingFunction: FunctionSummary?
    let patch: BytePatch?
    let bookmark: Bookmark?
    let isUndefined: Bool
    let isMarkedAsProcedure: Bool
}

/// Typed command routing for `WorkspaceCommand`. Both `isEnabled` and `perform` are
/// exhaustive switches, so the compiler refuses to build a command that has no handler —
/// the dead-menu-command class (a visible item posting a notification no one observes) is
/// structurally impossible here. A disabled command is a guarded, explained no-op; an
/// enabled command always performs a real, undoable effect.
extension WorkspaceStore {
    /// Whether `command` can run given the current document/selection. The menu disables
    /// the item when false; `perform` also guards on it.
    func isEnabled(_ command: WorkspaceCommand) -> Bool {
        isEnabled(command, target: commandExecutionTarget())
    }

    private func isEnabled(
        _ command: WorkspaceCommand,
        target: WorkspaceCommandExecutionTarget
    ) -> Bool {
        switch command {
        case .markAsUndefined, .markAsProcedure, .replaceWithNOP, .patchBytes, .assembleInstruction:
            return target.instruction != nil
        case .addBookmark:
            return target.location != nil
        case .removeBookmark:
            return target.bookmark != nil
        case .clearPatch:
            return target.patch != nil
        case .findNext, .findPrevious:
            return !(searchCursor?.isEmpty ?? true)
        case .nextProcedure, .previousProcedure:
            // Frozen compatibility debt: these tables remain the flat primary projection in WS-17.
            return !snapshot.functions.isEmpty
        case .topOfProcedure:
            return target.enclosingFunction != nil
        case .nextSection, .previousSection:
            // Frozen compatibility debt: broader section navigation is deferred.
            return !snapshot.sections.isEmpty
        case .nextXRef, .previousXRef:
            // The orbit remains focus-bound and is cleared when image focus changes.
            // Resolve its referrers in the same image as the validated selection.
            guard let location = target.location else { return false }
            if let cursor = xrefCursor, cursor.covers(location.address), !cursor.isEmpty { return true }
            return !snapshot.effectiveXRefs(to: location.address, in: location.slot).isEmpty
        case .copyAddress:
            return target.location != nil
        case .copyHexString:
            return target.instruction.map { !$0.bytes.isEmpty } ?? false
        case .nativeRequest, .nativeRefresh:
            return nativeCommandHasExactTarget
        case .nativeRetry:
            if case .submitted = nativeDecompilerDriveContext.machine.state {
                return nativeCommandHasExactTarget
            }
            return false
        case .nativeCancel:
            if case .submitted = nativeDecompilerDriveContext.machine.state {
                return true
            }
            return false
        }
    }

    /// Executes `command` ONLY when `note` targets this store (WS-2 multi-document routing). The
    /// typed-command router runs per-window, so this is the guard that keeps a command addressed
    /// to the focused document from mutating every open window. Extracted so the exact production
    /// decision is unit-testable (a view modifier's `onReceive` is not).
    func perform(_ command: WorkspaceCommand, ifTargetedBy note: Notification) {
        guard commandTargetsSelf(note) else { return }
        perform(command)
    }

    /// Executes `command` if enabled, routing to the existing (undoable, analysis-driving)
    /// store mutations. A disabled command surfaces a hint via `lastIssue` rather than
    /// doing nothing silently.
    func perform(_ command: WorkspaceCommand) {
        let target = commandExecutionTarget()
        guard isEnabled(command, target: target) else {
            lastIssue = "“\(command.title)” isn’t available right now."
            return
        }
        if commandRequiresExactSelectionOwner(command),
           target.location != selectedImageAddress {
            lastIssue = "“\(command.title)” isn’t available right now."
            return
        }
        switch command {
        case .markAsUndefined:
            guard let location = target.location else { return }
            applyCommandOverride(
                at: location,
                actionName: target.isUndefined ? "Clear Undefined" : "Mark as Undefined"
            ) { $0.isUndefined = !target.isUndefined }
        case .markAsProcedure:
            guard let location = target.location else { return }
            applyCommandOverride(
                at: location,
                actionName: target.isMarkedAsProcedure ? "Clear Function" : "Mark as Function"
            ) { $0.markAsProcedure = !target.isMarkedAsProcedure }
        case .addBookmark:
            if let location = target.location {
                addBookmark(at: location.address, name: "")
            }
        case .removeBookmark:
            if let location = target.location {
                removeBookmark(at: location.address)
            }
        case .patchBytes:
            pendingPatchBytesRequest = target.location.map {
                PatchBytesRequest(target: $0, ownerBinaryID: target.ownerBinaryID)
            }
        case .assembleInstruction:
            pendingAssembleRequest = target.location.map {
                AssembleRequest(target: $0, ownerBinaryID: target.ownerBinaryID)
            }
        case .replaceWithNOP:
            if let location = target.location {
                replaceCommandTargetWithNOP(location)
            }
        case .clearPatch:
            if let location = target.location {
                applyCommandOverride(at: location, actionName: "Clear Patch") { $0.patch = nil }
            }
        case .findNext:
            findNext()
        case .findPrevious:
            findPrevious()
        case .nextProcedure:
            navigateOrIssue(AddressNavigation.nextStart(after: selectedAddress,
                                                        in: snapshot.functions.map(\.startAddress)),
                            "No next function.")
        case .previousProcedure:
            navigateOrIssue(AddressNavigation.previousStart(before: selectedAddress,
                                                            in: snapshot.functions.map(\.startAddress)),
                            "No previous function.")
        case .topOfProcedure:
            if let location = target.location,
               let top = target.enclosingFunction?.startAddress {
                if snapshot.binary(in: location.slot) != nil {
                    _ = goToAddress(top, in: location.slot)
                } else {
                    // Primary compatibility for binary-less deterministic/headless fixtures.
                    navigateToReference(top)
                }
            } else {
                lastIssue = "The selection is not inside a function."
            }
        case .nextSection:
            navigateOrIssue(AddressNavigation.nextStart(after: selectedAddress,
                                                        in: snapshot.sections.map(\.address)),
                            "No next section.")
        case .previousSection:
            navigateOrIssue(AddressNavigation.previousStart(before: selectedAddress,
                                                            in: snapshot.sections.map(\.address)),
                            "No previous section.")
        case .nextXRef:
            stepXRef(forward: true)
        case .previousXRef:
            stepXRef(forward: false)
        case .copyAddress:
            if let location = target.location {
                pasteboard.setString(location.address.hexAddress)
            }
        case .copyHexString:
            if let bytes = target.instruction?.bytes {
                pasteboard.setString(bytes)
            }
        case .nativeRequest:
            requestNativeDecompiler()
        case .nativeRetry:
            retryNativeDecompiler()
        case .nativeRefresh:
            refreshNativeDecompiler()
        case .nativeCancel:
            cancelNativeDecompiler()
        }
    }

    /// Resolves the qualified location and all command-visible evidence once. A stale/out-of-range
    /// selection or a selection whose owner is no longer the focused image produces no location;
    /// every dependent field therefore abstains without consulting flat primary projections.
    private func commandExecutionTarget() -> WorkspaceCommandExecutionTarget {
        let location: ImageAddress?
        if let selectedImageAddress,
           selectedImageAddress.slot == focusedImageSlot,
           commandOwnerExists(selectedImageAddress.slot),
           snapshot.containsLoadedAddress(
                selectedImageAddress.address,
                in: selectedImageAddress.slot
           ) {
            location = selectedImageAddress
        } else {
            location = nil
        }

        guard let location else {
            return WorkspaceCommandExecutionTarget(
                location: nil,
                ownerBinaryID: nil,
                instruction: nil,
                enclosingFunction: nil,
                patch: nil,
                bookmark: nil,
                isUndefined: false,
                isMarkedAsProcedure: false
            )
        }

        let analysis = snapshot.analysis(in: location.slot)
        let override = snapshot.addressOverrides[location]
        let authoredPatch = override?.patch
        return WorkspaceCommandExecutionTarget(
            location: location,
            ownerBinaryID: snapshot.binary(in: location.slot)?.id,
            instruction: analysis?.instructions.first { $0.address == location.address },
            enclosingFunction: snapshot.enclosingFunction(
                for: location.address,
                in: location.slot
            ),
            patch: (authoredPatch?.isEmpty ?? true) ? nil : authoredPatch,
            bookmark: snapshot.bookmarks.first {
                $0.imageSlot == location.slot && $0.address == location.address
            },
            isUndefined: override?.isUndefined ?? false,
            isMarkedAsProcedure: override?.markAsProcedure ?? false
        )
    }

    /// Real workspaces require both a binary and analysis bucket. The binary-less primary form is
    /// retained solely for long-standing deterministic/headless fixtures and primary compatibility.
    private func commandOwnerExists(_ slot: ImageSlot) -> Bool {
        guard snapshot.analysis(in: slot) != nil else { return false }
        if snapshot.binary(in: slot) != nil { return true }
        return snapshot.binaries.isEmpty && slot == snapshot.primarySlot
    }

    private func commandRequiresExactSelectionOwner(_ command: WorkspaceCommand) -> Bool {
        switch command {
        case .markAsUndefined, .markAsProcedure,
             .addBookmark, .removeBookmark,
             .patchBytes, .assembleInstruction, .replaceWithNOP, .clearPatch,
             .topOfProcedure, .copyAddress, .copyHexString:
            return true
        case .findNext, .findPrevious,
             .nextProcedure, .previousProcedure,
             .nextSection, .previousSection,
             .nextXRef, .previousXRef,
             .nativeRequest, .nativeRetry, .nativeRefresh, .nativeCancel:
            return false
        }
    }

    private var nativeCommandHasExactTarget: Bool {
        guard let selection = selectedImageAddress,
              selection.slot == focusedImageSlot,
              snapshot.binary(in: selection.slot) != nil,
              let analysis = snapshot.analysis(in: selection.slot),
              analysis.analysisInputFingerprint != nil
        else { return false }
        return NativeDecompilerExactFunctionResolver.resolve(
            selectedAddress: selection.address,
            functions: analysis.functions
        ) != nil
    }

    /// Applies a selection command through the exact qualified override key. The shared override
    /// path retains existing dirty tracking, Undo/Redo ownership, and structural reanalysis rules.
    private func applyCommandOverride(
        at location: ImageAddress,
        actionName: String,
        mutate: (inout AddressOverride) -> Void
    ) {
        guard selectedImageAddress == location,
              focusedImageSlot == location.slot,
              commandOwnerExists(location.slot) else {
            lastIssue = "The selected image is no longer available."
            return
        }
        var override = snapshot.addressOverrides[location] ?? AddressOverride()
        mutate(&override)
        applyOverride(location, override, actionName: actionName)
    }

    private func replaceCommandTargetWithNOP(_ location: ImageAddress) {
        let architecture = snapshot.binary(in: location.slot)?.architecture.lowercased() ?? ""
        let patch = architecture.hasPrefix("x86_64") ? BytePatch.x86NOP : BytePatch.arm64NOP
        applyCommandOverride(at: location, actionName: "Patch Bytes") { $0.patch = patch }
    }

    private func navigateOrIssue(_ target: UInt64?, _ noneMessage: String) {
        if let target { navigateToReference(target) } else { lastIssue = noneMessage }
    }

    /// Steps Next/Previous XREF: cycles the referrers of the selected address, reusing the
    /// active cursor while the selection stays within its orbit (so stepping onto a referrer
    /// keeps cycling) and rebuilding from the current selection otherwise.
    private func stepXRef(forward: Bool) {
        guard let location = selectedImageAddress,
              location.slot == focusedImageSlot else {
            lastIssue = "Select an address to step its cross-references."
            return
        }
        var cursor: XRefStepCursor
        if let existing = xrefCursor, existing.covers(location.address), !existing.isEmpty {
            cursor = existing
        } else {
            let references = snapshot.effectiveXRefs(to: location.address, in: location.slot)
            cursor = XRefStepCursor(anchor: location.address, froms: references.map(\.from))
        }
        guard !cursor.isEmpty else {
            lastIssue = "No cross-references to this address."
            return
        }
        let target = forward ? cursor.next() : cursor.previous()
        xrefCursor = cursor
        if let target { navigateToReference(target) }
    }

    /// Seeds Find from a fresh result set, optionally on the exact image-qualified
    /// selection. An empty set clears the cursor (disabling Find Next/Previous).
    func seedSearchCursor(_ results: [BinarySearchResult], selecting target: ImageAddress? = nil) {
        searchCursor = results.isEmpty ? nil : SearchResultCursor(results: results, selecting: target)
    }

    /// Advances to the next Find hit (wrapping) and navigates the listing there.
    func findNext() { stepSearch(forward: true) }

    /// Retreats to the previous Find hit (wrapping) and navigates the listing there.
    func findPrevious() { stepSearch(forward: false) }

    private func stepSearch(forward: Bool) {
        guard var cursor = searchCursor, !cursor.isEmpty else {
            lastIssue = "Run Find first to step through matches."
            return
        }
        // SwiftUI binding callbacks can run after Cmd-G. Retained publications
        // therefore revalidate their exact authority at the navigation boundary.
        if let authority = cursor.retainedFindAuthority {
            let current = RetainedFindModel.makeContext(
                workspaceOwner: ObjectIdentifier(self), workspaceID: workspaceID,
                documentID: documentID, snapshot: snapshot, revision: mutationGeneration.rawValue,
                focusedSlot: focusedImageSlot, scope: authority.scope)
            guard authority.workspaceOwner == current.workspaceOwner,
                  authority.workspaceID == current.workspaceID, authority.documentID == current.documentID,
                  authority.revision == current.revision, authority.imageOwners == current.imageOwners,
                  authority.analysisFingerprints == current.analysisFingerprints,
                  authority.focusedSlot == current.focusedSlot else {
                searchCursor = nil
                lastIssue = "Find results changed. Run Find again to step through matches."
                return
            }
        }
        let hit = forward ? cursor.next() : cursor.previous()
        searchCursor = cursor
        guard let hit else { return }
        // WS-8: a Find result set spans all loaded images. A hit in the focused image navigates as
        // before (navigateToReference — no BinaryImage requirement, data-target hex fallback); a hit
        // in a SIBLING image crosses into it via the slot-aware goto so Cmd-G doesn't reinterpret its
        // address against the focused image.
        if hit.imageSlot == focusedImageSlot {
            navigateToReference(hit.address)
        } else {
            goToAddress(hit.address, in: hit.imageSlot)
        }
    }
}
