// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "lmux",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "lmux", targets: ["LMUX"])
    ],
    dependencies: [
        .package(path: "/Volumes/Developer/CodeBuddy/Projects/lmux/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "LMUX",
            dependencies: ["SwiftTerm"],
            path: "Sources/LMUX"
        )
    ]
)
