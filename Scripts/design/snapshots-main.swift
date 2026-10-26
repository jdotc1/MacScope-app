import Foundation

enum SnapshotRecordingError: Error {
    case renderingFailed(String)
}

try MainActor.assumeIsolated {
    let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var count = 0
    for subject in DSSnapshot.subjects {
        for variant in subject.variants {
            guard let png = DSSnapshot.png(of: subject, in: variant) else {
                throw SnapshotRecordingError.renderingFailed(subject.name)
            }
            try png.write(to: out.appending(path: "\(subject.name)@\(variant.label).png"))
            count += 1
        }
    }
    print("recorded \(count) candidate images in \(out.path)")
}
