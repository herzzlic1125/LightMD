import AppKit
import ImageIO
import SwiftUI
import SwiftDraw

enum MarkdownMedia {
    static func localURL(_ source: String, relativeTo document: URL?) -> URL? {
        if let absolute = URL(string: source), let scheme = absolute.scheme, !scheme.isEmpty {
            return absolute.isFileURL ? absolute.standardizedFileURL : nil
        }
        let beforeFragment = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let path = String(beforeFragment).removingPercentEncoding ?? String(beforeFragment)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let document else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    struct LoadedImage {
        let pixels: CGImage
        let size: CGSize
    }

    static func load(_ url: URL) throws -> LoadedImage {
        if url.pathExtension.lowercased() == "svg" {
            guard let svg = SwiftDraw.SVG(data: try Data(contentsOf: url)),
                  svg.size.width.isFinite, svg.size.height.isFinite,
                  svg.size.width > 0, svg.size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let scale = min(1, 2048 / max(svg.size.width, svg.size.height))
            let width = max(1, Int(ceil(svg.size.width * scale)))
            let height = max(1, Int(ceil(svg.size.height * scale)))
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(svg, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let pixels = context.makeImage() else { throw CocoaError(.fileReadCorruptFile) }
            return LoadedImage(pixels: pixels, size: CGSize(width: width, height: height))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        return LoadedImage(pixels: image,
                           size: CGSize(width: image.width, height: image.height))
    }
}

@MainActor
private final class DocumentImageCache {
    static let shared = DocumentImageCache()
    let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 64 * 1024 * 1024; images.countLimit = 80 }

    func key(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.path):\(attributes?[.modificationDate] ?? ""):\(attributes?[.size] ?? "")"
    }
}

struct MarkdownImageView: View {
    let source: String
    let alternative: String
    let documentURL: URL?
    let onOpen: (URL) -> Void
    @State private var image: NSImage?
    @State private var resolvedURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let image, let resolvedURL {
                Button { onOpen(resolvedURL) } label: {
                    SwiftUI.Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: image.size.width, maxHeight: 640)
                        .accessibilityLabel(alternative.isEmpty ? "图片" : alternative)
                }
                .buttonStyle(.plain)
                .help("点击查看原图")
            } else {
                HStack(spacing: 8) {
                    SwiftUI.Image(systemName: "photo")
                    Text(failed ? "无法显示图片：\(alternative.isEmpty ? source : alternative)" : "正在加载图片…")
                        .lineLimit(2)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: "\(documentURL?.path ?? ""):\(source)") {
            image = nil
            failed = false
            guard let url = MarkdownMedia.localURL(source, relativeTo: documentURL) else {
                failed = true
                return
            }
            resolvedURL = url
            let key = DocumentImageCache.shared.key(for: url)
            if let cached = DocumentImageCache.shared.images.object(forKey: key as NSString) {
                image = cached
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) { try? MarkdownMedia.load(url) }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                let decoded = NSImage(cgImage: loaded.pixels, size: loaded.size)
                DocumentImageCache.shared.images.setObject(decoded, forKey: key as NSString,
                                                            cost: loaded.pixels.bytesPerRow * loaded.pixels.height)
                image = decoded
            } else { failed = true }
        }
    }
}
