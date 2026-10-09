import AppKit
import PDFKit
import Foundation
import SwiftUI

@MainActor enum ExportChecks {
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = MermaidRenderer.shared
        let graph = "flowchart LR\n A[开始] --> B{通过检查?}\n B -->|是| C[结束]\n B -->|否| A"
        let flow = try await renderer.render(graph)
        precondition(flow.svg.contains("开始") && flow.svg.contains("marker"))
        precondition(flow.size.width > 100 && flow.size.height > 30)
        precondition(flow.image.representations.count > 0)
        let dark = try await renderer.render(graph, dark: true)
        precondition(flow.svg != dark.svg)
        let cached = try await renderer.render(graph)
        precondition(cached.image === flow.image)
        let sequence = try await renderer.render("sequenceDiagram\n participant A as 用户\n participant B as 应用\n A->>B: 保存\n B-->>A: 完成")
        precondition(sequence.svg.contains("保存"))
        do { _ = try await renderer.render("flowchart LR\n A --> ["); preconditionFailure("Invalid Mermaid accepted") }
        catch { }
        // A rejected graph must not poison the next queued job.
        let recovered = try await renderer.render("flowchart TB\n X[恢复] --> Y[成功]")
        precondition(recovered.svg.contains("恢复"))
        let host = NSHostingView(rootView: MermaidBlockView(source: graph).frame(width: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let initialHeight = host.fittingSize.height
        host.rootView = MermaidBlockView(source: graph).frame(width: 200)
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        precondition(initialHeight > 20 && host.fittingSize.height < initialHeight,
                     "Native Mermaid view did not resize proportionally")
        window.contentView = nil
        window.close()
        print("mermaid_flow_chinese_arrows_sequence_theme_cache_failure_recovery_native_resize=passed")

        let image = root.appendingPathComponent("图 片.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="600" height="240"><rect width="600" height="240" fill="#1074db"/><circle cx="300" cy="120" r="80" fill="#f0aa20"/></svg>"##.write(to: image, atomically: true, encoding: .utf8)
        let named = root.appendingPathComponent("original.md")
        try "# On disk\n".write(to: named, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: named)
        let segment = (0..<650).map { "SEG\(String(format: "%04d", $0)) 中文跨页正文。" }.joined(separator: " ")
        let table = "| A | B | C |\n| --- | --- | --- |\n" + (0..<65).map { "| ROW\(String(format: "%03d", $0)) | 中文单元格 | 内容 |\n" }.joined()
        let gauss = #"\boxed{\oiint_S\mathbf D\cdot d\mathbf S=Q_{\text{inside}}}"#
        let source = "$$" + gauss + "$$\n\n" + "# 中文 PDF 导出\n\n最新未保存内容 SNAPSHOT_SENTINEL。\n\n[链接](https://example.com/)\n\n\(segment)\n\n\(table)\n\n" +
            "```swift\nlet text = \"<script>not executable</script>\"\n```\n\n" +
            "$$\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}$$\n\n![图](%E5%9B%BE%20%E7%89%87.svg)\n\n```mermaid\n\(graph)\n```\n\nTAIL_SENTINEL 最后一段。\n"
        let state = ReaderState(sessionStore: SessionStore(url: root.appendingPathComponent("session.json")))
        let tabID = state.open(named)!
        state.updateSource(source, in: tabID)
        let snapshot = PDFSnapshot(source: state.currentTab!.source, fileURL: named, title: "original.md", fontSize: 16)
        // Prove the export uses the requested snapshot, independently of later editor changes.
        state.updateSource("# LATER_EDIT_SENTINEL\n", in: tabID)
        let htmlRenderer = PDFHTMLRenderer(snapshot: snapshot)
        let html = try await htmlRenderer.document()
        precondition(htmlRenderer.warnings.isEmpty)
        let svgPattern = try NSRegularExpression(pattern: #"data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)"#)
        let embeddedSVGs = svgPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: html),
                  let data = Data(base64Encoded: String(html[range])) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        precondition(embeddedSVGs.contains { $0.contains("∯") && $0.contains("menclose") && !$0.contains("merror") })
        print("gauss_formula_in_exported_svg_without_fallback=passed")
        precondition(html.contains("class=mermaid") && html.contains("class=math") && html.contains("class=local-image"))
        precondition(!html.contains("<script>not executable</script>"))
        let target = root.appendingPathComponent("document.pdf")
        let warnings = try await PDFExporter.export(snapshot, to: target)
        precondition(warnings.isEmpty)
        let pdf = PDFDocument(url: target)!
        let text = pdf.string ?? ""
        print("export_pdf_diagnostics pages=\(pdf.pageCount) bytes=\(text.utf8.count) tail=\(text.contains("TAIL_SENTINEL"))")
        precondition(pdf.pageCount > 3 && pdf.pageCount < 60)
        precondition(text.contains("SNAPSHOT_SENTINEL") && text.contains("TAIL_SENTINEL") && !text.contains("LATER_EDIT_SENTINEL"))
        for i in 0..<650 { precondition(text.contains("SEG\(String(format: "%04d", i))"), "Long paragraph lost segment \(i)") }
        for i in 0..<65 { precondition(text.contains("ROW\(String(format: "%03d", i))"), "Table lost row \(i)") }
        for i in 0..<pdf.pageCount {
            let page = pdf.page(at: i)!
            let box = page.bounds(for: .mediaBox)
            precondition(abs(box.width - 595) < 2 && abs(box.height - 842) < 2)
        }
        let normalized = text.precomposedStringWithCompatibilityMapping
        precondition(normalized.contains("开始") && normalized.contains("结束"), "Diagram labels missing from PDF")
        var bluePixels = 0
        for index in 0..<pdf.pageCount {
            let context = CGContext(data: nil, width: 300, height: 425, bitsPerComponent: 8, bytesPerRow: 1200,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.scaleBy(x: 0.5, y: 0.5)
            pdf.page(at: index)!.draw(with: .mediaBox, to: context)
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: 300 * 425 * 4, by: 4) {
                if pixels[offset] < 50 && pixels[offset + 1] > 80 && pixels[offset + 1] < 150 && pixels[offset + 2] > 180 && pixels[offset + 3] > 100 { bluePixels += 1 }
            }
        }
        precondition(bluePixels > 1000, "Local image missing from PDF pages")
        print("pdf_mermaid_labels_and_local_image_pixels=passed (\(bluePixels) blue pixels)")
        print("full_pdf_a4_pages=\(pdf.pageCount) long_paragraph_segments=650 table_rows=65 tail_and_edit_snapshot=passed")
        // Exporting itself must not mutate the Markdown source; the app's normal autosave may have run.
        precondition(try! String(contentsOf: named, encoding: .utf8) != source)
        let directSource = root.appendingPathComponent("unchanged.md")
        try before.write(to: directSource)
        let direct = PDFSnapshot(source: "# Test\n\nPlain content.", fileURL: directSource, title: "unchanged.md", fontSize: 16)
        _ = try await PDFExporter.export(direct, to: root.appendingPathComponent("unchanged.pdf"))
        precondition(try! Data(contentsOf: directSource) == before)
        do { _ = try await PDFExporter.export(direct, to: directSource); preconditionFailure("Source overwritten") }
        catch { precondition(try! Data(contentsOf: directSource) == before) }
        let alias = root.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directSource)
        do { _ = try await PDFExporter.export(direct, to: alias); preconditionFailure("Source alias overwritten") }
        catch { precondition(try! Data(contentsOf: directSource) == before) }
        let broken = PDFSnapshot(source: "# Fallback\n\n$\\unknowncommand$\n\n![missing](missing.png)\n\n```mermaid\nflowchart LR\n A --> [\n```\n\nFALLBACK_TAIL",
                                 fileURL: directSource, title: "fallback.md", fontSize: 16)
        let fallback = root.appendingPathComponent("fallback.pdf")
        let fallbackWarnings = try await PDFExporter.export(broken, to: fallback)
        precondition(fallbackWarnings.count == 3)
        precondition(PDFDocument(url: fallback)!.string!.contains("FALLBACK_TAIL"))
        precondition(!NSApp.windows.contains(where: \.isVisible))
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        print("pdf_source_preservation_invalid_asset_fallback_and_no_foreground_windows=passed")
    }
}
