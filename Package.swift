// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "now",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "now", targets: ["NowApp"])],
    targets: [
        .executableTarget(name: "NowApp", path: "Sources")
    ],
    swiftLanguageVersions: [.v5]
)
