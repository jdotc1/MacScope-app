// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecoveryKit",
    platforms: [.macOS("27.0")],
    products: [.library(name: "RecoveryKit", targets: ["RecoveryKit"])],
    targets: [.target(name: "RecoveryKit")]
)
