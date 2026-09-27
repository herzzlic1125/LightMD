import AppKit
import WebKit

/// A rendering surface owned by a job. It is never ordered front or made key.
@MainActor
final class OffscreenWebPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var printCompletion: CheckedContinuation<Void, Error>?
    private var printing: NSPrintOperation?
    private var loaded: ((Result<Void, Error>) -> Void)?

    init(width: CGFloat = 720, height: CGFloat = 900, script: String? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let script {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
    }

    static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'"

    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timer = DispatchWorkItem { [weak self] in
                self?.finishLoading(.failure(RenderError.timeout))
                self?.webView.stopLoading()
            }
            loaded = { result in timer.cancel(); continuation.resume(with: result) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timer)
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let timer = DispatchWorkItem { [weak self] in
                guard !finished else { return }
                finished = true
                self?.webView.stopLoading()
                continuation.resume(throwing: RenderError.timeout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timer)
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                guard !finished else { return }
                finished = true
                timer.cancel()
                continuation.resume(with: result)
            }
        }
    }

    func pdf(rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await webView.pdf(configuration: configuration)
    }

    func printPDF(to url: URL) async throws {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WKPrintingView computes pages asynchronously on the main thread.
        // A synchronous run() there sees an unresolved, effectively unbounded range.
        operation.canSpawnSeparateThread = true
        printing = operation
        try await withCheckedThrowingContinuation { continuation in
            printCompletion = continuation
            operation.runModal(for: window, delegate: self,
                didRun: #selector(printDidFinish(_:success:context:)), contextInfo: nil)
        }
    }

    @objc nonisolated private func printDidFinish(_ operation: NSPrintOperation, success: Bool,
                                                  context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let completion = self.printCompletion
            self.printCompletion = nil
            self.printing = nil
            if success { completion?.resume() }
            else { completion?.resume(throwing: RenderError.printFailed) }
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finishLoading(.failure(RenderError.processEnded)) }

    private func finishLoading(_ result: Result<Void, Error>) {
        let completion = loaded
        loaded = nil
        completion?(result)
    }

    enum RenderError: LocalizedError {
        case timeout, processEnded, printFailed
        var errorDescription: String? {
            switch self {
            case .printFailed: "无法生成 PDF，请重试。"
            case .timeout: "排版超时，请缩小图表后重试。"
            case .processEnded: "排版进程已退出，请重试。"
            }
        }
    }
}
