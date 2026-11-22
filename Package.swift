// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Edit",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Edit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Resources/Seti")]
        ),
    ]
)
