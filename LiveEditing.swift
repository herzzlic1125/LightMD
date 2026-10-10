import AppKit
import SwiftUI
import Markdown

@MainActor final class LiveEditSession: ObservableObject, Identifiable {
    let id = UUID()
    let tabID: UUID
    let blockID: UUID?
    let prefix: String
    let suffix: String
    let padding: String
    let originalRange: NSRange
    @Published private(set) var text: String
    @Published private(set) var preview: LiveSourceDocument?
    @Published var height: CGFloat = 60
    @Published var selectionRequest: SourceSelectionRequest?
    var selection: NSRange
    weak var editor: NSTextView?
    private(set) var composing = false
    private(set) var ended = false
    private var expectedSource: String
    private weak var reader: ReaderState?
    private var previewTask: Task<Void, Never>?

    init(reader: ReaderState, tabID: UUID, block: LiveSourceBlock?, source: String,
         selection: NSRange? = nil) {
        self.reader = reader
        self.tabID = tabID
        blockID = block?.id
        let content = source as NSString
        let range = block?.range ?? NSRange(location: content.length, length: 0)
        originalRange = range
        prefix = content.substring(to: range.location)
        suffix = content.substring(from: NSMaxRange(range))
        text = content.substring(with: range)
        padding = block == nil && !source.isEmpty && !source.hasSuffix("\n\n")
            && !source.hasSuffix("\r\n\r\n") ? (source.contains("\r\n") ? "\r\n\r\n" : "\n\n") : ""
        self.selection = selection ?? NSRange(location: range.length, length: 0)
        expectedSource = source
        schedulePreview()
    }

    var origin: Int { prefix.utf16.count + (text.isEmpty ? 0 : padding.utf16.count) }

    func receive(_ text: String, selection: NSRange) {
        guard !ended, !composing, let reader,
              let tab = reader.tabs.first(where: { $0.id == tabID }),
              sameSourceBytes(tab.source, expectedSource) else { return }
        self.selection = selection
        guard !sameSourceBytes(self.text, text) else { return }
        self.text = text
        let source = prefix + (text.isEmpty ? "" : padding) + text + suffix
        expectedSource = source
        reader.updateSource(source, in: tabID,
                            selectionAfter: NSRange(location: origin + selection.location, length: selection.length))
        schedulePreview()
        measure()
    }

    func recordSelection(_ range: NSRange) {
        selection = range
        reader?.recordSourceSelection(NSRange(location: origin + range.location, length: range.length), in: tabID)
    }

    func composition(_ active: Bool) {
        composing = active
        reader?.setSourceComposition(active, in: tabID)
        if active { previewTask?.cancel() }
        else { schedulePreview() }
    }

    func finish() {
        guard !ended else { return }
        if let editor, editor.hasMarkedText() { editor.unmarkText() }
        if let editor { receive(editor.string, selection: editor.selectedRange()) }
        composition(false)
        ended = true
        previewTask?.cancel()
        if let editor, editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
    }

    func reconcileUndo(source: String, selection: NSRange) -> Bool {
        let content = source as NSString
        guard !composing, content.length >= prefix.utf16.count + suffix.utf16.count,
              sameSourceBytes(content.substring(to: prefix.utf16.count), prefix),
              sameSourceBytes(content.substring(from: content.length - suffix.utf16.count), suffix) else { return false }
        let range = NSRange(location: prefix.utf16.count,
                            length: source.utf16.count - prefix.utf16.count - suffix.utf16.count)
        var fragment = (source as NSString).substring(with: range)
        if !padding.isEmpty, fragment.hasPrefix(padding) { fragment = String(fragment.dropFirst(padding.count)) }
        text = fragment
        expectedSource = source
        let start = min(fragment.utf16.count, max(0, selection.location - origin))
        let local = NSRange(location: start, length: min(selection.length, fragment.utf16.count - start))
        self.selection = local
        editor?.string = fragment
        editor?.setSelectedRange(local)
        selectionRequest = SourceSelectionRequest(tabID: tabID, range: local)
        schedulePreview()
        return true
    }

