// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClarcPackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClarcCore", targets: ["ClarcCore"]),
        .library(name: "ClarcChatKit", targets: ["ClarcChatKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "ClarcCore",
            path: "Sources/ClarcCore"
        ),
        .target(
            name: "ClarcChatKit",
            dependencies: ["ClarcCore"],
            path: "Sources/ClarcChatKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "ClarcCoreTests",
            dependencies: ["ClarcCore"],
            path: "Tests/ClarcCoreTests"
        ),
        .testTarget(
            name: "ClarcChatKitTests",
            dependencies: [
                "ClarcChatKit",
                "ClarcCore",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/ClarcChatKitTests"
        ),
    ]
)
