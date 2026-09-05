// swift-tools-version: 5.7
import PackageDescription

// SwiftTerm-only manifest used to build the macOS 12 `lmux-st.app` variant
// (see Makefile `build-st`/`app-st`). The Ghostty renderer requires macOS 13+
// and is excluded here; sources are the SAME files as the ghostty build —
// Ghostty-specific code is behind `#if canImport(GhosttyTerminal)`.
//
// Makefile usage: temporarily swaps this file over Package.swift during the
// st build (with trap-based restore) and builds into a separate scratch path
// (.build-st) so it never pollutes the normal .build.
let package = Package(
    name: "lmux",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "lmux", targets: ["LMUX"])
    ],
    dependencies: [
        // SwiftTerm (MIT). A Swift 5.7 backport patch is applied locally; see
        // the README for how to clone + patch it.
        .package(path: "../SwiftTerm"),
    ],
    targets: [
        .target(
            name: "LMUXCore",
            path: "Sources/LMUXCore"
        ),
        .executableTarget(
            name: "LMUX",
            dependencies: [
                "SwiftTerm",
                "LMUXCore",
            ],
            path: "Sources/LMUX"
        ),
        .testTarget(
            name: "LMUXCoreTests",
            dependencies: ["LMUXCore"],
            path: "Sources/LMUXCoreTests"
        )
    ]
)
