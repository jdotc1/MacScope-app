import Foundation

/// Production Assistant admission without an application scene. The caller owns workspace
/// admission, heavy-job serialization, saving, reopening, and comparison of persisted state.
@MainActor
enum HeadlessWorkspaceREAAcceptance {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(store: WorkspaceStore, prompt: String, artifactRoot: URL) async throws -> ScriptValue {
        let root = artifactRoot.appendingPathComponent("rea-assistant-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var observations: [String: ScriptValue] = [
            "artifactRoot": .string(root.path), "prompt": .string(prompt),
            "evidenceScope": .string("headless production Assistant; caller must separately save and reopen")
        ]
        var stage = "saved-preference"
        func receipt(_ passed: Bool, error: String? = nil) -> ScriptValue {
            var fields = observations
            fields["passed"] = .bool(passed)
            fields["stage"] = .string(stage)
            fields["error"] = error.map(ScriptValue.string) ?? .null
            return .object(fields)
        }
        do {
            let storedPreference = UserDefaults.standard.object(
                forKey: UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
            )
            observations["preferenceSource"] = .string(storedPreference == nil
                ? "production-quality-default" : "saved-provider-preference")
            let preference = try preferenceWithoutMutation(storedObject: storedPreference)
            let controller = Phase2LocalAIProviderController(
                preferenceStore: InMemoryPhase2LocalAIProviderPreferenceStore(initialPreference: preference)
            )
            guard controller.snapshot.endpoint?.providerKind == .mtplx else {
                throw Failure(description: "Provider preference does not select supported MTPLX authority")
            }
            stage = "readiness"
            _ = try await controller.refresh()
            observations["readiness"] = .string(String(describing: controller.snapshot.readiness))
            guard controller.captureReadyInferenceLease() != nil else {
                throw Failure(description: "MTPLX selection is not ready; no model lifecycle action was attempted")
            }
            // A historical target is explicit in the caller's prompt, never guessed from order.
            let targets = store.reaResultEvidence.records.filter {
                $0.authority.workspaceID == store.workspaceID
                    && prompt.localizedCaseInsensitiveContains($0.evidenceID.uuidString)
            }
            guard targets.count == 1, let target = targets.first else {
                throw Failure(description: "Prompt must identify exactly one admitted REA evidence UUID")
            }
            observations["targetEvidenceID"] = .string(target.evidenceID.uuidString)
            observations["targetResponseSHA256"] = .string(target.responseSHA256)
            let coordinator = Phase2ReadyInferenceCoordinator(controller: controller)
            let turn = store.preparePhase2AssistantConversationTurn(conversationID: UUID())
            let token = Phase2AssistantPublicationToken.capture(intent: .askMacScope, store: store)
            stage = "assistant-inference"
            let result = await Phase2AssistantSessionRunner().run(
                intent: .askMacScope, userGoal: prompt, store: store, coordinator: coordinator,
                turnContext: turn,
                contextOptions: .init(includeApplicationGraphContext: false, useProviderVisibleToolSelection: true)
            )
            observations["sessionFailure"] = .string(String(describing: result.failure))
            observations["inferenceDisposition"] = .string(String(describing: result.inferenceOutcome?.disposition))
            observations["violation"] = .string(String(describing: result.inferenceOutcome?.violation))
            observations["readOperations"] = .array(result.readExecutions.map { .string($0.candidate.operationID.rawValue) })
            observations["answer"] = result.inferenceOutcome?.finalCandidate.map { .string($0.text) } ?? .null
            stage = "accepted-historical-read"
            guard !Task.isCancelled, token.isCurrent(in: store), result.isAcceptedFinalAnswer,
                  let outcome = result.inferenceOutcome, outcome.violation == nil,
                  outcome.toolProposals.isEmpty, outcome.shellProposals.isEmpty,
                  outcome.debuggerActionProposals.isEmpty,
                  let candidate = outcome.finalCandidate, let context = result.groundedContext else {
                throw Failure(description: "Production runner did not accept a current citation-grounded answer without actions")
            }
            var matchedReads: [ScriptValue] = []
            for execution in result.readExecutions where execution.candidate.operationID == .reaResultsGet {
                guard execution.acceptedEvidence != nil,
                      case let .value(.object(fields)) = execution.candidate.data,
                      case let .text(text)? = fields.first(where: { $0.name == "acceptedREAResult" })?.value,
                      let page = try? JSONDecoder().decode(REAResultReadProjection.TextPage.self, from: Data(text.utf8)),
                      page.record.evidenceID == target.evidenceID,
                      page.record.responseSHA256 == target.responseSHA256,
                      let grounded = context.records.first(where: { $0.candidateID == execution.candidate.candidateID }),
                      candidate.evidenceIDs.contains(grounded.evidenceID) else { continue }
                matchedReads.append(.object([
                    "evidenceID": .string(page.record.evidenceID.uuidString),
                    "responseSHA256": .string(page.record.responseSHA256),
                    "citedGroundedEvidenceID": .string(grounded.evidenceID.uuidString),
                    "offset": .int(Int64(page.offset)), "text": .string(page.text)
                ]))
            }
            observations["matchedHistoricalReads"] = .array(matchedReads)
            guard !matchedReads.isEmpty else {
                throw Failure(description: "Final answer did not cite an actual accepted rea.results.get read of the requested record")
            }
            stage = "record-terminal-state"
            let state = Phase2AssistantDisplayMapper.state(for: result)
            guard let recorded = store.recordPhase2AssistantTerminalState(
                state, intent: .askMacScope, userGoal: prompt, turnContext: turn, publicationToken: token
            ), recorded.status == .completed, recorded.answerText == candidate.text else {
                throw Failure(description: "Production store refused the actual completed Assistant state")
            }
            observations["assistantRecordID"] = .string(recorded.id.uuidString)
            observations["conversationID"] = .string(recorded.conversationID.uuidString)
            observations["contentSHA256"] = .string(recorded.contentSHA256)
            observations["contextDigest"] = recorded.contextDigest.map(ScriptValue.string) ?? .null
            stage = "complete"
            let success = receipt(true)
            try success.jsonData(prettyPrinted: true).write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
            return success
        } catch {
            let failure = receipt(false, error: String(describing: error))
            try failure.jsonData(prettyPrinted: true).write(to: root.appendingPathComponent("failure.json"), options: .atomic)
            throw error
        }
    }

    private static func preferenceWithoutMutation(storedObject: Any?) throws -> Phase2LocalAIProviderPreference {
        // Match production app startup only on true absence. An existing invalid or legacy
        // value must never be reinterpreted as permission to select the default model.
        guard let storedObject else { return try .mtplxQualityDefault() }
        let key = UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        guard let data = storedObject as? Data,
              let scratch = UserDefaults(suiteName: "MacScope.HeadlessPreferenceDecode." + UUID().uuidString) else {
            throw Failure(description: "Existing saved provider preference is unreadable")
        }
        // Reuse the production canonical decoder in an isolated volatile domain: its invalid
        // preference cleanup cannot clear or rewrite the user's actual saved configuration.
        scratch.setVolatileDomain([key: data], forName: UserDefaults.argumentDomain)
        defer { scratch.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        guard let preference = UserDefaultsPhase2LocalAIProviderPreferenceStore(defaults: scratch).load() else {
            throw Failure(description: "Saved provider preference failed production decoding")
        }
        return preference
    }
}
