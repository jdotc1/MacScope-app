// swift-tools-version: 6.0
import PackageDescription
import Foundation
let crypto = ProcessInfo.processInfo.environment["PORTABLE_SWIFT_CRYPTO"] ?? "../../../../dependencies/swift-crypto-3.12.3"
let package = Package(name: "PortableRenderer", products: [.executable(name: "render-all", targets: ["RenderAll"])], dependencies: [.package(name: "swift-crypto", path: crypto)], targets: [
    .systemLibrary(name: "zlib", path: "Shims/zlib"),
    .target(name: "PortableDarwin", path: "Shims/PortableDarwin"),
    .target(name: "SwiftUI", path: "Shims/SwiftUI"),
    .target(name: "OSLog", path: "Shims/OSLog"),
    .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Shims/CryptoKit"),
    .executableTarget(name: "RenderAll", dependencies: ["PortableDarwin", "SwiftUI", "OSLog", "CryptoKit", "zlib"], path: "Sources/RenderAll")
], swiftLanguageModes: [.v6])
