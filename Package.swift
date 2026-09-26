// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightMD",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LightMD", targets: ["LightMD"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", revision: "392b73b858efe3dacec0e8a91c6e7fd19af0bb98")
    ],
    targets: [
        .executableTarget(name: "LightMD", dependencies: [
            .product(name: "Markdown", package: "swift-markdown")
        ], path: ".", exclude: ["LightMD.app", "LightMD_副本.app", "docs", "AGENTS.md", "Info.plist", "README.md", "Font-notes.md", "Checks", "cmark-cjk-emphasis.patch", "build.sh", "zh-Hans.lproj", "Assets", "LightMD-preview.html"], sources: ["LightMD.swift", "EditorSupport.swift", "WindowChrome.swift"]),
        .executableTarget(name: "CJKParserCheck", dependencies: [
            .product(name: "Markdown", package: "swift-markdown")
        ], path: "Checks")
    ]
)
