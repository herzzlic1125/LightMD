import Foundation
import Markdown

struct MathToken {
    let marker: String
    let original: String
    let formula: String
    let display: Bool
    let firstLine: Int
    let lastLine: Int
}

struct PreparedMarkdown {
    let text: String
    let tokens: [String: MathToken]
    var replacements: [MathSourceReplacement] = []
}

struct MathSourceReplacement {
    let original: NSRange
    let prepared: NSRange
}

enum MathMarkup {
    private static let markerRegex = try! NSRegularExpression(pattern: "\u{E000}LM[0-9]+\u{E001}")

    static func tokens(in text: String, from tokens: [String: MathToken]) -> [MathToken] {
        guard text.contains("\u{E000}") else { return [] }
        let content = text as NSString
        return markerRegex.matches(in: text, range: NSRange(location: 0, length: content.length))
            .compactMap { tokens[content.substring(with: $0.range)] }
    }

    static func readable(_ text: String, tokens: [String: MathToken]) -> String {
        guard text.contains("\u{E000}") else { return text }
        let content = text as NSString
        let output = NSMutableString(string: text)
        for match in markerRegex.matches(in: text, range: NSRange(location: 0, length: content.length)).reversed() {
            if let token = tokens[content.substring(with: match.range)] {
                output.replaceCharacters(in: match.range, with: token.original)
            }
        }
        return output as String
    }

