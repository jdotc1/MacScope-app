import SwiftUI
import LumenTokens
import LumenUI

enum LogicalBreakpointEditorLocatorKind: String, CaseIterable, Identifiable {
    case preferredAddress
    case imageOffset
    case function
    case symbol
    case source

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferredAddress: "Address"
        case .imageOffset: "Image Offset"
        case .function: "Function"
        case .symbol: "Symbol"
        case .source: "Source"
        }
    }
}

enum LogicalBreakpointEditorHitBehavior: String, CaseIterable, Identifiable {
    case always
    case skipFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Stop on every matching hit"
        case .skipFirst: "Skip first N matching hits"
        }
    }
}

enum LogicalBreakpointEditorActionKind: String, CaseIterable, Identifiable {
    case log
    case evaluateExpression

    var id: String { rawValue }

    var title: String {
        switch self {
        case .log: "Log"
        case .evaluateExpression: "Evaluate Target Expression"
        }
    }
}

enum LogicalBreakpointEditorLogFragmentKind: String, CaseIterable, Identifiable {
    case literal
    case targetExpression

    var id: String { rawValue }

    var title: String {
        switch self {
        case .literal: "Text"
        case .targetExpression: "Target Expression"
        }
    }
}

struct LogicalBreakpointOwnerChoice: Identifiable {
    let owner: DebuggerWorkspaceImageOwnerSeal
    let title: String
    let detail: String

    var id: DebuggerWorkspaceImageOwnerSeal { owner }
}

struct LogicalBreakpointSourceChoice: Identifiable {
    struct ID: Hashable {
        let owner: DebuggerWorkspaceImageOwnerSeal
        let identity: DebuggerCanonicalSourceFileIdentity
    }

    let owner: DebuggerWorkspaceImageOwnerSeal
    /// The exact resolver coordinate that supplied this source identity. This is nil only for an
    /// unavailable saved source retained so an existing specification can still be inspected.
    let ownerCoordinate: DebuggerWorkspaceArtifactCoordinate?
    let identity: DebuggerCanonicalSourceFileIdentity
    let title: String
    let detail: String

    var id: ID { ID(owner: owner, identity: identity) }

    func belongs(to candidate: DebuggerWorkspaceImageOwnerSeal) -> Bool {
        guard owner.slot == candidate.slot,
              owner.binaryID == candidate.binaryID else {
            return false
        }
        guard let candidateArtifact = candidate.artifactIdentity else { return true }
        return owner.artifactIdentity == candidateArtifact
    }
}

/// Current-Xcode live-proven authoring capabilities. The controller/view-model must inject these;
/// the sheet never infers backend support from session presence or transport branding.
struct LogicalBreakpointEditorCapabilities: Hashable, Sendable {
    let canAuthorConditions: Bool
    let canAuthorIgnoreFirst: Bool
    let canAuthorActions: Bool
    let canAuthorTargetExpressions: Bool
    let canAuthorContinueAfterActions: Bool

    static let unavailable = Self(
        canAuthorConditions: false,
        canAuthorIgnoreFirst: false,
        canAuthorActions: false,
        canAuthorTargetExpressions: false,
        canAuthorContinueAfterActions: false
    )
}

struct LogicalBreakpointEditorSubmission {
    let enabled: Bool
    let target: DebuggerLogicalBreakpointTarget
    let condition: String?
    let hitPolicy: DebuggerBreakpointHitPolicy
    let actions: [DebuggerBreakpointAction]
    let disposition: DebuggerBreakpointDisposition
}

enum LogicalBreakpointEditorValidationError: Error, Equatable, LocalizedError {
    case missingOwner
    case invalidAddress(field: String)
    case invalidUnsignedInteger(field: String)
    case missingSourceIdentity
    case sourceIdentityOwnerMismatch
    case invalidAction(index: Int, detail: String)
    case invalidSpecification(detail: String)

    var errorDescription: String? {
        switch self {
        case .missingOwner:
            "Choose the binary image that owns this breakpoint."
        case .invalidAddress(let field):
            "Enter a valid 64-bit hexadecimal or decimal value for \(field)."
        case .invalidUnsignedInteger(let field):
            "Enter a positive whole number in range for \(field)."
        case .missingSourceIdentity:
            "Choose a source file with exact imported debug identity."
        case .sourceIdentityOwnerMismatch:
            "Choose a source file owned by the selected binary image."
        case .invalidAction(let index, let detail):
            "Action \(index + 1): \(detail)"
        case .invalidSpecification(let detail):
            detail
        }
    }
}

