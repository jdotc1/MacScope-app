import Foundation
import XCTest
@testable import MacScope

final class Phase2LocalModelLifecycleCommandTests: XCTestCase {
    func testLoadCommandPreservesExactAuthorityModelAndContext() throws {
        let endpoint = try makeEndpoint(generation: 7)
        let inventory = try makeInventory(endpoint: endpoint)
        let effectID = UUID(uuidString: "720EE4F0-72AE-4402-8D3E-277B0D6249CA")!

        let command = try Phase2LocalModelLifecycleCommand.authorizeLoad(
            effectID: effectID,
            endpoint: endpoint,
            inventory: inventory,
            modelKey: languageModelKey,
            requestedContextLength: 32_768
        )

        XCTAssertEqual(command.effectID, effectID)
        XCTAssertEqual(command.profileID, endpoint.profileID)
        XCTAssertEqual(command.generation, 7)
        XCTAssertEqual(
            command.operation,
            .load(modelKey: languageModelKey, requestedContextLength: 32_768)
        )
    }

    func testLoadRejectsInventoryFromAnotherProfileOrGeneration() throws {
        let endpoint = try makeEndpoint(generation: 7)
        let otherProfile = try makeEndpoint(profileID: UUID(), generation: 7)
        let nextGeneration = try makeEndpoint(
            profileID: endpoint.profileID,
            generation: 8
        )

        for inventory in [
            try makeInventory(endpoint: otherProfile),
            try makeInventory(endpoint: nextGeneration),
        ] {
            XCTAssertThrowsError(try Phase2LocalModelLifecycleCommand.authorizeLoad(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: languageModelKey,
                requestedContextLength: 4_096
            )) { error in
                XCTAssertEqual(
                    error as? Phase2LocalModelLifecycleValidationError,
                    .inventoryIdentityMismatch
                )
            }
        }
    }

    func testLoadRequiresAnExactLanguageModelKey() throws {
        let endpoint = try makeEndpoint()
        let inventory = try makeInventory(endpoint: endpoint)

        XCTAssertThrowsError(try Phase2LocalModelLifecycleCommand.authorizeLoad(
            effectID: UUID(),
            endpoint: endpoint,
            inventory: inventory,
            modelKey: "publisher/missing",
            requestedContextLength: 4_096
        )) { error in
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .modelNotFound
            )
        }

