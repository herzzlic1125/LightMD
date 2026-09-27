import AppKit
import Foundation
import Markdown
import PDFKit
import UniformTypeIdentifiers

struct PDFSnapshot {
    let source: String
    let fileURL: URL?
    let title: String
    let fontSize: CGFloat
    var isPlainText: Bool { fileURL?.pathExtension.lowercased() == "txt" }
}

@MainActor
extension ReaderState {
    func exportPDF() {
        guard !isExportingPDF, let tab = currentTab else { return }
        // Freeze the current edit, including text not yet published to the preview.
        let snapshot = PDFSnapshot(source: tab.source, fileURL: tab.url, title: tab.title, fontSize: fontSize)
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.pdf]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.directoryURL = tab.url?.deletingLastPathComponent()
        panel.nameFieldStringValue = (tab.url?.deletingPathExtension().lastPathComponent ?? "未命名") + ".pdf"
        isExportingPDF = true
        let response: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else { return }
            guard result == .OK, let target = panel.url else { self.isExportingPDF = false; return }
            Task { @MainActor in
                defer { self.isExportingPDF = false }
                do {
                    let warnings = try await PDFExporter.export(snapshot, to: target)
                    self.pdfExportNotice = "已导出至：\n\(target.path)" + (warnings.isEmpty ? "" :
                        "\n\n以下内容未能排版，已在 PDF 中保留源码或占位：\n" + warnings.prefix(4).joined(separator: "\n"))
                } catch { self.error = "PDF 导出失败：\(error.localizedDescription)" }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: response) }
        else { panel.begin(completionHandler: response) }
    }
}

@MainActor
enum PDFExporter {
    static func export(_ snapshot: PDFSnapshot, to target: URL) async throws -> [String] {
        if target.resolvingSymlinksInPath().standardizedFileURL == snapshot.fileURL?.resolvingSymlinksInPath().standardizedFileURL {
            throw ExportError.sourceOverwrite
        }
        let renderer = PDFHTMLRenderer(snapshot: snapshot)
        let html = try await renderer.document()
        let surface = OffscreenWebPage(width: 700, height: 1000)
        defer { surface.close() }
        try await surface.load(html)
        let failures = try await surface.call("""
            await document.fonts.ready;
            const failed = await Promise.all(Array.from(document.images, async image => {
                try { await image.decode(); return image.naturalWidth > 0 ? null : image.alt; }
                catch { return image.alt || '图片'; }
            }));
            return failed.filter(value => value !== null);
            """) as? [String] ?? []
        // A broken asset is a failed export, never a silently missing part of the PDF.
        guard failures.isEmpty else { throw ExportError.imageDecode }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LightMD-PDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("document.pdf")
        try await surface.printPDF(to: temporary)
        let data = try Data(contentsOf: temporary)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ExportError.invalidPDF }
        // Do not replace an existing destination until a complete PDF is ready.
        try data.write(to: target, options: .atomic)
        return renderer.warnings
    }

    enum ExportError: LocalizedError {
        case sourceOverwrite, imageDecode, invalidPDF
        var errorDescription: String? {
            switch self {
            case .sourceOverwrite: "导出位置不能覆盖 Markdown 源文件。"
            case .imageDecode: "图片或图表解码失败，原目标文件未被替换。"
            case .invalidPDF: "排版没有生成有效的 PDF，原目标文件未被替换。"
            }
        }
    }
}

@MainActor
final class PDFHTMLRenderer {
    let snapshot: PDFSnapshot
    private var tokens: [String: MathToken] = [:]
    private var mathHTML: [String: String] = [:]
    private var images: [String: String] = [:]
    private var headingCounts: [String: Int] = [:]
    private(set) var warnings: [String] = []

