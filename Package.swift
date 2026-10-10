// swift-tools-version: 5.9
import PackageDescription
import Foundation

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let generatedBundles = ((try? FileManager.default.contentsOfDirectory(atPath: projectRoot)) ?? [])
    .filter { $0.hasSuffix(".app") }


let package = Package(
    name: "LightMD",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LightMD", targets: ["LightMD"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", revision: "392b73b858efe3dacec0e8a91c6e7fd19af0bb98"),
        .package(url: "https://github.com/colinc86/MathJaxSwift.git", exact: "3.5.0"),
        .package(url: "https://github.com/swhitty/SwiftDraw.git", exact: "0.27.0")
    ],
    targets: [
        .executableTarget(name: "LightMD", dependencies: [
            .product(name: "Markdown", package: "swift-markdown"),
            .product(name: "MathJaxSwift", package: "MathJaxSwift"),
            .product(name: "SwiftDraw", package: "SwiftDraw")
        ], path: ".", exclude: generatedBundles + ["docs", "AGENTS.md", "Lesson.md", "Info.plist", "README.md", "README.zh-CN.md", "LICENSE", "CONTRIBUTING.md", "ThirdPartyNotices.md", ".github", "Font-notes.md", "Checks", "cmark-cjk-emphasis.patch", "mathjax-app-resources.patch", "build.sh", "zh-Hans.lproj", "Assets", "LightMD-preview.html"], sources: ["LightMD.swift", "EditorSupport.swift", "DocumentEditing.swift", "LiveEditing.swift", "WindowChrome.swift", "SessionStore.swift", "MathMarkup.swift", "MathRenderer.swift", "MediaSupport.swift", "WebRenderSupport.swift", "MermaidSupport.swift", "PDFExport.swift"]),
        .executableTarget(name: "CJKParserCheck", dependencies: [
            .product(name: "Markdown", package: "swift-markdown")
        ], path: "Checks", exclude: ["Features", "Documentation", "Performance"])
    ]
)