        XCTAssertThrowsError(try Phase2LocalModelLifecycleCommand.authorizeLoad(
            effectID: UUID(),
            endpoint: endpoint,
            inventory: inventory,
            modelKey: embeddingModelKey,
            requestedContextLength: 2_048
        )) { error in
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .modelNotLanguage
            )
        }
    }

    func testLoadContextIsBoundedByModelMaximumAndGlobalMaximum() throws {
        let endpoint = try makeEndpoint()
        let inventory = try makeInventory(
            endpoint: endpoint,
            languageMaximumContextLength: 32_768
        )

        XCTAssertNoThrow(try Phase2LocalModelLifecycleCommand.authorizeLoad(
            effectID: UUID(),
            endpoint: endpoint,
            inventory: inventory,
            modelKey: languageModelKey,
            requestedContextLength: 32_768
        ))

        for invalidContext in [0, 32_769] {
            XCTAssertThrowsError(try Phase2LocalModelLifecycleCommand.authorizeLoad(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: languageModelKey,
                requestedContextLength: invalidContext
            )) { error in
                XCTAssertEqual(
                    error as? Phase2LocalModelLifecycleValidationError,
                    .invalidContextLength
                )
            }
        }

        let overGlobalMaximum = try makeInventory(
            endpoint: endpoint,
            languageMaximumContextLength: 4_194_305
        )
        XCTAssertThrowsError(try Phase2LocalModelLifecycleCommand.authorizeLoad(
            effectID: UUID(),
            endpoint: endpoint,
            inventory: overGlobalMaximum,
            modelKey: languageModelKey,
            requestedContextLength: 4_194_305
        )) { error in
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .invalidContextLength
            )
        }
    }

    func testUnloadPreservesExactOwnedRuntimeIdentityAndObservedConfiguration() async throws {
        let endpoint = try makeEndpoint(generation: 11)
        let configuration = makeObservedConfiguration()
        let inventory = try makeInventory(
            endpoint: endpoint,
            loadedInstance: .init(id: loadedInstanceID, configuration: configuration)
        )
        let ownership = Phase2LocalModelOwnership(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: languageModelKey,
            instanceID: loadedInstanceID
        )
        let ledger = Phase2LocalModelOwnershipLedger()
        await ledger.recordReconciledLoad(ownership)
        let effectID = UUID(uuidString: "05565B05-E878-40C7-B453-E00C84FD364B")!

        let command = try await Phase2LocalModelLifecycleCommand.authorizeUnload(
            effectID: effectID,
            endpoint: endpoint,
            inventory: inventory,
            modelKey: languageModelKey,
            instanceID: loadedInstanceID,
            observedConfiguration: configuration,
            ownershipLedger: ledger
        )

        XCTAssertEqual(command.effectID, effectID)
        XCTAssertEqual(command.profileID, endpoint.profileID)
        XCTAssertEqual(command.generation, endpoint.generation)
        XCTAssertEqual(
            command.operation,
            .unload(
                modelKey: languageModelKey,
                instanceID: loadedInstanceID,
                observedConfiguration: configuration
            )
        )
    }

    func testUnloadRejectsAnInstanceThatExistsButIsNotOwnedByThisRuntime() async throws {
        let endpoint = try makeEndpoint()
        let configuration = makeObservedConfiguration()
        let inventory = try makeInventory(
            endpoint: endpoint,
            loadedInstance: .init(id: loadedInstanceID, configuration: configuration)
        )

        do {
            _ = try await Phase2LocalModelLifecycleCommand.authorizeUnload(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: languageModelKey,
                instanceID: loadedInstanceID,
                observedConfiguration: configuration,
                ownershipLedger: Phase2LocalModelOwnershipLedger()
            )
            XCTFail("an externally loaded instance must not acquire unload authority")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .instanceNotOwned
            )
        }
    }

    func testUnloadRequiresExactModelInstanceAndObservedConfiguration() async throws {
        let endpoint = try makeEndpoint()
        let configuration = makeObservedConfiguration()
        let inventory = try makeInventory(
            endpoint: endpoint,
            loadedInstance: .init(id: loadedInstanceID, configuration: configuration)
        )
        let ledger = Phase2LocalModelOwnershipLedger()
        await ledger.recordReconciledLoad(.init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: languageModelKey,
            instanceID: loadedInstanceID
        ))

        do {
            _ = try await Phase2LocalModelLifecycleCommand.authorizeUnload(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: "publisher/missing",
                instanceID: loadedInstanceID,
                observedConfiguration: configuration,
                ownershipLedger: ledger
            )
            XCTFail("an instance must resolve under the exact observed model")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .modelNotFound
            )
        }

        do {
            _ = try await Phase2LocalModelLifecycleCommand.authorizeUnload(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: languageModelKey,
                instanceID: "different-instance",
                observedConfiguration: configuration,
                ownershipLedger: ledger
            )
            XCTFail("an unload target must be the exact observed instance")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .instanceNotFound
            )
        }

        let changedConfiguration = Phase2LocalModelInstanceConfiguration(
            effectiveContextLength: configuration.effectiveContextLength + 1,
            evaluationBatchSize: configuration.evaluationBatchSize,
            parallelPredictions: configuration.parallelPredictions,
            flashAttention: configuration.flashAttention,
            expertCount: configuration.expertCount,
            offloadsKVCacheToGPU: configuration.offloadsKVCacheToGPU
        )
        do {
            _ = try await Phase2LocalModelLifecycleCommand.authorizeUnload(
                effectID: UUID(),
                endpoint: endpoint,
                inventory: inventory,
                modelKey: languageModelKey,
                instanceID: loadedInstanceID,
                observedConfiguration: changedConfiguration,
                ownershipLedger: ledger
            )
            XCTFail("an unload target must retain the exact observed configuration")
        } catch {
            XCTAssertEqual(
                error as? Phase2LocalModelLifecycleValidationError,
                .instanceConfigurationMismatch
            )
        }
    }

    func testLedgerAddsAndRemovesOwnershipOnlyAtReconciliationTransitions() async throws {
        let endpoint = try makeEndpoint(generation: 3)
        let ownership = Phase2LocalModelOwnership(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            modelKey: languageModelKey,
            instanceID: loadedInstanceID
        )
        let ledger = Phase2LocalModelOwnershipLedger()

        var isOwned = await ledger.contains(ownership)
        XCTAssertFalse(isOwned)

        await ledger.recordReconciledLoad(ownership)
        isOwned = await ledger.contains(ownership)
        XCTAssertTrue(isOwned)

        await ledger.recordReconciledUnload(ownership)
        isOwned = await ledger.contains(ownership)
        XCTAssertFalse(isOwned)
    }

    func testLedgerDiscardsOwnershipWhenEndpointGenerationChanges() async throws {
        let profileID = UUID(uuidString: "859FE30A-83F3-4CB4-A8C5-97D57870B466")!
        let firstEndpoint = try makeEndpoint(profileID: profileID, generation: 4)
        let nextEndpoint = try makeEndpoint(profileID: profileID, generation: 5)
        let ownership = Phase2LocalModelOwnership(
            profileID: profileID,
            generation: firstEndpoint.generation,
            modelKey: languageModelKey,
            instanceID: loadedInstanceID
        )
        let ledger = Phase2LocalModelOwnershipLedger()

        await ledger.activate(endpoint: firstEndpoint)
        await ledger.recordReconciledLoad(ownership)
        var isOwned = await ledger.contains(ownership)
        XCTAssertTrue(isOwned)

        await ledger.activate(endpoint: nextEndpoint)
        isOwned = await ledger.contains(ownership)
        XCTAssertFalse(isOwned)
        let entries = await ledger.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    private func makeEndpoint(
        profileID: UUID = UUID(uuidString: "3B0AA43F-5552-4691-98B6-3A132A43E51D")!,
        generation: UInt64 = 1
    ) throws -> Phase2LocalProviderEndpoint {
        try .init(
            profileID: profileID,
            generation: generation,
            endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
    }

    private func makeInventory(
        endpoint: Phase2LocalProviderEndpoint,
        languageMaximumContextLength: Int = 262_144,
        loadedInstance: Phase2LocalModelLoadedInstance? = nil
    ) throws -> Phase2LocalModelInventory {
        let language = Phase2LocalModelDescriptor(
            type: .language,
            publisher: "publisher",
            key: languageModelKey,
            displayName: "Language Model",
            architecture: "qwen",
            quantization: .init(name: "Q4_K_M", bitsPerWeight: 4),
            sizeBytesOnDisk: 15_000_000_000,
            parameterCountDescription: "30B-A3B",
            maximumContextLength: languageMaximumContextLength,
            format: .gguf,
            capabilities: .init(
                supportsVision: false,
                trainedForToolUse: true,
                reasoning: .init(allowedOptions: [.off], defaultOption: .off)
            ),
            variants: [languageModelKey],
            providerSelectedVariant: languageModelKey,
            loadedInstances: loadedInstance.map { [$0] } ?? []
        )
        let embedding = Phase2LocalModelDescriptor(
            type: .embedding,
            publisher: "publisher",
            key: embeddingModelKey,
            displayName: "Embedding Model",
            architecture: nil,
            quantization: nil,
            sizeBytesOnDisk: 1,
            parameterCountDescription: nil,
            maximumContextLength: 2_048,
            format: .gguf,
            capabilities: nil,
            variants: [],
            providerSelectedVariant: nil,
            loadedInstances: []
        )
        return try .init(
            profileID: endpoint.profileID,
            generation: endpoint.generation,
            models: [language, embedding]
        )
    }

    private func makeObservedConfiguration() -> Phase2LocalModelInstanceConfiguration {
        .init(
            effectiveContextLength: 32_768,
            evaluationBatchSize: 512,
            parallelPredictions: nil,
            flashAttention: true,
            expertCount: 8,
            offloadsKVCacheToGPU: true
        )
    }

    private var languageModelKey: String { "publisher/exact-language@q4_k_m" }
    private var embeddingModelKey: String { "publisher/exact-embedding" }
    private var loadedInstanceID: String { "runtime-instance-7" }
}
