import Foundation

/// A bounded, read-only projection of an Apple JSON crash report. Source indices remain
/// intact; report addresses never become authority for the currently loaded binary.
struct CrashReport: Sendable {
    let processName: String
    let exceptionSummary: String
    let threads: [CrashReportThread]
    let images: [CrashReportImage]

    enum ParseError: Error, LocalizedError {
        case inputTooLarge, malformed, resourceLimit, invalidImageRange

        var errorDescription: String? {
            switch self {
            case .inputTooLarge: return "The crash report exceeds the 16 MiB limit."
            case .malformed: return "The crash report is not a supported JSON crash report."
            case .resourceLimit: return "The crash report exceeds the thread, frame, or image limit."
            case .invalidImageRange: return "The crash report contains an invalid image address range."
            }
        }
    }

    static func parse(_ data: Data) throws -> CrashReport {
        guard data.count <= 16 * 1_024 * 1_024 else { throw ParseError.inputTooLarge }
        let decoder = JSONDecoder()
        let body: Body
        var metadata: Metadata?
        if let single = try? decoder.decode(Body.self, from: data) {
            body = single
        } else {
            // Apple's .ips envelope is one metadata object on the first line, followed
            // by a separate JSON object. Never scan for a convenient inner object.
            guard let newline = data.firstIndex(of: 10),
                  let header = try? decoder.decode(Metadata.self, from: Data(data[..<newline])),
                  let payload = try? decoder.decode(Body.self, from: Data(data[data.index(after: newline)...]))
            else { throw ParseError.malformed }
            metadata = header
            body = payload
        }
        guard body.threads.count <= 1_024, body.usedImages.count <= 20_000 else {
            throw ParseError.resourceLimit
        }
        var frameCount = 0
        let threads = try body.threads.enumerated().map { index, thread in
            guard thread.frames.count <= 100_000 - frameCount else { throw ParseError.resourceLimit }
            frameCount += thread.frames.count
            return CrashReportThread(id: index, name: thread.name ?? thread.queue,
                triggered: thread.triggered ?? (body.faultingThread == index),
                frames: try thread.frames.enumerated().map { offset, frame in
                    guard frame.imageIndex.map({ $0 >= 0 }) ?? true else { throw ParseError.malformed }
                    return CrashReportFrame(id: offset, imageIndex: frame.imageIndex,
                        imageOffset: frame.imageOffset, reportedSymbol: frame.symbol)
                })
        }
        let images = try body.usedImages.map { image in
            guard !image.base.addingReportingOverflow(image.size).overflow else {
                throw ParseError.invalidImageRange
            }
            return CrashReportImage(name: image.name ?? "Unknown image", uuid: image.uuid,
                base: image.base, size: image.size)
        }
        let exception = [body.exception?.type, body.exception?.signal, body.exception?.subtype]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return CrashReport(processName: body.procName ?? metadata?.app_name ?? "Unknown process",
            exceptionSummary: exception.isEmpty ? "Exception not reported" : exception,
            threads: threads, images: images)
    }

    func resolve(_ frame: CrashReportFrame, against context: CrashReportImageContext?) -> CrashReportResolvedFrame {
        func unresolved(_ reason: String) -> CrashReportResolvedFrame {
            CrashReportResolvedFrame(address: nil, symbol: nil, diagnostic: reason)
        }
        guard let index = frame.imageIndex, images.indices.contains(index),
              let offset = frame.imageOffset else { return unresolved("No image-relative address") }
        let image = images[index]
        guard let context else { return unresolved("Open the matching image to navigate") }
        guard let reportedUUID = Self.canonicalUUID(image.uuid),
              let loadedUUID = Self.canonicalUUID(context.uuid), reportedUUID == loadedUUID else {
            return unresolved("Image UUID does not match the open image")
        }
        guard offset < image.size else { return unresolved("Frame offset is outside the reported image") }
        let (address, overflow) = context.preferredBase.addingReportingOverflow(offset)
        guard !overflow, context.mappedRanges.contains(where: { $0.contains(address) }) else {
            return unresolved("Frame address is outside the open image")
        }
        // An exact label is known, but an unbounded preceding label is not a function.
        var symbol: CrashReportSymbol?
        for candidate in context.symbols {
            if candidate.address == address {
                symbol = candidate
                break
            }
            if let end = candidate.endAddress, candidate.address < end,
               candidate.address <= address, address < end,
               symbol.map({ $0.address < candidate.address }) ?? true {
                symbol = candidate
            }
        }
        return CrashReportResolvedFrame(address: address, symbol: symbol?.name, diagnostic: nil)
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.utf8.count == 32,
              compact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return compact
    }

    private struct Metadata: Decodable { let app_name: String? }
    private struct Body: Decodable {
        let procName: String?
        let exception: ExceptionDetails?
        let faultingThread: Int?
        let threads: [ThreadDetails]
        let usedImages: [ImageDetails]
    }
    private struct ExceptionDetails: Decodable { let type: String?; let signal: String?; let subtype: String? }
    private struct ThreadDetails: Decodable {
        let name: String?
        let queue: String?
        let triggered: Bool?
        let frames: [FrameDetails]
    }
    private struct FrameDetails: Decodable { let imageIndex: Int?; let imageOffset: UInt64?; let symbol: String? }
    private struct ImageDetails: Decodable { let name: String?; let uuid: String?; let base: UInt64; let size: UInt64 }
}

struct CrashReportThread: Identifiable, Sendable {
    let id: Int
    let name: String?
    let triggered: Bool
    let frames: [CrashReportFrame]
}

struct CrashReportFrame: Identifiable, Sendable {
    let id: Int
    let imageIndex: Int?
    let imageOffset: UInt64?
    let reportedSymbol: String?
}

struct CrashReportImage: Sendable {
    let name: String
    let uuid: String?
    let base: UInt64
    let size: UInt64
}

struct CrashReportImageContext: Sendable {
    let uuid: String
    let preferredBase: UInt64
    let mappedRanges: [Range<UInt64>]
    let symbols: [CrashReportSymbol]
}

struct CrashReportSymbol: Sendable {
    let name: String
    let address: UInt64
    let endAddress: UInt64?
}

struct CrashReportResolvedFrame: Sendable {
    let address: UInt64?
    let symbol: String?
    let diagnostic: String?
}
