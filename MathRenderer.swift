import AppKit
import MathJaxSwift
import SwiftDraw
import SwiftUI

enum FormulaConfiguration {
    // The bundled MathJax TeX set omits the closed surface integral command.
    // Define it only in the rendering input; retain the original source for editing,
    // copying, saving and failure fallback. Keep operator/subscript semantics.
    static func renderingInput(_ formula: String) -> String {
        #"\newcommand{\oiint}{\mathop{∯}\nolimits}"# + formula
    }

    // Pin the decimal pattern: the dependency's default dot matches any character,
    // swallowing adjacent operators, matrix columns and row separators.
    static var inputOptions: TeXInputProcessorOptions {
        TeXInputProcessorOptions(
            loadPackages: ["base", "ams", "cases", "mathtools", "newcommand"],
            digits: #"^(?:[0-9]+(?:\{,\}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)"#)
    }
}

struct FormulaImage {
    let image: NSImage
    let baselineOffset: CGFloat
}

enum FormulaResult {
    case pending
    case image(FormulaImage)
    case failure(String)
}

private enum FormulaWorkResult {
    case success(FormulaImage)
    case failure(String)
}

// Each leaf block observes only the formula jobs it actually requested.
@MainActor
final class FormulaUpdates: ObservableObject {
    func refresh() { objectWillChange.send() }
}

private final class WeakFormulaUpdates {
    weak var value: FormulaUpdates?
    init(_ value: FormulaUpdates) { self.value = value }
}

@MainActor
final class FormulaCache: ObservableObject {
    // Diagnostic counter, deliberately not published to the whole document.
    private(set) var revision = 0
    private struct Key: Hashable {
        let formula: String
        let display: Bool
        let fontSize: CGFloat
        let scale: CGFloat
    }
    private struct Cached {
        let value: FormulaResult
        let cost: Int
        var access: UInt64
    }
    private var cache: [Key: Cached] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private let costLimit = 64 * 1024 * 1024
    private let countLimit = 2048
    private var visible: [Key] = []
    private var background: [Key] = []
    private var pending = Set<Key>()
    private var urgent = Set<Key>()
    private var running: Key?
    private var waiting: [Key: [ObjectIdentifier: WeakFormulaUpdates]] = [:]
    private var updates: [ObjectIdentifier: WeakFormulaUpdates] = [:]
    private var updateScheduled = false

    private func key(for token: MathToken, fontSize: CGFloat, displayScale: CGFloat) -> Key {
        Key(formula: token.formula, display: token.display, fontSize: fontSize,
            scale: min(3, max(1, displayScale)))
    }

    func result(for token: MathToken, fontSize: CGFloat, displayScale: CGFloat,
                observer: FormulaUpdates? = nil) -> FormulaResult {
        let key = key(for: token, fontSize: fontSize, displayScale: displayScale)
        if var stored = cache[key] {
            clock &+= 1
            stored.access = clock
            cache[key] = stored
            return stored.value
        }
        if let observer {
            waiting[key, default: [:]][ObjectIdentifier(observer)] = WeakFormulaUpdates(observer)
        }
        pending.insert(key)
        if key != running, urgent.insert(key).inserted { visible.append(key) }
        startNext()
        return .pending
    }

    // A single background job runs at a time. New visible requests jump ahead of
    // this queue, and switching document/size replaces obsolete prefetch work.
    func prefetch(_ tokens: [MathToken], fontSize: CGFloat, displayScale: CGFloat) {
        for key in background where key != running && !urgent.contains(key) {
            pending.remove(key)
        }
        background.removeAll(keepingCapacity: true)
        // Do not warm more entries than the cache can retain on enormous files.
        var budget = countLimit
        for token in tokens {
            let key = key(for: token, fontSize: fontSize * (token.display ? 1.12 : 1),
                          displayScale: displayScale)
            guard cache[key] == nil, pending.insert(key).inserted else { continue }
            background.append(key)
            budget -= 1
            if budget == 0 { break }
        }
        startNext()
    }

    private func startNext() {
        guard running == nil else { return }
        var next: Key?
        while !visible.isEmpty {
            let key = visible.removeFirst()
            urgent.remove(key)
            if pending.contains(key) { next = key; break }
        }
        if next == nil {
            while !background.isEmpty {
                let key = background.removeFirst()
                if pending.contains(key) { next = key; break }
            }
        }
        guard let key = next else { return }
        running = key
        let xHeight = max(1, systemSerifFont(size: key.fontSize).xHeight)
        FormulaWorker.shared.render(key.formula, display: key.display,
                                    xHeight: xHeight, displayScale: key.scale) { [weak self] result in
            Task { @MainActor in self?.finish(key, result: result) }
        }
    }

