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
        editor.layoutManager?.allowsNonContiguousLayout = true
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
        var sourceY: CGFloat?
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
    private var recentPreviewFrames: [String: CGRect] = [:]
    private var previewContentWidth: CGFloat?
    private var sourceSpans: [String: SourceLineSpan] = [:]
    private var cachedSourceSize = CGSize.zero
    private var regions: [SourceRegion] = []
    private var regionsByPath: [String: SourceRegion] = [:]
    private(set) var isResizing = false
    var isActive = false

    func beginDividerResize() {
        guard !isResizing else { return }
        isResizing = true
    }

    func endDividerResize() {
        guard isResizing else { return }
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
        updateSpans(spans)
        rememberPreviewFrames(frames)
        previewFrames = frames
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
        recentPreviewFrames.removeAll()
        invalidateSource()
    }

    private func rememberPreviewFrames(_ frames: [String: CGRect]) {
        guard !frames.isEmpty else {
            recentPreviewFrames.removeAll()
            previewContentWidth = nil
            return
        }
        let roots = frames.filter { !$0.key.contains(".") }
        let width = roots.first?.value.width
        let viewportY = preview?.contentView.bounds.minY ?? 0
        let shared = roots.filter { previewFrames[$0.key] != nil }
        let widthChanged: Bool
        if let width, let previousWidth = previewContentWidth {
            widthChanged = abs(width - previousWidth) > 1
        } else { widthChanged = width != previewContentWidth }
        if widthChanged || shared.contains(where: {
            abs($0.value.height - (previewFrames[$0.key]?.height ?? 0)) > 0.5
        }) {
            recentPreviewFrames.removeAll()
            previewContentWidth = width
        } else if let nearest = shared.min(by: {
            abs($0.value.minY - viewportY) < abs($1.value.minY - viewportY)
        }), let previous = previewFrames[nearest.key] {
            let shift = nearest.value.minY - previous.minY
            if abs(shift) > 0.5 {
                recentPreviewFrames = recentPreviewFrames.mapValues { $0.offsetBy(dx: 0, dy: shift) }
            }
        } else if shared.isEmpty {
            recentPreviewFrames.removeAll()
        }
        recentPreviewFrames.merge(frames, uniquingKeysWith: { _, newest in newest })
        let margin = max(300, (preview?.contentView.bounds.height ?? 700) * 2)
        recentPreviewFrames = recentPreviewFrames.filter {
            $0.value.maxY >= viewportY - margin && $0.value.minY <= viewportY + margin
        }
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
        return Position(path: region.path, fraction: fraction, sourceY: y)
    }

    private func visibleMapping() -> [(source: CGFloat, preview: CGFloat)] {
        prepareSourceRegions()
        let frames = recentPreviewFrames.merging(previewFrames, uniquingKeysWith: { _, newest in newest })
        var containers = Set<String>()
        for path in frames.keys {
            var components = path.split(separator: ".")
            while components.count > 1 {
                components.removeLast()
                containers.insert(components.joined(separator: "."))
            }
        }
        var points: [(source: CGFloat, preview: CGFloat)] = []
        for (path, frame) in frames {
            guard let region = regionsByPath[path], frame.height > 0,
                  !containers.contains(path) else { continue }
            points.append((region.start, frame.minY))
            points.append((region.end, frame.maxY))
        }
        points.sort { $0.source == $1.source ? $0.preview < $1.preview : $0.source < $1.source }
        var unique: [(source: CGFloat, preview: CGFloat)] = []
        var index = 0
        while index < points.count {
            var end = index + 1
            while end < points.count && abs(points[end].source - points[index].source) < 0.01 { end += 1 }
            let point = (source: points[index].source,
                         preview: (points[index].preview + points[end - 1].preview) / 2)
            if let previous = unique.last {
                if point.preview > previous.preview { unique.append(point) }
            } else { unique.append(point) }
            index = end
        }
        return unique
    }

    private func interpolate(_ value: CGFloat, from points: [(CGFloat, CGFloat)]) -> CGFloat? {
        guard let first = points.first, let last = points.last else { return nil }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].0 <= value { low = middle } else { high = middle }
        }
        let left = points[low], right = points[high]
        let fraction = (value - left.0) / max(0.01, right.0 - left.0)
        return left.1 + fraction * (right.1 - left.1)
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
        if let frame = previewFrames[position.path] ?? recentPreviewFrames[position.path] {
            let target: CGFloat
            if position.atBottom {
                target = (preview.documentView?.frame.height ?? 0) - preview.contentView.bounds.height
            } else if let sourceY = position.sourceY,
                      let mapped = interpolate(sourceY, from: visibleMapping().map { ($0.source, $0.preview) }) {
                target = mapped
            } else { target = frame.minY + position.fraction * frame.height }
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
            guard let target = interpolate(y, from: visibleMapping().map { ($0.preview, $0.source) }) else { return }
            scroll(source, to: target)
        }
    }
}