    init(snapshot: PDFSnapshot) { self.snapshot = snapshot }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    func document() async throws -> String {
        let body: String
        if snapshot.isPlainText {
            body = "<div class=plain>\(Self.escape(snapshot.source))</div>"
        } else {
            let prepared = MathMarkup.prepare(snapshot.source)
            tokens = prepared.tokens
            body = try await children(Document(parsing: prepared.text))
        }
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(OffscreenWebPage.policy)">
        <title>\(Self.escape(snapshot.title))</title><style>
        :root{color-scheme:light}*{box-sizing:border-box}
        html,body{margin:0;padding:0;background:white;color:#252525}
        body{font:\(min(32, max(12, snapshot.fontSize)))px/1.55 'Songti SC',serif;overflow-wrap:anywhere}
        p{margin:0 0 14px;orphans:3;widows:3}h1,h2,h3,h4,h5,h6{line-height:1.3;break-after:avoid;page-break-after:avoid;margin:18px 0 14px}
        h1{font-size:1.6em}h2{font-size:1.5em}h3{font-size:1.25em}h4,h5,h6{font-size:1.1em}
        strong{font-family:'STSongti-SC-Black','Songti SC',serif;font-weight:900}
        em{font-family:'Kaiti SC',serif} .latin{font-family:ui-serif,'New York',Georgia,serif}
        .punct{font-family:SimSong,'Songti SC',serif} strong .punct{font-family:'STSongti-SC-Black',serif}
        a{color:#236ac5;text-decoration:underline}ul,ol{padding-left:1.5em}li{margin-bottom:8px}
        blockquote{border-left:3px solid #aaa;margin:0 0 14px;padding-left:1em;color:#555}
        code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}
        code{background:#f3f3f3;padding:.1em .25em}pre{padding:12px;background:#f3f3f3;white-space:pre-wrap;overflow-wrap:anywhere;margin:0 0 14px}
        pre code{padding:0;background:none;font-size:1em}.plain{white-space:pre-wrap;orphans:3;widows:3}
        table{border-collapse:collapse;width:100%;table-layout:fixed;font-size:.9em;margin-bottom:14px}
        th,td{border:1px solid #ddd;padding:8px;vertical-align:top;text-align:left}th{background:#f5f5f5}
        thead{display:table-header-group}tr{break-inside:avoid;page-break-inside:avoid}
        table.three-col th:nth-child(1),table.three-col td:nth-child(1){width:19%}
        table.three-col th:nth-child(2),table.three-col td:nth-child(2){width:32%}
        table.three-col th:nth-child(3),table.three-col td:nth-child(3){width:49%}
        .local-image,.mermaid{display:block;max-width:100%;max-height:900px;object-fit:contain;margin:12px auto;break-inside:avoid;page-break-inside:avoid}
        .math{max-width:100%;object-fit:contain}.display-math{display:block;text-align:center;margin:14px 0;break-inside:avoid;page-break-inside:avoid}
        .display-math img{max-width:100%;max-height:900px}.missing{color:#666;font:12px/1.5 -apple-system,sans-serif}
        hr{border:0;border-top:1px solid #ddd;margin:14px 0}
        @media print{body{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
        </style></head><body>\(body)</body></html>
        """
    }

    private func children(_ node: Markup) async throws -> String {
        var result = ""
        for child in node.children { result += try await render(child) }
        return result
    }

    private func render(_ node: Markup) async throws -> String {
        if let text = node as? Markdown.Text { return await textWithMath(text.string) }
        if let heading = node as? Heading {
            let base = slug(plain(heading)), count = headingCounts[base, default: 0]
            headingCounts[base] = count + 1
            return "<h\(heading.level) id=\"\(Self.escape(base + (count == 0 ? "" : "-\(count)")))\">\(try await children(heading))</h\(heading.level)>"
        }
        if let paragraph = node as? Paragraph {
            let content = try await children(paragraph)
            return "<p>\(content)</p>"
        }
        if node is Strong { return "<strong>\(try await children(node))</strong>" }
        if node is Emphasis { return "<em>\(try await children(node))</em>" }
        if node is Strikethrough { return "<del>\(try await children(node))</del>" }
        if let code = node as? InlineCode { return "<code>\(Self.escape(code.code))</code>" }
        if let code = node as? CodeBlock {
            if code.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" {
                do {
                    let diagram = try await MermaidRenderer.shared.render(code.code)
                    return "<img class=mermaid alt=\"Mermaid 流程图\" src=\"data:image/svg+xml;base64,\(Data(diagram.svg.utf8).base64EncodedString())\">"
                } catch {
                    warnings.append("Mermaid 流程图：已保留源码")
                    return "<p class=missing>流程图无法显示，源码如下：</p><pre><code>\(Self.escape(code.code))</code></pre>"
                }
            }
            return "<pre><code>\(Self.escape(code.code))</code></pre>"
        }
        if node is BlockQuote { return "<blockquote>\(try await children(node))</blockquote>" }
        if let list = node as? OrderedList { return "<ol start=\"\(list.startIndex)\">\(try await children(list))</ol>" }
        if node is UnorderedList { return "<ul>\(try await children(node))</ul>" }
        if node is ListItem { return "<li>\(try await children(node))</li>" }
        if let link = node as? Markdown.Link {
            let content = try await children(link)
            let destination = link.destination ?? ""
            if let scheme = URL(string: destination)?.scheme?.lowercased(), !["http", "https", "mailto", "file"].contains(scheme) { return content }
            return "<a href=\"\(Self.escape(destination))\">\(content)</a>"
        }
        if let image = node as? Markdown.Image { return await imageHTML(image) }
        if node is SoftBreak { return "\n" }
        if node is LineBreak { return "<br>" }
        if node is ThematicBreak { return "<hr>" }
        if let table = node as? Markdown.Table {
            var output = "<table\(Array(table.head.cells).count == 3 ? " class=three-col" : "")><thead>"
            output += try await tableRow(Array(table.head.cells), header: true)
            output += "</thead><tbody>"
            for row in table.body.rows { output += try await tableRow(Array(row.cells), header: false) }
            return output + "</tbody></table>"
        }
        if let html = node as? HTMLBlock { return "<pre>\(Self.escape(html.rawHTML))</pre>" }
        if let html = node as? InlineHTML { return Self.escape(html.rawHTML) }
        return try await children(node)
    }

    private func tableRow(_ cells: [Markdown.Table.Cell], header: Bool) async throws -> String {
        let tag = header ? "th" : "td"
        var result = "<tr>"
        for cell in cells { result += "<\(tag)>\(try await children(cell))</\(tag)>" }
        return result + "</tr>"
    }

    private func textWithMath(_ text: String) async -> String {
        var result = "", remaining = text[...]
        while let range = remaining.range(of: "\u{E000}LM[0-9]+\u{E001}", options: .regularExpression) {
            result += typography(String(remaining[..<range.lowerBound]))
            let marker = String(remaining[range])
            if let token = tokens[marker] { result += await formulaHTML(token) }
            else { result += Self.escape(marker) }
            remaining = remaining[range.upperBound...]
        }
        return result + typography(String(remaining))
    }

    private func formulaHTML(_ token: MathToken) async -> String {
        let key = "\(token.display):\(token.formula)"
        if let existing = mathHTML[key] { return existing }
        let html: String
        do {
            let svg = try await FormulaExport.svg(token.formula, display: token.display)
            func capture(_ pattern: String) -> String {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
                      let range = Range(match.range(at: 1), in: svg) else { return "" }
                return String(svg[range])
            }
            let width = capture(#"width="([0-9.]+ex)""#)
            let height = capture(#"height="([0-9.]+ex)""#)
            let baseline = capture(#"vertical-align:\s*(-?[0-9.]+ex)"#)
            let image = "<img class=math alt=\"\(Self.escape(token.original))\" style=\"width:\(width);height:\(height);vertical-align:\(baseline)\" src=\"data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())\">"
            html = token.display ? "<span class=display-math>\(image)</span>" : image
        } catch {
            warnings.append("数学公式：\(token.original.prefix(60))")
            html = "<code>\(Self.escape(token.original))</code>"
        }
        mathHTML[key] = html
        return html
    }

    private func imageHTML(_ image: Markdown.Image) async -> String {
        let source = image.source ?? "", alternative = plain(image)
        if let existing = images[source] { return existing }
        let html: String
        if let url = MarkdownMedia.localURL(source, relativeTo: snapshot.fileURL),
           let loaded = await Task.detached(priority: .userInitiated, operation: { try? MarkdownMedia.load(url) }).value,
           let png = NSBitmapImageRep(cgImage: loaded.pixels).representation(using: .png, properties: [:]) {
            html = "<img class=local-image alt=\"\(Self.escape(alternative))\" src=\"data:image/png;base64,\(png.base64EncodedString())\">"
        } else {
            warnings.append("图片：\(source)")
            html = "<span class=missing>无法显示图片：\(Self.escape(alternative.isEmpty ? source : alternative))</span>"
        }
        images[source] = html
        return html
    }

    private func plain(_ node: Markup) -> String {
        if let text = node as? Markdown.Text {
            return tokens.values.reduce(text.string) { $0.replacingOccurrences(of: $1.marker, with: $1.original) }
        }
        if let code = node as? InlineCode { return code.code }
        return node.children.map(plain).joined()
    }

    private func slug(_ text: String) -> String {
        let kept = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0.isWhitespace }
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    private func typography(_ text: String) -> String {
        let characters = Array(text)
        var result = "", run = "", runClass = "", previous: ReadingRun?
        func flush() {
            guard !run.isEmpty else { return }
            let escaped = Self.escape(run)
            result += runClass.isEmpty ? escaped : "<span class=\(runClass)>\(escaped)</span>"
            run = ""
        }
        for (index, character) in characters.enumerated() {
            let kind = readingRun(for: character, previous: previous,
                                  next: index + 1 < characters.count ? characters[index + 1] : nil)
            let css = kind == .english || kind == .digit ? "latin" : kind == .hanPunctuation ? "punct" : ""
            if css != runClass { flush(); runClass = css }
            run.append(character)
            previous = kind
        }
        flush()
        return result
    }
}
