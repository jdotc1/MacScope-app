// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "swift-fileio-extra",
    products: [
        .library(name: "FileIOBinary", targets: ["FileIOBinary"]),
    ],
    dependencies: [
        .package(path: "../swift-fileio"),
        .package(path: "../swift-binary-parse-support"),
    ],
    targets: [
        .target(
            name: "FileIOBinary",
            dependencies: [
                .product(name: "FileIO", package: "swift-fileio"),
                .product(name: "BinaryParseSupport", package: "swift-binary-parse-support"),
            ]
        ),
    ]
)