    static func prepare(_ source: String) -> PreparedMarkdown {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else {
            return PreparedMarkdown(text: source, tokens: [:])
        }
        let characters = Array(source)
        var output = ""
        var originalOffset = 0
        var preparedOffset = 0
        var replacements: [MathSourceReplacement] = []
        var tokens: [String: MathToken] = [:]
        var cursor = 0
        var line = 1
        var lineStart = true
        var fence: (Character, Int)?
        var protectedLines = Set<Int>()
        func protectCode(_ node: Markup) {
            if node is CodeBlock || node is HTMLBlock, let range = node.range {
                let last = max(range.lowerBound.line,
                               range.upperBound.line - (range.upperBound.column == 1 ? 1 : 0))
                protectedLines.formUnion(range.lowerBound.line...last)
                return
            }
            for child in node.children { protectCode(child) }
        }
        protectCode(Document(parsing: source))

        func appendOriginal(until end: Int) {
            while cursor < end {
                let character = characters[cursor]
                output.append(character)
                let length = String(character).utf16.count
                originalOffset += length
                preparedOffset += length
                if character.isNewline { line += 1; lineStart = true }
                else { lineStart = false }
                cursor += 1
            }
        }

        func escaped(_ index: Int) -> Bool {
            var count = 0
            var previous = index - 1
            while previous >= 0 && characters[previous] == "\\" {
                count += 1
                previous -= 1
            }
            return !count.isMultiple(of: 2)
        }

        func close(for opener: String, from start: Int, acrossLines: Bool) -> Int? {
            let closing = Array(opener == "\\(" ? "\\)" : opener == "\\[" ? "\\]" : opener)
            var index = start
            var candidateLine = line
            while index + closing.count <= characters.count {
                if protectedLines.contains(candidateLine) { return nil }
                if !acrossLines && characters[index].isNewline { return nil }
                if characters[index] == closing[0] && !escaped(index)
                    && Array(characters[index..<(index + closing.count)]) == closing {
                    if opener == "$" && index + 1 < characters.count && characters[index + 1] == "$" {
                        index += 2
                        continue
                    }
                    return index
                }
                if characters[index].isNewline { candidateLine += 1 }
                index += 1
            }
            return nil
        }

        func linkEnd(at start: Int) -> Int? {
            let bracket = characters[start] == "!" ? start + 1 : start
            guard bracket < characters.count && characters[bracket] == "[" else { return nil }
            var depth = 1
            var index = bracket + 1
            while index < characters.count && !characters[index].isNewline {
                if characters[index] == "[" && !escaped(index) { depth += 1 }
                if characters[index] == "]" && !escaped(index) {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            guard index + 1 < characters.count, depth == 0,
                  characters[index + 1] == "(" || characters[index + 1] == "[" else { return nil }
            let opening = characters[index + 1]
            let closing: Character = opening == "(" ? ")" : "]"
            depth = 1
            index += 2
            while index < characters.count && !characters[index].isNewline {
                if characters[index] == opening && !escaped(index) { depth += 1 }
                if characters[index] == closing && !escaped(index) {
                    depth -= 1
                    if depth == 0 { return index + 1 }
                }
                index += 1
            }
            return nil
        }

        func fenceMarker(in sourceLine: String) -> (Character, Int, String)? {
            var text = sourceLine.trimmingCharacters(in: .whitespaces)
            while text.hasPrefix(">") {
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespaces)
            }
            if let match = text.range(of: #"^(?:[-+*]|[0-9]+[.)])\s+"#, options: .regularExpression) {
                text.removeSubrange(match)
                text = text.trimmingCharacters(in: .whitespaces)
            }
            guard let first = text.first, first == "`" || first == "~" else { return nil }
            let count = text.prefix(while: { $0 == first }).count
            guard count >= 3 else { return nil }
            return (first, count, String(text.dropFirst(count)))
        }

        while cursor < characters.count {
            if lineStart {
                var end = cursor
                while end < characters.count && !characters[end].isNewline { end += 1 }
                let rawLine = String(characters[cursor..<end])
                let nextLine = end < characters.count ? end + 1 : end
                if protectedLines.contains(line) {
                    appendOriginal(until: nextLine)
                    continue
                }
                if let current = fence {
                    if let marker = fenceMarker(in: rawLine), marker.0 == current.0,
                       marker.1 >= current.1, marker.2.trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                    }
                    appendOriginal(until: nextLine)
                    continue
                }
                if let marker = fenceMarker(in: rawLine) {
                    fence = (marker.0, marker.1)
                    appendOriginal(until: nextLine)
                    continue
                }
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("<")
                    || rawLine.range(of: #"^\s{0,3}\[[^\]]+\]:"#, options: .regularExpression) != nil {
                    appendOriginal(until: nextLine)
                    continue
                }
            }

            if characters[cursor] == "`" {
                let count = characters[cursor...].prefix(while: { $0 == "`" }).count
                var ending = cursor + count
                var found: Int?
                while ending < characters.count {
                    if characters[ending] == "`" {
                        let length = characters[ending...].prefix(while: { $0 == "`" }).count
                        if length == count { found = ending + length; break }
                        ending += length
                    } else { ending += 1 }
                }
                if let found { appendOriginal(until: found); continue }
                appendOriginal(until: cursor + count)
                continue
            }

            if (characters[cursor] == "[" || characters[cursor] == "!") && !escaped(cursor),
               let end = linkEnd(at: cursor) {
                appendOriginal(until: end)
                continue
            }

            let opener: String?
            if characters[cursor] == "$" && !escaped(cursor) {
                opener = cursor + 1 < characters.count && characters[cursor + 1] == "$" ? "$$" : "$"
            } else if characters[cursor] == "\\" && !escaped(cursor), cursor + 1 < characters.count,
                      characters[cursor + 1] == "(" || characters[cursor + 1] == "[" {
                opener = characters[cursor + 1] == "(" ? "\\(" : "\\["
            } else { opener = nil }

            if let opener {
                let contentStart = cursor + opener.count
                let display = opener == "$$" || opener == "\\["
                if let closing = close(for: opener, from: contentStart, acrossLines: display) {
                    let content = String(characters[contentStart..<closing])
                    let formula = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let needsSignal = opener == "$" && (content.first?.isWhitespace == true || content.last?.isWhitespace == true)
                    let hasSignal = formula.contains(where: { "\\=^_{}+-*/".contains($0) })
                    let after = closing + opener.count
                    if !formula.isEmpty && formula.utf8.count <= 50_000
                        && (!needsSignal || hasSignal)
                        && !(opener == "$" && after < characters.count && characters[after].isNumber) {
                        let firstLine = line
                        let original = String(characters[cursor..<after])
                        let marker = "\u{E000}LM\(tokens.count)\u{E001}"
                        let replacementStart = preparedOffset
                        output.append(contentsOf: marker)
                        preparedOffset += marker.utf16.count
                        for character in original where character.isNewline {
                            output.append(character)
                            preparedOffset += String(character).utf16.count
                        }
                        replacements.append(MathSourceReplacement(
                            original: NSRange(location: originalOffset, length: original.utf16.count),
                            prepared: NSRange(location: replacementStart, length: preparedOffset - replacementStart)))
                        originalOffset += original.utf16.count
                        line += original.filter(\.isNewline).count
                        lineStart = original.last?.isNewline == true
                        tokens[marker] = MathToken(marker: marker, original: original, formula: formula,
                                                   display: display, firstLine: firstLine, lastLine: line)
                        cursor = after
                        continue
                    }
                }
            }
            appendOriginal(until: cursor + 1)
        }
        return PreparedMarkdown(text: output, tokens: tokens, replacements: replacements)
    }
}
