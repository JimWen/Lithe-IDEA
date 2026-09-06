// swift-tools-version:5.9

import PackageDescription

// Lithe compiles only the fixed-version terminal library. See upstream.json
// and lithe-typography.patch for the exact upstream inputs and local changes.
let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            resources: [
                .process("Apple/Metal/Shaders.metal"),
                .copy("Notices")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