    private func finish(_ key: Key, result: FormulaWorkResult) {
        running = nil
        pending.remove(key)
        let value: FormulaResult
        let entryCost: Int
        switch result {
        case .success(let image):
            value = .image(image)
            entryCost = max(1, Int(image.image.size.width * image.image.size.height * key.scale * key.scale * 4))
        case .failure(let message): value = .failure(message); entryCost = 1
        }
        clock &+= 1
        cache[key] = Cached(value: value, cost: entryCost, access: clock)
        cost += entryCost
        while cost > costLimit || cache.count > countLimit {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access }) else { break }
            cost -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
        }
        revision &+= 1
        if let observers = waiting.removeValue(forKey: key) {
            updates.merge(observers, uniquingKeysWith: { _, newest in newest })
            if !updateScheduled {
                updateScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                    guard let self else { return }
                    self.updateScheduled = false
                    let batch = self.updates
                    self.updates.removeAll(keepingCapacity: true)
                    for observer in batch.values { observer.value?.refresh() }
                }
            }
        }
        startNext()
    }
}

enum FormulaExport {
    static func svg(_ formula: String, display: Bool) async throws -> String {
        try await FormulaWorker.shared.svg(formula, display: display)
    }
}

// Engine access is confined to the serial queue.
private final class FormulaWorker: @unchecked Sendable {
    static let shared = FormulaWorker()
    private let queue = DispatchQueue(label: "local.lightmd.math", qos: .userInitiated)
    private var engine: MathJax?
    private let markupCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    func svg(_ formula: String, display: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.convert(formula, display: display)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func convert(_ formula: String, display: Bool) throws -> String {
        let key = "\(display):\(formula)" as NSString
        if let cached = markupCache.object(forKey: key) { return cached as String }
        if engine == nil { engine = try MathJax(preferredOutputFormats: [.svg]) }
        let markup = try engine!.tex2svg(FormulaConfiguration.renderingInput(formula), styles: false,
            conversionOptions: ConversionOptions(display: display), inputOptions: FormulaConfiguration.inputOptions)
        markupCache.setObject(markup as NSString, forKey: key, cost: markup.utf8.count)
        return markup
    }

    func render(_ formula: String, display: Bool, xHeight: CGFloat, displayScale: CGFloat,
                completion: @escaping (FormulaWorkResult) -> Void) {
        queue.async {
            do {
                let markup = try self.convert(formula, display: display)
                let geometry = try self.geometry(from: markup, xHeight: xHeight)
                let image = try self.image(from: markup, size: geometry.size, scale: displayScale)
                completion(.success(FormulaImage(image: image, baselineOffset: geometry.baseline)))
            } catch {
                completion(.failure(error.localizedDescription))
            }
        }
    }

    private func geometry(from markup: String, xHeight: CGFloat) throws ->
        (size: CGSize, baseline: CGFloat) {
        guard let header = markup.range(of: #"<svg\b[^>]*>"#, options: .regularExpression) else {
            throw FormulaError.invalidGeometry
        }
        let attributes = String(markup[header])
        func attribute(_ pattern: String) -> CGFloat? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                  let range = Range(match.range(at: 1), in: attributes),
                  let value = Double(attributes[range]),
                  value.isFinite else { return nil }
            return CGFloat(value)
        }
        guard let width = attribute(#"width="([0-9.]+)ex""#),
              let height = attribute(#"height="([0-9.]+)ex""#),
              let baseline = attribute(#"vertical-align:\s*(-?[0-9.]+)ex"#)
                ?? attribute(#"vertical-align:\s*(0)(?=\s*[;"])"#),
              width > 0, height > 0 else { throw FormulaError.invalidGeometry }
        let size = CGSize(width: ceil(width * xHeight), height: ceil(height * xHeight))
        guard size.width <= 8_192, size.height <= 8_192 else { throw FormulaError.tooLarge }
        return (size, baseline * xHeight)
    }

    private func image(from markup: String, size: CGSize, scale: CGFloat) throws -> NSImage {
        guard let svg = SwiftDraw.SVG(data: Data(markup.utf8)) else { throw FormulaError.invalidSVG }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard width > 0, height > 0, width * height <= 16_000_000,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FormulaError.tooLarge }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.draw(svg, in: CGRect(origin: .zero, size: size))
        guard let pixels = context.makeImage() else { throw FormulaError.invalidSVG }
        let image = NSImage(cgImage: pixels, size: size)
        image.isTemplate = true
        return image
    }

    private enum FormulaError: LocalizedError {
        case invalidGeometry, invalidSVG, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidGeometry: "无法读取公式尺寸"
            case .invalidSVG: "无法绘制公式"
            case .tooLarge: "公式尺寸超出显示范围"
            }
        }
    }
}
