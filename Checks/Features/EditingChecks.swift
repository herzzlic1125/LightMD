import AppKit
import SwiftUI

@MainActor struct EditingChecks {
    static func run() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original: String
        if let path = ProcessInfo.processInfo.environment["LIGHTMD_EDITING_FIXTURE"] {
            original = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            original = (0..<400).map { "## Section \($0)\n\nText $x_{\($0)}$ and $$\\frac{\($0)}{2}$$\n\n" }.joined()
        }
        let file = directory.appendingPathComponent("editing.md")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let store = SessionStore(url: directory.appendingPathComponent("session.json"))
        let state = ReaderState(sessionStore: store)
        state.open(file)
        state.isEditing = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        ReadingLayoutChecks.pump(host, 0.8)
        let editor = ReadingLayoutChecks.descendants(host).compactMap { $0 as? NSTextView }
            .first(where: { $0.isEditable })!
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        var gaps: [Double] = []
        var lastTick = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append((now - lastTick) * 1000)
                lastTick = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        var latencies: [Double] = []
        for round in 0..<3 {
            editor.insertText("\nTyping round \(round): ", replacementRange: NSRange(location: NSNotFound, length: 0))
            // This pause intentionally lets the old main-thread parse run.
            ReadingLayoutChecks.pump(host, 0.25)
            let beforeIME = state.currentTab!.source
            let previewBeforeIME = state.currentTab!.previewID
            let diskBeforeIME = try Data(contentsOf: file)
            for syllable in ["n", "ni", "nih", "niha", "nihao"] {
                let start = CFAbsoluteTimeGetCurrent()
                editor.setMarkedText(syllable, selectedRange: NSRange(location: syllable.utf16.count, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                precondition(editor.hasMarkedText())
                ReadingLayoutChecks.pump(host, 0.08)
            }
            // A composition pause must not replace the native marked text.
            ReadingLayoutChecks.pump(host, 1.1)
            print("ime_checkpoint round=\(round) marked=\(editor.hasMarkedText()) sourceEqual=\(state.currentTab?.source == beforeIME) previewEqual=\(state.currentTab?.previewID == previewBeforeIME) diskEqual=\((try? Data(contentsOf: file)) == diskBeforeIME)")
            precondition(editor.hasMarkedText() && editor.string.hasSuffix("nihao"))
            precondition(state.currentTab?.source == beforeIME && state.currentTab?.previewID == previewBeforeIME)
            precondition(try! Data(contentsOf: file) == diskBeforeIME, "Autosave wrote an uncommitted composition")
            editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
            ReadingLayoutChecks.pump(host, 0.35)
            precondition(!editor.hasMarkedText() && editor.string.hasSuffix("你好"))
            precondition(state.currentTab?.source == editor.string)
            precondition(editor.selectedRange().location == (editor.string as NSString).length)
        }
        ReadingLayoutChecks.pump(host, 1.2)
        precondition(try! String(contentsOf: file, encoding: .utf8) == editor.string)
        precondition(!window.isVisible)
        print(String(format: "editing chars=%d marked_calls=%d marked_max_ms=%.2f heartbeat_max_ms=%.2f heartbeat_over100ms=%d",
                     original.utf16.count, latencies.count, latencies.max() ?? 0, gaps.max() ?? 0,
                     gaps.filter { $0 > 100 }.count))
        print("native_marked_text_commit_after_pause_and_autosave=passed")
        timer.invalidate()
        let committed = editor.string
        precondition(state.undoManager(for: state.selectedID).canUndo)
        state.undoEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        precondition(editor.string != committed && state.currentTab?.source == editor.string)
        precondition(state.undoManager(for: state.selectedID).canRedo)
        state.redoEditing()
        ReadingLayoutChecks.pump(host, 0.35)
        precondition(editor.string == committed && state.currentTab?.source == committed)
        precondition(state.currentTab?.isDirty == false)
        editor.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let outside = "# Outside edit during composition\n"
        try outside.write(to: file, atomically: true, encoding: .utf8)
        ReadingLayoutChecks.pump(host, 1.6)
        precondition(editor.hasMarkedText() && state.currentTab?.externalConflict == true)
        editor.insertText("冲突草稿", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 1.2)
        precondition(state.currentTab?.source == editor.string && state.currentTab?.isDirty == true)
        precondition(try! String(contentsOf: file, encoding: .utf8) == outside)
        editor.setMarkedText("modeDraft", selectedRange: NSRange(location: 9, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        state.isEditing = false
        ReadingLayoutChecks.pump(host, 0.6)
        precondition(state.currentTab?.source.hasSuffix("modeDraft") == true)
        state.isEditing = true
        ReadingLayoutChecks.pump(host, 0.6)
        let reopened = ReadingLayoutChecks.descendants(host).compactMap { $0 as? NSTextView }
            .first(where: { $0.isEditable })!
        reopened.setSelectedRange(NSRange(location: (reopened.string as NSString).length, length: 0))
        reopened.insertText(" AFTER_MODE_SWITCH", replacementRange: NSRange(location: NSNotFound, length: 0))
        ReadingLayoutChecks.pump(host, 0.5)
        precondition(state.currentTab?.index.last?.text.contains("AFTER_MODE_SWITCH") == true)
        let raceFile = directory.appendingPathComponent("race.md")
        try "# Before\n".write(to: raceFile, atomically: true, encoding: .utf8)
        let racing = ReaderState(sessionStore: SessionStore(url: directory.appendingPathComponent("race-session.json")))
        racing.open(raceFile)
        racing.updateSource(String(repeating: original, count: 4), in: racing.selectedID)
        FeatureRenderCheck.pump(0.19)
        racing.updateSource("# LATEST_SENTINEL\n\nFinal $x^2$", in: racing.selectedID)
        FeatureRenderCheck.pump(0.65)
        precondition(racing.currentOutline.first?.title == "LATEST_SENTINEL")
        precondition(racing.currentMathTokens.count == 1)
        precondition(racing.currentTab?.index.last?.text.contains("$x^2$") == true)
        print("native_caret_undo_redo_composition_external_conflict_mode_switch_and_latest_background_preview=passed")
    }
}
