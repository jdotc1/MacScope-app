import Foundation

struct Phase2SSERecord: Equatable, Sendable {
    let event: String
    let data: String
    let id: String?
    let retryMilliseconds: Int?

    init(event: String, data: String, id: String? = nil, retryMilliseconds: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }
}

struct Phase2SSEDecoderLimits: Equatable, Sendable {
    let maximumPendingBytes: Int
    let maximumLineBytes: Int
    let maximumRecordBytes: Int
    let maximumCumulativeBytes: Int
    let maximumRecordCount: Int

    init(
        maximumPendingBytes: Int = 65_536,
        maximumLineBytes: Int = 16_384,
        maximumRecordBytes: Int = 262_144,
        maximumCumulativeBytes: Int = 1_048_576,
        maximumRecordCount: Int = 256
    ) {
        precondition(maximumPendingBytes >= 0)
        precondition(maximumLineBytes >= 0)
        precondition(maximumRecordBytes >= 0)
        precondition(maximumCumulativeBytes >= 0)
        precondition(maximumRecordCount >= 0)
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumRecordBytes = maximumRecordBytes
        self.maximumCumulativeBytes = maximumCumulativeBytes
        self.maximumRecordCount = maximumRecordCount
    }
}

enum Phase2SSEDecoderError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidLineEnding
    case malformedField
    case unsupportedField(String)
    case duplicateField(String)
    case invalidRetry
    case missingEvent
    case missingData
    case emptyEvent
    case emptyData
    case incompleteLine
    case incompleteRecord
    case pendingByteLimitExceeded
    case lineByteLimitExceeded
    case recordByteLimitExceeded
    case cumulativeByteLimitExceeded
    case recordCountLimitExceeded
    case alreadyFinished
    case alreadyFailed
}

struct Phase2SSEDecoder: Sendable {
    private let limits: Phase2SSEDecoderLimits
    private let defaultEvent: String?
    private var pending: [UInt8] = []
    private var cumulativeBytes = 0
    private var emittedRecordCount = 0
    private var currentRecordBytes = 0
    private var currentEvent: String?
    private var currentData: [String] = []
    private var currentID: String?
    private var currentRetry: Int?
    private var sawID = false
    private var sawRetry = false
    private var sawRecordField = false
    private var isFinished = false
    private var isFailed = false

    init(
        limits: Phase2SSEDecoderLimits = .init(),
        defaultEvent: String? = nil
    ) {
        precondition(defaultEvent?.isEmpty != true)
        self.limits = limits
        self.defaultEvent = defaultEvent
    }

