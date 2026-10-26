import Foundation
import CryptoKit
let arguments = CommandLine.arguments
 guard arguments.count == 3 else { fatalError("Usage: render-all <binary> <output>") }
// Prove that the unchanged production Bundle.main loader sees exact tree bytes.
guard let repoPath = ProcessInfo.processInfo.environment["PORTABLE_REPO"],
      let resourceURL = Bundle.main.url(forResource: CallSignaturePack.bundledResourceName, withExtension: "json") else {
    fatalError("Required tree resource not visible through production Bundle.main lookup")
}
let treeResourceURL = URL(fileURLWithPath: repoPath).appendingPathComponent("MacScope/Resources/SDKCallSignaturePack.json")
let treeResourceData = try Data(contentsOf: treeResourceURL)
let bundleResourceData = try Data(contentsOf: resourceURL)
guard treeResourceData == bundleResourceData, CallSignaturePack.bundled != nil else {
    fatalError("Production bundle resource differs from the tree or fails strict decoding")
}
let resourceDigest = SHA256.hash(data: bundleResourceData).map { String(format: "%02x", $0) }.joined()
print("Production Bundle.main resource: \(resourceURL.path), bytes=\(bundleResourceData.count), sha256=\(resourceDigest)")
let snapshot = try AnalysisEngine().analyze(url: URL(fileURLWithPath: arguments[1]))
let slot = snapshot.primarySlot
 guard let analysis = snapshot.analysis(in: slot) else { fatalError("Missing primary analysis") }
 guard snapshot.imageWideIndirectCalls(in: slot, compute: true) != nil else { fatalError("Image-wide report incomplete") }
let options = DecompilerOptions(userDefaults: .standard)
print("Decompiler options: \(String(reflecting: options))")
let service = DocumentExportService()
var output = ""
for function in analysis.functions {
    let input = snapshot.pseudocodeRenderInput(selectedAddress: function.startAddress, in: slot)
    precondition(input.startAddress == function.startAddress)
    let text = service.pseudocodeText(for: input, options: options)
    let name = function.name.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    output += "// FUNCTION name=\(name) start=0x\(String(function.startAddress, radix: 16))\n" + text + "\n\n"
}
try output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
print("Rendered \(analysis.functions.count) functions through production MacIR export")
