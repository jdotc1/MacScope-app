import Foundation
import Darwin

/// Each invocation owns a fresh authenticated connection. Invalidation ends a client
/// wait only; it is never evidence that the broker's process group has terminated.
protocol REAAssetCatalogCaptureTransport: Sendable {
    func request(_ request: REAAssetCatalogCaptureRequest) async throws -> Data
    func cancel(_ request: REAAssetCatalogCaptureRequest)
    func retire()
}

final class REASignedAssetCatalogCaptureTransport: REAAssetCatalogCaptureTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: REAAssetCaptureWaiter?
    private var used = false
    private var canceled = false

    func request(_ request: REAAssetCatalogCaptureRequest) async throws -> Data {
        let bytes = try REAAssetCatalogAuthority.encode(request)
        let waiter = REAAssetCaptureWaiter()
        let channel = NSXPCConnection(machServiceName: Phase2ShellBrokerProtocolIdentity.persistentMachServiceName, options: [])
        channel.remoteObjectInterface = NSXPCInterface(with: Phase2ShellBrokerXPCProtocol.self)
        channel.setCodeSigningRequirement(Phase2ShellBrokerPeerRequirement.launchAgent)
        let admitted = lock.withLock { () -> Bool in
            guard !used, !canceled else { return false }
            used = true; connection = channel; pending = waiter; return true
        }
        guard admitted else { throw REAAssetCatalogCaptureProvider.Failure.unavailable }
        channel.interruptionHandler = { [weak self] in self?.retire() }
        channel.invalidationHandler = { [weak self] in self?.retire() }
        channel.resume()
        guard let proxy = channel.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(error))
        }) as? Phase2ShellBrokerXPCProtocol else {
            retire(); throw REAAssetCatalogCaptureProvider.Failure.unavailable
        }
        proxy.handshake { data in
            do {
                guard data.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                    throw REAAssetCatalogCaptureProvider.Failure.invalidReply
                }
                let hello = try Phase2ShellBrokerWireCodec.decodeHandshake(data)
                guard hello.schemaVersion == Phase2ShellBrokerProtocolIdentity.schemaVersion,
                      hello.serviceIdentifier == Phase2ShellBrokerProtocolIdentity.serviceIdentifier,
                      hello.wireProtocol == Phase2ShellBrokerProtocolIdentity.wireProtocol,
                      hello.status == .boundaryReady,
                      hello.maximumMessageBytes == Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
                    throw REAAssetCatalogCaptureProvider.Failure.invalidReply
                }
                guard !waiter.isFinished else { return }
                proxy.executeAssetCatalog(bytes) { waiter.finish(.success($0)) }
            } catch { waiter.finish(.failure(error)) }
        }
        return try await waiter.value()
    }
    func cancel(_ request: REAAssetCatalogCaptureRequest) {
        let channel = lock.withLock { canceled = true; return connection }
        guard let channel, let data = try? REAAssetCatalogAuthority.encode(request),
              let proxy = channel.remoteObjectProxyWithErrorHandler({ _ in }) as? Phase2ShellBrokerXPCProtocol else { return }
        proxy.cancelAssetCatalog(data) { _ in }
    }
    func retire() {
        let saved = lock.withLock { () -> (NSXPCConnection?, REAAssetCaptureWaiter?) in
            used = true; canceled = true
            let saved = (connection, pending); connection = nil; pending = nil; return saved
        }
        saved.1?.finish(.failure(REAAssetCatalogCaptureProvider.Failure.unavailable))
        saved.0?.invalidationHandler = nil; saved.0?.interruptionHandler = nil
        saved.0?.invalidate()
    }
}

