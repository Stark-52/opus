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
        // 1.14 is the first to keep a scrolled-up view in place while output
        // arrives; 1.99 is the line of breaking changes, so stay on 1.20.x.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0"))
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
