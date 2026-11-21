// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KeyBar",
            path: "Sources/KeyBar",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
