import Foundation

@MainActor
protocol WorkspaceDocumentContentSource: AnyObject {
    var documentID: UUID { get }
    var workspaceID: UUID { get }
    var mutationGeneration: WorkspaceDocumentMutationGeneration { get }
    var hasUnsavedChanges: Bool { get }

    func makePackagePayload() throws -> WorkspaceDocumentPackagePayload
    func installValidatedPackage(
        _ package: WorkspaceDocumentValidatedPackage,
        from location: WorkspaceDocumentLocation
    ) throws
    func acceptPublishedWrite(
        capturedGeneration: WorkspaceDocumentMutationGeneration,
        adopting location: WorkspaceDocumentLocation?
    )
}

@MainActor
protocol WorkspaceDocumentMutationObserving: AnyObject {
    func noteMutation(_ generation: WorkspaceDocumentMutationGeneration)
}

extension WorkspaceStore: WorkspaceDocumentContentSource {}
