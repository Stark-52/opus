// swift-tools-version: 5.9
// Opus — native macOS launcher for Claude Code.
//
// Build:  ./build.sh   (produces Opus.app)
// Dev:    swift build  (produces .build/debug/Opus)

import PackageDescription

let package = Package(
    name: "Opus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Opus", targets: ["Opus"]),
        .executable(name: "opus-attach", targets: ["opus-attach"]),
        .executable(name: "opus-secrets", targets: ["opus-secrets"])
    ],
    dependencies: [
        // 1.99.0 is the first to clear a row's soft wrap when a line feed
        // moves into it: before, a row Claude Code erased and rewrote kept
        // the wrap of the text it replaced, and the next resize glued it to
        // the row above (scrollback scattered on a diagonal).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.99.2"))
    ],
    targets: [
        .target(
            name: "OpusSecretsKit"
        ),
        .target(
            name: "OpusSearchKit"
        ),
        .target(
            name: "OpusScriptsKit",
            dependencies: ["OpusSearchKit"]
        ),
        .target(
            name: "OpusArtifactsKit"
        ),
        .executableTarget(
            name: "Opus",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "OpusSecretsKit",
                "OpusScriptsKit",
                "OpusArtifactsKit",
                "OpusSearchKit"
            ]
        ),
        .executableTarget(
            name: "opus-attach"
        ),
        .executableTarget(
            name: "opus-secrets",
            dependencies: ["OpusSecretsKit"]
        ),
        .testTarget(
            name: "OpusTests",
            dependencies: ["Opus", "OpusSecretsKit", "OpusScriptsKit", "OpusArtifactsKit", "OpusSearchKit"]
        )
    ]
)
