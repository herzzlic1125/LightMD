import AppKit
import SwiftUI
import Foundation

private final class ActiveWindowButtons: NSView {
    weak var sourceWindow: NSWindow?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let sourceWindow else { return }
        let buttons: [(NSWindow.ButtonType, NSColor)] = [
            (.closeButton, NSColor(calibratedRed: 1, green: 0.37, blue: 0.34, alpha: 1)),
            (.miniaturizeButton, NSColor(calibratedRed: 1, green: 0.74, blue: 0.18, alpha: 1)),
            (.zoomButton, NSColor(calibratedRed: 0.20, green: 0.79, blue: 0.27, alpha: 1))
        ]
        for (kind, color) in buttons {
            guard let button = sourceWindow.standardWindowButton(kind) else { continue }
            let frame = convert(button.bounds, from: button).insetBy(dx: 1, dy: 1)
            NSColor.black.withAlphaComponent(0.14).setStroke()
            color.setFill()
            let circle = NSBezierPath(ovalIn: frame)
            circle.lineWidth = 0.7
            circle.fill()
            circle.stroke()
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@main @MainActor struct CaptureReading {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let sample = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let expectedFormulaCount = Int(CommandLine.arguments[3])!
        let contentHeight = CGFloat(Double(CommandLine.arguments[4])!)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LightMD-Readme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try String(contentsOf: sample, encoding: .utf8)
        let state = ReaderState(sessionStore: SessionStore(url: temporary.appendingPathComponent("session.json")))
        state.updateSource(source, in: state.selectedID)
        state.fontSize = 20
        state.isEditing = true
        // Use a generic display path. This sample never reads or writes a personal document.
        let displayName = sample.lastPathComponent.contains("reading-zh-")
            ? "阅读示例.md" : "Reading.md"
        state.tabs[0].url = URL(fileURLWithPath: "/Users/example/Documents/\(displayName)")
        state.tabs[0].savedSource = source
        setbuf(stdout, nil)
        let host = NSHostingView(rootView: ReaderView(state: state).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: contentHeight),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        let toolbar = NSToolbar(identifier: "LightMDDocumentationToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            if state.currentDocument != nil && state.currentMathTokens.count == expectedFormulaCount
                && state.formulas.revision >= expectedFormulaCount { break }
        }
        print("Formula tokens=\(state.currentMathTokens.count), rendered=\(state.formulas.revision)")
        precondition(state.currentDocument != nil && state.currentMathTokens.count == expectedFormulaCount
            && state.formulas.revision >= expectedFormulaCount, "Preview did not finish rendering")
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
        // Capture the native document region from the composited frame view.
        // The titlebar accessory sits outside this region in an offscreen window.
        let view = window.contentView!.superview!
        // An offscreen NSWindow does not settle titlebar accessories like a key
        // window does. Align its native title and accessory views with the
        // native close button before capturing; nothing is ordered front.
        if let title = view.subviews.first(where: { $0.identifier?.rawValue == "LightMDCenteredTitle" }),
           let close = window.standardWindowButton(.closeButton) {
            title.removeFromSuperview()
            title.translatesAutoresizingMaskIntoConstraints = true
            title.frame.origin = NSPoint(x: (view.bounds.width - title.frame.width) / 2,
                                         y: close.frame.midY - title.frame.height / 2)
            view.addSubview(title, positioned: .above, relativeTo: nil)
        }
        // SwiftUI's titlebar accessory is clipped by an unshown NSWindow.
        // Mount the same production control view in the frame for this image.
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        let controls = NSHostingView(rootView: ChromeCapsuleControls(isEditing: true,
            showsOutline: false, isExporting: false,
            onMode: {}, onOutline: {}, onExport: {}))
        let titleY = window.standardWindowButton(.closeButton)?.frame.midY ?? (view.bounds.height - 16)
        controls.frame = NSRect(x: view.bounds.width - 110, y: titleY - 13,
                                width: 102, height: 26)
        view.addSubview(controls, positioned: .above, relativeTo: nil)
        controls.layoutSubtreeIfNeeded()
        // Hidden windows receive inactive gray system button colors. Render the
        // standard buttons in their active colors at their native frame locations
        // for the documentation image, without activating this test process.
        let buttons = ActiveWindowButtons(frame: view.bounds)
        buttons.sourceWindow = window
        view.addSubview(buttons, positioned: .above, relativeTo: nil)
        let bounds = view.bounds
        let scale: CGFloat = 2
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: output, options: .atomic)
        precondition(!window.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        print("Native reader capture: \(bitmap.pixelsWide) × \(bitmap.pixelsHigh), 20 pt, \(expectedFormulaCount) rendered formulas; no visible window")
    }
}
