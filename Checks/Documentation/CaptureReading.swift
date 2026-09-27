import AppKit
import SwiftUI
import Foundation

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
        // Use a generic display path. This sample never reads or writes a personal document.
        state.tabs[0].url = URL(fileURLWithPath: "/Users/example/Documents/Reading.md")
        state.tabs[0].savedSource = source
        setbuf(stdout, nil)
        let host = NSHostingView(rootView: ReaderView(state: state).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: contentHeight),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
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
        let bounds = NSRect(x: 0, y: 80, width: view.bounds.width,
                            height: view.bounds.height - 176)
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
