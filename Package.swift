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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "OpusSecretsKit"
        ),
        .target(
            name: "OpusScriptsKit"
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
                "OpusArtifactsKit"
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
            dependencies: ["Opus", "OpusSecretsKit", "OpusScriptsKit", "OpusArtifactsKit"]
        )
    ]
)
