// swift-tools-version: 5.9
import PackageDescription
import Foundation

// A test invocation selects a separate executable target and scratch directory.
// This supports Command Line Tools without XCTest and keeps all application APIs internal.
let suites: [String: [String]] = [
    "updater": ["Tests/Updater/Runner.swift"],
    "selftest": ["Tests/NowTests"],
    "notification": ["scripts/notification-smoke.swift", "scripts/notification-preview.swift",
                     "scripts/notification-lifecycle-smoke.swift", "scripts/preference-recovery-smoke.swift"],
    "reminder": ["scripts/reminder-state-smoke.swift"],
    "cache": ["scripts/calendar-cache-smoke.swift"],
    "fetch": ["scripts/calendar-fetch-smoke.swift"],
    "workload": ["scripts/feed-workload-smoke.swift"],
    "parser": ["scripts/parser-performance-smoke.swift"]
]
let suite = ProcessInfo.processInfo.environment["NOW_TEST_SUITE"]
let target: Target
let product: Product
if let suite {
    guard let fixtures = suites[suite] else { fatalError("Unknown NOW_TEST_SUITE: \(suite)") }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let excluded = try! FileManager.default.contentsOfDirectory(atPath: root.path).filter {
        !["Sources", "scripts", "Tests", "Package.swift"].contains($0) && !$0.hasPrefix(".")
    } + (try! FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("scripts").path))
        .map { "scripts/" + $0 }.filter { !fixtures.contains($0) }
        + (suite == "selftest" ? ["Tests/Updater"] : suite == "updater" ? ["Tests/NowTests"] : ["Tests"])
    target = .executableTarget(
        name: "NowHarness", path: ".", exclude: excluded, sources: ["Sources"] + fixtures,
        swiftSettings: [.define("NOW_TESTING"), .define("NOW_" + suite.uppercased() + "_TESTS")]
    )
    product = .executable(name: "now-harness", targets: ["NowHarness"])
} else {
    target = .executableTarget(name: "NowApp", path: "Sources")
    product = .executable(name: "now", targets: ["NowApp"])
}
let package = Package(
    name: "now",
    platforms: [.macOS(.v13)],
    products: [product],
    targets: [target],
    swiftLanguageVersions: [.v5]
)
