// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "DeepSeekHarnessMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DeepSeekHarnessMac", targets: ["DeepSeekHarnessMac"]),
        .executable(name: "DeepSeekAppBridge", targets: ["DeepSeekAppBridge"]),
        .executable(name: "DeepSeekArtifactBridge", targets: ["DeepSeekArtifactBridge"]),
        .executable(name: "DeepSeekBridgeFixture", targets: ["DeepSeekBridgeFixture"])
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekHarnessMac",
            path: "Sources/DeepSeekHarnessMac"
        ),
        .executableTarget(
            name: "DeepSeekAppBridge",
            path: "Sources/DeepSeekAppBridge"
        ),
        .executableTarget(
            name: "DeepSeekArtifactBridge",
            path: "Sources/DeepSeekArtifactBridge"
        ),
        .executableTarget(
            name: "DeepSeekBridgeFixture",
            path: "Sources/DeepSeekBridgeFixture"
        )
    ]
)
