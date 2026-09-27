import AppKit
import CryptoKit
import MathJaxSwift
import SwiftDraw
import SwiftUI

enum FormulaConfiguration {
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

private final class FormulaBox: NSObject {
    let value: FormulaResult
    init(_ value: FormulaResult) { self.value = value }
}

@MainActor
final class FormulaCache: ObservableObject {
    @Published private(set) var revision = 0
    private let cache = NSCache<NSString, FormulaBox>()
    private var pending = Set<String>()

    init() {
        cache.countLimit = 240
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    func result(for token: MathToken, fontSize: CGFloat, displayScale: CGFloat) -> FormulaResult {
        let scale = min(3, max(1, displayScale))
        let keyData = Data("\(token.display):\(fontSize):\(scale):\(token.formula)".utf8)
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        if let stored = cache.object(forKey: key as NSString) { return stored.value }
        guard pending.insert(key).inserted else { return .pending }
        let xHeight = max(1, systemSerifFont(size: fontSize).xHeight)
        FormulaWorker.shared.render(token.formula, display: token.display,
                                    xHeight: xHeight, displayScale: scale) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.pending.remove(key)
                let value: FormulaResult
                switch result {
                case .success(let image): value = .image(image)
                case .failure(let message): value = .failure(message)
                }
                let cost: Int
                if case .image(let rendered) = value {
                    cost = Int(rendered.image.size.width * rendered.image.size.height * scale * scale * 4)
                } else { cost = 1 }
                self.cache.setObject(FormulaBox(value), forKey: key as NSString, cost: max(1, cost))
                self.revision &+= 1
            }
        }
        return .pending
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

    func svg(_ formula: String, display: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.convert(formula, display: display)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func convert(_ formula: String, display: Bool) throws -> String {
        if engine == nil { engine = try MathJax(preferredOutputFormats: [.svg]) }
        return try engine!.tex2svg(formula, styles: false,
            conversionOptions: ConversionOptions(display: display), inputOptions: FormulaConfiguration.inputOptions)
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
              let baseline = attribute(#"vertical-align:\s*(-?[0-9.]+)ex"#),
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
