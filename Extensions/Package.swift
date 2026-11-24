// swift-tools-version: 6.2
import PackageDescription

let providers = [
    ("GitHubCIUsage", "github-ci"), ("NeonUsage", "neon"), ("TursoUsage", "turso"),
    ("VercelUsage", "vercel"), ("CloudflareUsage", "cloudflare"), ("AIUsage", "ai-usage"),
    ("AILimits", "ai-limits"), ("ACPOpenCode", "acp-opencode"), ("ACPAntigravity", "acp-antigravity"),
]
let sdk: Target.Dependency = .product(name: "RxCodeExtensionSDK", package: "Packages")
let package = Package(
    name: "RxCodeUsageExtensions",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../Packages")],
    targets: [.target(name: "ExtensionTestSupport", dependencies: [sdk], path: "TestSupport")] + providers.flatMap { name, directory -> [Target] in
        let core: Target.Dependency = .product(name: "RxCodeCore", package: "Packages")
        var testDependencies: [Target.Dependency] = [.target(name: name), sdk, core]
        if ["VercelUsage", "CloudflareUsage"].contains(name) { testDependencies.append("ExtensionTestSupport") }
        return [.target(name: name, dependencies: [sdk], path: directory + "/Sources"),
         .testTarget(name: name + "Tests", dependencies: testDependencies, path: directory + "/Tests")]
    }
)
