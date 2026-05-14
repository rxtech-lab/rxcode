// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxCodePackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RxCodeCore", targets: ["RxCodeCore"]),
        .library(name: "RxCodeChatKit", targets: ["RxCodeChatKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "RxCodeCore",
            path: "Sources/RxCodeCore"
        ),
        .target(
            name: "RxCodeChatKit",
            dependencies: ["RxCodeCore"],
            path: "Sources/RxCodeChatKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "RxCodeCoreTests",
            dependencies: ["RxCodeCore"],
            path: "Tests/RxCodeCoreTests"
        ),
        .testTarget(
            name: "RxCodeChatKitTests",
            dependencies: [
                "RxCodeChatKit",
                "RxCodeCore",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/RxCodeChatKitTests"
        ),
    ]
)
