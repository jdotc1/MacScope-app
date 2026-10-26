import Foundation

enum Phase2NativeModelLifecycleHTTPClientError: Error, Equatable, Sendable {
    case cancelledBeforeDispatch
    case authenticationRequired
    case rejected
    case reconciliationRequired
}

enum Phase2NativeModelLifecycleOperation: Equatable, Sendable {
    case load(modelKey: String, contextLength: Int)
    case unload(instanceID: String)
}

struct Phase2NativeModelLoadConfiguration: Equatable, Sendable {
    let contextLength: Int
    let evaluationBatchSize: Int?
    let flashAttention: Bool?
    let expertCount: Int?
    let offloadsKVCacheToGPU: Bool?
}

struct Phase2NativeModelLoadReceipt: Equatable, Sendable {
    let instanceID: String
    let loadTimeSeconds: Double
    let configuration: Phase2NativeModelLoadConfiguration
}

enum Phase2NativeModelLifecycleReceipt: Equatable, Sendable {
    case loaded(Phase2NativeModelLoadReceipt)
    case unloaded(String)
}

struct Phase2NativeModelLifecycleHTTPClient: Sendable {
    static let maximumResponseBytes = 65_536

    private let load: @Sendable (URLRequest) async throws -> Phase2OpenAIChatHTTPResponse
    private let responseByteLimit: Int
    private let requestTimeout: TimeInterval

    init<Loader: Phase2OpenAIChatURLLoading>(
        loader: Loader,
        responseByteLimit: Int = Self.maximumResponseBytes,
        requestTimeout: TimeInterval = 5
    ) {
        precondition((1...Self.maximumResponseBytes).contains(responseByteLimit))
        precondition(requestTimeout > 0)
        load = { try await loader.load($0) }
        self.responseByteLimit = responseByteLimit
        self.requestTimeout = requestTimeout
    }

    init(
        responseByteLimit: Int = Self.maximumResponseBytes,
        requestTimeout: TimeInterval = 5,
        resourceTimeout: TimeInterval = 15
    ) {
        precondition(resourceTimeout >= requestTimeout)
        self.init(
            loader: Self.makeProductionLoader(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout,
                responseByteLimit: responseByteLimit
            ),
            responseByteLimit: responseByteLimit,
            requestTimeout: requestTimeout
        )
    }

    static func makeProductionLoader(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        responseByteLimit: Int
    ) -> Phase2OpenAIChatURLSessionLoader {
        Phase2OpenAIChatURLSessionLoader(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maximumProducedResponseBytes: responseByteLimit
        )
    }

