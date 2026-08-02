// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CBSM",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "CBSM", targets: ["CBSM"])
    ],
    dependencies: [
        .package(path: "/Users/manshiangli/Projects/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "CBSM",
            dependencies: ["SwiftTerm"],
            path: "Sources/CBSM"
        )
    ]
)
