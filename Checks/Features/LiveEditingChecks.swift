import AppKit
import Foundation
import SwiftUI
import Markdown

@MainActor struct LiveEditingChecks {
    static func pump(_ seconds: Double = 0.3) { FeatureRenderCheck.pump(seconds) }

    static func run() throws {
        let paragraph = "正文😀 e\u{301} **粗体** $x_i^2$ 尾部"
        let heading = "# 标题😀"
        let formula = "$$\n\\begin{aligned}a&=b\\\\c&=d\\end{aligned}\n$$"
        let code = "```swift\nlet value = \"$not_math$\"\n```"
        let table = "| A | B |\n| --- | --- |\n| $x^2$ | text |"
        let raw = heading + "\r\n\r\n" + paragraph + "\r\n\r\n" + formula + "\n\n" +
            "> 引用 $y^2$\n> 第二行\n\n" + "- item one\n  - nested item\n- item two\n\n" +
            code + "\n\n" + table + "\n\n[unused]: https://example.com/\n\nUntouched final paragraph"
        let parsed = LiveSourceDocument.parse(raw)
        let fragments = parsed.blocks.map { (raw as NSString).substring(with: $0.range) }
        print("live_range_fragments=\(fragments)")
        for required in [heading, paragraph, formula, code, table, "Untouched final paragraph"] {
            precondition(fragments.contains(required), "Precise range missing: \(required), got \(fragments)")
        }
        precondition(fragments.contains { $0.hasPrefix("> 引用") && $0.contains("> 第二行") })
        precondition(fragments.contains { $0.hasPrefix("- item one") && $0.contains("  - nested") })
        for (left, right) in zip(parsed.blocks, parsed.blocks.dropFirst()) {
            precondition(NSMaxRange(left.range) <= right.range.location)
        }
        for (old, new) in [("😀e\u{301}", "😁e\u{301}"), ("e\u{301}", "é"), ("a😀b", "a🧑‍💻b")] {
            let edit = SourceEdit.difference(from: old, to: new, selection: NSRange(location: 0, length: 0))
            precondition(sameSourceBytes((old as NSString).replacingCharacters(in:
                NSRange(location: edit.location, length: edit.before.utf16.count), with: edit.after), new))
            precondition(sameSourceBytes((new as NSString).replacingCharacters(in:
                NSRange(location: edit.location, length: edit.after.utf16.count), with: edit.before), old))
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("live.md")
        let originalData = Data([0xEF, 0xBB, 0xBF]) + Data(raw.utf8)
        try originalData.write(to: file)
        let state = ReaderState(sessionStore: SessionStore(url: root.appendingPathComponent("session.json")))
        state.open(file)
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        ReadingLayoutChecks.pump(host, 0.5)
        state.toggleLiveEditing()
        ReadingLayoutChecks.pump(host, 0.3)
        let controller = state.liveEditingController!
        print("live_entered blocks=\(controller.document?.blocks.count ?? -1)")
        precondition(state.mode == .live && !state.isEditing)
        let first = controller.document!.blocks.first {
            (controller.document!.source as NSString).substring(with: $0.range) == paragraph
        }!
        controller.begin(first)
        ReadingLayoutChecks.pump(host, 0.25)
        precondition(sameSourceBytes(state.currentTab!.source, raw))
        precondition(try! Data(contentsOf: file) == originalData)
        let editor = ReadingLayoutChecks.descendants(host).first {
            $0.identifier?.rawValue == "liveBlockEditor"
        } as! NSTextView
        precondition(editor.string == paragraph)
        print("live_activated native text matches")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let beforeIME = state.currentTab!.source
        editor.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 1.2)
        precondition(editor.hasMarkedText() && state.currentTab?.source == beforeIME)
        precondition(try! Data(contentsOf: file) == originalData)
        editor.insertText("你好\n\n## New heading\n\nNew paragraph", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.4)
        let edited = state.currentTab!.source
        let replacement = paragraph + "你好\n\n## New heading\n\nNew paragraph"
        print("live_edited preview_blocks=\(controller.active?.preview?.blocks.count ?? -1) correct_source=\(sameSourceBytes(edited, (raw as NSString).replacingCharacters(in: first.range, with: replacement)))")
        precondition(sameSourceBytes(edited, (raw as NSString).replacingCharacters(in: first.range, with: replacement)))
        precondition(controller.active?.preview?.blocks.count == 3)
        // Clicking an old rendered block after an insertion must account for the
        // shift of every later source range, not write into a different paragraph.
        let untouched = controller.document!.blocks.last!
        controller.begin(untouched)
        ReadingLayoutChecks.pump(host, 0.3)
        precondition(controller.active?.text == "Untouched final paragraph")
        print("live_shifted_selection=passed")
        let secondEditor = ReadingLayoutChecks.descendants(host).first {
            $0.identifier?.rawValue == "liveBlockEditor"
        } as! NSTextView
        secondEditor.setSelectedRange(NSRange(location: (secondEditor.string as NSString).length, length: 0))
        secondEditor.insertText(" edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.35)
        precondition(state.currentTab?.source == edited + " edited")
        state.undoEditing()
        ReadingLayoutChecks.pump(host, 0.3)
        precondition(state.currentTab?.source == edited && controller.active?.text == "Untouched final paragraph")
        print("live_first_undo=passed")
        secondEditor.setSelectedRange(NSRange(location: 0, length: 9))
        secondEditor.insertText("CHANGED", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.1)
        state.undoEditing()
        ReadingLayoutChecks.pump(host, 0.1)
        precondition(secondEditor.selectedRange() == NSRange(location: 0, length: 9))
        precondition(state.currentTab?.source == edited)
        secondEditor.setSelectedRange(NSRange(location: (secondEditor.string as NSString).length, length: 0))
        secondEditor.insertText(" edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.1)
        state.undoEditing()
        ReadingLayoutChecks.pump(host, 0.1)
        state.toggleMode()
        ReadingLayoutChecks.pump(host, 0.6)
        print("live_to_source mode=\(state.mode) unchanged=\(state.currentTab?.source == edited) undo=\(state.undoManager(for: state.selectedID).canUndo)")
        precondition(state.mode == .source)
        state.undoEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        print("live_second_undo exact=\(sameSourceBytes(state.currentTab!.source, raw)) source=\(state.currentTab!.source)")
        precondition(sameSourceBytes(state.currentTab!.source, raw))
        state.redoEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        precondition(state.currentTab?.source == edited)
        state.redoEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        precondition(state.currentTab?.source == edited + " edited")
        print("live_cross_mode_redo=passed")
        state.toggleLiveEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        controller.begin(nil)
        ReadingLayoutChecks.pump(host, 0.25)
        let appendEditor = ReadingLayoutChecks.descendants(host).first {
            $0.identifier?.rawValue == "liveBlockEditor"
        } as! NSTextView
        appendEditor.insertText("## End\n\nFinal **bold**", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 1.25)
        print("live_append=\(String(state.currentTab!.source.suffix(65)).debugDescription)")
        precondition(state.currentTab!.source == edited + " edited\r\n\r\n## End\n\nFinal **bold**")
        let saved = try Data(contentsOf: file)
        precondition(saved.starts(with: [0xEF, 0xBB, 0xBF]))
        precondition(String(data: saved.dropFirst(3), encoding: .utf8) == state.currentTab!.source)
        state.toggleLiveEditing()
        ReadingLayoutChecks.pump(host, 0.3)
        precondition(state.mode == .reading)
        // Accepting a new external version invalidates the previous undo stack.
        try "# EXTERNAL\n\nFresh paragraph\n".write(to: file, atomically: true, encoding: .utf8)
        ReadingLayoutChecks.pump(host, 1.6)
        precondition(state.currentTab?.source == "# EXTERNAL\n\nFresh paragraph\n")
        precondition(!state.undoManager(for: state.selectedID).canUndo)
        state.toggleLiveEditing()
        ReadingLayoutChecks.pump(host, 0.3)
        let externalBlock = controller.document!.blocks.last!
        controller.begin(externalBlock)
        ReadingLayoutChecks.pump(host, 0.2)
        let externalEditor = ReadingLayoutChecks.descendants(host).first {
            $0.identifier?.rawValue == "liveBlockEditor"
        } as! NSTextView
        try "# ANOTHER_EXTERNAL\n".write(to: file, atomically: true, encoding: .utf8)
        ReadingLayoutChecks.pump(host, 1.6)
        precondition(state.currentTab?.externalConflict == true && externalEditor.string == "Fresh paragraph")
        externalEditor.setSelectedRange(NSRange(location: (externalEditor.string as NSString).length, length: 0))
        externalEditor.insertText(" draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.1)
        externalEditor.setMarkedText("closeCandidate", selectedRange: NSRange(location: 14, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(state.confirmCloseAll())
        precondition(state.currentTab!.source.hasSuffix("Fresh paragraph draftcloseCandidate\n"))
        precondition(try! String(contentsOf: file, encoding: .utf8) == "# ANOTHER_EXTERNAL\n")
        let restored = ReaderState(sessionStore: SessionStore(url: root.appendingPathComponent("session.json")))
        precondition(restored.currentTab?.source == state.currentTab?.source && restored.currentTab?.externalConflict == true)
        // While replacing a stale rendered snapshot, old positions are not editable.
        controller.fold()
        precondition(controller.isRefreshing)
        controller.begin(externalBlock)
        precondition(controller.active == nil)
        precondition(!window.isVisible)
        print("live_precise_source_ranges_math_unicode_CRLF_BOM_IME_local_preview_shifted_blocks_cross_mode_undo_append_save=passed")
        print("live_selected_word_undo_external_reload_history_active_conflict_candidate_close_stale_click=passed")
    }

    static func performance() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LIGHTMD_LIVE_FIXTURE"] else { return }
        let raw = try String(contentsOfFile: fixture, encoding: .utf8)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("performance.md")
        try raw.write(to: file, atomically: true, encoding: .utf8)
        let state = ReaderState(sessionStore: SessionStore(url: root.appendingPathComponent("session.json")))
        state.open(file)
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        ReadingLayoutChecks.pump(host, 0.4)
        let deadline = Date().addingTimeInterval(15)
        var requests = state.currentMathTokens.values.map { ($0, CGFloat(16 * ($0.display ? 1.12 : 1))) }
        func warmVariants(_ node: Markup) {
            if let heading = node as? Heading {
                let size: CGFloat = 16 * (heading.level == 1 ? 1.6 : heading.level == 2 ? 1.5 : 1.25)
                requests += MathMarkup.tokens(in: heading.format(), from: state.currentMathTokens).map { ($0, size) }
            } else if let table = node as? Markdown.Table {
                requests += MathMarkup.tokens(in: table.format(), from: state.currentMathTokens).map { ($0, CGFloat(14.4)) }
            }
            for child in node.children { warmVariants(child) }
        }
        if let document = state.currentDocument { warmVariants(document) }
        var ready = false
        repeat {
            ready = requests.allSatisfy {
                if case .image = state.formulas.result(for: $0.0, fontSize: $0.1, displayScale: 2) { return true }
                return false
            }
            ReadingLayoutChecks.pump(host, 0.05)
        } while !ready && Date() < deadline
        precondition(ready)
        state.toggleLiveEditing(); ReadingLayoutChecks.pump(host, 0.4)
        let controller = state.liveEditingController!
        var last = CFAbsoluteTimeGetCurrent(), gaps: [Double] = []
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in MainActor.assumeIsolated {
            let now = CFAbsoluteTimeGetCurrent(); gaps.append((now - last) * 1000); last = now
        }}
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        let revision = state.formulas.revision
        for fraction in [0.0, 0.5, 1.0] {
            let document = controller.document!
            let candidates = document.blocks.filter {
                let fragment = (document.source as NSString).substring(with: $0.range)
                return $0.markup.first is Paragraph && !fragment.contains("$") && !fragment.contains("\\[") && !fragment.contains("\\(")
            }
            let target = candidates[min(candidates.count - 1, Int(Double(candidates.count - 1) * fraction))]
            controller.begin(target); ReadingLayoutChecks.pump(host, 0.2)
            let editor = ReadingLayoutChecks.descendants(host).first { $0.identifier?.rawValue == "liveBlockEditor" } as! NSTextView
            let identity = ObjectIdentifier(editor)
            for _ in 0..<8 {
                editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
                ReadingLayoutChecks.pump(host, 0.04)
            }
            ReadingLayoutChecks.pump(host, 0.3)
            let current = ReadingLayoutChecks.descendants(host).first { $0.identifier?.rawValue == "liveBlockEditor" }!
            precondition(ObjectIdentifier(current) == identity, "Active editor was rebuilt while typing")
            controller.fold(); ReadingLayoutChecks.pump(host, 0.3)
        }
        print(String(format: "live_long_document tokens=%d heartbeat_max_ms=%.2f over100ms=%d warm_formula_new_renders=%d",
            state.currentMathTokens.count, gaps.max() ?? 0, gaps.filter { $0 > 100 }.count, state.formulas.revision - revision))
        precondition(state.formulas.revision == revision)
        precondition(!window.isVisible)
        print("live_long_document_top_middle_bottom_stable_editor_warm_formula_cache=passed")
    }
}
