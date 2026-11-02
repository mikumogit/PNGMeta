// swift-tools-version: 6.0
import PackageDescription

// emit-module が Testing のマクロ実装を自動では読まないため、明示する。
let testSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-load-plugin-library",
        "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
    ]),
]

let package = Package(
    name: "PNGMeta",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PNGMetaCore", targets: ["PNGMetaCore"]),
        .executable(name: "PNGMeta", targets: ["PNGMeta"]),
    ],
    targets: [
        .target(name: "PNGMetaCore"),
        .executableTarget(
            name: "PNGMeta",
            dependencies: ["PNGMetaCore"]
        ),
        .testTarget(
            name: "PNGMetaCoreTests",
            dependencies: ["PNGMetaCore"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: testSwiftSettings
        ),
    ]
)
