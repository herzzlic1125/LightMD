import AppKit
import Foundation

@MainActor struct SessionCheck {
    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(url: dir.appendingPathComponent("session.json"))
        let file = dir.appendingPathComponent("notes.md")
        try "# Original\n".write(to: file, atomically: true, encoding: .utf8)
        let first = ReaderState(sessionStore: store)
        let fileID = first.open(file)!
        first.recordBookmark(ReadingBookmark(path: "4", fraction: 0.35, atTop: false, atBottom: false), in: fileID)
        first.updateSource("# Draft 📝\n", in: fileID)
        first.newTab()
        let draftID = first.selectedID
        first.updateSource("# Untitled draft\n\n$E=mc^2$", in: draftID)
        first.newTab()
        first.selectedID = draftID
        precondition(first.saveSessionNow())
        let saved = try Data(contentsOf: store.url)
        precondition(saved.contains(Data("Untitled draft".utf8)))
        let second = ReaderState(sessionStore: store)
        precondition(second.tabs.count == 3 && second.selectedID == second.tabs[1].id)
        precondition(second.tabs[0].source == "# Draft 📝\n" && second.tabs[0].isDirty)
        precondition(second.tabs[1].url == nil && second.tabs[1].source.contains("Untitled draft"))
        precondition(second.bookmark(for: second.tabs[0].id)?.fraction == 0.35)
        precondition(try! String(contentsOf: file, encoding: .utf8) == "# Original\n")
        print("ordered_tabs_selection_bookmark_and_drafts=passed")
        try "# External change\n".write(to: file, atomically: true, encoding: .utf8)
        let third = ReaderState(sessionStore: store)
        precondition(third.tabs[0].externalConflict && third.tabs[0].source == "# Draft 📝\n")
        third.selectedID = third.tabs[0].id
        precondition(!third.saveCurrent())
        precondition(try! String(contentsOf: file, encoding: .utf8) == "# External change\n")
        precondition(third.saveSessionNow())
        let again = ReaderState(sessionStore: store)
        precondition(again.tabs[0].externalConflict)
        again.selectedID = again.tabs[0].id
        precondition(!again.saveCurrent())
        precondition(try! String(contentsOf: file, encoding: .utf8) == "# External change\n")
        print("restored_external_revision_protected_across_repeated_restarts=passed")
        try FileManager.default.removeItem(at: file)
        let fourth = ReaderState(sessionStore: store)
        precondition(fourth.tabs[0].externalConflict && fourth.tabs[0].source == "# Draft 📝\n")
        fourth.selectedID = fourth.tabs[0].id
        precondition(!fourth.saveCurrent() && !FileManager.default.fileExists(atPath: file.path))
        print("missing_file_draft_preserved=passed")

        let cleanURL = dir.appendingPathComponent("clean.md")
        try "CLEAN_CONTENT_SENTINEL".write(to: cleanURL, atomically: true, encoding: .utf8)
        let cleanStore = SessionStore(url: dir.appendingPathComponent("clean-session.json"))
        let clean = ReaderState(sessionStore: cleanStore)
        clean.open(cleanURL)
        precondition(clean.saveSessionNow())
        let cleanData = try Data(contentsOf: cleanStore.url)
        precondition(!cleanData.contains(Data("CLEAN_CONTENT_SENTINEL".utf8)))
        print("clean_file_content_not_duplicated=passed")
        let exitStore = SessionStore(url: dir.appendingPathComponent("exit-session.json"))
        let exiting = ReaderState(sessionStore: exitStore)
        exiting.open(cleanURL)
        exiting.updateSource("# Saved on quit\n", in: exiting.selectedID)
        exiting.newTab()
        exiting.updateSource("Unnamed draft retained on quit", in: exiting.selectedID)
        precondition(exiting.confirmCloseAll())
        precondition(try! String(contentsOf: cleanURL, encoding: .utf8) == "# Saved on quit\n")
        let resumed = ReaderState(sessionStore: exitStore)
        precondition(resumed.currentTab!.source == "Unnamed draft retained on quit")
        print("normal_quit_flushes_named_file_and_preserves_unnamed_draft=passed")
        let brokenParent = dir.appendingPathComponent("not-a-directory")
        let broken = ReaderState(sessionStore: SessionStore(url: brokenParent.appendingPathComponent("session.json")))
        broken.updateSource("Draft must survive failed storage", in: broken.selectedID)
        try Data("occupied".utf8).write(to: brokenParent)
        precondition(!broken.confirmCloseAll() && broken.error != nil)
        precondition(broken.currentTab!.source == "Draft must survive failed storage")
        print("failed_session_write_blocks_quit_and_keeps_draft=passed")