    func measure() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor, let layout = editor.layoutManager,
                  let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let next = min(480, max(48, ceil(layout.usedRect(for: container).height + editor.textContainerInset.height * 2 + 8)))
            if abs(next - self.height) > 1 { self.height = next }
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard !composing, !ended else { return }
        let fragment = text
        previewTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) }
            catch { return }
            let work = Task.detached(priority: .userInitiated) { LiveSourceDocument.parse(fragment) }
            let result = await work.value
            guard !Task.isCancelled, let self, !self.composing, !self.ended,
                  sameSourceBytes(self.text, fragment) else { return }
            self.preview = result
        }
    }
}

@MainActor final class LiveEditingController: ObservableObject {
    @Published private(set) var document: LiveSourceDocument?
    @Published private(set) var active: LiveEditSession?
    @Published private(set) var presentationID = UUID()
    @Published private(set) var isRefreshing = false
    private weak var reader: ReaderState?
    private var task: Task<Void, Never>?
    private var tabID: UUID?
    private var pendingSelection: NSRange?
    private var pendingNavigation: OutlineEntry?
    private(set) var shouldReveal = true

    func configure(_ reader: ReaderState) { self.reader = reader }

    func enter() {
        guard let reader, reader.isLiveEditing else { return }
        finish()
        if tabID != reader.selectedID { document = nil; presentationID = UUID() }
        tabID = reader.selectedID
        refresh()
    }

    func refresh() {
        guard let reader, reader.isLiveEditing, active == nil, let tab = reader.currentTab else { return }
        task?.cancel()
        isRefreshing = true
        let source = tab.source, id = tab.id
        task = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { LiveSourceDocument.parse(source) }
            let result = await work.value
            guard !Task.isCancelled, let self, let reader = self.reader,
                  reader.isLiveEditing, reader.selectedID == id, self.active == nil,
                  sameSourceBytes(reader.currentTab?.source ?? "", source) else { return }
            self.tabID = id
            self.document = result
            self.presentationID = UUID()
            self.isRefreshing = false
            if let navigation = self.pendingNavigation {
                self.pendingNavigation = nil
                if let target = result.outline.first(where: { $0.slug == navigation.slug }) {
                    reader.navigate(to: target.id)
                }
            } else if let selection = self.pendingSelection {
                self.pendingSelection = nil
                let block = result.blocks.first { selection.location >= $0.range.location
                    && selection.location < NSMaxRange($0.range) }
                self.begin(block, selection: block.map {
                    let start = min($0.range.length, max(0, selection.location - $0.range.location))
                    return NSRange(location: start, length: min(selection.length, $0.range.length - start))
                })
            } else if result.blocks.isEmpty { self.begin(nil) }
        }
    }

    func begin(_ block: LiveSourceBlock?, selection: NSRange? = nil, reveal: Bool = true) {
        guard !isRefreshing, let reader, let id = tabID, reader.selectedID == id else { return }
        if active?.blockID == block?.id, active != nil { return }
        if active != nil {
            let previous = active!
            finish()
            // The old snapshot may have shifted after an edit. Select by original
            // character position only after refreshing against the current source.
            let currentLength = reader.currentTab?.source.utf16.count ?? 0
            var location = block?.range.location ?? currentLength
            if let block, block.range.location >= NSMaxRange(previous.originalRange), let document {
                location += currentLength - document.source.utf16.count
            }
            pendingSelection = NSRange(location: max(0, min(currentLength, location)), length: 0)
            refresh()
            return
        }
        guard let source = reader.currentTab?.source,
              document.map({ sameSourceBytes($0.source, source) }) == true else {
            pendingSelection = NSRange(location: block?.range.location ?? 0, length: 0)
            refresh()
            return
        }
        let session = LiveEditSession(reader: reader, tabID: id, block: block, source: source, selection: selection)
        reader.recordSourceSelection(NSRange(location: session.origin + session.selection.location,
                                             length: session.selection.length), in: id)
        shouldReveal = reveal
        active = session
    }

    func finish() {
        active?.finish()
        active = nil
    }

    func fold() { finish(); refresh() }

    func navigate(_ entry: OutlineEntry) {
        finish()
        pendingNavigation = entry
        refresh()
    }

    func undo(_ request: SourceSelectionRequest?) {
        guard let request, let reader, request.tabID == reader.selectedID, reader.isLiveEditing else { return }
        if let active, active.reconcileUndo(source: reader.currentTab?.source ?? "", selection: request.range) { return }
        finish()
        pendingSelection = request.range
        refresh()
    }

    func leave() { finish(); task?.cancel(); task = nil; isRefreshing = false }
}

