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
        .executable(name: "opus-attach", targets: ["opus-attach"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Opus",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(
            name: "opus-attach"
        )
    ]
)