        let corruptStore = SessionStore(url: dir.appendingPathComponent("corrupt-session.json"))
        try Data("{invalid".utf8).write(to: corruptStore.url)
        let corrupt = ReaderState(sessionStore: corruptStore)
        precondition(corrupt.error != nil && corrupt.tabs.count == 1)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("session-unreadable-") }
        precondition(!backups.isEmpty)
        precondition(try! Data(contentsOf: backups[0]) == Data("{invalid".utf8))
        print("unreadable_session_retained=passed")
    }
}

import Foundation

struct MathMarkupCheck {
    static func run() {
        let source = #"""
        价格 $5 和 $10，公式 $x_i^2+\frac{a}{b}$。
        另一种 \(\sqrt{x}\)，块公式：
        $$
        \begin{cases}x & \text{若 }x>0\\ 0 & \text{否则}\end{cases}
        $$
        \[\int_0^1 x\,dx\]
        `代码 $y$` 和 ``两格 `$z$` ``。
        ```math
        $ignored$
        ```
        ![图片](a$5.png) 与 [链接](file$6.md)。
        \$7 保持字面，$ x^2 $ 可显示，$ x $ 保持字面。
        """#
        let prepared = MathMarkup.prepare(source)
        let formulas = prepared.tokens.values.map(\.formula)
        precondition(formulas.count == 5, "Unexpected tokens: \(formulas)")
        precondition(formulas.contains(#"x_i^2+\frac{a}{b}"#))
        precondition(formulas.contains(#"\sqrt{x}"#))
        precondition(formulas.contains(#"\int_0^1 x\,dx"#))
        precondition(formulas.contains(#"x^2"#))
        precondition(prepared.text.contains("$5 和 $10"))
        precondition(prepared.text.contains("`代码 $y$`"))
        precondition(prepared.text.contains("a$5.png"))
        precondition(prepared.text.filter(\.isNewline).count == source.filter(\.isNewline).count)
        let windows = MathMarkup.prepare("前\r\n$$\r\na^2\r\n$$\r\n后")
        precondition(windows.tokens.count == 1)
        precondition(windows.tokens.values.first!.firstLine == 2 && windows.tokens.values.first!.lastLine == 4)
        precondition(windows.text.filter(\.isNewline).count == 4)
        precondition(MathMarkup.prepare("```\n\n$ignored$\n```\n").tokens.isEmpty)
        precondition(MathMarkup.prepare("    $ignored$\n").tokens.isEmpty)
        precondition(MathMarkup.prepare("[id]: /$ignored$.md\n").tokens.isEmpty)
        precondition(MathMarkup.prepare("- item\n\n    \\[x=1\\]\n").tokens.count == 1)
        precondition(MathMarkup.prepare("$$ unclosed\n\n```\n$$\n```\n").tokens.isEmpty)
        print("math_delimiters_code_prices_links_multiline_crlf=passed")
    }
}

import AppKit
import SwiftUI
import ImageIO
import Foundation
import MathJaxSwift

@MainActor struct FeatureRenderCheck {
    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func rendered(_ formula: String, size: CGFloat = 16) -> FormulaImage {
        let cache = FormulaCache()
        let token = MathToken(marker: "test", original: "$$\(formula)$$", formula: formula,
                              display: true, firstLine: 1, lastLine: 1)
        for _ in 0..<100 {
            switch cache.result(for: token, fontSize: size, displayScale: 2) {
            case .image(let image): return image
            case .failure(let error): fatalError("\(formula): \(error)")
            case .pending: pump(0.03)
            }
        }
        fatalError("Formula rendering timed out")
    }
    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let engine = try MathJax(preferredOutputFormats: [.svg])
        func svg(_ input: String) throws -> String {
            try engine.tex2svg(input, styles: false, conversionOptions: ConversionOptions(display: true),
                               inputOptions: FormulaConfiguration.inputOptions)
        }
        func count(_ markup: String, _ node: String) -> Int {
            markup.components(separatedBy: "data-mml-node=\"\(node)\"").count - 1
        }
        for input in [#"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#,
                      #"\begin{cases}x^2&\text{若 }x>0\\ 0&\text{否则}\end{cases}"#,
                      #"\begin{aligned}x&=1\\y&=2\end{aligned}"#] {
            let markup = try svg(input)
            precondition(count(markup, "mtr") == 2 && count(markup, "mtd") == 4, "Rows or columns were lost")
        }
        let arithmetic = try svg("1+2")
        precondition(count(arithmetic, "mn") == 2 && count(arithmetic, "mo") == 1)
        let decimals = try svg("1.25+.5+1{,}234.56")
        precondition(count(decimals, "mn") == 3 && count(decimals, "mo") == 2)
        print("math_numeric_operators_matrix_columns_cases_rows_and_decimals=passed")
        let formulas = [#"\text{中文条件}"#, #"x_i^2"#, #"\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#,
                        #"\begin{pmatrix}1&2\\3&4\end{pmatrix}"#,
                        #"\begin{cases}x^2&\text{若 }x>0\\ 0&\text{否则}\end{cases}"#,
                        #"\begin{aligned}a&=b&c&=d\\e&=f&g&=h\end{aligned}"#]
        for formula in formulas {
            let result = rendered(formula)
            print("rendered_size=\(result.image.size) formula=\(formula)")
            precondition(result.image.size.width > 1 && result.image.size.height > 1)
            if formula.contains("begin") { precondition(result.image.size.height > 24, "Matrix or aligned rows collapsed") }
            let bitmap = NSBitmapImageRep(data: result.image.tiffRepresentation!)!
            var marked = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { marked += 1 }
                }
            }
            precondition(marked > 4, "Blank formula image")
        }
        let small = rendered(#"\frac{x}{y}"#, size: 16)
        let large = rendered(#"\frac{x}{y}"#, size: 24)
        precondition(large.image.size.height > small.image.size.height * 1.3)
        let invalid = MathToken(marker: "bad", original: #"$\unknowncommand$"#,
                                formula: #"\unknowncommand"#, display: false, firstLine: 1, lastLine: 1)
        let cache = FormulaCache()
        var failed = false
        for _ in 0..<100 {
            if case .failure = cache.result(for: invalid, fontSize: 16, displayScale: 2) { failed = true; break }
            pump(0.02)
        }
        precondition(failed)
        print("formula_fraction_matrix_chinese_cases_aligned_size_and_failure=passed")

        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("图 片.png")
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let doc = directory.appendingPathComponent("sample.md")
        let resolved = MarkdownMedia.localURL("%E5%9B%BE%20%E7%89%87.png", relativeTo: doc)!
        precondition(resolved == imageURL)
        let loaded = try MarkdownMedia.load(resolved)
        precondition(loaded.size.width / loaded.size.height == 2)
        let svgURL = directory.appendingPathComponent("diagram.svg")
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="600" height="300"><rect width="600" height="300" fill="blue"/></svg>"#.write(to: svgURL, atomically: true, encoding: .utf8)
        let vector = try MarkdownMedia.load(svgURL)
        precondition(vector.size.width / vector.size.height == 2)
        precondition(MarkdownMedia.localURL("https://example.invalid/image.png", relativeTo: doc) == nil)
        print("relative_unicode_raster_vector_image_paths_and_aspect_ratio=passed")

        let markdown = "# Math $x_i^2$\n\n中文 $\\frac{a}{b}$ English。\n\n$$\n\\begin{aligned}a&=b\\\\c&=d\\end{aligned}\n$$\n\n## After\n\n![图](%E5%9B%BE%20%E7%89%87.png)\n"
        try markdown.write(to: doc, atomically: true, encoding: .utf8)
        let state = ReaderState(sessionStore: SessionStore(url: directory.appendingPathComponent("session.json")))
        state.open(doc)
        precondition(state.currentMathTokens.count == 3 && state.currentTab!.source == markdown)
        precondition(!state.currentOutline.contains { $0.title.contains("\u{E000}") })
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<50 { host.layoutSubtreeIfNeeded(); pump(0.025) }
        precondition(state.formulas.revision >= 3, "Formula placeholders were not rendered by the document view")
        state.updateSource(markdown + "\nSaved.\n", in: state.selectedID)
        pump(1.2)
        precondition(try! String(contentsOf: doc, encoding: .utf8) == markdown + "\nSaved.\n")
        window.contentView = nil
        print("document_formula_image_integration_and_original_source_save=passed")
    }
}


@main @MainActor struct FeatureChecks {
    static func main() throws {
        setbuf(stdout, nil)
        try SessionCheck.run()
        MathMarkupCheck.run()
        try FeatureRenderCheck.run()
        var finished = false
        var exportError: Error?
        Task { @MainActor in
            do { try await ExportChecks.run() }
            catch { exportError = error }
            finished = true
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if let exportError { throw exportError }
    }
}
