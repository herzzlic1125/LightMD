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

private final class SplitHandleView: NSView {
    var ratio: CGFloat = 0.4
    var availableWidth: CGFloat = 1
    var minimumRatio: CGFloat = 0
    var maximumRatio: CGFloat = 1
    var active = false
    var onDragStarted: (() -> Void)?
    var onRatioChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartX: CGFloat?
    private var dragStartRatio: CGFloat = 0.4
    private var resizeTrackingArea: NSTrackingArea?

    override func resetCursorRects() {
        if active { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeTrackingArea { removeTrackingArea(resizeTrackingArea) }
        resizeTrackingArea = nil
        guard active else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate,
                                            .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        resizeTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { if active { NSCursor.resizeLeftRight.set() } }
    override func mouseEntered(with event: NSEvent) { if active { NSCursor.resizeLeftRight.set() } }
    override func mouseMoved(with event: NSEvent) { if active { NSCursor.resizeLeftRight.set() } }
    override func mouseExited(with event: NSEvent) {
        if dragStartX == nil { NSCursor.arrow.set() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard active else { return }
        dragStartX = event.locationInWindow.x
        dragStartRatio = ratio
        onDragStarted?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard active, let dragStartX else { return }
        NSCursor.resizeLeftRight.set()
        let next = min(max(dragStartRatio + (event.locationInWindow.x - dragStartX)
                           / max(1, availableWidth), minimumRatio), maximumRatio)
        if abs(next - ratio) >= 0.0005 { onRatioChanged?(next) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        onDragEnded?()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, dragStartX != nil {
            dragStartX = nil
            onDragEnded?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        onDragEnded?()
        NSCursor.arrow.set()
    }
}

struct SplitHandle: NSViewRepresentable {
    let ratio: CGFloat
    let availableWidth: CGFloat
    let minimumRatio: CGFloat
    let maximumRatio: CGFloat
    let active: Bool
    let onDragStarted: () -> Void
    let onRatioChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = SplitHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SplitHandleView else { return }
        configure(view)
    }

    private func configure(_ view: SplitHandleView) {
        let cursorChanged = view.active != active
        view.ratio = ratio
        view.availableWidth = availableWidth
        view.minimumRatio = minimumRatio
        view.maximumRatio = maximumRatio
        view.active = active
        view.onDragStarted = onDragStarted
        view.onRatioChanged = onRatioChanged
        view.onDragEnded = onDragEnded
        if cursorChanged {
            view.updateTrackingAreas()
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

struct SourceLineSpan: Equatable {
    let start: Int
    let end: Int
}

@MainActor
final class ScrollSyncController {
    private enum Side { case source, preview }
    private struct Position {
        let path: String
        let fraction: CGFloat
        var atBottom = false
        var root: String { String(path.split(separator: ".").first ?? "0") }
    }
    private struct SourceRegion {
        let path: String
        let start: CGFloat
        let end: CGFloat
    }

    private weak var source: NSScrollView?
    private weak var preview: NSScrollView?
    private var sourceObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?
    private var revealPreview: ((String) -> Void)?
    private var pendingSide: Side?
    private var updateScheduled = false
    private var generation: UInt64 = 0
    private var pendingPosition: Position?
    private var pendingPreviewIntent = false
    private var savedPreviewPosition: Position?
    private var requestedRoot: String?
    private var previewFrames: [String: CGRect] = [:]
    private var sourceSpans: [String: SourceLineSpan] = [:]
    private var cachedSourceSize = CGSize.zero
    private var regions: [SourceRegion] = []
    private var regionsByPath: [String: SourceRegion] = [:]
    private(set) var isResizing = false
    private weak var resizingEditor: NSTextView?
    private var previousWidthTracking = true
    var isActive = false

    func beginDividerResize() {
        guard !isResizing else { return }
        isResizing = true
        resizingEditor = source?.documentView as? NSTextView
        previousWidthTracking = resizingEditor?.textContainer?.widthTracksTextView ?? true
        resizingEditor?.textContainer?.widthTracksTextView = false
    }

    func endDividerResize() {
        guard isResizing else { return }
        if let editor = resizingEditor, let container = editor.textContainer {
            container.widthTracksTextView = previousWidthTracking
            if previousWidthTracking {
                container.containerSize.width = max(1, editor.bounds.width - editor.textContainerInset.width * 2)
            }
        }
        resizingEditor = nil
        invalidateSource()
        isResizing = false
    }

    deinit {
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
    }

    func attachSource(_ scroll: NSScrollView) {
        guard source !== scroll else { return }
        endDividerResize()
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        source = scroll
        invalidateSource()
        sourceObserver = observe(scroll, side: .source)
    }

    func attachPreview(_ scroll: NSScrollView, reveal: @escaping (String) -> Void) {
        revealPreview = reveal
        guard preview !== scroll else { return }
        if let previewObserver { NotificationCenter.default.removeObserver(previewObserver) }
        preview = scroll
        previewObserver = observe(scroll, side: .preview)
    }

    func detachSource() {
        endDividerResize()
        if let sourceObserver { NotificationCenter.default.removeObserver(sourceObserver) }
        sourceObserver = nil
        source = nil
        cancelPending()
    }

    private func observe(_ scroll: NSScrollView, side: Side) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                               object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(side) }
        }
    }

    func updateAnchors(_ frames: [String: CGRect], spans: [String: SourceLineSpan]) {
        previewFrames = frames
        updateSpans(spans)
        guard pendingPosition != nil else { return }
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.applyPendingPosition()
        }
    }

    func updateSpans(_ spans: [String: SourceLineSpan]) {
        guard sourceSpans != spans else { return }
        sourceSpans = spans
        invalidateSource()
    }

    func invalidateSource() {
        cachedSourceSize = .zero
        regions.removeAll(keepingCapacity: true)
        regionsByPath.removeAll(keepingCapacity: true)
    }

    private func cancelPending() {
        generation &+= 1
        pendingSide = nil
        pendingPosition = nil
        pendingPreviewIntent = false
        requestedRoot = nil
    }

    private func schedule(_ side: Side) {
        generation &+= 1
        if side == .preview {
            pendingPosition = nil
            pendingPreviewIntent = false
            requestedRoot = nil
        }
        guard isActive, !isResizing else { return }
        if side == .source { pendingPreviewIntent = false }
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

    func beginPreviewNavigation() -> UInt64 {
        cancelPending()
        return generation
    }

    func completePreviewNavigation(_ ticket: UInt64) {
        guard generation == ticket else { return }
        synchronize(from: .preview)
    }

    func navigatePreview(to path: String) {
        cancelPending()
        pendingPosition = Position(path: path, fraction: 0)
        pendingPreviewIntent = true
        applyPendingPosition()
    }

    func alignSourceToPreview() {
        cancelPending()
        synchronize(from: .preview)
    }

    func alignPreviewToSource() {
        cancelPending()
        synchronize(from: .source)
    }

    func capturePreviewPosition() {
        guard let preview else { savedPreviewPosition = nil; return }
        savedPreviewPosition = previewPosition(at: preview.contentView.bounds.origin.y)
    }

    @discardableResult
    func restorePreviewPosition() -> Bool {
        guard let savedPreviewPosition else { return false }
        cancelPending()
        pendingPosition = savedPreviewPosition
        pendingPreviewIntent = true
        self.savedPreviewPosition = nil
        applyPendingPosition()
        return true
    }

    private func prepareSourceRegions() {
        guard let editor = source?.documentView as? NSTextView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        guard cachedSourceSize != editor.frame.size || regions.isEmpty else { return }
        layout.ensureLayout(for: container)
        let content = editor.string as NSString
        let requested = Set(sourceSpans.values.flatMap { [$0.start, $0.end] })
        var positions: [Int: CGFloat] = [:]
        var offset = 0, line = 1
        while offset < content.length && positions.count < requested.count {
            if requested.contains(line) {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                positions[line] = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + editor.textContainerOrigin.y
            }
            var end = 0
            content.getLineStart(nil, end: &end, contentsEnd: nil,
                                 for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            offset = end
            line += 1
        }
        let textBottom = layout.usedRect(for: container).maxY + editor.textContainerOrigin.y
        for missing in requested where positions[missing] == nil { positions[missing] = textBottom }
        regions = sourceSpans.compactMap { path, span in
            guard let start = positions[span.start], let end = positions[span.end] else { return nil }
            return SourceRegion(path: path, start: start, end: max(start + 1, end))
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.path.split(separator: ".").count < $1.path.split(separator: ".").count
        }
        regionsByPath = Dictionary(uniqueKeysWithValues: regions.map { ($0.path, $0) })
        cachedSourceSize = editor.frame.size
    }

    private func sourcePosition(at y: CGFloat) -> Position? {
        prepareSourceRegions()
        guard !regions.isEmpty else { return nil }
        var low = 0, high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].start <= y { low = middle + 1 } else { high = middle }
        }
        let region = regions[max(0, low - 1)]
        let fraction = min(1, max(0, (y - region.start) / (region.end - region.start)))
        return Position(path: region.path, fraction: fraction)
    }

    private func previewPosition(at y: CGFloat) -> Position? {
        let candidates = previewFrames.filter { sourceSpans[$0.key] != nil && $0.value.height > 0 }
        let nearest = candidates.min { left, right in
            func distance(_ rect: CGRect) -> CGFloat { max(0, max(rect.minY - y, y - rect.maxY)) }
            let leftDistance = distance(left.value), rightDistance = distance(right.value)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            let leftDepth = left.key.split(separator: ".").count
            let rightDepth = right.key.split(separator: ".").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return left.value.height < right.value.height
        }
        guard let nearest else { return nil }
        return Position(path: nearest.key,
                        fraction: min(1, max(0, (y - nearest.value.minY) / nearest.value.height)))
    }

    private func scroll(_ view: NSScrollView, to y: CGFloat) {
        guard let document = view.documentView else { return }
        let maximum = max(0, document.frame.height - view.contentView.bounds.height)
        let target = min(maximum, max(0, y))
        guard abs(view.contentView.bounds.origin.y - target) >= 0.5 else { return }
        view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.origin.x, y: target))
        view.reflectScrolledClipView(view.contentView)
    }

    private func applyPendingPosition() {
        guard (isActive || pendingPreviewIntent), !isResizing,
              let position = pendingPosition, let preview else { return }
        if let frame = previewFrames[position.path] {
            let target = position.atBottom
                ? (preview.documentView?.frame.height ?? 0) - preview.contentView.bounds.height
                : frame.minY + position.fraction * frame.height
            scroll(preview, to: target)
            requestedRoot = nil
            if pendingPreviewIntent && isActive { synchronize(from: .preview) }
        } else if requestedRoot != position.root {
            requestedRoot = position.root
            revealPreview?(position.root)
        }
    }

    private func synchronize(from side: Side) {
        guard isActive, !isResizing, let source, let preview else { return }
        if side == .source {
            let y = source.contentView.bounds.origin.y
            if y <= 0.5 {
                pendingPosition = nil
                requestedRoot = nil
                scroll(preview, to: 0)
                return
            }
            let maximum = max(0, (source.documentView?.frame.height ?? 0) - source.contentView.bounds.height)
            if maximum > 0 && y >= maximum - 0.5 {
                prepareSourceRegions()
                if let last = regions.last {
                    pendingPosition = Position(path: last.path, fraction: 1, atBottom: true)
                }
            } else { pendingPosition = sourcePosition(at: y) }
            applyPendingPosition()
        } else {
            let y = preview.contentView.bounds.origin.y
            if y <= 0.5 { scroll(source, to: 0); return }
            let maximum = max(0, (preview.documentView?.frame.height ?? 0) - preview.contentView.bounds.height)
            if maximum > 0 && y >= maximum - 0.5 {
                scroll(source, to: (source.documentView?.frame.height ?? 0) - source.contentView.bounds.height)
                return
            }
            guard let position = previewPosition(at: y) else { return }
            prepareSourceRegions()
            guard let region = regionsByPath[position.path] else { return }
            scroll(source, to: region.start + position.fraction * (region.end - region.start))
        }
    }
}
