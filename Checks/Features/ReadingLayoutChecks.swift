import AppKit
import SwiftUI

@MainActor struct ReadingLayoutChecks {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func pump(_ host: NSView, _ seconds: Double = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < end
    }

    static func run() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("layout.md")
        let source = (0..<100).map { "## Heading \($0) with a longer title\n\n" + String(repeating: "Reading layout text. ", count: 20) + "\n\n" }.joined()
        try source.write(to: file, atomically: true, encoding: .utf8)
        let state = ReaderState(sessionStore: SessionStore(url: dir.appendingPathComponent("session.json")))
        state.open(file)
        state.showsOutline = true
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        pump(host)
        func reading() -> NSScrollView {
            descendants(host).first { $0.identifier?.rawValue == "readingPreviewScroll" } as! NSScrollView
        }
        func handle() -> NSView {
            descendants(host).first { $0.identifier?.rawValue == "outlineResizeHandle" }!
        }
        func checkSeparation() {
            let scroll = reading(), grip = handle()
            let viewport = scroll.convert(scroll.bounds, to: host)
            let edge = grip.convert(grip.bounds, to: host)
            print("layout_geometry viewport=\(viewport) handle=\(edge) scroller=\(scroll.hasVerticalScroller) hidden=\(scroll.verticalScroller?.isHidden ?? true)")
            precondition(scroll.hasVerticalScroller && scroll.verticalScroller != nil)
            precondition(scroll.verticalScroller?.isHidden == false)
            precondition(viewport.maxX <= edge.minX + 1, "Outline covers the reading scrollbar")
            precondition(viewport.width > 150)
        }
        func drag(_ delta: CGFloat) {
            let grip = handle()
            let start = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            grip.mouseDown(with: event(.leftMouseDown, start))
            let end = CGPoint(x: start.x + delta, y: start.y)
            grip.mouseDragged(with: event(.leftMouseDragged, end))
            pump(host, 0.06)
            grip.mouseUp(with: event(.leftMouseUp, end))
            pump(host, 0.15)
        }
        checkSeparation()
        precondition(abs(reading().frame.width - 779) < 2)
        // Real native mouse handlers, with no visible window or browser.
        for fraction in [0.0, 0.5, 1.0] {
            let scroll = reading()
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
            pump(host, 0.06)
            drag(-900)
            checkSeparation()
            precondition(abs(reading().frame.width - 580) < 2)
            drag(900)
            checkSeparation()
            precondition(abs(reading().frame.width - 840) < 2)
        }
        drag(-140)
        precondition(abs(reading().frame.width - 700) < 2)
        state.showsOutline = false
        pump(host)
        precondition(abs(reading().frame.width - 1000) < 2)
        state.showsOutline = true
        pump(host)
        checkSeparation()
        precondition(abs(reading().frame.width - 700) < 2, "Reopening outline lost its width")
        state.isEditing = true
        pump(host, 0.6)
        precondition(!state.showsOutline)
        precondition(reading().hasVerticalScroller)
        state.showsOutline = true
        pump(host)
        checkSeparation()
        drag(-900)
        checkSeparation()
        let editingWidth = reading().frame.width
        drag(900)
        checkSeparation()
        precondition(reading().frame.width > editingWidth)
        state.isEditing = false
        pump(host, 0.6)
        checkSeparation()
        window.setContentSize(CGSize(width: 680, height: 700))
        pump(host)
        drag(-900)
        checkSeparation()
        precondition(abs(reading().frame.width - 306) < 2)
        // The handle shares the native source divider's cancellation behavior.
        let grip = handle()
        let point = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     eventNumber: 1, clickCount: 1, pressure: 1)!
        grip.mouseDown(with: down)
        grip.cancelOperation(nil)
        precondition(abs(OutlineLayout.width(1000, in: 680) - 374) < 0.001)
        precondition(OutlineLayout.width(10, in: 680) == 160)
        print("reading_scroller_uncovered_native_outline_drag_limits_reopen_editing_resize_cancel=passed")
        precondition(!window.isVisible)
        precondition(try! String(contentsOf: file, encoding: .utf8) == source)
    }
}
