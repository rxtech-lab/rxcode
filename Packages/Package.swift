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
        .library(name: "RxCodeSync", targets: ["RxCodeSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.3.1"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "MessageList",
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
            name: "RxCodeChatKit",
            dependencies: [
                "MessageList",
                "RxCodeCore",
                .product(name: "Textual", package: "textual"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
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
            name: "RxCodeSyncTests",
            dependencies: ["RxCodeSync"],
            path: "Tests/RxCodeSyncTests"
        ),
    ]
)
