// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MachOKit",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "MachOKit", targets: ["MachOKit"]),
    ],
    dependencies: [
        .package(path: "../swift-fileio"),
        .package(path: "../swift-fileio-extra"),
        .package(path: "../swift-binary-parse-support"),
    ],
    targets: [
        .target(
            name: "MachOKit",
            dependencies: [
                "MachOKitC",
                .product(name: "FileIO", package: "swift-fileio"),
                .product(name: "FileIOBinary", package: "swift-fileio-extra"),
                .product(name: "BinaryParseSupport", package: "swift-binary-parse-support"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ImportObjcForwardDeclarations"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("DeprecateApplicationMain"),
                .enableUpcomingFeature("IsolatedDefaultValues"),
                .enableUpcomingFeature("GlobalConcurrency"),
            ]
        ),
        .target(name: "MachOKitC", publicHeadersPath: "include"),
    ]
)