final class REAAssetCatalogCaptureProvider: Sendable {
    enum Failure: Error, Equatable, Sendable { case invalidInput, invalidReply, rejected, timeout, unavailable }
    struct AcceptedCapture: Sendable {
        let request: REAAssetCatalogCaptureRequest
        let response: REAAssetCatalogCaptureResponse
        let producerReceiptSHA256: String
        var catalog: REAUIAssetCatalogCapture {
            .init(targetSHA256:request.targetSHA256,snapshotID:request.snapshotID,path:request.relativePath,
                catalogSHA256:request.catalogSHA256,captureID:request.captureID.uuidString,toolSHA256:request.toolSHA256,
                metadataSHA256:response.metadataSHA256,metadataBytes:response.metadata)
        }
        fileprivate init(request: REAAssetCatalogCaptureRequest, response: REAAssetCatalogCaptureResponse) throws {
            self.request = request; self.response = response
            producerReceiptSHA256 = REAAssetCatalogAuthority.digest(try REAAssetCatalogAuthority.encode(response))
        }
    }
    private let makeTransport: @Sendable () -> any REAAssetCatalogCaptureTransport
    private let timeoutNanoseconds: UInt64
    init(timeout: TimeInterval = 30,
         makeTransport: @escaping @Sendable () -> any REAAssetCatalogCaptureTransport = { REASignedAssetCatalogCaptureTransport() }) {
        self.makeTransport = makeTransport
        timeoutNanoseconds = UInt64(min(max(timeout.isFinite ? timeout : 30,0.001),30)*1_000_000_000)
    }
    func capture(_ request: REAAssetCatalogCaptureRequest) async throws -> AcceptedCapture {
        try Task.checkCancellation(); try REAAssetCatalogAuthority.verify(request)
        let transport = makeTransport(), waiter = REAAssetCaptureWaiter()
        let timer = Task {
            try? await Task.sleep(nanoseconds:timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            waiter.finish(.failure(Failure.timeout)) { transport.cancel(request); transport.retire() }
        }
        Task { do { waiter.finish(.success(try await transport.request(request))) } catch { waiter.finish(.failure(error)) } }
        let bytes: Data
        do { bytes = try await withTaskCancellationHandler { try await waiter.value() } onCancel: {
            waiter.finish(.failure(CancellationError())) { transport.cancel(request); transport.retire() }
        } } catch { timer.cancel(); transport.retire(); throw error }
        timer.cancel(); defer { transport.retire() }
        guard bytes.count <= 12_000_000, let response = try? JSONDecoder().decode(REAAssetCatalogCaptureResponse.self,from:bytes),
              (try? REAAssetCatalogAuthority.encode(response)) == bytes, response.request == request else { throw Failure.invalidReply }
        if response.cleanup?.requestID == request.requestID, response.cleanup?.sessionID == request.sessionID,
           response.cleanup?.observedProcessAbsent == true, (response.cleanup?.processIdentifier ?? 0) > 1,
           response.cleanup?.outcome == response.terminal {
            try Self.removeStage(request.stageRootPath)
        }
        guard response.isAccepted,
              (try? REAAssetCatalogAuthority.metadataJSON(response.metadata)) != nil else { throw Failure.rejected }
        try Task.checkCancellation(); return try AcceptedCapture(request:request,response:response)
    }
    static func stage(catalogBytes: Data, relativePath: String, selectedImage: LoadedBinary, snapshotID: String, runner: URL,
        parent: URL = MacScopeWorkRoot.url.appendingPathComponent("REA-Asset-Captures", isDirectory: true)) throws -> REAAssetCatalogCaptureRequest {
        guard !catalogBytes.isEmpty, catalogBytes.count <= 67_108_864,
              MacScopeWorkRoot.contains(parent.path), parent.resolvingSymlinksInPath().path == parent.path else { throw Failure.invalidInput }
        let target = try REAUIResourceProjection.selectedSliceSHA256(selectedImage)
        let runnerHash = REAAssetCatalogAuthority.digest(try REAAssetCatalogAuthority.bytes(runner.path,maximum:268_435_456,owner:getuid(),readOnly:false))
        let toolHash = REAAssetCatalogAuthority.digest(try REAAssetCatalogAuthority.bytes("/usr/bin/assetutil",maximum:67_108_864,owner:0,readOnly:false))
        let fm = FileManager.default
        try fm.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var info = stat(); guard lstat(parent.path,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw Failure.invalidInput }
        let root = parent.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            guard fm.createFile(atPath:root.appendingPathComponent("catalog.car").path,contents:catalogBytes,attributes:[.posixPermissions:0o400]) else { throw Failure.invalidInput }
            let request = REAAssetCatalogCaptureRequest(requestID:UUID(),sessionID:UUID(),captureID:UUID(),stageRootPath:root.path,
                relativePath:relativePath,targetSHA256:target,snapshotID:snapshotID,catalogSHA256:REAAssetCatalogAuthority.digest(catalogBytes),
                catalogByteCount:UInt64(catalogBytes.count),toolSHA256:toolHash,runnerSHA256:runnerHash)
            try REAAssetCatalogAuthority.verify(request); return request
        } catch { try? fm.removeItem(at:root); throw error }
    }
    private static func removeStage(_ path: String) throws {
        guard MacScopeWorkRoot.contains(path),URL(fileURLWithPath:path).resolvingSymlinksInPath().path == path else { throw Failure.invalidInput }
        try FileManager.default.removeItem(atPath:path)
    }
}

private final class REAAssetCaptureWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?
    var isFinished: Bool { lock.withLock { result != nil } }
    @discardableResult func finish(_ value: Result<Data, Error>, beforeResume: () -> Void = {}) -> Bool {
        let saved = lock.withLock { () -> (Bool, CheckedContinuation<Data, Error>?) in
            guard result == nil else { return (false, nil) }
            result = value; let saved = continuation; continuation = nil; return (true, saved)
        }
        if saved.0 { beforeResume() }
        saved.1?.resume(with: value); return saved.0
    }
    func value() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let saved = lock.withLock { () -> Result<Data, Error>? in
                if let result { return result }; self.continuation = continuation; return nil
            }
            if let saved { continuation.resume(with: saved) }
        }
    }
}
