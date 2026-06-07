// swift-tools-version: 6.2
import PackageDescription

// Tree-sitter grammar packages used by `SyntaxHighlighter`. Each one ships a
// `tree_sitter_<lang>()` parser plus a `queries/highlights.scm` bundle that
// `LanguageConfiguration(_:name:)` auto-discovers. Their own SwiftTreeSitter
// dependency is test-only, so SwiftPM prunes it and the mix of ChimeHQ- and
// tree-sitter-org-hosted SwiftTreeSitter URLs does not conflict with ours.
let grammarPackages: [Package.Dependency] = [
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
    .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp", exact: "0.23.5"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-php", exact: "0.24.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-scala", exact: "0.26.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-haskell", exact: "0.23.1"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua", exact: "0.5.0"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
    .package(url: "https://github.com/fwcd/tree-sitter-kotlin", exact: "0.3.8"),
]

// Grammar products linked into RxCodeCore (where `SyntaxHighlighter` lives).
let grammarProducts: [Target.Dependency] = [
    .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
    .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
    .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
    .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
    .product(name: "TreeSitterPython", package: "tree-sitter-python"),
    .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
    .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
    .product(name: "TreeSitterGo", package: "tree-sitter-go"),
    .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
    .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
    .product(name: "TreeSitterJava", package: "tree-sitter-java"),
    .product(name: "TreeSitterC", package: "tree-sitter-c"),
    .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
    .product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
    .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
    .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
    .product(name: "TreeSitterPHP", package: "tree-sitter-php"),
    .product(name: "TreeSitterScala", package: "tree-sitter-scala"),
    .product(name: "TreeSitterHaskell", package: "tree-sitter-haskell"),
    .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
    .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
    .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
    .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
    .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
]

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
    ] + grammarPackages,
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
            dependencies: grammarProducts + ["TreeSitterScanners"],
            path: "Sources/RxCodeCore"
        ),
        // Provides external-scanner symbols (`tree_sitter_<lang>_external_scanner_*`)
        // for grammar packages whose SPM manifest omits `scanner.c` when consumed
        // as a dependency (a CWD-relative `fileExists` check). Vendored from the
        // matching grammar tags.
        .target(
            name: "TreeSitterScanners",
            path: "Sources/TreeSitterScanners",
            sources: ["csrc"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("csrc")]
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
