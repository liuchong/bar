// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bar",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Bar", targets: ["Bar"])],
    targets: [
        .target(name: "BarCore"),
        .target(name: "BarNative", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "Bar", dependencies: ["BarCore", "BarNative"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "BarIntegrationTests", dependencies: ["BarCore"]),
        .testTarget(name: "BarCoreTests", dependencies: ["BarCore"])
    ]
)
