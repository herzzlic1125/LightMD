import AppKit
import SwiftUI

struct MarkdownSourceEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onScrollView: (NSScrollView) -> Void
    let onTextApplied: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        var applyingExternalText = false

        init(_ parent: MarkdownSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applyingExternalText, let view = notification.object as? NSTextView else { return }
            parent.onChange(view.string)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0,
                                                    height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        scroll.documentView = editor
        DispatchQueue.main.async { onScrollView(scroll) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if !sameSourceBytes(editor.string, text) && !editor.hasMarkedText() {
            context.coordinator.applyingExternalText = true
            editor.string = text
            editor.undoManager?.removeAllActions()
            context.coordinator.applyingExternalText = false
            onTextApplied()
        }
        onScrollView(scroll)
    }
}

@MainActor
final class ScrollSyncController {
    private enum Side { case source, preview }
    private weak var source: NSScrollView?
    private weak var preview: NSScrollView?
    private var sourceObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?
    private var pendingSide: Side?
    private var updateScheduled = false
    private var applying = false
    private var previewAnchors: [String: CGFloat] = [:]
    private var sourceLines: [String: Int] = [:]
    private var cachedSourceSize = CGSize.zero
    private var cachedLinePositions: [Int: CGFloat] = [:]
    var isActive = false

    deinit {
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
    }

    func attachSource(_ scroll: NSScrollView) {
        guard source !== scroll else { return }
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        source = scroll
        cachedSourceSize = .zero
        sourceObserver = observe(scroll, side: .source)
    }

    func attachPreview(_ scroll: NSScrollView) {
        guard preview !== scroll else { return }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        preview = scroll
        previewObserver = observe(scroll, side: .preview)
    }

    func detachSource() {
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        sourceObserver = nil
        source = nil
        pendingSide = nil
    }

    private func observe(_ scroll: NSScrollView, side: Side) -> NSObjectProtocol {
        scroll.contentView.postsBoundsChangedNotifications = true
        return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedule(side) }
        }
    }

    func updateAnchors(_ anchors: [String: CGFloat], lines: [String: Int]) {
        previewAnchors = anchors
        sourceLines = lines
        cachedLinePositions.removeAll()
    }

    func updateLines(_ lines: [String: Int]) {
        sourceLines = lines
        cachedLinePositions.removeAll()
    }

    func invalidateSource() {
        cachedSourceSize = .zero
        cachedLinePositions.removeAll()
    }

    private func schedule(_ side: Side) {
        guard isActive else { return }
        pendingSide = side
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard let side = self.pendingSide else { return }
            self.pendingSide = nil
            self.synchronize(from: side)
        }
    }

    func alignSourceToPreview() { synchronize(from: .preview) }
    func alignPreviewToSource() { synchronize(from: .source) }

    private func sourcePositions(in editor: NSTextView) -> [Int: CGFloat] {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return [:] }
        let content = editor.string as NSString
        let size = editor.frame.size
        if cachedSourceSize == size && !cachedLinePositions.isEmpty {
            return cachedLinePositions
        }
        cachedSourceSize = size
        layout.ensureLayout(for: container)
        let requested = Set(sourceLines.values)
        var positions: [Int: CGFloat] = [:]
        var offset = 0
        var line = 1
        while offset < content.length && positions.count < requested.count {
            if requested.contains(line) {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                positions[line] = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + editor.textContainerOrigin.y
            }
            var start = 0, end = 0, contentsEnd = 0
            content.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                 for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            offset = end
            line += 1
        }
        cachedLinePositions = positions
        return positions
    }

    private func mappedPosition(_ position: CGFloat, from points: [(CGFloat, CGFloat)]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        if position <= first.0 { return first.1 }
        if position >= last.0 { return last.1 }
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].0 <= position { low = middle } else { high = middle }
        }
        let left = points[low], right = points[high]
        let fraction = (position - left.0) / max(1, right.0 - left.0)
        return left.1 + fraction * (right.1 - left.1)
    }

    private func synchronize(from side: Side) {
        guard isActive, !applying, let source, let preview else { return }
        let origin = side == .source ? source : preview
        let destination = side == .source ? preview : source
        guard let destinationDocument = destination.documentView,
              let editor = source.documentView as? NSTextView,
              let previewDocument = preview.documentView else { return }

        let destinationMaximum = max(0, destinationDocument.frame.height - destination.contentView.bounds.height)
        let sourceHeight = editor.frame.height
        let previewHeight = previewDocument.frame.height
        let positions = sourcePositions(in: editor)
        var anchors = sourceLines.compactMap { path, line -> (CGFloat, CGFloat)? in
            guard let sourceY = positions[line], let previewY = previewAnchors[path] else { return nil }
            return (sourceY, previewY)
        }.sorted { $0.0 < $1.0 }
        anchors.insert((0, 0), at: 0)
        anchors.append((sourceHeight, previewHeight))
        var ordered: [(CGFloat, CGFloat)] = []
        for point in anchors where point.0.isFinite && point.1.isFinite {
            guard let previous = ordered.last else { ordered.append(point); continue }
            if point.0 > previous.0 && point.1 >= previous.1 { ordered.append(point) }
        }
        let mapping = side == .source ? ordered : ordered.map { ($0.1, $0.0) }
        let mapped = mappedPosition(origin.contentView.bounds.origin.y, from: mapping)
        let targetY = min(destinationMaximum, max(0, mapped))
        guard abs(destination.contentView.bounds.origin.y - targetY) >= 1 else { return }
        applying = true
        destination.contentView.scroll(to: NSPoint(x: destination.contentView.bounds.origin.x,
                                                   y: targetY))
        destination.reflectScrolledClipView(destination.contentView)
        applying = false
    }
}
