// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxCodePackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "RxCodeCore", targets: ["RxCodeCore"]),
        .library(name: "RxCodeChatKit", targets: ["RxCodeChatKit"]),
        .library(name: "RxCodeEditor", targets: ["RxCodeEditor"]),
        .library(name: "RxCodeSync", targets: ["RxCodeSync"]),
        .library(name: "DiffView", targets: ["DiffView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/rxtech-lab/RxAgentSDK.git", .upToNextMinor(from: "1.0.4")),
    ],
    targets: [
        .target(
            name: "RxCodeCore",
            path: "Sources/RxCodeCore"
        ),
        .target(
            name: "RxCodeChatKit",
            dependencies: [
                "DiffView",
                "RxCodeCore",
                .product(name: "RxAgentSDK", package: "RxAgentSDK"),
            ],
            path: "Sources/RxCodeChatKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .target(
            name: "RxCodeSync",
            dependencies: ["RxCodeCore"],
            path: "Sources/RxCodeSync"
        ),
        .target(
            name: "RxCodeEditor",
            dependencies: ["RxCodeCore"],
            path: "Sources/RxCodeEditor"
        ),
        .target(
            name: "DiffView",
            dependencies: ["RxCodeCore"],
            path: "Sources/DiffView",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "DiffViewTests",
            dependencies: ["DiffView", "RxCodeCore"],
            path: "Tests/DiffViewTests"
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
        .testTarget(
            name: "RxCodeEditorTests",
            dependencies: ["RxCodeEditor"],
            path: "Tests/RxCodeEditorTests"
        ),
        .testTarget(
            name: "RxCodeSyncTests",
            dependencies: ["RxCodeSync"],
            path: "Tests/RxCodeSyncTests"
        ),
    ]
)
