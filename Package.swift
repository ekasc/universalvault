// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UniversalVault",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "UniversalVault", targets: ["App"]),
        .library(name: "UniversalVaultCore", targets: ["Core"]),
        .library(name: "UniversalVaultSecurity", targets: ["VaultSecurity"]),
        .library(name: "UniversalVaultInsertion", targets: ["Insertion"]),
    ],
    targets: [
        .target(name: "Core", path: "Sources/Core"),
        .target(name: "VaultSecurity", dependencies: ["Core"], path: "Sources/Security"),
        .target(name: "Insertion", dependencies: ["Core"], path: "Sources/Insertion", linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ApplicationServices")]),
        .executableTarget(name: "App", dependencies: ["Core", "VaultSecurity", "Insertion"], path: "Sources/App"),
        .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Tests/CoreTests"),
        .testTarget(name: "SecurityTests", dependencies: ["Core", "VaultSecurity"], path: "Tests/SecurityTests"),
    ]
)
