import AppKit
import SwiftUI

private struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 34, height: 26)
            .background(configuration.isPressed ? Color.primary.opacity(0.10) : .clear)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct ChromeCapsuleControls: View {
    let isEditing: Bool
    let showsOutline: Bool
    let isExporting: Bool
    let onMode: () -> Void
    let onOutline: () -> Void
    let onExport: () -> Void
    let onNewFile: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onExport) {
                Group {
                    if isExporting { ProgressView().controlSize(.small) }
                    else { Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .regular)) }
                }
                .foregroundStyle(.primary)
            }
            .disabled(isExporting)
            .help(isExporting ? "正在导出 PDF…" : "导出 PDF")
            .accessibilityLabel(isExporting ? "正在导出 PDF" : "导出 PDF")

            Button(action: onMode) {
                Image(systemName: isEditing ? "book" : "square.split.2x1")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .help(isEditing ? "切换到阅读模式" : "切换到双栏编辑模式")
            .accessibilityLabel(isEditing ? "切换到阅读模式" : "切换到双栏编辑模式")

            Button(action: onOutline) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .help(showsOutline ? "隐藏右侧目录" : "显示右侧目录")
            .accessibilityLabel(showsOutline ? "隐藏右侧目录" : "显示右侧目录")

            Button(action: onNewFile) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .help("新建文件… (⌘N)")
            .accessibilityLabel("新建文件")
        }
        .buttonStyle(CapsuleButtonStyle())
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.7))
        .clipShape(Capsule())
    }
}

private final class WindowChromeView: NSView {
    var title = "未命名"
    var isEditing = false
    var showsOutline = true
    var isExporting = false
    var onMode: (() -> Void)?
    var onOutline: (() -> Void)?
    var onExport: (() -> Void)?
    var onNewFile: (() -> Void)?

    private weak var installedWindow: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private var controls: NSHostingView<ChromeCapsuleControls>?
    private var titleLabel: NSTextField?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        reconcileWindow()
        guard let window else { return }
        window.title = title
        window.titleVisibility = .hidden
        titleLabel?.stringValue = title
        controls?.rootView = makeControls()
    }

    private func reconcileWindow() {
        if installedWindow !== window {
            detach()
            if let window { install(in: window) }
        }
        if let window, let frameView = window.contentView?.superview,
           titleLabel?.superview !== frameView {
            titleLabel?.removeFromSuperview()
            addCenteredTitle(to: frameView, window: window)
        }
    }

    private func install(in window: NSWindow) {
        installedWindow = window
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 146, height: 28))
        let hosting = NSHostingView(rootView: makeControls())
        hosting.frame = NSRect(x: 4, y: 1, width: 136, height: 26)
        container.addSubview(hosting)
        controls = hosting

        let controller = NSTitlebarAccessoryViewController()
        controller.layoutAttribute = .right
        controller.view = container
        window.addTitlebarAccessoryViewController(controller)
        accessory = controller
        if let frameView = window.contentView?.superview {
            addCenteredTitle(to: frameView, window: window)
        }
    }

    private func addCenteredTitle(to frameView: NSView, window: NSWindow) {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier("LightMDCenteredTitle")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(label, positioned: .above, relativeTo: nil)
        var constraints = [
            label.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            label.widthAnchor.constraint(lessThanOrEqualTo: frameView.widthAnchor, multiplier: 0.45)
        ]
        if let closeButton = window.standardWindowButton(.closeButton) {
            constraints.append(label.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor))
        } else {
            constraints.append(label.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 14))
        }
        NSLayoutConstraint.activate(constraints)
        titleLabel = label
    }

    private func makeControls() -> ChromeCapsuleControls {
        ChromeCapsuleControls(isEditing: isEditing, showsOutline: showsOutline, isExporting: isExporting,
                              onMode: { [weak self] in self?.onMode?() },
                              onOutline: { [weak self] in self?.onOutline?() },
                              onExport: { [weak self] in self?.onExport?() },
                              onNewFile: { [weak self] in self?.onNewFile?() })
    }

    func detach() {
        titleLabel?.removeFromSuperview()
        titleLabel = nil
        if let installedWindow, let accessory,
           let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            installedWindow.removeTitlebarAccessoryViewController(at: index)
        }
        accessory = nil
        controls = nil
        installedWindow = nil
    }
}

struct WindowChrome: NSViewRepresentable {
    let title: String
    let isEditing: Bool
    let showsOutline: Bool
    let isExporting: Bool
    let onMode: () -> Void
    let onOutline: () -> Void
    let onExport: () -> Void
    let onNewFile: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowChromeView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowChromeView else { return }
        configure(view)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? WindowChromeView)?.detach()
    }

    private func configure(_ view: WindowChromeView) {
        view.title = title
        view.isEditing = isEditing
        view.showsOutline = showsOutline
        view.isExporting = isExporting
        view.onMode = onMode
        view.onOutline = onOutline
        view.onExport = onExport
        view.onNewFile = onNewFile
        view.refresh()
    }
}