struct LogicalBreakpointEditorLogFragmentDraft: Identifiable {
    var id = UUID()
    var kind: LogicalBreakpointEditorLogFragmentKind = .literal
    var value = ""

    init(
        id: UUID = UUID(),
        kind: LogicalBreakpointEditorLogFragmentKind = .literal,
        value: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.value = value
    }

    init(fragment: DebuggerBreakpointLogTemplateFragment) {
        switch fragment {
        case .literal(let value):
            kind = .literal
            self.value = value
        case .targetExpression(let value):
            kind = .targetExpression
            self.value = value
        }
    }

    var durableFragment: DebuggerBreakpointLogTemplateFragment {
        switch kind {
        case .literal: .literal(value)
        case .targetExpression: .targetExpression(value)
        }
    }
}

struct LogicalBreakpointEditorActionDraft: Identifiable {
    var id = UUID()
    var kind: LogicalBreakpointEditorActionKind = .log
    var logFragments: [LogicalBreakpointEditorLogFragmentDraft] = [
        LogicalBreakpointEditorLogFragmentDraft(),
    ]
    var expressionLabel = ""
    var expression = ""

    init(
        id: UUID = UUID(),
        kind: LogicalBreakpointEditorActionKind = .log,
        logFragments: [LogicalBreakpointEditorLogFragmentDraft] = [
            LogicalBreakpointEditorLogFragmentDraft(),
        ],
        expressionLabel: String = "",
        expression: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.logFragments = logFragments
        self.expressionLabel = expressionLabel
        self.expression = expression
    }

    init(action: DebuggerBreakpointAction) {
        switch action {
        case .log(let template):
            kind = .log
            logFragments = template.fragments.map(LogicalBreakpointEditorLogFragmentDraft.init)
        case .evaluateTargetExpression(let capture):
            kind = .evaluateExpression
            logFragments = []
            expressionLabel = capture.label
            expression = capture.expression
        }
    }

    func validatedAction() throws -> DebuggerBreakpointAction {
        switch kind {
        case .log:
            return .log(try DebuggerBreakpointLogTemplate(
                fragments: logFragments.map(\.durableFragment)
            ))
        case .evaluateExpression:
            return .evaluateTargetExpression(try DebuggerBreakpointExpressionCapture(
                label: expressionLabel,
                expression: expression
            ))
        }
    }
}

struct LogicalBreakpointEditorDraft {
    var enabled = true
    var locatorKind: LogicalBreakpointEditorLocatorKind = .preferredAddress
    var owner: DebuggerWorkspaceImageOwnerSeal?

    var preferredAddressText = ""
    var segmentName = "__TEXT"
    var segmentPreferredStartText = ""
    var imageOffsetText = ""
    var functionEntryText = ""
    var functionRawLinkageNameHint = ""
    var symbolRawLinkageName = ""
    var symbolKind = ""
    var symbolLibraryName = ""
    var cardinality: DebuggerLogicalBreakpointCardinality = .exactlyOne
    var sourceIdentity: DebuggerCanonicalSourceFileIdentity?
    var sourceIdentityOwner: DebuggerWorkspaceImageOwnerSeal?
    var sourceLineText = ""
    var usesExactSourceColumn = false
    var sourceColumnText = ""

    var condition = ""
    var hitBehavior: LogicalBreakpointEditorHitBehavior = .always
    var skipFirstCountText = "1"
    var actions: [LogicalBreakpointEditorActionDraft] = []
    var disposition: DebuggerBreakpointDisposition = .stop

    init(owner: DebuggerWorkspaceImageOwnerSeal? = nil, preferredAddress: UInt64? = nil) {
        self.owner = owner
        if let preferredAddress {
            preferredAddressText = preferredAddress.hexAddress
        }
    }

