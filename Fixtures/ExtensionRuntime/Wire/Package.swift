// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FixtureWire",
    platforms: [.macOS(.v26)],
    products: [.library(name: "FixtureWire", targets: ["FixtureWire"])],
    targets: [.target(name: "FixtureWire")]
)