struct LiveDocumentContent: View, Equatable {
    @ObservedObject var controller: LiveEditingController
    let presentationID: UUID
    let fontSize: CGFloat
    let documentURL: URL?
    let reader: ReaderState

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.presentationID == rhs.presentationID && lhs.fontSize == rhs.fontSize && lhs.documentURL == rhs.documentURL
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if let document = controller.document {
                ForEach(document.blocks) { block in
                    Group {
                    if let active = controller.active, active.blockID == block.id {
                        LiveBlockEditor(session: active, reader: reader, fontSize: fontSize,
                                        documentURL: documentURL, onFold: { controller.fold() })
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(block.markup.enumerated()), id: \.offset) { index, node in
                                MarkdownBlockView(block: node, fontSize: fontSize, path: block.paths[index],
                                    mathTokens: document.tokens, documentURL: documentURL,
                                    onOpenImage: { reader.imagePreviewURL = $0 })
                            }
                        }
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded { controller.begin(block, reveal: false) })
                        .help("点击编辑这一段")
                        .allowsHitTesting(!controller.isRefreshing)
                    }
                    }
                    .id("document:\(block.path)")
                    .previewScrollAnchor(block.path)
                }
                if let active = controller.active, active.blockID == nil {
                    LiveBlockEditor(session: active, reader: reader, fontSize: fontSize,
                                    documentURL: documentURL, onFold: { controller.fold() })
                        .id("live-end")
                } else {
                    Button("继续写…") { controller.begin(nil) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .font(.system(size: 13)).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("live-end")
                }
            } else { ProgressView().frame(maxWidth: .infinity).padding(24) }
        }
        .environment(\.openURL, OpenURLAction { _ in .handled })
    }
}

private struct LiveBlockEditor: View {
    @ObservedObject var session: LiveEditSession
    let reader: ReaderState
    let fontSize: CGFloat
    let documentURL: URL?
    let onFold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("编辑当前段落").foregroundStyle(.secondary)
                Spacer()
                Button("完成") { onFold() }.buttonStyle(.plain).help("收起语法（Esc）")
            }.font(.system(size: 11))
            MarkdownSourceEditor(text: session.text, onChange: { _ in },
                onScrollView: { scroll in
                    session.editor = scroll.documentView as? NSTextView
                    session.editor?.identifier = NSUserInterfaceItemIdentifier("liveBlockEditor")
                    session.measure()
                }, onTextApplied: { session.measure() },
                onCompositionChanged: { session.composition($0) },
                documentUndoManager: reader.undoManager(for: session.tabID),
                onCommittedChange: { session.receive($0, selection: $1) },
                onSelectionChanged: { session.recordSelection($0) },
                selectionRequest: session.selectionRequest,
                initialSelection: session.selection,
                onCommand: { selector, view in
                    if selector == #selector(NSResponder.cancelOperation(_:)), !view.hasMarkedText() {
                        onFold(); return true
                    }
                    return false
                })
                .frame(height: session.height)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
            if let preview = session.preview, !session.text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview.blocks) { block in
                        ForEach(Array(block.markup.enumerated()), id: \.offset) { index, node in
                            MarkdownBlockView(block: node, fontSize: fontSize, path: "live-preview.\(block.id).\(index)",
                                mathTokens: preview.tokens, documentURL: documentURL,
                                onOpenImage: { reader.imagePreviewURL = $0 })
                        }
                    }
                }.padding(.top, 4)
            }
        }
        .id(session.id)
        .padding(8)
        .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}