    init(specification: DebuggerLogicalBreakpointSpecification) {
        enabled = specification.enabled
        condition = specification.condition ?? ""
        actions = specification.actions.map(LogicalBreakpointEditorActionDraft.init)
        disposition = specification.disposition

        switch specification.hitPolicy {
        case .always:
            hitBehavior = .always
            skipFirstCountText = "1"
        case .ignoreFirst(let count):
            hitBehavior = .skipFirst
            skipFirstCountText = String(count)
        }

        switch specification.target {
        case .preferredAddress(let owner, let preferredVA):
            locatorKind = .preferredAddress
            self.owner = owner
            preferredAddressText = preferredVA.hexAddress
        case .imageOffset(let owner, let segmentName, let start, let offset):
            locatorKind = .imageOffset
            self.owner = owner
            self.segmentName = segmentName
            segmentPreferredStartText = start.hexAddress
            imageOffsetText = offset.hexAddress
        case .function(let owner, let entry, let hint):
            locatorKind = .function
            self.owner = owner
            functionEntryText = entry.hexAddress
            functionRawLinkageNameHint = hint ?? ""
        case .symbol(let owner, let name, let kind, let library, let cardinality):
            locatorKind = .symbol
            self.owner = owner
            symbolRawLinkageName = name
            symbolKind = kind ?? ""
            symbolLibraryName = library ?? ""
            self.cardinality = cardinality
        case .source(let owner, let file, let line, let columnPolicy, let cardinality):
            locatorKind = .source
            self.owner = owner
            sourceIdentity = file
            sourceIdentityOwner = owner
            sourceLineText = String(line)
            self.cardinality = cardinality
            switch columnPolicy {
            case .any:
                usesExactSourceColumn = false
            case .exact(let column):
                usesExactSourceColumn = true
                sourceColumnText = String(column)
            }
        }
    }

    func validatedSubmission() throws -> LogicalBreakpointEditorSubmission {
        guard let owner else {
            throw LogicalBreakpointEditorValidationError.missingOwner
        }

        let target: DebuggerLogicalBreakpointTarget
        switch locatorKind {
        case .preferredAddress:
            target = .preferredAddress(
                owner: owner,
                preferredVA: try Self.address(preferredAddressText, field: "preferred address")
            )
        case .imageOffset:
            target = .imageOffset(
                owner: owner,
                segmentName: segmentName,
                expectedSegmentPreferredStart: try Self.address(
                    segmentPreferredStartText,
                    field: "segment preferred start"
                ),
                offset: try Self.address(imageOffsetText, field: "image offset")
            )
        case .function:
            target = .function(
                owner: owner,
                entryPreferredVA: try Self.address(functionEntryText, field: "function entry"),
                rawLinkageNameHint: Self.optional(functionRawLinkageNameHint)
            )
        case .symbol:
            target = .symbol(
                owner: owner,
                exactRawLinkageName: symbolRawLinkageName,
                kind: Self.optional(symbolKind),
                libraryName: Self.optional(symbolLibraryName),
                cardinality: cardinality
            )
        case .source:
            guard let sourceIdentity else {
                throw LogicalBreakpointEditorValidationError.missingSourceIdentity
            }
            guard let sourceIdentityOwner,
                  sourceIdentityOwner.slot == owner.slot,
                  sourceIdentityOwner.binaryID == owner.binaryID,
                  owner.artifactIdentity == nil
                    || sourceIdentityOwner.artifactIdentity == owner.artifactIdentity else {
                throw LogicalBreakpointEditorValidationError.sourceIdentityOwnerMismatch
            }
            let line = try Self.positiveUInt32(sourceLineText, field: "source line")
            let columnPolicy: DebuggerSourceColumnPolicy
            if usesExactSourceColumn {
                columnPolicy = .exact(try Self.positiveUInt32(sourceColumnText, field: "source column"))
            } else {
                columnPolicy = .any
            }
            target = .source(
                owner: owner,
                file: sourceIdentity,
                line: line,
                columnPolicy: columnPolicy,
                cardinality: cardinality
            )
        }

        let hitPolicy: DebuggerBreakpointHitPolicy
        switch hitBehavior {
        case .always:
            hitPolicy = .always
        case .skipFirst:
            hitPolicy = .ignoreFirst(try Self.positiveUInt32(
                skipFirstCountText,
                field: "skip-first count"
            ))
        }

        let durableActions: [DebuggerBreakpointAction] = try actions.enumerated().map { index, action in
            do {
                return try action.validatedAction()
            } catch {
                throw LogicalBreakpointEditorValidationError.invalidAction(
                    index: index,
                    detail: error.localizedDescription
                )
            }
        }

        let submission = LogicalBreakpointEditorSubmission(
            enabled: enabled,
            target: target,
            condition: Self.optional(condition),
            hitPolicy: hitPolicy,
            actions: durableActions,
            disposition: disposition
        )

        do {
            _ = try DebuggerLogicalBreakpointSpecification(
                id: DebuggerLogicalBreakpointID(rawValue: UUID()),
                revision: DebuggerLogicalBreakpointRevision(validating: 1),
                enabled: submission.enabled,
                target: submission.target,
                condition: submission.condition,
                hitPolicy: submission.hitPolicy,
                actions: submission.actions,
                disposition: submission.disposition
            )
        } catch {
            throw LogicalBreakpointEditorValidationError.invalidSpecification(
                detail: error.localizedDescription
            )
        }

        return submission
    }