    func perform(
        _ operation: Phase2NativeModelLifecycleOperation,
        at endpoint: Phase2LoopbackEndpoint,
        reserveDispatch: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Phase2NativeModelLifecycleReceipt {
        guard !Task.isCancelled else {
            throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
        }

        let path: String
        let body: Data
        do {
            switch operation {
            case let .load(modelKey, contextLength):
                guard validIdentifier(modelKey), (1...4_194_304).contains(contextLength) else {
                    throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
                }
                path = "/api/v1/models/load"
                body = try sortedJSON([
                    "model": modelKey,
                    "context_length": contextLength,
                    "echo_load_config": true,
                ])
            case let .unload(instanceID):
                guard validIdentifier(instanceID) else {
                    throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
                }
                path = "/api/v1/models/unload"
                body = try sortedJSON(["instance_id": instanceID])
            }
        } catch let error as Phase2NativeModelLifecycleHTTPClientError {
            throw error
        } catch {
            throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
        }

        guard let url = URL(string: endpoint.origin.absoluteString + path) else {
            throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        guard !Task.isCancelled, reserveDispatch() else {
            throw Phase2NativeModelLifecycleHTTPClientError.cancelledBeforeDispatch
        }

        let response: Phase2OpenAIChatHTTPResponse
        do {
            response = try await load(request)
        } catch {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }
        let cancellation = Phase2NativeLifecycleResponseCancellation(response.cancel)
        defer { cancellation.cancel() }

        guard !Task.isCancelled else {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }
        guard response.finalURL == url, !(300...399).contains(response.statusCode) else {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw Phase2NativeModelLifecycleHTTPClientError.authenticationRequired
        }
        guard response.statusCode == 200 else {
            throw Phase2NativeModelLifecycleHTTPClientError.rejected
        }
        guard let contentType = response.contentType,
              !contentType.utf8.contains(0x0D),
              !contentType.utf8.contains(0x0A)
        else {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mediaType == "application/json" else {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }

        var data = Data()
        data.reserveCapacity(min(responseByteLimit, 8_192))
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard chunk.count <= responseByteLimit - data.count else {
                    throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
                }
                data.append(chunk)
            }
            try Task.checkCancellation()
        } catch {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }

        do {
            var validator = Phase2NativeLifecycleJSONValidator(data: data, maximumDepth: 32)
            try validator.validate()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
            }
            switch operation {
            case .load:
                return .loaded(try decodeLoad(root))
            case let .unload(instanceID):
                guard Set(root.keys) == ["instance_id"],
                      let echoed = root["instance_id"] as? String,
                      echoed == instanceID,
                      validIdentifier(echoed)
                else { throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired }
                return .unloaded(echoed)
            }
        } catch let error as Phase2NativeModelLifecycleHTTPClientError {
            throw error
        } catch {
            throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
        }
    }

    private func decodeLoad(_ root: [String: Any]) throws -> Phase2NativeModelLoadReceipt {
        guard Set(root.keys) == ["type", "instance_id", "load_time_seconds", "status", "load_config"],
              root["type"] as? String == "llm",
              root["status"] as? String == "loaded",
              let instanceID = root["instance_id"] as? String,
              validIdentifier(instanceID),
              let loadTime = jsonDouble(root["load_time_seconds"]),
              loadTime.isFinite, loadTime >= 0,
              let config = root["load_config"] as? [String: Any],
              let context = jsonInteger(config["context_length"]),
              (1...4_194_304).contains(context)
        else { throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired }

        let evaluationBatchSize = try positiveOptionalInteger(config, key: "eval_batch_size")
        let expertCount = try positiveOptionalInteger(config, key: "num_experts")
        let flashAttention = try optionalBoolean(config, key: "flash_attention")
        let offload = try optionalBoolean(config, key: "offload_kv_cache_to_gpu")
        return .init(
            instanceID: instanceID,
            loadTimeSeconds: loadTime,
            configuration: .init(
                contextLength: context,
                evaluationBatchSize: evaluationBatchSize,
                flashAttention: flashAttention,
                expertCount: expertCount,
                offloadsKVCacheToGPU: offload
            )
        )
    }
}

private func sortedJSON(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func validIdentifier(_ value: String) -> Bool {
    !value.utf8.isEmpty && value.utf8.count <= 512
        && !value.utf8.contains(where: { $0 <= 0x1F || $0 == 0x7F })
}

private func jsonInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number),
          let integer = Int(number.stringValue)
    else { return nil }
    return integer
}

private func jsonDouble(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return number.doubleValue
}

private func positiveOptionalInteger(_ object: [String: Any], key: String) throws -> Int? {
    guard object.keys.contains(key) else { return nil }
    guard let value = jsonInteger(object[key]), value > 0 else {
        throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
    }
    return value
}

private func optionalBoolean(_ object: [String: Any], key: String) throws -> Bool? {
    guard object.keys.contains(key) else { return nil }
    guard let number = object[key] as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw Phase2NativeModelLifecycleHTTPClientError.reconciliationRequired
    }
    return number.boolValue
}

private final class Phase2NativeLifecycleResponseCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: (@Sendable () -> Void)?
    init(_ operation: @escaping @Sendable () -> Void) { self.operation = operation }
    func cancel() {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.operation = nil }
            return self.operation
        }
        operation?()
    }
}

