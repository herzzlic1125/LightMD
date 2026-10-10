import AppKit
import SwiftUI

// Native layout timings, not a display FPS measurement. No visible window or browser.
@MainActor enum ScrollMetrics {
    static var bodies = 0
    static var renders = 0
}

@main @MainActor struct ScrollChecks {
    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews($0) }
    }

    static func outlineHandle(_ view: NSView) -> NSView? {
        if view.identifier?.rawValue == "outlineResizeHandle" { return view }
        return view.subviews.lazy.compactMap { outlineHandle($0) }.first
    }

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let before = try Data(contentsOf: file)
        let state = ReaderState(sessionStore: SessionStore(url:
            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("isolated-session.json")))
        state.open(file)
        print("tokens=\(state.currentMathTokens.count) unique=\(Set(state.currentMathTokens.values.map { "\($0.display):\($0.formula)" }).count)")
        let host = NSHostingView(rootView: ReaderView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.4)
        guard let scroll = scrollViews(host).max(by: {
            $0.contentView.bounds.width * $0.contentView.bounds.height < $1.contentView.bounds.width * $1.contentView.bounds.height
        }) else { fatalError("No preview scroll view") }
        for pass in 0..<3 {
            let bodyStart = ScrollMetrics.bodies, renderStart = ScrollMetrics.renders
            var times: [Double] = []
            for step in 0..<120 {
                let start = CFAbsoluteTimeGetCurrent()
                let fraction = step < 60 ? Double(step) / 59 : Double(119 - step) / 59
                let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                host.layoutSubtreeIfNeeded()
                pump(1.0 / 60)
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let sorted = times.sorted()
            print(String(format: "pass=%d avg_ms=%.2f p95_ms=%.2f max_ms=%.2f over33ms=%d bodies=%d renders=%d height=%.0f",
                         pass, times.reduce(0,+) / Double(times.count), sorted[Int(Double(sorted.count) * 0.95)], sorted.last!,
                         times.filter { $0 > 33.3 }.count, ScrollMetrics.bodies - bodyStart,
                         ScrollMetrics.renders - renderStart, scroll.documentView?.frame.height ?? 0))
            pump(0.8)
        }
        var images = 0, failures = 0, pending = 0
        for token in state.currentMathTokens.values {
            switch state.formulas.result(for: token, fontSize: state.fontSize * (token.display ? 1.12 : 1), displayScale: 2) {
            case .image: images += 1
            case .failure: failures += 1
            case .pending: pending += 1
            }
        }
        print("retained_tokens images=\(images) failures=\(failures) pending=\(pending)")
        precondition(pending == 0, "Prefetched document did not stay cached")
        state.showsOutline = true
        pump(0.4)
        for fraction in [0.0, 0.5, 1.0] {
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
            host.layoutSubtreeIfNeeded(); pump(0.1)
            let grip = outlineHandle(host)!
            let start = grip.convert(CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            grip.mouseDown(with: event(.leftMouseDown, start))
            let dragStart = CFAbsoluteTimeGetCurrent()
            for step in 0..<30 {
                let delta = CGFloat(step < 15 ? step : 29 - step) * -12
                grip.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: start.x + delta, y: start.y)))
                host.layoutSubtreeIfNeeded(); pump(1.0 / 60)
            }
            grip.mouseUp(with: event(.leftMouseUp, start))
            print(String(format: "outline_drag_at=%.1f avg_ms=%.2f", fraction,
                         (CFAbsoluteTimeGetCurrent() - dragStart) * 1000 / 30))
            for step in 0..<10 {
                let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maximum, max(0,
                    scroll.contentView.bounds.minY + (step < 5 ? -60 : 60)))))
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                host.layoutSubtreeIfNeeded(); pump(1.0 / 60)
            }
        }
        state.isEditing = true
        pump(0.6)
        for fraction in [0.0, 0.5, 1.0] {
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
            host.layoutSubtreeIfNeeded(); pump(0.1)
            let start = CFAbsoluteTimeGetCurrent()
            for step in 0..<30 {
                window.setContentSize(CGSize(width: 1000 + (step % 15) * 15, height: 850))
                host.layoutSubtreeIfNeeded(); pump(1.0 / 60)
            }
            print(String(format: "resize_at=%.1f avg_ms=%.2f", fraction,
                         (CFAbsoluteTimeGetCurrent() - start) * 1000 / 30))
            let name = Notification.Name("scroll-check-divider")
            NotificationCenter.default.post(name: name, object: nil, userInfo: ["start": true])
            let dragStart = CFAbsoluteTimeGetCurrent()
            for step in 0..<30 {
                NotificationCenter.default.post(name: name, object: nil,
                    userInfo: ["ratio": CGFloat(0.3 + Double(step % 15) * 0.02)])
                host.layoutSubtreeIfNeeded(); pump(1.0 / 60)
            }
            NotificationCenter.default.post(name: name, object: nil)
            print(String(format: "divider_at=%.1f avg_ms=%.2f", fraction,
                         (CFAbsoluteTimeGetCurrent() - dragStart) * 1000 / 30))
            for step in 0..<10 {
                let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                let position = min(maximum, max(0, scroll.contentView.bounds.minY + (step < 5 ? -60 : 60)))
                scroll.contentView.scroll(to: CGPoint(x: 0, y: position))
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                host.layoutSubtreeIfNeeded(); pump(1.0 / 60)
            }
        }
        precondition(try! Data(contentsOf: file) == before)
        precondition(!window.isVisible)
        window.contentView = nil
        window.close()
        print("source_unchanged_and_offscreen=passed")
    }
}