    mutating func selectOwner(_ owner: DebuggerWorkspaceImageOwnerSeal?) {
        self.owner = owner
        guard let owner,
              let sourceIdentityOwner,
              sourceIdentityOwner.slot == owner.slot,
              sourceIdentityOwner.binaryID == owner.binaryID,
              owner.artifactIdentity == nil
                || sourceIdentityOwner.artifactIdentity == owner.artifactIdentity else {
            sourceIdentity = nil
            sourceIdentityOwner = nil
            return
        }
    }

    mutating func selectSourceChoice(_ choice: LogicalBreakpointSourceChoice?) {
        sourceIdentity = choice?.identity
        sourceIdentityOwner = choice?.owner
    }

    private static func optional(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func address(_ value: String, field: String) throws -> UInt64 {
        var candidate = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
        let radix: Int
        if candidate.lowercased().hasPrefix("0x") {
            candidate.removeFirst(2)
            radix = 16
        } else {
            radix = 10
        }
        guard !candidate.isEmpty, let result = UInt64(candidate, radix: radix) else {
            throw LogicalBreakpointEditorValidationError.invalidAddress(field: field)
        }
        return result
    }

    private static func positiveUInt32(_ value: String, field: String) throws -> UInt32 {
        let candidate = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
        guard let result = UInt32(candidate), result > 0 else {
            throw LogicalBreakpointEditorValidationError.invalidUnsignedInteger(field: field)
        }
        return result
    }
}

struct LogicalBreakpointEditorSheet: View {
    let title: String
    let ownerChoices: [LogicalBreakpointOwnerChoice]
    let sourceChoices: [LogicalBreakpointSourceChoice]
    let capabilities: LogicalBreakpointEditorCapabilities
    let onSave: (LogicalBreakpointEditorSubmission) -> Void
    let onCancel: () -> Void

    @State private var draft: LogicalBreakpointEditorDraft

    init(
        title: String,
        draft: LogicalBreakpointEditorDraft,
        ownerChoices: [LogicalBreakpointOwnerChoice],
        sourceChoices: [LogicalBreakpointSourceChoice],
        capabilities: LogicalBreakpointEditorCapabilities,
        onSave: @escaping (LogicalBreakpointEditorSubmission) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        _draft = State(initialValue: draft)
        self.ownerChoices = ownerChoices
        self.sourceChoices = sourceChoices
        self.capabilities = capabilities
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        let validation = validationState

        // Lumen sheet: tile, title and the offline note at the top; form
        // sections; the validation verdict as the status, a quiet Cancel (Esc) and Save as the
        // accent action (Return) at the foot. The controls stay as they were.
        LumenSheet(
            title,
            subtitle: "Saved intent is valid while the debugger is offline or the target image is unloaded.",
            systemImage: "lumen.breakpoint",
            hue: .hueRed,
            status: validationStatus(validation),
            cancelAccessibilityIdentifier: LogicalBreakpointEditorAccessibilityID.cancel,
            onCancel: onCancel,
            primary: LumenBarAction("Save", isEnabled: validation.isValid,
                                 accessibilityIdentifier: LogicalBreakpointEditorAccessibilityID.save) {
                if case .valid(let submission) = validation {
                    onSave(submission)
                }
            }
        ) {
                LumenFormSection("Location") {
                    LumenFormRow("Image") {
                    Picker("Binary Image", selection: ownerSelection) {
                        Text("Choose an image").tag(Optional<DebuggerWorkspaceImageOwnerSeal>.none)
                        ForEach(effectiveOwnerChoices) { choice in
                            VStack(alignment: .leading) {
                                Text(choice.title)
                                Text(choice.detail)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(choice.owner))
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.owner)
                    }

                    LumenFormRow("Locator") {
                    LumenModeSwitcher(selection: $draft.locatorKind, options: LogicalBreakpointEditorLocatorKind.allCases, style: .pill, title: \.title)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Locator")
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.locator)
                    }

                    LumenFormRow(draft.locatorKind.title) {
                        VStack(alignment: .leading, spacing: Lumen.Space.s4) { locatorFields }
                            .textFieldStyle(.roundedBorder)
                    }
                }

                LumenFormSection("Behavior") {
                    LumenFormRow("Enabled") {
                    Toggle("Enabled", isOn: $draft.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.enabled)
                    }

                    LumenFormRow("Condition") {
                    TextField("Optional target-language condition", text: $draft.condition)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!capabilities.canAuthorConditions)
                        .help(capabilities.canAuthorConditions
                            ? "Conditions are bounded target-language expressions. Raw debugger commands are not supported."
                            : capabilityUnavailableHelp)
                        .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.condition)
                    }

                    LumenFormRow("Hit policy") {
                    HStack(spacing: Lumen.Space.s5) {
                    Picker("Hit Policy", selection: $draft.hitBehavior) {
                        ForEach(LogicalBreakpointEditorHitBehavior.allCases) { behavior in
                            Text(behavior.title)
                                .tag(behavior)
                                .disabled(
                                    behavior == .skipFirst
                                        && !capabilities.canAuthorIgnoreFirst
                                )
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.hitPolicy)
                    .help(capabilities.canAuthorIgnoreFirst
                        ? "Choose whether every matching hit or only hits after a bounded skip count are eligible."
                        : capabilityUnavailableHelp)

                    if draft.hitBehavior == .skipFirst {
                        TextField("Hits to skip", text: $draft.skipFirstCountText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .disabled(!capabilities.canAuthorIgnoreFirst)
                            .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.skipFirstCount)
                    }
                    }
                    }

                    LumenFormRow("After actions") {
                    Picker("After Successful Actions", selection: $draft.disposition) {
                        Text("Stop").tag(DebuggerBreakpointDisposition.stop)
                        Text("Continue")
                            .tag(DebuggerBreakpointDisposition.continueAfterSuccessfulActions)
                            .disabled(!capabilities.canAuthorContinueAfterActions)
                    }
                    .pickerStyle(.segmented)
                    .help(capabilities.canAuthorContinueAfterActions
                        ? "Choose whether a successful typed action sequence stops or continues."
                        : capabilityUnavailableHelp)
                    .labelsHidden()
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.disposition)
                    }
                }