private struct Phase2NativeLifecycleJSONValidator {
    enum Failure: Error { case malformed, duplicateKey, invalidIntegerLexeme, depthLimitExceeded }
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0
    init(data: Data, maximumDepth: Int) {
        precondition(maximumDepth >= 0)
        bytes = Array(data)
        self.maximumDepth = maximumDepth
    }

    mutating func validate() throws {
        skipWhitespace(); try parseValue(at: [], depth: 0); skipWhitespace()
        guard index == bytes.count else { throw Failure.malformed }
    }

    private mutating func parseValue(at path: [String], depth: Int) throws {
        guard depth <= maximumDepth else { throw Failure.depthLimitExceeded }
        guard index < bytes.count else { throw Failure.malformed }
        switch bytes[index] {
        case UInt8(ascii: "{"): try parseObject(at: path, depth: depth)
        case UInt8(ascii: "["): try parseArray(at: path, depth: depth)
        case UInt8(ascii: "\""): _ = try scanString()
        case UInt8(ascii: "t"): try consumeLiteral("true")
        case UInt8(ascii: "f"): try consumeLiteral("false")
        case UInt8(ascii: "n"): try consumeLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try scanNumber(at: path)
        default: throw Failure.malformed
        }
    }

    private mutating func parseObject(at path: [String], depth: Int) throws {
        try consume(UInt8(ascii: "{")); skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "}")) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let encoded = try scanString()
            guard let key = try? JSONDecoder().decode(String.self, from: encoded),
                  keys.insert(key).inserted else { throw Failure.duplicateKey }
            skipWhitespace(); try consume(UInt8(ascii: ":")); skipWhitespace()
            try parseValue(at: path + [key], depth: depth + 1); skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) { return }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(at path: [String], depth: Int) throws {
        try consume(UInt8(ascii: "[")); skipWhitespace()
        if consumeIfPresent(UInt8(ascii: "]")) { return }
        while true {
            try parseValue(at: path, depth: depth + 1); skipWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) { return }
            try consume(UInt8(ascii: ",")); skipWhitespace()
        }
    }

    private mutating func scanString() throws -> Data {
        let start = index; try consume(UInt8(ascii: "\"")); var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if escaped { escaped = false }
            else if byte == UInt8(ascii: "\\") { escaped = true }
            else if byte == UInt8(ascii: "\"") { return Data(bytes[start..<index]) }
        }
        throw Failure.malformed
    }

    private mutating func scanNumber(at path: [String]) throws {
        let start = index
        while index < bytes.count,
              ![9, 10, 13, 32, UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}")].contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw Failure.malformed }
        if isIntegerPath(path), !isIntegerLexeme(bytes[start..<index]) {
            throw Failure.invalidIntegerLexeme
        }
    }

    private func isIntegerPath(_ path: [String]) -> Bool {
        switch path {
        case ["load_config", "context_length"], ["load_config", "eval_batch_size"],
             ["load_config", "num_experts"]: true
        default: false
        }
    }

    private func isIntegerLexeme(_ value: ArraySlice<UInt8>) -> Bool {
        var cursor = value.startIndex
        guard cursor < value.endIndex else { return false }
        if value[cursor] == UInt8(ascii: "-") {
            cursor = value.index(after: cursor)
            guard cursor < value.endIndex else { return false }
        }
        if value[cursor] == UInt8(ascii: "0") { return value.index(after: cursor) == value.endIndex }
        guard (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(value[cursor]) else { return false }
        cursor = value.index(after: cursor)
        while cursor < value.endIndex {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(value[cursor]) else { return false }
            cursor = value.index(after: cursor)
        }
        return true
    }

    private mutating func consumeLiteral(_ literal: String) throws { for byte in literal.utf8 { try consume(byte) } }
    private mutating func consume(_ byte: UInt8) throws { guard consumeIfPresent(byte) else { throw Failure.malformed } }
    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private mutating func skipWhitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
}
