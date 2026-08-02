// swift-tools-version: 6.0
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
        .package(path: "/Users/manshiangli/Projects/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "LMUX",
            dependencies: ["SwiftTerm"],
            path: "Sources/LMUX"
        )
    ]
)
