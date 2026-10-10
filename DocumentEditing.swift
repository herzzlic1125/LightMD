import AppKit
import Foundation
import Markdown

enum ReaderMode: String { case reading, source, live }

@MainActor final class DocumentUndoTarget: NSObject {
    weak var reader: ReaderState?
    init(_ reader: ReaderState) { self.reader = reader }
}

struct SourceSelectionRequest {
    let id = UUID()
    let tabID: UUID
    let range: NSRange
}

struct SourceEdit {
    let location: Int
    let before: String
    let after: String
    let selectionBefore: NSRange
    let selectionAfter: NSRange

    static func difference(from old: String, to new: String, selection: NSRange,
                           selectionAfter: NSRange? = nil) -> SourceEdit {
        let left = Array(old.utf16), right = Array(new.utf16)
        var start = 0
        while start < min(left.count, right.count), left[start] == right[start] { start += 1 }
        // Never split the surrogate pair of a Unicode scalar.
        if start > 0, start < left.count, (0xD800...0xDBFF).contains(left[start - 1]) { start -= 1 }
        var oldEnd = left.count, newEnd = right.count
        while oldEnd > start, newEnd > start, left[oldEnd - 1] == right[newEnd - 1] {
            oldEnd -= 1; newEnd -= 1
        }
        if oldEnd < left.count, oldEnd > start, (0xD800...0xDBFF).contains(left[oldEnd - 1]) {
            oldEnd += 1; newEnd += 1
        }
        return SourceEdit(location: start,
            before: (old as NSString).substring(with: NSRange(location: start, length: oldEnd - start)),
            after: (new as NSString).substring(with: NSRange(location: start, length: newEnd - start)),
            selectionBefore: selection,
            selectionAfter: selectionAfter ?? NSRange(location: newEnd, length: 0))
    }

    var reversed: SourceEdit {
        SourceEdit(location: location, before: after, after: before,
                   selectionBefore: selectionAfter, selectionAfter: selectionBefore)
    }
}

struct LiveSourceBlock: Identifiable {
    let id = UUID()
    let markup: [Markup]
    let range: NSRange
    let path: String
    let paths: [String]
}

// Fresh immutable AST; never shared with a worker that is still traversing it.
struct LiveSourceDocument: @unchecked Sendable {
    let source: String
    let blocks: [LiveSourceBlock]
    let tokens: [String: MathToken]
    let outline: [OutlineEntry]

    static func parse(_ source: String) -> LiveSourceDocument {
        let prepared = MathMarkup.prepare(source)
        let document = Document(parsing: prepared.text)
        let mapper = LiveSourceMap(prepared: prepared)
        let length = (source as NSString).length
        var blocks: [LiveSourceBlock] = []
        for (index, block) in document.children.enumerated() {
            guard let span = block.range else { continue }
            let start = mapper.originalOffset(for: mapper.offset(span.lowerBound), upper: false)
            let end = mapper.originalOffset(for: mapper.offset(span.upperBound), upper: true)
            guard start >= 0, end >= start, end <= length else { continue }
            // Opaque multiline math may extend a parser range. Overlapping
            // ranges are combined rather than allowing two competing editors.
            if let previous = blocks.last, start < NSMaxRange(previous.range) {
                blocks.removeLast()
                let combined = NSRange(location: previous.range.location,
                    length: max(NSMaxRange(previous.range), end) - previous.range.location)
                blocks.append(LiveSourceBlock(markup: previous.markup + [block], range: combined,
                    path: previous.path, paths: previous.paths + [String(index)]))
            } else {
                blocks.append(LiveSourceBlock(markup: [block],
                    range: NSRange(location: start, length: end - start), path: String(index), paths: [String(index)]))
            }
        }
        return LiveSourceDocument(source: source, blocks: blocks, tokens: prepared.tokens,
                                  outline: ReaderState.outline(for: document, tokens: prepared.tokens))
    }
}

private struct LiveSourceMap {
    let replacements: [MathSourceReplacement]
    let byteToUTF16: [Int]
    let lineStarts: [Int]

    init(prepared: PreparedMarkdown) {
        replacements = prepared.replacements
        var map = [Int](repeating: 0, count: prepared.text.utf8.count + 1)
        var starts = [0], byte = 0, utf16 = 0
        let scalars = Array(prepared.text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let bytes = String(scalar).utf8.count
            for position in byte..<(byte + bytes) { map[position] = utf16 }
            byte += bytes
            utf16 += scalar.value > 0xFFFF ? 2 : 1
            map[byte] = utf16
            if scalar == "\n" || (scalar == "\r" && (index + 1 == scalars.count || scalars[index + 1] != "\n")) {
                starts.append(byte)
            }
        }
        byteToUTF16 = map
        lineStarts = starts
    }

    func offset(_ location: SourceLocation) -> Int {
        guard location.line > 0, location.line <= lineStarts.count else { return byteToUTF16.last ?? 0 }
        let byte = min(byteToUTF16.count - 1, max(0, lineStarts[location.line - 1] + location.column - 1))
        return byteToUTF16[byte]
    }

    func originalOffset(for offset: Int, upper: Bool) -> Int {
        var delta = 0
        for change in replacements {
            if offset <= change.prepared.location { break }
            if offset < NSMaxRange(change.prepared) {
                return upper ? NSMaxRange(change.original) : change.original.location
            }
            delta = NSMaxRange(change.original) - NSMaxRange(change.prepared)
        }
        return offset + delta
    }
}
