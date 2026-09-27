import AppKit
import CryptoKit
import SwiftUI

struct MermaidDiagram {
    let svg: String
    let image: NSImage
    let size: CGSize
}

@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()
    private final class Box: NSObject { let diagram: MermaidDiagram; init(_ diagram: MermaidDiagram) { self.diagram = diagram } }
    private let cache = NSCache<NSString, Box>()
    private var pending: [String: Task<MermaidDiagram, Error>] = [:]
    private var tail: Task<Void, Never>?
    private var page: OffscreenWebPage?

    init() { cache.countLimit = 60; cache.totalCostLimit = 32 * 1024 * 1024 }

    static func bundledScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "mermaid.tiny", withExtension: "js", subdirectory: "Mermaid") else {
            throw DiagramError.missingResources
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func render(_ source: String, dark: Bool = false) async throws -> MermaidDiagram {
        guard source.utf8.count <= 100_000 else { throw DiagramError.tooLarge }
        let key = SHA256.hash(data: Data("\(dark):\(source)".utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = cache.object(forKey: key as NSString) { return cached.diagram }
        if let task = pending[key] { return try await task.value }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            do { return try await self.renderNow(source, dark: dark) }
            catch { self.page?.close(); self.page = nil; throw error }
        }
        pending[key] = task
        tail = Task { _ = try? await task.value }
        defer { pending[key] = nil }
        let diagram = try await task.value
        cache.setObject(Box(diagram), forKey: key as NSString,
                        cost: diagram.svg.utf8.count + Int(diagram.size.width * diagram.size.height * 4))
        return diagram
    }

    private func renderNow(_ source: String, dark: Bool) async throws -> MermaidDiagram {
        if page == nil {
            let surface = OffscreenWebPage(script: try Self.bundledScript())
            try await surface.load("""
                <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(OffscreenWebPage.policy)">
                <style>html,body{margin:0;padding:0;background:transparent}#result{display:inline-block}svg{display:block}</style></head><body><div id="result"></div></body></html>
                """)
            page = surface
        }
        guard let page else { throw DiagramError.missingResources }
        let value = try await page.call("""
            const engine = globalThis.mermaid.default || globalThis.mermaid;
            engine.initialize({startOnLoad:false,securityLevel:'strict',theme:dark?'dark':'default',
              fontFamily:'-apple-system, PingFang SC, sans-serif',htmlLabels:false,maxTextSize:100000,maxEdges:1000,
              secure:['securityLevel','startOnLoad','maxTextSize','maxEdges','htmlLabels','fontFamily'],
              flowchart:{htmlLabels:false,useMaxWidth:false}});
            document.getElementById('result').replaceChildren();
            await document.fonts.ready;
            const output = await engine.render(renderID, source);
            document.getElementById('result').innerHTML = output.svg;
            const svg = document.querySelector('#result > svg');
            const box = svg.viewBox.baseVal;
            const width = Math.ceil(box.width || svg.getBoundingClientRect().width);
            const height = Math.ceil(box.height || svg.getBoundingClientRect().height);
            svg.style.maxWidth='none'; svg.style.width=width+'px'; svg.style.height=height+'px';
            svg.setAttribute('width',width); svg.setAttribute('height',height);
            await document.fonts.ready;
            return {svg:svg.outerHTML,width,height};
            """, arguments: ["source": source, "dark": dark, "renderID": "diagram" + UUID().uuidString.replacingOccurrences(of: "-", with: "")])
        guard let result = value as? [String: Any], let svg = result["svg"] as? String,
              let width = result["width"] as? Double, let height = result["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8192, height <= 8192, width * height <= 16_000_000 else { throw DiagramError.tooLarge }
        let size = CGSize(width: width, height: height)
        page.webView.setFrameSize(size)
        let data = try await page.pdf(rect: CGRect(origin: .zero, size: size))
        guard let image = NSImage(data: data) else { throw DiagramError.invalidImage }
        image.size = size
        return MermaidDiagram(svg: svg, image: image, size: size)
    }

    enum DiagramError: LocalizedError {
        case missingResources, tooLarge, invalidImage
        var errorDescription: String? {
            switch self {
            case .missingResources: "Mermaid 离线资源缺失，请重新安装 LightMD。"
            case .tooLarge: "流程图过大，请拆分后再显示。"
            case .invalidImage: "无法生成流程图。"
            }
        }
    }
}

struct MermaidBlockView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var diagram: MermaidDiagram?
    @State private var failure: String?

    var body: some View {
        Group {
            if let diagram {
                Image(nsImage: diagram.image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: diagram.size.width)
                    .accessibilityLabel("Mermaid 流程图")
            } else if let failure {
                VStack(alignment: .leading, spacing: 8) {
                    Label("流程图无法显示", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.secondary)
                        .help(failure)
                    Text(source).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack { ProgressView().controlSize(.small); Text("正在绘制流程图…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .contextMenu {
            Button("复制 Mermaid 源码") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
            }
        }
        .task(id: "\(colorScheme == .dark):\(source)") {
            diagram = nil; failure = nil
            do {
                let rendered = try await MermaidRenderer.shared.render(source, dark: colorScheme == .dark)
                guard !Task.isCancelled else { return }
                diagram = rendered
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }
}