    mutating func append<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [Phase2SSERecord] {
        guard !isFinished else { throw Phase2SSEDecoderError.alreadyFinished }
        guard !isFailed else { throw Phase2SSEDecoderError.alreadyFailed }

        do {
            guard bytes.count <= limits.maximumCumulativeBytes - cumulativeBytes else {
                throw Phase2SSEDecoderError.cumulativeByteLimitExceeded
            }
            let incoming = Array(bytes)
            cumulativeBytes += incoming.count
            pending.append(contentsOf: incoming)

            var records: [Phase2SSERecord] = []
            var consumed = 0
            while let lineFeed = pending[consumed...].firstIndex(of: 0x0A) {
                let framedLineBytes = lineFeed - consumed + 1
                var line = Array(pending[consumed..<lineFeed])
                consumed = lineFeed + 1

                if line.last == 0x0D {
                    line.removeLast()
                }
                guard !line.contains(0x0D) else {
                    throw Phase2SSEDecoderError.invalidLineEnding
                }
                guard line.count <= limits.maximumLineBytes else {
                    throw Phase2SSEDecoderError.lineByteLimitExceeded
                }
                if !line.isEmpty || hasCurrentRecord {
                    guard framedLineBytes <= limits.maximumRecordBytes - currentRecordBytes else {
                        throw Phase2SSEDecoderError.recordByteLimitExceeded
                    }
                    currentRecordBytes += framedLineBytes
                }
                if let record = try process(line: line) {
                    records.append(record)
                }
            }

            if consumed > 0 {
                pending.removeFirst(consumed)
            }
            try validatePendingFragment()
            return records
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finish() throws -> [Phase2SSERecord] {
        guard !isFinished else { throw Phase2SSEDecoderError.alreadyFinished }
        guard !isFailed else { throw Phase2SSEDecoderError.alreadyFailed }
        isFinished = true

        guard pending.isEmpty else {
            guard String(bytes: pending, encoding: .utf8) != nil else {
                throw Phase2SSEDecoderError.invalidUTF8
            }
            throw Phase2SSEDecoderError.incompleteLine
        }
        guard !hasCurrentRecord else {
            throw Phase2SSEDecoderError.incompleteRecord
        }
        return []
    }

    private var hasCurrentRecord: Bool {
        currentRecordBytes > 0 || sawRecordField
    }

    private mutating func validatePendingFragment() throws {
        let carriageReturns = pending.indices.filter { pending[$0] == 0x0D }
        if carriageReturns.contains(where: { $0 != pending.index(before: pending.endIndex) }) {
            throw Phase2SSEDecoderError.invalidLineEnding
        }

        let prospectiveLineBytes = pending.last == 0x0D ? pending.count - 1 : pending.count
        guard prospectiveLineBytes <= limits.maximumLineBytes else {
            throw Phase2SSEDecoderError.lineByteLimitExceeded
        }
        guard pending.count <= limits.maximumPendingBytes else {
            throw Phase2SSEDecoderError.pendingByteLimitExceeded
        }
    }

    private mutating func process(line: [UInt8]) throws -> Phase2SSERecord? {
        guard let text = String(bytes: line, encoding: .utf8) else {
            throw Phase2SSEDecoderError.invalidUTF8
        }

        if line.isEmpty {
            defer { resetCurrentRecord() }
            guard hasCurrentRecord else { return nil }
            guard sawRecordField else { return nil }
            return try completedRecord()
        }

        if text.hasPrefix(":") {
            return nil
        }

        guard let separator = text.firstIndex(of: ":"), separator != text.startIndex else {
            throw Phase2SSEDecoderError.malformedField
        }
        let field = String(text[..<separator])
        var valueStart = text.index(after: separator)
        if valueStart < text.endIndex, text[valueStart] == " " {
            valueStart = text.index(after: valueStart)
        }
        let value = String(text[valueStart...])
        sawRecordField = true

        switch field {
        case "event":
            guard currentEvent == nil else { throw Phase2SSEDecoderError.duplicateField(field) }
            guard !value.isEmpty else { throw Phase2SSEDecoderError.emptyEvent }
            currentEvent = value
        case "data":
            guard !value.isEmpty else { throw Phase2SSEDecoderError.emptyData }
            currentData.append(value)
        case "id":
            guard !sawID else { throw Phase2SSEDecoderError.duplicateField(field) }
            guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw Phase2SSEDecoderError.malformedField
            }
            sawID = true
            currentID = value
        case "retry":
            guard !sawRetry else { throw Phase2SSEDecoderError.duplicateField(field) }
            guard !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let retry = Int(value) else {
                throw Phase2SSEDecoderError.invalidRetry
            }
            sawRetry = true
            currentRetry = retry
        default:
            throw Phase2SSEDecoderError.unsupportedField(field)
        }
        return nil
    }

    private mutating func completedRecord() throws -> Phase2SSERecord {
        guard let event = currentEvent ?? defaultEvent else {
            throw Phase2SSEDecoderError.missingEvent
        }
        guard !currentData.isEmpty else { throw Phase2SSEDecoderError.missingData }
        guard emittedRecordCount < limits.maximumRecordCount else {
            throw Phase2SSEDecoderError.recordCountLimitExceeded
        }
        emittedRecordCount += 1
        return Phase2SSERecord(
            event: event,
            data: currentData.joined(separator: "\n"),
            id: currentID,
            retryMilliseconds: currentRetry
        )
    }

    private mutating func resetCurrentRecord() {
        currentRecordBytes = 0
        currentEvent = nil
        currentData.removeAll(keepingCapacity: true)
        currentID = nil
        currentRetry = nil
        sawID = false
        sawRetry = false
        sawRecordField = false
    }
}
