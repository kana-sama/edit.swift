// swift-tools-version: 6.4
import Foundation
import PackageDescription

let agentChecks = ProcessInfo.processInfo.environment["EDIT_AGENT_BUILD"] == "1"
let editorTarget = agentChecks ? "EditAgent" : "Edit"
let editorSources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Sources/Edit")
let checkSources = try FileManager.default.contentsOfDirectory(atPath: editorSources.path)
    .filter { $0.hasSuffix("Check.swift") }.sorted()

let package = Package(
    name: "Edit",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3", traits: []),
    ],
    targets: [
        .systemLibrary(name: "EditSyntaxABI"),
        .executableTarget(
            name: editorTarget,
            dependencies: ["EditSyntaxABI", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Edit",
            exclude: agentChecks ? [] : checkSources,
            resources: [.copy("Resources/Seti")],
            swiftSettings: agentChecks ? [.define("EDIT_AGENT_CHECKS")] : []
        ),
    ]
)
