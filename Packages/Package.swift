// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RxCodePackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MessageList", targets: ["MessageList"]),
        .library(name: "RxCodeCore", targets: ["RxCodeCore"]),
        .library(name: "RxCodeChatKit", targets: ["RxCodeChatKit"]),
        .library(name: "RxCodeEditor", targets: ["RxCodeEditor"]),
        .library(name: "RxCodeMarkdown", targets: ["RxCodeMarkdown"]),
        .library(name: "RxCodeSync", targets: ["RxCodeSync"]),
        .library(name: "DiffView", targets: ["DiffView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "MessageList",
            dependencies: ["RxCodeCore"],
            path: "Sources/MessageList",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .target(
            name: "RxCodeCore",
            path: "Sources/RxCodeCore"
        ),
        .target(
            name: "RxCodeMarkdown",
            dependencies: ["RxCodeCore"],
            path: "Sources/RxCodeMarkdown"
        ),
        .target(
            name: "RxCodeChatKit",
            dependencies: [
                "DiffView",
                "MessageList",
                "RxCodeCore",
                "RxCodeMarkdown",
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
            name: "MessageListTests",
            dependencies: [
                "MessageList",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            path: "Tests/MessageListTests"
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
            name: "RxCodeMarkdownTests",
            dependencies: ["RxCodeMarkdown"],
            path: "Tests/RxCodeMarkdownTests"
        ),
        .testTarget(
            name: "RxCodeSyncTests",
            dependencies: ["RxCodeSync"],
            path: "Tests/RxCodeSyncTests"
        ),
    ]
)