                LumenFormSection("Typed Actions") {
                    if draft.actions.isEmpty {
                        Text("No actions. The breakpoint stops after its hit policy and optional condition pass.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach($draft.actions) { $action in
                        LogicalBreakpointEditorActionView(
                            action: $action,
                            actionIndex: actionIndex(for: action.id),
                            actionCount: draft.actions.count,
                            canAuthorActions: capabilities.canAuthorActions,
                            canAuthorTargetExpressions: capabilities.canAuthorTargetExpressions,
                            onMove: { moveAction(id: action.id, offset: $0) },
                            onDelete: { deleteAction(id: action.id) }
                        )
                    }

                    Menu {
                        Button("Log") {
                            draft.actions.append(LogicalBreakpointEditorActionDraft(kind: .log))
                        }
                        .disabled(!capabilities.canAuthorActions)
                        Button("Evaluate Target Expression") {
                            draft.actions.append(LogicalBreakpointEditorActionDraft(kind: .evaluateExpression))
                        }
                        .disabled(
                            !capabilities.canAuthorActions
                                || !capabilities.canAuthorTargetExpressions
                        )
                    } label: {
                        Label("Add Action", systemImage: LogicalBreakpointEditorSymbols.add)
                    }
                    .disabled(!capabilities.canAuthorActions || draft.actions.count >= 16)
                    .help(!capabilities.canAuthorActions
                        ? capabilityUnavailableHelp
                        : draft.actions.count >= 16
                            ? "A breakpoint may contain at most 16 actions"
                            : "Add a typed breakpoint action")
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.addAction)

                    if !capabilities.canAuthorConditions
                        || !capabilities.canAuthorIgnoreFirst
                        || !capabilities.canAuthorActions
                        || !capabilities.canAuthorTargetExpressions
                        || !capabilities.canAuthorContinueAfterActions {
                        Label(capabilityUnavailableHelp, systemImage: LogicalBreakpointEditorSymbols.capability)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.capabilityNotice)
                    }
                }

        }
        .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.actions)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 680)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.sheet)
    }

    /// The validation verdict as the sheet's status: the error when invalid, else the save scope.
    private func validationStatus(_ validation: LogicalBreakpointEditorValidationState) -> LumenSheetStatus {
        if case .invalid(let message) = validation {
            return LumenSheetStatus(message, tone: .danger)
        }
        return LumenSheetStatus("Saved as durable intent; it binds when the target image loads.")
    }

    @ViewBuilder
    private var locatorFields: some View {
        switch draft.locatorKind {
        case .preferredAddress:
            TextField("Preferred address (0x…)", text: $draft.preferredAddressText)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.preferredAddress)
        case .imageOffset:
            TextField("Segment name", text: $draft.segmentName)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.segmentName)
            TextField("Expected segment preferred start (0x…)", text: $draft.segmentPreferredStartText)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.segmentPreferredStart)
            TextField("Offset (0x…)", text: $draft.imageOffsetText)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.imageOffset)
        case .function:
            TextField("Function entry preferred address (0x…)", text: $draft.functionEntryText)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.functionEntry)
            TextField("Optional raw linkage-name corroboration", text: $draft.functionRawLinkageNameHint)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.functionLinkageHint)
        case .symbol:
            TextField("Exact raw linkage name", text: $draft.symbolRawLinkageName)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.symbolLinkageName)
            TextField("Optional symbol kind", text: $draft.symbolKind)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.symbolKind)
            TextField("Optional library name", text: $draft.symbolLibraryName)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.symbolLibrary)
            cardinalityPicker
        case .source:
            Picker("Source File", selection: sourceIdentitySelection) {
                Text("Choose exact debug source identity")
                    .tag(Optional<DebuggerCanonicalSourceFileIdentity>.none)
                ForEach(effectiveSourceChoices) { choice in
                    VStack(alignment: .leading) {
                        Text(choice.title)
                        Text(choice.detail)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(choice.identity))
                }
            }
            .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.sourceFile)
            TextField("Line", text: $draft.sourceLineText)
                .frame(maxWidth: 120)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.sourceLine)
            Toggle("Match an exact column", isOn: $draft.usesExactSourceColumn)
                .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.sourceUseExactColumn)
            if draft.usesExactSourceColumn {
                TextField("Column", text: $draft.sourceColumnText)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.sourceColumn)
            }
            cardinalityPicker
        }
    }

    /// U9-4d: matching sites as a Lumen radio group, each choice saying what it binds.
    private var cardinalityPicker: some View {
        LumenRadioGroup(
            selection: $draft.cardinality,
            options: [DebuggerLogicalBreakpointCardinality.exactlyOne, .allExactMatches],
            title: { $0 == .exactlyOne ? "Exactly One" : "All Exact Matches" }
        ) { choice in
            Text(choice == .exactlyOne
                 ? "Binds only when one site matches; several stay pending as ambiguous."
                 : "Binds every exactly matching site, up to 256.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Matching Sites")
        .accessibilityIdentifier(LogicalBreakpointEditorAccessibilityID.matchingSites)
    }

    private var effectiveOwnerChoices: [LogicalBreakpointOwnerChoice] {
        var choices = ownerChoices
        if let owner = draft.owner, !choices.contains(where: { $0.owner == owner }) {
            choices.append(LogicalBreakpointOwnerChoice(
                owner: owner,
                title: "Saved Image",
                detail: "Slot \(owner.slot.rawValue) · current owner unavailable"
            ))
        }
        return choices
    }

    private var effectiveSourceChoices: [LogicalBreakpointSourceChoice] {
        guard let owner = draft.owner else { return [] }
        var choices = sourceChoices.filter { $0.belongs(to: owner) }
        if let identity = draft.sourceIdentity,
           let sourceOwner = draft.sourceIdentityOwner,
           sourceOwner.slot == owner.slot,
           sourceOwner.binaryID == owner.binaryID,
           (owner.artifactIdentity == nil || sourceOwner.artifactIdentity == owner.artifactIdentity),
           !choices.contains(where: { $0.identity == identity }) {
            choices.append(LogicalBreakpointSourceChoice(
                owner: sourceOwner,
                ownerCoordinate: nil,
                identity: identity,
                title: identity.tablePath.logicalBreakpointEditorDisplayPath,
                detail: "Saved exact debug identity · current source authority unavailable"
            ))
        }
        return choices
    }

    private var ownerSelection: Binding<DebuggerWorkspaceImageOwnerSeal?> {
        Binding(
            get: { draft.owner },
            set: { draft.selectOwner($0) }
        )
    }

    private var sourceIdentitySelection: Binding<DebuggerCanonicalSourceFileIdentity?> {
        Binding(
            get: { draft.sourceIdentity },
            set: { identity in
                guard let identity else {
                    draft.selectSourceChoice(nil)
                    return
                }
                draft.selectSourceChoice(
                    effectiveSourceChoices.first { $0.identity == identity }
                )
            }
        )
    }

    private var validationState: LogicalBreakpointEditorValidationState {
        do {
            return .valid(try draft.validatedSubmission())
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private var capabilityUnavailableHelp: String {
        "This control remains unavailable until the current-Xcode live debugger proof advertises the required capability."
    }

    private func actionIndex(for id: UUID) -> Int {
        draft.actions.firstIndex(where: { $0.id == id }) ?? 0
    }

    private func deleteAction(id: UUID) {
        draft.actions.removeAll { $0.id == id }
    }

    private func moveAction(id: UUID, offset: Int) {
        guard let index = draft.actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard draft.actions.indices.contains(destination) else { return }
        draft.actions.swapAt(index, destination)
    }
}

private enum LogicalBreakpointEditorValidationState {
    case valid(LogicalBreakpointEditorSubmission)
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

private struct LogicalBreakpointEditorActionView: View {
    @Binding var action: LogicalBreakpointEditorActionDraft
    let actionIndex: Int
    let actionCount: Int
    let canAuthorActions: Bool
    let canAuthorTargetExpressions: Bool
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                HStack(spacing: Lumen.Space.s4) {
                    Picker("Action \(actionIndex + 1)", selection: $action.kind) {
                        ForEach(LogicalBreakpointEditorActionKind.allCases) { kind in
                            Text(kind.title)
                                .tag(kind)
                                .disabled(kind == .evaluateExpression && !canAuthorTargetExpressions)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(!canAuthorActions)
                    .accessibilityIdentifier(actionAccessibilityID("kind"))

                    Button {
                        onMove(-1)
                    } label: {
                        Image(systemName: LogicalBreakpointEditorSymbols.moveUp)
                    }
                    .disabled(!canAuthorActions || actionIndex == 0)
                    .help("Move action earlier")
                    .accessibilityIdentifier(actionAccessibilityID("move-up"))

                    Button {
                        onMove(1)
                    } label: {
                        Image(systemName: LogicalBreakpointEditorSymbols.moveDown)
                    }
                    .disabled(!canAuthorActions || actionIndex + 1 >= actionCount)
                    .help("Move action later")
                    .accessibilityIdentifier(actionAccessibilityID("move-down"))

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: LogicalBreakpointEditorSymbols.delete)
                    }
                    .help("Delete action")
                    .accessibilityIdentifier(actionAccessibilityID("delete"))
                }

                switch action.kind {
                case .log:
                    logEditor
                case .evaluateExpression:
                    TextField("Display label", text: $action.expressionLabel)
                        .disabled(!canAuthorActions || !canAuthorTargetExpressions)
                    TextField("Target expression", text: $action.expression)
                        .disabled(!canAuthorActions || !canAuthorTargetExpressions)
                        .accessibilityIdentifier(actionAccessibilityID("expression"))
                    if !canAuthorActions || !canAuthorTargetExpressions {
                        capabilityUnavailableLabel
                    }
                }
            }
            .padding(Lumen.Space.s2)
        } label: {
            Text("Action \(actionIndex + 1)")
                .font(.caption.weight(.semibold))
        }
        .accessibilityIdentifier(actionAccessibilityID(nil))
    }

    private var logEditor: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            ForEach($action.logFragments) { $fragment in
                let fragmentIndex = fragmentIndex(for: fragment.id)
                HStack(spacing: Lumen.Space.s4) {
                    Picker("Fragment Type", selection: $fragment.kind) {
                        ForEach(LogicalBreakpointEditorLogFragmentKind.allCases) { kind in
                            Text(kind.title)
                                .tag(kind)
                                .disabled(kind == .targetExpression && !canAuthorTargetExpressions)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .disabled(!canAuthorActions)
                    .accessibilityIdentifier(fragmentAccessibilityID(fragmentIndex, "kind"))

                    TextField(
                        fragment.kind == .literal ? "Log text" : "Target expression",
                        text: $fragment.value
                    )
                    .disabled(
                        !canAuthorActions
                            || (fragment.kind == .targetExpression
                                && !canAuthorTargetExpressions)
                    )
                    .accessibilityIdentifier(fragmentAccessibilityID(fragmentIndex, "value"))

                    Button(role: .destructive) {
                        action.logFragments.removeAll { $0.id == fragment.id }
                    } label: {
                        Image(systemName: LogicalBreakpointEditorSymbols.delete)
                    }
                    .help("Delete log fragment")
                    .accessibilityIdentifier(fragmentAccessibilityID(fragmentIndex, "delete"))
                }
                .accessibilityIdentifier(fragmentAccessibilityID(fragmentIndex, nil))
            }

            Menu {
                Button("Text Fragment") {
                    action.logFragments.append(LogicalBreakpointEditorLogFragmentDraft(kind: .literal))
                }
                Button("Target Expression Fragment") {
                    action.logFragments.append(LogicalBreakpointEditorLogFragmentDraft(kind: .targetExpression))
                }
                .disabled(
                    !canAuthorTargetExpressions
                        || expressionFragmentCount >= Self.maximumLogFragments
                        || action.logFragments.count >= Self.maximumLogFragments
                )
            } label: {
                Label("Add Log Fragment", systemImage: LogicalBreakpointEditorSymbols.add)
            }
            .controlSize(.small)
            .disabled(!canAuthorActions || action.logFragments.count >= Self.maximumLogFragments)
            .help(!canAuthorActions
                ? "Typed-action authoring is unavailable for the current debugger capability set."
                : action.logFragments.count >= Self.maximumLogFragments
                    ? "A log template may contain at most \(Self.maximumLogFragments) editable fragments."
                    : "Append a bounded text or target-expression fragment.")
            .accessibilityIdentifier(actionAccessibilityID("add-fragment"))

            if action.logFragments.contains(where: { $0.kind == .targetExpression })
                && !canAuthorTargetExpressions {
                capabilityUnavailableLabel
            }
        }
        .accessibilityIdentifier(actionAccessibilityID("fragments"))
    }

    private var expressionFragmentCount: Int {
        action.logFragments.filter { $0.kind == .targetExpression }.count
    }

    private func actionAccessibilityID(_ suffix: String?) -> String {
        LogicalBreakpointEditorAccessibilityID.action(actionIndex, suffix: suffix)
    }

    private func fragmentAccessibilityID(_ index: Int, _ suffix: String?) -> String {
        LogicalBreakpointEditorAccessibilityID.fragment(
            actionIndex: actionIndex,
            fragmentIndex: index,
            suffix: suffix
        )
    }

    private func fragmentIndex(for id: UUID) -> Int {
        action.logFragments.firstIndex(where: { $0.id == id }) ?? 0
    }

    private var capabilityUnavailableLabel: some View {
        Label(
            "Target-expression authoring awaits the current-Xcode live capability proof.",
            systemImage: LogicalBreakpointEditorSymbols.capability
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private static let maximumLogFragments = 32
}

private enum LogicalBreakpointEditorAccessibilityID {
    private static let base = "debugger.logical-breakpoint-editor"
    static let sheet = "\(base).sheet"
    static let title = "\(base).title"
    static let owner = "\(base).owner"
    static let locator = "\(base).locator"
    static let enabled = "\(base).enabled"
    static let condition = "\(base).condition"
    static let hitPolicy = "\(base).hit-policy"
    static let skipFirstCount = "\(base).skip-first-count"
    static let disposition = "\(base).disposition"
    static let actions = "\(base).actions"
    static let addAction = "\(base).add-action"
    static let capabilityNotice = "\(base).capability-notice"
    static let validation = "\(base).validation"
    static let cancel = "\(base).cancel"
    static let save = "\(base).save"
    static let preferredAddress = "\(base).preferred-address"
    static let segmentName = "\(base).segment-name"
    static let segmentPreferredStart = "\(base).segment-preferred-start"
    static let imageOffset = "\(base).image-offset"
    static let functionEntry = "\(base).function-entry"
    static let functionLinkageHint = "\(base).function-linkage-hint"
    static let symbolLinkageName = "\(base).symbol-linkage-name"
    static let symbolKind = "\(base).symbol-kind"
    static let symbolLibrary = "\(base).symbol-library"
    static let matchingSites = "\(base).matching-sites"
    static let sourceFile = "\(base).source-file"
    static let sourceLine = "\(base).source-line"
    static let sourceUseExactColumn = "\(base).source-use-exact-column"
    static let sourceColumn = "\(base).source-column"

    static func action(_ index: Int, suffix: String?) -> String {
        let action = "\(base).action.\(index)"
        guard let suffix else { return action }
        return "\(action).\(suffix)"
    }

    static func fragment(actionIndex: Int, fragmentIndex: Int, suffix: String?) -> String {
        let fragment = "\(action(actionIndex, suffix: nil)).fragment.\(fragmentIndex)"
        guard let suffix else { return fragment }
        return "\(fragment).\(suffix)"
    }
}

private enum LogicalBreakpointEditorSymbols {
    static let add = "plus"
    static let capability = "lock"
    static let delete = "trash"
    static let moveDown = "arrow.down"
    static let moveUp = "arrow.up"
    static let validation = "exclamationmark.triangle.fill"
}

private extension DebuggerCanonicalSourceTablePath {
    var logicalBreakpointEditorDisplayPath: String {
        let value: String
        switch self {
        case .absoluteUTF8(let path), .compilationDirectoryRelativeUTF8(let path):
            value = path
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        if (value.hasPrefix("/Users/") || value.hasPrefix("/home/")), components.count >= 2 {
            let suffix = components.dropFirst(2).joined(separator: "/")
            return suffix.isEmpty ? "<home>" : "<home>/\(suffix)"
        }
        return value
    }
}
