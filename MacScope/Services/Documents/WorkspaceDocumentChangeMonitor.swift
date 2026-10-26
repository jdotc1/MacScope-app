import Foundation
import Synchronization

protocol WorkspaceDocumentFilePresenterRegistering: Sendable {
    func add(_ presenter: WorkspaceDocumentFilePresenterBridge)
    func remove(_ presenter: WorkspaceDocumentFilePresenterBridge)
}

struct FoundationWorkspaceDocumentFilePresenterRegistrar:
    WorkspaceDocumentFilePresenterRegistering {
    func add(_ presenter: WorkspaceDocumentFilePresenterBridge) {
        NSFileCoordinator.addFilePresenter(presenter)
    }

    func remove(_ presenter: WorkspaceDocumentFilePresenterBridge) {
        NSFileCoordinator.removeFilePresenter(presenter)
    }
}

final class WorkspaceDocumentFilePresenterBridge:
    NSObject,
    NSFilePresenter,
    @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let emitHint: @Sendable (WorkspaceDocumentChangeHint) -> Void

    init(
        location: WorkspaceDocumentLocation,
        emitHint: @escaping @Sendable (WorkspaceDocumentChangeHint) -> Void
    ) {
        self.presentedItemURL = location.canonicalURL
        let queue = OperationQueue()
        queue.name = "org.macscope.workspace-document-presenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.emitHint = emitHint
        super.init()
    }

    func presentedItemDidChange() {
        emitHint(.changed)
    }

    func presentedItemDidMove(to newURL: URL) {
        emitHint(.moved)
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping (Error?) -> Void
    ) {
        emitHint(.deleted)
        completionHandler(nil)
    }
}

struct WorkspaceDocumentChangeMonitor: WorkspaceDocumentChangeMonitoring {
    private let registrar: any WorkspaceDocumentFilePresenterRegistering

    init(
        registrar: any WorkspaceDocumentFilePresenterRegistering =
            FoundationWorkspaceDocumentFilePresenterRegistrar()
    ) {
        self.registrar = registrar
    }

    func changes(
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentChangeFeed {
        let pair = AsyncStream.makeStream(
            of: WorkspaceDocumentChangeHint.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let probeDemand = WorkspaceDocumentProbeDemand()
        let sink = WorkspaceDocumentChangeHintSink(
            continuation: pair.continuation,
            probeDemand: probeDemand
        )
        let presenter = WorkspaceDocumentFilePresenterBridge(
            location: location,
            emitHint: { hint in
                sink.yield(hint)
            }
        )
        let registration = WorkspaceDocumentPresenterRegistration(
            presenter: presenter,
            registrar: registrar
        )
        pair.continuation.onTermination = { @Sendable _ in
            registration.cancel()
        }
        return WorkspaceDocumentChangeFeed(
            stream: pair.stream,
            probeDemand: probeDemand
        )
    }
}

private actor WorkspaceDocumentChangeHintSink {
    nonisolated let continuation: AsyncStream<WorkspaceDocumentChangeHint>.Continuation
    nonisolated let probeDemand: WorkspaceDocumentProbeDemand

    init(
        continuation: AsyncStream<WorkspaceDocumentChangeHint>.Continuation,
        probeDemand: WorkspaceDocumentProbeDemand
    ) {
        self.continuation = continuation
        self.probeDemand = probeDemand
    }

    nonisolated func yield(_ hint: WorkspaceDocumentChangeHint) {
        probeDemand.admit()
        continuation.yield(hint)
    }
}

private final class WorkspaceDocumentPresenterRegistration: Sendable {
    private let registrar: any WorkspaceDocumentFilePresenterRegistering
    private let presenter: Mutex<WorkspaceDocumentFilePresenterBridge?>

    init(
        presenter: WorkspaceDocumentFilePresenterBridge,
        registrar: any WorkspaceDocumentFilePresenterRegistering
    ) {
        self.registrar = registrar
        self.presenter = Mutex(presenter)
        registrar.add(presenter)
    }

    func cancel() {
        let registeredPresenter = presenter.withLock { presenter in
            defer { presenter = nil }
            return presenter
        }
        if let registeredPresenter {
            registrar.remove(registeredPresenter)
        }
    }

    deinit {
        cancel()
    }
}
