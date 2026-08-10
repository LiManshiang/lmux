// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "lmux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "lmux", targets: ["LMUX"])
    ],
    dependencies: [
        .package(path: "/Volumes/Developer/CodeBuddy/Projects/lmux/SwiftTerm"),
        .package(path: "/Volumes/Developer/CodeBuddy/Projects/lmux/libghostty-spm"),
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
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
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
