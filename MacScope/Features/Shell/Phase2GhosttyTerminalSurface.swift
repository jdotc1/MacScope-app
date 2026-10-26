import SwiftUI
import LumenTokens
import LumenUI

/// Compile-time truth for the independently pinned recovery renderer. When the C module is
/// unavailable the concrete surface below does not exist, so callers must select a non-grid path.
enum Phase2GhosttyLegacyGridCompilation {
#if canImport(GhosttyVt)
    static let isAvailable = true
#else
    static let isAvailable = false
#endif
}

#if canImport(GhosttyVt)
struct Phase2GhosttyTerminalSurface: NSViewRepresentable {
    private static let maximumForwardedInputUTF8ByteCount = 32 << 10

    let sessionID: UUID
    let terminalSize: Phase2HumanPTYTerminalSize
    let transcriptEvents: [Phase2HumanPTYTranscriptEvent]
    let inputHandler: ([UInt8]) -> Void
    let resizeHandler: (Phase2HumanPTYTerminalSize) -> Void
    /// Read when the parent's body creates this view, which subscribes it to theme changes
    /// (Observation); `update` then reapplies the terminal palette.
    private let themeIdentity = TerminalThemeIdentity.current()

    init(
        sessionID: UUID,
        terminalSize: Phase2HumanPTYTerminalSize,
        transcriptEvents: [Phase2HumanPTYTranscriptEvent],
        inputHandler: @escaping ([UInt8]) -> Void,
        resizeHandler: @escaping (Phase2HumanPTYTerminalSize) -> Void
    ) {
        self.sessionID = sessionID
        self.terminalSize = terminalSize
        self.transcriptEvents = transcriptEvents
        self.inputHandler = inputHandler
        self.resizeHandler = resizeHandler
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionID: sessionID, terminalSize: terminalSize)
    }

    func makeNSView(context: Context) -> Phase2GhosttyTerminalGridView {
        let view = Phase2GhosttyTerminalGridView()
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(
        _ nsView: Phase2GhosttyTerminalGridView,
        context: Context
    ) {
        update(nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(
        _ nsView: Phase2GhosttyTerminalGridView,
        coordinator: Coordinator
    ) {
        nsView.snapshot = nil
        nsView.keyEventHandler = nil
        nsView.committedTextHandler = nil
        nsView.pasteHandler = nil
        nsView.geometryHandler = nil
        nsView.scrollHandler = nil
        nsView.scrollToOffsetHandler = nil
        nsView.beginSelectionHandler = nil
        nsView.extendSelectionHandler = nil
        nsView.endSelectionHandler = nil
        nsView.clearSelectionHandler = nil
        nsView.selectedTextHandler = nil
        nsView.selectAllHandler = nil
        nsView.mouseEventHandler = nil
        nsView.appearanceChangedHandler = nil
        coordinator.retire()
    }

    private func update(
        _ view: Phase2GhosttyTerminalGridView,
        coordinator: Coordinator
    ) {
        coordinator.update(
            sessionID: sessionID,
            terminalSize: terminalSize,
            transcriptEvents: transcriptEvents
        )
        view.keyEventHandler = { [weak coordinator] event in
            guard event.characters.map({ Self.isForwardableInput($0) }) ?? true,
                  event.charactersIgnoringModifiers.map({ Self.isForwardableInput($0) }) ?? true
            else { return }
            guard let bytes = coordinator?.model?.encodeInput(event), !bytes.isEmpty else { return }
            inputHandler(bytes)
        }
        view.committedTextHandler = { [weak coordinator] text in
            guard Self.isForwardableInput(text) else { return }
            let event = Phase2TerminalInputEncoder.KeyEvent(
                keyCode: 0,
                characters: text,
                charactersIgnoringModifiers: text,
                modifiers: []
            )
            guard let bytes = coordinator?.model?.encodeInput(event), !bytes.isEmpty else { return }
            inputHandler(bytes)
        }
        view.pasteHandler = { [weak coordinator] text in
            guard Self.isForwardableInput(text) else { return }
            guard let bytes = coordinator?.model?.encodePaste(text), !bytes.isEmpty else { return }
            inputHandler(bytes)
        }
        view.geometryHandler = { [weak coordinator, weak view] size, pixels in
            guard let coordinator else { return }
            coordinator.proposeGeometry(size: size, pixels: pixels, resizeHandler: resizeHandler)
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.scrollHandler = { [weak coordinator, weak view] rows in
            guard let coordinator, let model = coordinator.model else { return }
            model.scrollViewport(rows: rows)
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.scrollToOffsetHandler = { [weak coordinator, weak view] offset in
            guard let coordinator, let model = coordinator.model else { return }
            model.scrollViewport(to: offset)
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.beginSelectionHandler = { [weak coordinator, weak view] point in
            guard let coordinator, let model = coordinator.model else { return }
            _ = model.beginSelection(at: point)
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.extendSelectionHandler = { [weak coordinator, weak view] point in
            guard let coordinator, let model = coordinator.model else { return }
            _ = model.extendSelection(to: point)
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.endSelectionHandler = { [weak coordinator] in coordinator?.model?.endSelection() }
        view.clearSelectionHandler = { [weak coordinator, weak view] in
            guard let coordinator, let model = coordinator.model else { return }
            model.clearSelection()
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.selectedTextHandler = { [weak coordinator] in coordinator?.model?.selectedText() }
        view.selectAllHandler = { [weak coordinator, weak view] in
            guard let coordinator, let model = coordinator.model else { return }
            _ = model.selectAll()
            view?.snapshot = coordinator.refreshSnapshot()
        }
        view.mouseEventHandler = { [weak coordinator] event, geometry in
            guard let model = coordinator?.model, model.isMouseTrackingEnabled else { return false }
            if let bytes = model.encodeMouse(event, geometry: geometry), !bytes.isEmpty {
                inputHandler(bytes)
            }
            // A tracking application owns the gesture even when its current protocol intentionally
            // emits no bytes for this event (for example an X10 release).
            return true
        }
        view.appearanceChangedHandler = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            if coordinator.applyThemeIfChanged(TerminalThemePalette(appearance: LumenAppearance(view.effectiveAppearance))) {
                view.cursorColor = coordinator.appliedPalette.map { NSColor(themeRGB: $0.cursor) }
                view.snapshot = coordinator.refreshSnapshot()
            }
        }
        _ = themeIdentity
        if coordinator.applyThemeIfChanged(TerminalThemePalette(appearance: LumenAppearance(view.effectiveAppearance))) {
            view.cursorColor = coordinator.appliedPalette.map { NSColor(themeRGB: $0.cursor) }
            coordinator.refreshSnapshot()
        }
        view.snapshot = coordinator.snapshot
        view.reportGeometryIfNeeded()
    }

    private static func isForwardableInput(_ value: String) -> Bool {
        value.utf8.count <= maximumForwardedInputUTF8ByteCount
    }

    @MainActor
    final class Coordinator {
        private static let maximumPixelDimension: UInt32 = 1_048_576

        struct Limits: Equatable, Sendable {
            static let production = Self(
                maximumEvents: Phase2HumanPTYTranscriptLimits.productionMaximum.maximumEvents,
                maximumEventBytes: Phase2HumanPTYTranscriptLimits.productionMaximum.maximumEventBytes,
                maximumCumulativeBytes: Phase2HumanPTYTranscriptLimits.productionMaximum.maximumCumulativeBytes,
                maximumColumns: 512,
                maximumRows: 512,
                maximumCells: 128 * 1_024
            )

            let maximumEvents: Int
            let maximumEventBytes: Int
            let maximumCumulativeBytes: Int
            let maximumColumns: Int
            let maximumRows: Int
            let maximumCells: Int

            init(
                maximumEvents: Int,
                maximumEventBytes: Int,
                maximumCumulativeBytes: Int,
                maximumColumns: Int,
                maximumRows: Int,
                maximumCells: Int
            ) {
                precondition(maximumEvents > 0)
                precondition(maximumEventBytes > 0)
                precondition(maximumCumulativeBytes > 0)
                precondition(maximumColumns > 0)
                precondition(maximumRows > 0)
                precondition(maximumCells > 0)
                self.maximumEvents = maximumEvents
                self.maximumEventBytes = maximumEventBytes
                self.maximumCumulativeBytes = maximumCumulativeBytes
                self.maximumColumns = maximumColumns
                self.maximumRows = maximumRows
                self.maximumCells = maximumCells
            }
        }

        enum Rejection: Error, Equatable, Sendable {
            case emptyTranscript
            case eventCountExceeded(count: Int, limit: Int)
            case wrongSession(sequence: UInt64)
            case sequenceGap(expected: UInt64, actual: UInt64)
            case replayedOrOutOfOrder(sequence: UInt64)
            case explicitTranscriptGap(sequence: UInt64)
            case invalidSource(sequence: UInt64)
            case emptyBytePayload(sequence: UInt64)
            case eventByteBudgetExceeded(sequence: UInt64, count: Int, limit: Int)
            case cumulativeByteBudgetExceeded(count: Int, limit: Int)
            case invalidTerminalSize(columns: Int, rows: Int)
            case columnBudgetExceeded(count: Int, limit: Int)
            case rowBudgetExceeded(count: Int, limit: Int)
            case cellBudgetExceeded(count: Int, limit: Int)
            case terminalSizeMismatch(
                expectedColumns: Int,
                expectedRows: Int,
                actualColumns: Int,
                actualRows: Int
            )
            case terminalSizeChangedWithoutEvidence
            case eventAfterTerminal(sequence: UInt64, terminalSequence: UInt64)
            case duplicateTerminal(firstSequence: UInt64, duplicateSequence: UInt64)
            case replayedSnapshot(acceptedCount: Int, candidateCount: Int)
            case mutatedAcceptedPrefix(sequence: UInt64)
            case rendererUnavailable
            case rendererSnapshotInvalid
        }

        enum UpdateDisposition: Equatable, Sendable {
            case applied(eventCount: Int, byteCount: Int)
            case coalesced
            case rejected(Rejection)
            case retired
        }

        private struct ValidatedTranscript {
            let cumulativeByteCount: Int
        }

        private(set) var model: Phase2GhosttyTerminalModel?
        private(set) var snapshot: Phase2TerminalGridSnapshot?
        private(set) var sessionID: UUID
        private(set) var authoritativeTerminalSize: Phase2HumanPTYTerminalSize
        private(set) var lastUpdateDisposition: UpdateDisposition?
        private(set) var appliedBatchCount = 0
        private(set) var appliedEventCount = 0
        private(set) var coalescedUpdateCount = 0
        private(set) var acceptedByteCount = 0
        private(set) var isRetired = false

        var acceptedEventCount: Int { acceptedEvents.count }

        private let limits: Limits
        private var acceptedEvents: [Phase2HumanPTYTranscriptEvent] = []
        private var lastPixelGeometry: Phase2TerminalPixelGeometry?
        private var lastProposedSize: Phase2HumanPTYTerminalSize?

        init(
            sessionID: UUID,
            terminalSize: Phase2HumanPTYTerminalSize,
            limits: Limits = .production
        ) {
            self.sessionID = sessionID
            authoritativeTerminalSize = terminalSize
            self.limits = limits
        }

        func proposeGeometry(
            size: Phase2HumanPTYTerminalSize,
            pixels: Phase2TerminalPixelGeometry,
            resizeHandler: (Phase2HumanPTYTerminalSize) -> Void
        ) {
            guard !isRetired,
                  pixels.isValid,
                  pixels.screenWidth <= Self.maximumPixelDimension,
                  pixels.screenHeight <= Self.maximumPixelDimension,
                  pixels.cellWidth <= Self.maximumPixelDimension,
                  pixels.cellHeight <= Self.maximumPixelDimension,
                  rejection(for: size) == nil
            else { return }
            let pixelGeometryChanged = lastPixelGeometry != pixels
            lastPixelGeometry = pixels
            if size == authoritativeTerminalSize {
                // Rows and columns remain broker authority. A backing-scale transition may update
                // physical cell metrics only after the logical dimensions are already accepted.
                guard pixelGeometryChanged, let model else { return }
                model.resize(
                    to: size,
                    cellWidthPixels: pixels.cellWidth,
                    cellHeightPixels: pixels.cellHeight
                )
                return
            }
            guard size != lastProposedSize else { return }
            lastProposedSize = size
            resizeHandler(size)
        }

        func update(
            sessionID candidateSessionID: UUID,
            terminalSize candidateTerminalSize: Phase2HumanPTYTerminalSize,
            transcriptEvents: [Phase2HumanPTYTranscriptEvent]
        ) {
            guard !isRetired else {
                lastUpdateDisposition = .retired
                return
            }

            let replacesSession = candidateSessionID != sessionID
            if replacesSession {
                releaseRendererStateAndEvidence()
                sessionID = candidateSessionID
                authoritativeTerminalSize = candidateTerminalSize
                lastPixelGeometry = nil
                lastProposedSize = nil
            }

            let validated: ValidatedTranscript
            switch validate(
                sessionID: candidateSessionID,
                terminalSize: candidateTerminalSize,
                events: transcriptEvents
            ) {
            case .success(let value):
                validated = value
            case .failure(let rejection):
                reject(rejection)
                return
            }

            if !replacesSession,
               candidateTerminalSize == authoritativeTerminalSize,
               transcriptEvents == acceptedEvents,
               model != nil,
               snapshot != nil {
                coalescedUpdateCount += 1
                lastUpdateDisposition = .coalesced
                return
            }

            guard transcriptEvents.count >= acceptedEvents.count else {
                reject(.replayedSnapshot(
                    acceptedCount: acceptedEvents.count,
                    candidateCount: transcriptEvents.count
                ))
                return
            }
            for index in acceptedEvents.indices where transcriptEvents[index] != acceptedEvents[index] {
                reject(.mutatedAcceptedPrefix(sequence: transcriptEvents[index].sequence))
                return
            }

            let suffix = Array(transcriptEvents.dropFirst(acceptedEvents.count))
            if !acceptedEvents.isEmpty,
               candidateTerminalSize != authoritativeTerminalSize,
               !suffix.contains(where: { event in
                   if case .resize = event.payload { return true }
                   return false
               }) {
                reject(.terminalSizeChangedWithoutEvidence)
                return
            }

            let previousEventCount = acceptedEvents.count
            let eventsToIngest: [Phase2HumanPTYTranscriptEvent]
            if model == nil {
                model = Phase2GhosttyTerminalModel(
                    sessionID: candidateSessionID,
                    terminalSize: candidateTerminalSize
                )
                appliedPalette = nil
                eventsToIngest = transcriptEvents
            } else {
                eventsToIngest = suffix
            }

            guard let model, model.sessionID == candidateSessionID else {
                reject(.rendererUnavailable)
                return
            }
            let ingestion = model.ingest(eventsToIngest)
            guard ingestion.appliedSequences == eventsToIngest.map(\.sequence),
                  ingestion.ignoredDuplicateSequences.isEmpty,
                  ingestion.ignoredForeignSessionSequences.isEmpty,
                  ingestion.missingSequenceRanges.isEmpty,
                  model.terminalSize == candidateTerminalSize
            else {
                reject(.rendererUnavailable)
                return
            }

            acceptedEvents = transcriptEvents
            acceptedByteCount = validated.cumulativeByteCount
            authoritativeTerminalSize = candidateTerminalSize
            if authoritativeTerminalSize == lastProposedSize { lastProposedSize = nil }
            if let pixels = lastPixelGeometry {
                model.resize(
                    to: candidateTerminalSize,
                    cellWidthPixels: pixels.cellWidth,
                    cellHeightPixels: pixels.cellHeight
                )
            }

            guard refreshSnapshot() != nil else { return }
            let appliedCount = transcriptEvents.count - previousEventCount
            let appliedBytes = suffixByteCount(transcriptEvents.dropFirst(previousEventCount))
            appliedBatchCount += 1
            appliedEventCount += appliedCount
            lastUpdateDisposition = .applied(eventCount: appliedCount, byteCount: appliedBytes)
        }

        /// The palette last pushed into the current model; reset when the model is replaced.
        private(set) var appliedPalette: TerminalThemePalette?

        /// Applies `palette` when it differs from what the current model already has.
        func applyThemeIfChanged(_ palette: TerminalThemePalette) -> Bool {
            guard !isRetired, let model, palette != appliedPalette else { return false }
            model.applyTheme(palette)
            appliedPalette = palette
            return true
        }

        @discardableResult
        func refreshSnapshot() -> Phase2TerminalGridSnapshot? {
            guard !isRetired, let model, let candidate = model.snapshot() else {
                if !isRetired { reject(.rendererUnavailable) }
                return nil
            }
            guard candidate.sessionID == sessionID,
                  candidate.columns == authoritativeTerminalSize.columns,
                  candidate.rows == authoritativeTerminalSize.rows,
                  candidate.gridRows.count == candidate.rows,
                  candidate.gridRows.allSatisfy({ $0.cells.count == candidate.columns }),
                  candidate.lastAppliedSequence == acceptedEvents.last?.sequence,
                  candidate.missingSequenceRanges.isEmpty,
                  rejection(for: Phase2HumanPTYTerminalSize(
                      columns: candidate.columns,
                      rows: candidate.rows
                  )) == nil
            else {
                reject(.rendererSnapshotInvalid)
                return nil
            }
            snapshot = candidate
            return candidate
        }

        func retire() {
            guard !isRetired else { return }
            isRetired = true
            releaseRendererStateAndEvidence()
            lastPixelGeometry = nil
            lastProposedSize = nil
            lastUpdateDisposition = .retired
        }

        private func validate(
            sessionID: UUID,
            terminalSize: Phase2HumanPTYTerminalSize,
            events: [Phase2HumanPTYTranscriptEvent]
        ) -> Result<ValidatedTranscript, Rejection> {
            if let rejection = rejection(for: terminalSize) { return .failure(rejection) }
            guard !events.isEmpty else { return .failure(.emptyTranscript) }
            guard events.count <= limits.maximumEvents else {
                return .failure(.eventCountExceeded(count: events.count, limit: limits.maximumEvents))
            }

            var expectedSequence: UInt64 = 1
            var cumulativeByteCount = 0
            var finalResize: Phase2HumanPTYTerminalSize?
            var terminalSequence: UInt64?

            for event in events {
                guard event.sessionID == sessionID else {
                    return .failure(.wrongSession(sequence: event.sequence))
                }
                guard event.sequence == expectedSequence else {
                    if event.sequence < expectedSequence {
                        return .failure(.replayedOrOutOfOrder(sequence: event.sequence))
                    }
                    return .failure(.sequenceGap(expected: expectedSequence, actual: event.sequence))
                }

                if let terminalSequence {
                    return .failure(.eventAfterTerminal(
                        sequence: event.sequence,
                        terminalSequence: terminalSequence
                    ))
                }
                guard Self.isSourceAllowed(event.source, for: event.payload) else {
                    return .failure(.invalidSource(sequence: event.sequence))
                }

                switch event.payload {
                case .input(let bytes), .output(_, let bytes):
                    guard !bytes.isEmpty else {
                        return .failure(.emptyBytePayload(sequence: event.sequence))
                    }
                case .resize(let columns, let rows):
                    let size = Phase2HumanPTYTerminalSize(columns: columns, rows: rows)
                    if let rejection = rejection(for: size) { return .failure(rejection) }
                    finalResize = size
                case .gap:
                    return .failure(.explicitTranscriptGap(sequence: event.sequence))
                case .terminal:
                    terminalSequence = event.sequence
                case .signal, .reconnect:
                    break
                }

                let byteCount = event.payload.byteCount
                guard byteCount <= limits.maximumEventBytes else {
                    return .failure(.eventByteBudgetExceeded(
                        sequence: event.sequence,
                        count: byteCount,
                        limit: limits.maximumEventBytes
                    ))
                }
                let addition = cumulativeByteCount.addingReportingOverflow(byteCount)
                guard !addition.overflow,
                      addition.partialValue <= limits.maximumCumulativeBytes
                else {
                    return .failure(.cumulativeByteBudgetExceeded(
                        count: addition.overflow ? Int.max : addition.partialValue,
                        limit: limits.maximumCumulativeBytes
                    ))
                }
                cumulativeByteCount = addition.partialValue
                expectedSequence &+= 1
            }

            if let finalResize, finalResize != terminalSize {
                return .failure(.terminalSizeMismatch(
                    expectedColumns: terminalSize.columns,
                    expectedRows: terminalSize.rows,
                    actualColumns: finalResize.columns,
                    actualRows: finalResize.rows
                ))
            }
            return .success(ValidatedTranscript(cumulativeByteCount: cumulativeByteCount))
        }

        private func rejection(for size: Phase2HumanPTYTerminalSize) -> Rejection? {
            guard size.isValid else {
                return .invalidTerminalSize(columns: size.columns, rows: size.rows)
            }
            guard size.columns <= limits.maximumColumns else {
                return .columnBudgetExceeded(count: size.columns, limit: limits.maximumColumns)
            }
            guard size.rows <= limits.maximumRows else {
                return .rowBudgetExceeded(count: size.rows, limit: limits.maximumRows)
            }
            let cells = size.columns.multipliedReportingOverflow(by: size.rows)
            guard !cells.overflow, cells.partialValue <= limits.maximumCells else {
                return .cellBudgetExceeded(
                    count: cells.overflow ? Int.max : cells.partialValue,
                    limit: limits.maximumCells
                )
            }
            return nil
        }

        private static func isSourceAllowed(
            _ source: Phase2HumanPTYEventSource,
            for payload: Phase2HumanPTYEventPayload
        ) -> Bool {
            switch payload {
            case .input, .resize, .signal:
                source == .human
            case .reconnect:
                source == .app
            case .output, .gap, .terminal:
                source == .broker
            }
        }

        private func suffixByteCount(
            _ events: ArraySlice<Phase2HumanPTYTranscriptEvent>
        ) -> Int {
            events.reduce(into: 0) { total, event in
                total += event.payload.byteCount
            }
        }

        private func reject(_ rejection: Rejection) {
            // The accepted transcript is a monotonic authority fence, even after the concrete
            // renderer state is discarded. Forgetting it would let the same stale or mutated
            // prefix arrive again and masquerade as a fresh transcript, resurrecting bytes that
            // were already rejected. A later exact transcript or valid extension may rebuild the
            // renderer from this retained evidence.
            releaseRendererState()
            lastUpdateDisposition = .rejected(rejection)
        }

        private func releaseRendererState() {
            snapshot = nil
            model = nil
        }

        private func releaseRendererStateAndEvidence() {
            releaseRendererState()
            acceptedEvents.removeAll(keepingCapacity: false)
            acceptedByteCount = 0
        }
    }
}
#endif
