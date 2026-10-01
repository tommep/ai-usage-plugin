// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AIUsage", targets: ["AIUsage"])],
    targets: [
        .executableTarget(name: "AIUsage", resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "AIUsageTests", dependencies: ["AIUsage"])
    ]
)
