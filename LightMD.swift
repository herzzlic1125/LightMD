import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Markdown
import CoreFoundation
import QuickLook

func sameSourceBytes(_ first: String, _ second: String) -> Bool {
    first.utf8.elementsEqual(second.utf8)
}

enum ReadingRun: Equatable {
    case han, hanPunctuation, english, digit
}

let chinesePunctuation: Set<Character> = Set("，。：；「」（）《》？！～、．“”‘’【】")

func systemSerifFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = system.fontDescriptor.withDesign(.serif),
          let serif = NSFont(descriptor: descriptor, size: size) else { return system }
    return serif
}

func readingRun(for character: Character, previous: ReadingRun?, next: Character?) -> ReadingRun {
    let scalar = character.unicodeScalars.first?.value ?? 0
    if chinesePunctuation.contains(character) { return .hanPunctuation }
    if (48...57).contains(scalar) { return .digit }
    if (65...90).contains(scalar) || (97...122).contains(scalar)
        || (0x00C0...0x024F).contains(scalar) || (0x1E00...0x1EFF).contains(scalar) {
        return .english
    }
    if scalar < 128 && character != " " && character != "\t" && character != "\n" {
        let nextIsDigit = next.flatMap { $0.unicodeScalars.first?.value }.map { (48...57).contains($0) } ?? false
        if previous == .digit || (nextIsDigit && ".:-/+".contains(character)) { return .digit }
        return .english
    }
    return .han
}

private func readingFont(for run: ReadingRun, size: CGFloat, strong: Bool, emphasized: Bool, heading: Bool) -> Font {
    let font: Font
    switch run {
    case .english, .digit:
        font = Font(systemSerifFont(size: size, weight: strong
                                    ? (heading ? .semibold : .bold) : .regular))
    case .han:
        font = .custom(emphasized ? (strong ? "STKaitiSC-Bold" : "STKaitiSC-Regular")
                    : strong ? (heading ? "STSongti-SC-Bold" : "STSongti-SC-Black")
                             : "STSongti-SC-Regular", size: size)
    case .hanPunctuation:
        font = .custom(emphasized ? (strong ? "STKaitiSC-Bold" : "STKaitiSC-Regular")
                    : strong && !heading ? "STSongti-SC-Black"
                    : strong ? "SimSong-Bold" : "SimSong", size: size)
    }
    return emphasized && (run == .english || run == .digit) ? font.italic() : font
}

func readingBaseline(for run: ReadingRun, size: CGFloat, strong: Bool,
                     emphasized: Bool, heading: Bool) -> CGFloat {
    guard run == .han || run == .hanPunctuation else { return 0 }
    if heading { return size * 0.06 }
    return strong && !emphasized ? -size * 0.02 : size * 0.04
}

private func styledReadingText(_ text: String, size: CGFloat, strong: Bool = false,
                               emphasized: Bool = false, heading: Bool = false) -> SwiftUI.Text {
    var result = SwiftUI.Text("")
    var run = ""
    var runKind: ReadingRun?
    func styled(_ content: String, kind: ReadingRun) -> SwiftUI.Text {
        let font = readingFont(for: kind, size: size, strong: strong,
                               emphasized: emphasized, heading: heading)
        let fragment = SwiftUI.Text(content).font(font)
        return fragment.baselineOffset(readingBaseline(for: kind, size: size, strong: strong,
                                                      emphasized: emphasized, heading: heading))
    }
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
        let kind = readingRun(for: character, previous: runKind,
                              next: index + 1 < characters.count ? characters[index + 1] : nil)
        if let previous = runKind, previous != kind {
            result = result + styled(run, kind: previous)
            run = ""
        }
        run.append(character)
        runKind = kind
    }
    if let kind = runKind { result = result + styled(run, kind: kind) }
    return result
}

struct OutlineEntry: Identifiable {
    let id: String
    let title: String
    let level: Int
    let slug: String
}

struct IndexedBlock {
    let path: String
    let text: String
}

struct FileStamp: Equatable {
    let modified: Date?
    let size: UInt64
    let inode: UInt64
}

struct NavigationRequest {
    let id = UUID()
    let tabID: UUID
    let path: String
}

struct SearchHit {
    let path: String
}

@MainActor
struct ReaderTab: Identifiable {
    let id: UUID
    var url: URL?
    var source: String
    var document: Document?
    var outline: [OutlineEntry]
    var index: [IndexedBlock]
    var plainLines: [String]?
    var scrollSpans: [String: SourceLineSpan]
    var encodingName: String
    var stamp: FileStamp?
    var savedSource: String
    var savedData: Data?
    var externalConflict: Bool
    var editRevision: UInt64
    var previewID: UUID
    var autoSaveError: String?
    var mathTokens: [String: MathToken]

    init(id: UUID = UUID(), url: URL? = nil, source: String = "", document: Document? = nil,
         outline: [OutlineEntry] = [], index: [IndexedBlock] = [], plainLines: [String]? = nil,
         scrollSpans: [String: SourceLineSpan] = [:],
         encodingName: String = "UTF-8", stamp: FileStamp? = nil,
         savedSource: String = "", savedData: Data? = nil, externalConflict: Bool = false,
         editRevision: UInt64 = 0, previewID: UUID = UUID(),
         mathTokens: [String: MathToken] = [:]) {
        self.id = id
        self.url = url
        self.source = source
        self.document = document
        self.outline = outline
        self.index = index
        self.plainLines = plainLines
        self.scrollSpans = scrollSpans
        self.encodingName = encodingName
        self.stamp = stamp
        self.savedSource = savedSource
        self.savedData = savedData
        self.externalConflict = externalConflict
        self.editRevision = editRevision
        self.previewID = previewID
        self.autoSaveError = nil
        self.mathTokens = mathTokens
    }

    var title: String { url?.lastPathComponent ?? "未命名" }
    var isDirty: Bool { !sameSourceBytes(source, savedSource) }
}

@MainActor
final class ReaderState: ObservableObject {
    @Published var tabs: [ReaderTab]
    @Published var selectedID: UUID {
        willSet {
            if selectedID != newValue, let bookmark = captureCurrentBookmark?() {
                readingBookmarks[selectedID] = bookmark
            }
        }
        didSet { if selectedID != oldValue { scheduleSessionWrite() } }
    }
    @Published var fontSize: CGFloat = 16
    @Published var showsOutline = false
    @Published var isEditing = false
    @Published var isSearching = false
    @Published var searchQuery = ""
    @Published var searchHitIndex = 0
    @Published var navigationRequest: NavigationRequest?
    @Published var error: String?
    @Published var imagePreviewURL: URL?

    private var fileTimer: Timer?
    private var pendingRefresh: [UUID: Task<Void, Never>] = [:]
    private var pendingParse: [UUID: Task<Void, Never>] = [:]
    private var pendingAutoSave: [UUID: Task<Void, Never>] = [:]
    private var pendingSessionWrite: Task<Void, Never>?
    private var readingBookmarks: [UUID: ReadingBookmark] = [:]
    private let sessionStore: SessionStore
    let formulas = FormulaCache()
    private let canWriteSession: Bool
    var captureCurrentBookmark: (() -> ReadingBookmark?)?
    var beforeReload: ((UUID) -> Void)?
    var afterReload: ((UUID) -> Void)?
    var beforeModeChange: (() -> Void)?
    var afterModeChange: (() -> Void)?

    init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
        let loaded = sessionStore.load()
        let recovered = Self.restore(loaded.session)
        tabs = recovered.tabs
        selectedID = recovered.selectedID
        readingBookmarks = recovered.bookmarks
        canWriteSession = loaded.canWrite
        error = loaded.error
        fileTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFiles() }
        }
    }

    var currentTab: ReaderTab? { tabs.first { $0.id == selectedID } }
    var currentURL: URL? { currentTab?.url }
    var currentDocument: Document? { currentTab?.document }
    var currentOutline: [OutlineEntry] { currentTab?.outline ?? [] }
    var currentLines: [String]? { currentTab?.plainLines }
    var currentMathTokens: [String: MathToken] { currentTab?.mathTokens ?? [:] }
    func bookmark(for tabID: UUID) -> ReadingBookmark? { readingBookmarks[tabID] }

    func recordBookmark(_ bookmark: ReadingBookmark, in tabID: UUID) {
        guard readingBookmarks[tabID] != bookmark else { return }
        readingBookmarks[tabID] = bookmark
        scheduleSessionWrite()
    }

    private func sessionSnapshot() -> SavedSession {
        let selectedIndex = tabs.firstIndex { $0.id == selectedID } ?? 0
        let items = tabs.map { tab in
            let draft = tab.isDirty || tab.url == nil ? tab.source : nil
            return SavedTab(path: tab.url?.path, draft: draft,
                            baselineSHA256: draft != nil ? tab.savedData.map(SessionStore.fingerprint) : nil,
                            bookmark: readingBookmarks[tab.id], externalConflict: tab.externalConflict)
        }
        return SavedSession(version: 1, selectedIndex: selectedIndex, tabs: items)
    }

    private func scheduleSessionWrite() {
        guard canWriteSession else { return }
        pendingSessionWrite?.cancel()
        pendingSessionWrite = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            _ = self?.saveSessionNow()
        }
    }

    @discardableResult
    func saveSessionNow() -> Bool {
        guard canWriteSession else { return false }
        if let bookmark = captureCurrentBookmark?() { readingBookmarks[selectedID] = bookmark }
        pendingSessionWrite?.cancel()
        pendingSessionWrite = nil
        do {
            try sessionStore.save(sessionSnapshot())
            return true
        } catch {
            self.error = "无法保存会话与草稿：\(error.localizedDescription)"
            return false
        }
    }
    func toggleMode() {
        beforeModeChange?()
        isEditing.toggle()
    }

    var searchHits: [SearchHit] {
        guard !searchQuery.isEmpty else { return [] }
        var result: [SearchHit] = []
        for block in currentTab?.index ?? [] {
            var remaining = block.text.startIndex..<block.text.endIndex
            while let match = block.text.range(of: searchQuery,
                                                options: [.caseInsensitive, .diacriticInsensitive],
                                                range: remaining), !match.isEmpty {
                result.append(SearchHit(path: block.path))
                remaining = match.upperBound..<block.text.endIndex
            }
        }
        return result
    }

    var activeSearchPath: String? {
        let hits = searchHits
        guard !hits.isEmpty else { return nil }
        return hits[min(searchHitIndex, hits.count - 1)].path
    }

    func navigate(to path: String, in tabID: UUID? = nil) {
        guard let id = tabID ?? currentTab?.id else { return }
        navigationRequest = NavigationRequest(tabID: id, path: path)
    }

    func moveSearch(by step: Int) {
        let hits = searchHits
        guard !hits.isEmpty else { return }
        searchHitIndex = (searchHitIndex + step + hits.count) % hits.count
        navigate(to: hits[searchHitIndex].path)
    }

    private static func plainTitle(_ node: Markup) -> String {
        if let text = node as? Markdown.Text { return text.string }
        if let code = node as? InlineCode { return code.code }
        if let code = node as? CodeBlock { return code.code }
        if node is SoftBreak || node is LineBreak { return " " }
        return node.children.map { plainTitle($0) }.joined()
    }

    private static func readableTitle(_ node: Markup, tokens: [String: MathToken]) -> String {
        var title = plainTitle(node)
        for token in tokens.values {
            title = title.replacingOccurrences(of: token.marker, with: token.original)
        }
        return title
    }

    private static func slug(_ title: String) -> String {
        var output = ""
        var lastWasHyphen = false
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                output.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !output.isEmpty, !lastWasHyphen {
                output.append("-")
                lastWasHyphen = true
            }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func collectHeadings(_ node: Markup, path: String,
                                        tokens: [String: MathToken], into entries: inout [OutlineEntry]) {
        if let heading = node as? Heading {
            entries.append(OutlineEntry(id: path, title: readableTitle(heading, tokens: tokens), level: heading.level,
                                        slug: ""))
        }
        for (index, child) in node.children.enumerated() {
            collectHeadings(child, path: "\(path).\(index)", tokens: tokens, into: &entries)
        }
    }

    private static func outline(for document: Document, tokens: [String: MathToken] = [:]) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        for (index, block) in document.children.enumerated() {
            collectHeadings(block, path: String(index), tokens: tokens, into: &entries)
        }
        var counts: [String: Int] = [:]
        return entries.map { entry in
            let base = slug(entry.title)
            let number = counts[base, default: 0]
            counts[base] = number + 1
            return OutlineEntry(id: entry.id, title: entry.title, level: entry.level,
                                slug: number == 0 ? base : "\(base)-\(number)")
        }
    }

    private static func index(for document: Document, tokens: [String: MathToken] = [:]) -> [IndexedBlock] {
        document.children.enumerated().map { index, block in
            IndexedBlock(path: String(index), text: readableTitle(block, tokens: tokens))
        }
    }

    private static func scrollSpans(for document: Document,
                                    tokens: [String: MathToken] = [:]) -> [String: SourceLineSpan] {
        var lines: [String: SourceLineSpan] = [:]
        func collect(_ block: Markup, path: String) {
            if let range = block.range {
                let end = range.upperBound.line + (range.upperBound.column > 1 ? 1 : 0)
                let embedded = tokens.values.filter { plainTitle(block).contains($0.marker) }
                lines[path] = SourceLineSpan(start: range.lowerBound.line,
                                             end: max(range.lowerBound.line + 1,
                                                      max(end, embedded.map { $0.lastLine + 1 }.max() ?? end)))
            }
            if block is OrderedList || block is UnorderedList || block is ListItem || block is BlockQuote {
                for (index, child) in block.children.enumerated() {
                    collect(child, path: "\(path).\(index)")
                }
            }
        }
        for (index, block) in document.children.enumerated() {
            collect(block, path: String(index))
        }
        return lines
    }

    private static func stamp(for url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(modified: attributes[.modificationDate] as? Date,
                         size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                         inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }

    private static func decode(_ data: Data) throws -> (text: String, name: String) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: Data(data.dropFirst(3)), encoding: .utf8) {
            return (text, "UTF-8 BOM")
        }
        if data.starts(with: [0xFF, 0xFE]),
           let text = String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) {
            return (text, "UTF-16 LE BOM")
        }
        if data.starts(with: [0xFE, 0xFF]),
           let text = String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian) {
            return (text, "UTF-16 BE BOM")
        }
        let sample = Array(data.prefix(512))
        if sample.count >= 16 && sample.count.isMultiple(of: 2) {
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let threshold = sample.count / 8
            if oddZeros > threshold && evenZeros < threshold / 2,
               let text = String(data: data, encoding: .utf16LittleEndian) { return (text, "UTF-16 LE") }
            if evenZeros > threshold && oddZeros < threshold / 2,
               let text = String(data: data, encoding: .utf16BigEndian) { return (text, "UTF-16 BE") }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return (text, "GB18030") }
        throw NSError(domain: "LightMD", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法识别文件编码"])
    }

    private static func makeTab(id: UUID = UUID(), url: URL, text: String,
                                encoding: String, stamp: FileStamp?, data: Data) -> ReaderTab {
        if url.pathExtension.lowercased() == "txt" {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")
            return ReaderTab(id: id, url: url, source: text,
                             index: lines.enumerated().map { IndexedBlock(path: String($0.offset), text: $0.element) },
                             plainLines: lines,
                             scrollSpans: Dictionary(uniqueKeysWithValues: lines.indices.map { (String($0), SourceLineSpan(start: $0 + 1, end: $0 + 2)) }),
                             encodingName: encoding, stamp: stamp,
                             savedSource: text, savedData: data)
        }
        let prepared = MathMarkup.prepare(text)
        let document = Document(parsing: prepared.text)
        return ReaderTab(id: id, url: url, source: text, document: document,
                         outline: outline(for: document, tokens: prepared.tokens),
                         index: index(for: document, tokens: prepared.tokens),
                         scrollSpans: scrollSpans(for: document, tokens: prepared.tokens),
                         encodingName: encoding, stamp: stamp,
                         savedSource: text, savedData: data, mathTokens: prepared.tokens)
    }

    private static func parseDraft(_ tab: inout ReaderTab) {
        if tab.url?.pathExtension.lowercased() == "txt" {
            tab.mathTokens = [:]
            let lines = tab.source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            tab.document = nil
            tab.plainLines = lines
            tab.outline = []
            tab.index = lines.enumerated().map { IndexedBlock(path: String($0.offset), text: $0.element) }
            tab.scrollSpans = Dictionary(uniqueKeysWithValues: lines.indices.map {
                (String($0), SourceLineSpan(start: $0 + 1, end: $0 + 2))
            })
        } else {
            let prepared = MathMarkup.prepare(tab.source)
            let document = Document(parsing: prepared.text)
            tab.mathTokens = prepared.tokens
            tab.document = document
            tab.plainLines = nil
            tab.outline = outline(for: document, tokens: prepared.tokens)
            tab.index = index(for: document, tokens: prepared.tokens)
            tab.scrollSpans = scrollSpans(for: document, tokens: prepared.tokens)
        }
        tab.previewID = UUID()
    }

    private static func restore(_ session: SavedSession?) ->
        (tabs: [ReaderTab], selectedID: UUID, bookmarks: [UUID: ReadingBookmark]) {
        var restored: [ReaderTab] = []
        var bookmarks: [UUID: ReadingBookmark] = [:]
        var selected: UUID?
        for (position, item) in (session?.tabs ?? []).enumerated() {
            let url = item.path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            var tab: ReaderTab?
            if let url, let data = try? Data(contentsOf: url), let decoded = try? decode(data) {
                var loaded = makeTab(url: url, text: decoded.text, encoding: decoded.name,
                                     stamp: stamp(for: url), data: data)
                if let draft = item.draft, !sameSourceBytes(draft, decoded.text) {
                    loaded.source = draft
                    loaded.editRevision = 1
                    loaded.externalConflict = item.externalConflict == true || item.baselineSHA256 != SessionStore.fingerprint(data)
                    parseDraft(&loaded)
                }
                tab = loaded
            } else if let draft = item.draft {
                var loaded = ReaderTab(url: url, source: draft,
                                       savedSource: url != nil && draft.isEmpty ? "\u{0}" : "",
                                       externalConflict: url != nil)
                loaded.editRevision = 1
                parseDraft(&loaded)
                tab = loaded
            }
            guard let tab else { continue }
            restored.append(tab)
            if let bookmark = item.bookmark { bookmarks[tab.id] = bookmark }
            if position == session?.selectedIndex { selected = tab.id }
        }
        if restored.isEmpty { restored = [ReaderTab()] }
        return (restored, selected ?? restored[0].id, bookmarks)
    }

    private static func encode(_ text: String, as name: String) -> Data? {
        switch name {
        case "UTF-8 BOM":
            guard let body = text.data(using: .utf8) else { return nil }
            return Data([0xEF, 0xBB, 0xBF]) + body
        case "UTF-16 LE BOM", "UTF-16 LE":
            guard let body = text.data(using: .utf16LittleEndian) else { return nil }
            return (name.hasSuffix("BOM") ? Data([0xFF, 0xFE]) : Data()) + body
        case "UTF-16 BE BOM", "UTF-16 BE":
            guard let body = text.data(using: .utf16BigEndian) else { return nil }
            return (name.hasSuffix("BOM") ? Data([0xFE, 0xFF]) : Data()) + body
        case "GB18030":
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            return text.data(using: encoding, allowLossyConversion: false)
        default:
            return text.data(using: .utf8)
        }
    }

    func updateSource(_ source: String, in tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              !sameSourceBytes(tabs[index].source, source) else { return }
        tabs[index].source = source
        if !tabs[index].isDirty { tabs[index].autoSaveError = nil }
        tabs[index].editRevision &+= 1
        scheduleSessionWrite()
        let revision = tabs[index].editRevision
        pendingParse[tabID]?.cancel()
        pendingParse[tabID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) }
            catch { return }
            self?.publishPreview(for: tabID, revision: revision)
        }
        pendingAutoSave[tabID]?.cancel()
        pendingAutoSave[tabID] = nil
        guard tabs[index].url != nil, tabs[index].isDirty, !tabs[index].externalConflict else { return }
        pendingAutoSave[tabID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            guard let self, let tab = self.tabs.first(where: { $0.id == tabID }),
                  tab.editRevision == revision else { return }
            self.pendingAutoSave[tabID] = nil
            guard tab.isDirty, !tab.externalConflict, let url = tab.url else { return }
            _ = self.write(tabID: tabID, to: url, saveAs: false, automatic: true)
        }
    }

    private func publishPreview(for tabID: UUID, revision: UInt64) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].editRevision == revision else { return }
        let source = tabs[index].source
        if tabs[index].url?.pathExtension.lowercased() == "txt" {
            tabs[index].mathTokens = [:]
            let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")
            tabs[index].plainLines = lines
            tabs[index].document = nil
            tabs[index].outline = []
            tabs[index].index = lines.enumerated().map { IndexedBlock(path: String($0.offset), text: $0.element) }
            tabs[index].scrollSpans = Dictionary(uniqueKeysWithValues: lines.indices.map { (String($0), SourceLineSpan(start: $0 + 1, end: $0 + 2)) })
        } else {
            let prepared = MathMarkup.prepare(source)
            let document = Document(parsing: prepared.text)
            tabs[index].mathTokens = prepared.tokens
            tabs[index].document = document
            tabs[index].outline = Self.outline(for: document, tokens: prepared.tokens)
            tabs[index].index = Self.index(for: document, tokens: prepared.tokens)
            tabs[index].scrollSpans = Self.scrollSpans(for: document, tokens: prepared.tokens)
            tabs[index].plainLines = nil
        }
        tabs[index].previewID = UUID()
        pendingParse[tabID] = nil
    }

    @discardableResult
    func saveCurrent() -> Bool { save(tabID: selectedID) }

    @discardableResult
    func saveAsCurrent() -> Bool { saveAs(tabID: selectedID) }

    private func save(tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        guard let url = tab.url else { return saveAs(tabID: tabID) }
        if !tab.isDirty { return true }
        return write(tabID: tabID, to: url, saveAs: false)
    }

    private func saveAs(tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tab.url?.lastPathComponent ?? "未命名.md"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(tabID: tabID, to: url, saveAs: true)
    }

    private func saveFailure(_ message: String, at index: Int, automatic: Bool) {
        if automatic { tabs[index].autoSaveError = message }
        else { error = message }
    }

    private func write(tabID: UUID, to url: URL, saveAs: Bool, automatic: Bool = false) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let tab = tabs[index]
        if !saveAs && tab.externalConflict {
            saveFailure("文件已在外部修改或无法读取，请使用「另存为…」保留当前草稿。",
                        at: index, automatic: automatic)
            return false
        }
        if !saveAs, let baseline = tab.savedData {
            guard let disk = try? Data(contentsOf: url), disk == baseline else {
                tabs[index].externalConflict = true
                saveFailure("文件已在外部修改或无法读取，当前编辑尚未覆盖磁盘版本。请使用「另存为…」保存副本。",
                            at: index, automatic: automatic)
                return false
            }
        }
        var encoding = tab.encodingName
        var data = Self.encode(tab.source, as: encoding)
        if data == nil && saveAs {
            encoding = "UTF-8"
            data = tab.source.data(using: .utf8)
        }
        guard let data else {
            saveFailure("当前编码无法保存新增字符。请用「另存为…」保存 UTF-8 副本。",
                        at: index, automatic: automatic)
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            tabs[index].url = url
            tabs[index].savedSource = tab.source
            tabs[index].savedData = data
            tabs[index].stamp = Self.stamp(for: url)
            tabs[index].encodingName = encoding
            tabs[index].externalConflict = false
            tabs[index].autoSaveError = nil
            scheduleSessionWrite()
            pendingAutoSave[tabID]?.cancel()
            pendingAutoSave[tabID] = nil
            if pendingParse[tabID] != nil || saveAs {
                pendingParse[tabID]?.cancel()
                publishPreview(for: tabID, revision: tab.editRevision)
            }
            if !automatic { error = nil }
            return true
        } catch {
            saveFailure("无法保存文件：\(url.path)\n\(error.localizedDescription)",
                        at: index, automatic: automatic)
            return false
        }
    }

    private func pollFiles() {
        for tab in tabs {
            guard let url = tab.url, let current = Self.stamp(for: url), current != tab.stamp,
                  pendingRefresh[tab.id] == nil, !tab.externalConflict else { continue }
            pendingRefresh[tab.id] = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                reload(tabID: tab.id)
            }
        }
    }

    private func reload(tabID: UUID) {
        defer { pendingRefresh[tabID] = nil }
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let url = tabs[index].url, let stamp = Self.stamp(for: url),
              let data = try? Data(contentsOf: url),
              let decoded = try? Self.decode(data) else { return }
        if tabs[index].isDirty {
            if sameSourceBytes(decoded.text, tabs[index].source) {
                tabs[index].savedSource = decoded.text
                tabs[index].savedData = data
                tabs[index].stamp = stamp
                tabs[index].externalConflict = false
                tabs[index].autoSaveError = nil
            } else if tabs[index].savedData == data {
                tabs[index].stamp = stamp
            } else {
                tabs[index].externalConflict = true
            }
            return
        }
        if sameSourceBytes(tabs[index].source, decoded.text) {
            tabs[index].stamp = stamp
            tabs[index].savedData = data
            return
        }
        if selectedID == tabID { beforeReload?(tabID) }
        tabs[index] = Self.makeTab(id: tabID, url: url, text: decoded.text,
                                  encoding: decoded.name, stamp: stamp, data: data)
        if selectedID == tabID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.afterReload?(tabID)
            }
        }
    }

    func newTab() {
        let tab = ReaderTab()
        tabs.append(tab)
        selectedID = tab.id
        scheduleSessionWrite()
    }

    private func confirmDiscardChanges(in tabID: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }), tab.isDirty else { return true }
        if let url = tab.url, !tab.externalConflict,
           write(tabID: tabID, to: url, saveAs: false, automatic: true) { return true }
        let alert = NSAlert()
        alert.messageText = "保存对「\(tab.title)」的修改吗？"
        alert.informativeText = "未保存的编辑内容将丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(tabID: tabID)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func confirmCloseAll() -> Bool {
        for tab in tabs where tab.isDirty && tab.url != nil && !tab.externalConflict {
            if let url = tab.url { _ = write(tabID: tab.id, to: url, saveAs: false, automatic: true) }
        }
        return saveSessionNow()
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard confirmDiscardChanges(in: id) else { return }
        pendingParse[id]?.cancel()
        pendingParse[id] = nil
        pendingRefresh[id]?.cancel()
        pendingRefresh[id] = nil
        pendingAutoSave[id]?.cancel()
        pendingAutoSave[id] = nil
        if tabs.count == 1 {
            tabs[0] = ReaderTab()
            selectedID = tabs[0].id
            _ = saveSessionNow()
            return
        }
        tabs.remove(at: index)
        readingBookmarks[id] = nil
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
        _ = saveSessionNow()
    }

    @discardableResult
    func open(_ newURL: URL) -> UUID? {
        guard ["md", "markdown", "mdown", "txt"].contains(newURL.pathExtension.lowercased()) else {
            error = "请选择 Markdown 或纯文本文件。"
            return nil
        }
        let scoped = newURL.startAccessingSecurityScopedResource()
        defer { if scoped { newURL.stopAccessingSecurityScopedResource() } }
        do {
            if let existing = tabs.first(where: { $0.url?.standardizedFileURL == newURL.standardizedFileURL }) {
                selectedID = existing.id
                return existing.id
            }
            let data = try Data(contentsOf: newURL)
            let decoded = try Self.decode(data)
            let tab = Self.makeTab(url: newURL, text: decoded.text, encoding: decoded.name,
                                   stamp: Self.stamp(for: newURL), data: data)
            if let index = tabs.firstIndex(where: { $0.id == selectedID }),
               tabs[index].url == nil, !tabs[index].isDirty {
                tabs[index] = tab
            } else {
                tabs.append(tab)
            }
            selectedID = tab.id
            error = nil
            scheduleSessionWrite()
            return tab.id
        } catch {
            self.error = "无法读取文件：\(newURL.path)\n\(error.localizedDescription)"
            return nil
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls { open(url) }
        }
    }

    func followLink(_ target: URL) {
        if target.isFileURL {
            var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)
            parts?.fragment = nil
            parts?.query = nil
            let file = parts?.url ?? target
            if ["md", "markdown", "mdown", "txt"].contains(file.pathExtension.lowercased()) {
                if let tabID = open(file), let fragment = target.fragment,
                   let tab = tabs.first(where: { $0.id == tabID }) {
                    let label = fragment.removingPercentEncoding ?? fragment
                    if let entry = tab.outline.first(where: { $0.slug == label || $0.title == label }) {
                        navigate(to: entry.id, in: tabID)
                    }
                }
            } else {
                NSWorkspace.shared.open(file)
            }
        } else if ["https", "http", "mailto"].contains(target.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(target)
        }
    }
}

@MainActor
private final class ScrollKeeper {
    weak var scrollView: NSScrollView?
    private var savedY: CGFloat?
    private var savedRatio: CGFloat = 0

    func capture() {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        savedY = clip.bounds.origin.y
        savedRatio = maximum > 0 ? clip.bounds.origin.y / maximum : 0
    }

    func captureIfNeeded() {
        if savedY == nil { capture() }
    }

    func discard() { savedY = nil }

    func restore() {
        guard let scrollView, let oldY = savedY,
              let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let position = oldY <= maximum ? oldY : maximum * savedRatio
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: max(0, position)))
        scrollView.reflectScrolledClipView(clip)
        savedY = nil
    }
}

private final class ScrollResolverView: NSView {
    var onResolve: ((NSScrollView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            var ancestor = self?.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    self?.onResolve?(scroll)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct ScrollResolver: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> ScrollResolverView {
        let view = ScrollResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ view: ScrollResolverView, context: Context) {
        view.onResolve = onResolve
    }
}

private struct PreviewScrollAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func previewScrollAnchor(_ path: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: PreviewScrollAnchorKey.self,
                                   value: [path: geometry.frame(in: .named("previewContent"))])
        })
    }
}

private struct PreviewDocumentContent: View, Equatable {
    let tabID: UUID
    let previewID: UUID
    let lines: [String]?
    let document: Document?
    let fontSize: CGFloat
    let activeSearchPath: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabID == rhs.tabID && lhs.previewID == rhs.previewID
            && lhs.fontSize == rhs.fontSize && lhs.activeSearchPath == rhs.activeSearchPath
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: lines == nil ? 14 : 0) {
            if let lines {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    styledReadingText(line.isEmpty ? " " : line, size: fontSize)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(activeSearchPath == String(index)
                                    ? Color.yellow.opacity(0.16) : Color.clear)
                        .id("document:\(index)")
                        .previewScrollAnchor(String(index))
                }
            } else {
                ForEach(Array((document.map { Array($0.children) } ?? []).enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block, fontSize: fontSize, path: String(index))
                        .background(activeSearchPath == String(index)
                                    ? Color.yellow.opacity(0.16) : Color.clear)
                        .id("document:\(index)")
                }
            }
        }
    }
}

private struct AnimatedReaderLayout<Content: View>: View, Animatable {
    var modeProgress: CGFloat
    var outlineInset: CGFloat
    let content: (CGFloat, CGFloat) -> Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(modeProgress, outlineInset) }
        set { modeProgress = newValue.first; outlineInset = newValue.second }
    }

    var body: some View {
        content(modeProgress, outlineInset)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct DocumentTab: View {
    let title: String
    let isDirty: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onSelect) {
                Text(title + (isDirty ? " ●" : ""))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(isSelected || isHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isSelected || isHovered ? 1 : 0)
            .allowsHitTesting(isSelected || isHovered)
            .accessibilityHidden(!isSelected && !isHovered)
            .help("关闭标签页")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .bottom) {
            if isSelected { Rectangle().frame(height: 2) }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var state: ReaderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollKeeper = ScrollKeeper()
    @State private var scrollSync = ScrollSyncController()
    @FocusState private var searchFocused: Bool
    @State private var animatedOutlineInset: CGFloat = 0
    @State private var outlineBeforeEditing = false
    @State private var editSplitRatio: CGFloat = 0.4
    @State private var editorMounted = false
    @State private var animatedModeProgress: CGFloat = 0
    @State private var modeTransitioning = false
    @State private var modeGeneration = 0
    @State private var pendingModeCommit: Task<Void, Never>?

    private let outlineWidth: CGFloat = 221
    private let outlineDuration = 0.28
    private let modeDuration = 0.28

    private func textWidth(for inset: CGFloat, available width: CGFloat) -> CGFloat {
        min(760, max(1, width - inset - 60))
    }

    private func textX(for inset: CGFloat, available width: CGFloat) -> CGFloat {
        (width - inset - textWidth(for: inset, available: width)) / 2
    }

    private func settleOutline() {
        let target = state.showsOutline ? outlineWidth : 0
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            animatedOutlineInset = target
        }
    }

    private func transitionOutline(to visible: Bool) {
        let target = visible ? outlineWidth : 0
        if reduceMotion {
            settleOutline()
            return
        }
        withAnimation(.easeInOut(duration: outlineDuration)) {
            animatedOutlineInset = target
        }
    }

    private func settleMode() {
        pendingModeCommit?.cancel()
        pendingModeCommit = nil
        modeGeneration += 1
        let editing = state.isEditing
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            editorMounted = editing
            animatedModeProgress = editing ? 1 : 0
            modeTransitioning = false
        }
        scrollSync.isActive = editing
        if !editing { scrollSync.detachSource() }
    }

    private func transitionMode(to editing: Bool) {
        pendingModeCommit?.cancel()
        modeGeneration += 1
        let generation = modeGeneration
        let tabID = state.selectedID
        let target: CGFloat = editing ? 1 : 0
        scrollSync.endDividerResize()
        scrollSync.isActive = false
        modeTransitioning = true
        if editing { editorMounted = true }

        if reduceMotion {
            settleMode()
            let settledGeneration = modeGeneration
            pendingModeCommit = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, modeGeneration == settledGeneration,
                      state.selectedID == tabID else { return }
                state.afterModeChange?()
                pendingModeCommit = nil
            }
            return
        }

        pendingModeCommit = Task { @MainActor in
            await Task.yield() // Mount the source pane before moving it into view.
            guard !Task.isCancelled, modeGeneration == generation else { return }
            withAnimation(.easeInOut(duration: modeDuration)) {
                animatedModeProgress = target
            }
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard !Task.isCancelled, modeGeneration == generation,
                  state.isEditing == editing else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                editorMounted = editing
                modeTransitioning = false
            }
            scrollSync.isActive = editing
            if !editing { scrollSync.detachSource() }
            await Task.yield()
            guard !Task.isCancelled, modeGeneration == generation,
                  state.selectedID == tabID else { return }
            state.afterModeChange?()
            pendingModeCommit = nil
        }
    }

    private func outlineSidebar(onSelect: @escaping (OutlineEntry) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("目录")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if state.currentOutline.isEmpty {
                        Text("此文档没有标题")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                            .padding(14)
                    }
                    ForEach(state.currentOutline) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            Text(entry.title)
                                .font(.system(size: 12, weight: entry.level == 1 ? .medium : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(min(max(entry.level - 1, 0), 4)) * 12)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 220)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("在文档中查找", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { state.moveSearch(by: 1) }
                .onExitCommand { state.isSearching = false }
                .frame(maxWidth: 300)
            Text(state.searchHits.isEmpty ? "0/0" : "\(min(state.searchHitIndex + 1, state.searchHits.count))/\(state.searchHits.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { state.moveSearch(by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .help("上一个匹配")
            Button { state.moveSearch(by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .help("下一个匹配")
            Button { state.isSearching = false; state.searchQuery = "" } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭查找")
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(state.tabs) { tab in
                        DocumentTab(title: tab.title, isDirty: tab.isDirty,
                                    isSelected: state.selectedID == tab.id,
                                    onSelect: { state.selectedID = tab.id },
                                    onClose: { state.closeTab(tab.id) })
                    }
                    Button { state.newTab() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .help("新建标签页 (⌘T)")
                }
            }
            Divider()
            if let url = state.currentURL {
                Text(url.path)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 25)
                Divider()
            }
            if state.isSearching {
                searchBar
                Divider()
            }
            if state.currentTab?.externalConflict == true {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("文件已在外部修改。你的编辑仍在，保存前请先另存为。")
                    Button("另存为…") { state.saveAsCurrent() }
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.orange.opacity(0.12))
            } else if let message = state.currentTab?.autoSaveError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("自动保存失败：\(message)").lineLimit(2).help(message)
                    Button("重试保存") { state.saveCurrent() }
                    Button("另存为…") { state.saveAsCurrent() }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
            }
            if state.currentURL == nil && state.currentTab?.source.isEmpty != false
                && !state.isEditing && !editorMounted {
                VStack(spacing: 14) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("打开 Markdown 文件").font(.title2)
                    Text("按 ⌘O 打开文件，或将 .md 文件拖到窗口中")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AnimatedReaderLayout(modeProgress: animatedModeProgress,
                                     outlineInset: animatedOutlineInset) { modeProgress, outlineInset in
                GeometryReader { splitGeometry in
                let dividerWidth: CGFloat = 14
                let availableWidth = max(1, splitGeometry.size.width - dividerWidth)
                let minimumSource = min(280, availableWidth * 0.45)
                let minimumPreview = min(360, availableWidth * 0.45)
                let sourceWidth = min(max(availableWidth * editSplitRatio, minimumSource),
                                      availableWidth - minimumPreview)
                let modeInset = sourceWidth + dividerWidth
                let visibleSourceWidth = modeProgress * sourceWidth
                let visibleDividerWidth = modeProgress * dividerWidth
                let previewWidth = max(1, splitGeometry.size.width - modeProgress * modeInset)
                let previewTabID = state.selectedID
                HStack(spacing: 0) {
                    if editorMounted, let tabID = state.currentTab?.id {
                        MarkdownSourceEditor(text: state.currentTab?.source ?? "",
                                             onChange: {
                                                 scrollSync.invalidateSource()
                                                 state.updateSource($0, in: tabID)
                                             },
                                             onScrollView: { scrollSync.attachSource($0) },
                                             onTextApplied: { scrollSync.invalidateSource() })
                            .id(tabID)
                            .frame(width: sourceWidth, height: splitGeometry.size.height)
                            .frame(width: visibleSourceWidth, height: splitGeometry.size.height,
                                   alignment: .trailing)
                            .clipped()
                            .allowsHitTesting(state.isEditing && !modeTransitioning)
                            .accessibilityHidden(!state.isEditing || modeTransitioning)

                        SplitHandle(ratio: editSplitRatio,
                                    availableWidth: availableWidth,
                                    minimumRatio: minimumSource / availableWidth,
                                    maximumRatio: 1 - minimumPreview / availableWidth,
                                    active: state.isEditing && !modeTransitioning,
                                    onDragStarted: { scrollSync.beginDividerResize() },
                                    onRatioChanged: { editSplitRatio = $0 },
                                    onDragEnded: {
                                        scrollSync.endDividerResize()
                                        DispatchQueue.main.async { scrollSync.alignSourceToPreview() }
                                    })
                            .frame(width: visibleDividerWidth, height: splitGeometry.size.height)
                            .allowsHitTesting(state.isEditing && !modeTransitioning)
                            .accessibilityHidden(!state.isEditing || modeTransitioning)
                    }
                    ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .topLeading) {
                            ScrollView {
                                PreviewDocumentContent(tabID: state.selectedID,
                                                       previewID: state.currentTab?.previewID ?? state.selectedID,
                                                       lines: state.currentLines,
                                                       document: state.currentDocument,
                                                       fontSize: state.fontSize,
                                                       activeSearchPath: state.activeSearchPath)
                                .equatable()
                                .background(ScrollResolver {
                                    scrollKeeper.scrollView = $0
                                    scrollSync.attachPreview($0, tabID: previewTabID,
                                                             reveal: { proxy.scrollTo("document:\($0)", anchor: .top) },
                                                             onBookmark: { bookmark in
                                        state.recordBookmark(bookmark, in: previewTabID)
                                    })
                                }
                                    .frame(width: 0, height: 0))
                                .frame(width: textWidth(for: outlineInset, available: width), alignment: .leading)
                                .padding(.vertical, 18)
                                .coordinateSpace(name: "previewContent")
                                .textSelection(.enabled)
                                .offset(x: textX(for: outlineInset, available: width))
                                .frame(width: width, alignment: .leading)
                            }
                            .id(state.selectedID)
                            .frame(width: width)
                            .onPreferenceChange(PreviewScrollAnchorKey.self) { anchors in
                                scrollSync.updateAnchors(anchors,
                                                         spans: state.currentTab?.scrollSpans ?? [:])
                            }

                            HStack(spacing: 0) {
                                Divider()
                                outlineSidebar { entry in
                                    scrollSync.navigatePreview(to: entry.id)
                                }
                            }
                            .frame(width: outlineWidth, alignment: .leading)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .offset(x: width - outlineInset)
                            .allowsHitTesting(state.showsOutline)
                            .accessibilityHidden(!state.showsOutline)
                        }
                        .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                        .task(id: state.navigationRequest?.id) {
                            guard let request = state.navigationRequest else { return }
                            await Task.yield()
                            guard request.tabID == state.selectedID else { return }
                            scrollSync.navigatePreview(to: request.path)
                        }
                    }
                    }
                    .frame(width: previewWidth, height: splitGeometry.size.height)
                }
                .frame(width: splitGeometry.size.width, height: splitGeometry.size.height,
                       alignment: .topLeading)
                .clipped()
                }
                }
            }
        }
        .frame(minWidth: state.isEditing ? 880 : 680, minHeight: 420)
        .background(WindowChrome(title: state.currentTab?.title ?? "未命名",
                                 isEditing: state.isEditing,
                                 showsOutline: state.showsOutline,
                                 onMode: { state.toggleMode() },
                                 onOutline: { state.showsOutline.toggle() })
            .frame(width: 0, height: 0))
        .environmentObject(state)
        .environmentObject(state.formulas)
        .quickLookPreview($state.imagePreviewURL)
        .environment(\.openURL, OpenURLAction { target in
            state.followLink(target)
            return .handled
        })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !providers.isEmpty else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { state.open(url) } }
                }
            }
            return true
        }
        .onAppear {
            state.captureCurrentBookmark = { [weak scrollSync] in scrollSync?.currentBookmark() }
            scrollSync.queueRestoration(state.bookmark(for: state.selectedID), for: state.selectedID)
            settleOutline()
            settleMode()
            let keeper = scrollKeeper
            let reader = state
            state.beforeReload = { [weak keeper] _ in keeper?.capture() }
            state.afterReload = { [weak keeper, weak reader] tabID in
                if reader?.selectedID == tabID { keeper?.restore() }
            }
            state.beforeModeChange = { [weak keeper, weak scrollSync] in
                keeper?.captureIfNeeded()
                scrollSync?.capturePreviewPosition()
            }
            state.afterModeChange = { [weak keeper, weak scrollSync] in
                if scrollSync?.restorePreviewPosition() == true {
                    keeper?.discard()
                } else {
                    keeper?.restore()
                    scrollSync?.alignSourceToPreview()
                }
            }
        }
        .onChange(of: state.showsOutline) { transitionOutline(to: $0) }
        .onChange(of: state.isEditing) { editing in
            if editing {
                outlineBeforeEditing = state.showsOutline
                state.showsOutline = false
            } else {
                state.showsOutline = outlineBeforeEditing
            }
            transitionMode(to: editing)
        }
        .onChange(of: state.selectedID) { tabID in
            scrollSync.queueRestoration(state.bookmark(for: tabID), for: tabID)
            settleOutline()
            settleMode()
            scrollSync.endDividerResize()
            let ticket = scrollSync.beginPreviewNavigation()
            scrollSync.updateAnchors([:], spans: state.currentTab?.scrollSpans ?? [:])
            scrollKeeper.discard()
            state.searchHitIndex = 0
            if state.isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard state.selectedID == tabID else { return }
                    scrollSync.completePreviewNavigation(ticket)
                }
            }
        }
        .onChange(of: state.currentTab?.scrollSpans) { lines in
            scrollSync.updateSpans(lines ?? [:])
        }
        .onChange(of: state.currentTab?.previewID) { _ in
            _ = scrollSync.beginPreviewNavigation()
            scrollSync.invalidateSource()
        }
        .onChange(of: reduceMotion) { enabled in
            if enabled && modeTransitioning {
                settleMode()
                DispatchQueue.main.async { state.afterModeChange?() }
            }
        }
        .onChange(of: state.isSearching) { active in
            if active { DispatchQueue.main.async { searchFocused = true } }
        }
        .onChange(of: state.searchQuery) { _ in
            state.searchHitIndex = 0
            if let first = state.searchHits.first { state.navigate(to: first.path) }
        }
        .onDisappear {
            _ = state.saveSessionNow()
            state.captureCurrentBookmark = nil
            pendingModeCommit?.cancel()
            scrollSync.endDividerResize()
            scrollSync.isActive = false
            scrollSync.detachSource()
            state.beforeReload = nil
            state.afterReload = nil
            state.beforeModeChange = nil
            state.afterModeChange = nil
        }
        .alert("操作失败", isPresented: Binding(
            get: { state.error != nil },
            set: { if !$0 { state.error = nil } }
        )) {
            Button("好") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }
}

struct MarkdownBlockView: View {
    @EnvironmentObject private var reader: ReaderState
    @EnvironmentObject private var formulaCache: FormulaCache
    @Environment(\.displayScale) private var displayScale
    let block: Markup
    let fontSize: CGFloat
    let path: String

    private enum ParagraphPart {
        case text([Markup])
        case image(Markdown.Image)
    }

    private func paragraphParts(_ paragraph: Paragraph) -> [ParagraphPart] {
        func hasImage(_ node: Markup) -> Bool {
            node is Markdown.Image || node.children.contains(where: hasImage)
        }
        guard paragraph.children.contains(where: hasImage) else { return [] }
        func split(_ node: Markup) -> [ParagraphPart] {
            if let image = node as? Markdown.Image { return [.image(image)] }
            guard hasImage(node) else { return [.text([node])] }
            var output: [ParagraphPart] = []
            for child in node.children {
                for part in split(child) {
                    if case .text(let children) = part {
                        output.append(.text([node.withUncheckedChildren(children)]))
                    } else { output.append(part) }
                }
            }
            return output
        }
        var result: [ParagraphPart] = []
        var text: [Markup] = []
        func flush() {
            if !text.map({ $0.format() }).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(text))
            }
            text.removeAll()
        }
        for child in paragraph.children {
            for part in split(child) {
                if case .text(let children) = part { text.append(contentsOf: children) }
                else { flush(); result.append(part) }
            }
        }
        flush()
        return result
    }

    private func alternativeText(_ node: Markup) -> String {
        if let text = node as? Markdown.Text { return text.string }
        return node.children.map { alternativeText($0) }.joined()
    }

    private func formulaText(_ content: String, size: CGFloat,
                             strong: Bool, emphasized: Bool, heading: Bool) -> SwiftUI.Text {
        guard content.contains("\u{E000}") else {
            return styledReadingText(content, size: size, strong: strong,
                                     emphasized: emphasized, heading: heading)
        }
        var result = SwiftUI.Text("")
        var remaining = content[...]
        while let range = remaining.range(of: "\u{E000}LM[0-9]+\u{E001}", options: .regularExpression) {
            result = result + styledReadingText(String(remaining[..<range.lowerBound]), size: size,
                                        strong: strong, emphasized: emphasized, heading: heading)
            let marker = String(remaining[range])
            if let token = reader.currentMathTokens[marker] {
                switch formulaCache.result(for: token, fontSize: size, displayScale: displayScale) {
                case .image(let rendered):
                    result = result + SwiftUI.Text(SwiftUI.Image(nsImage: rendered.image).renderingMode(.template))
                        .baselineOffset(rendered.baselineOffset)
                        .accessibilityLabel(token.formula)
                case .pending, .failure:
                    result = result + styledReadingText(token.original, size: size, strong: strong,
                                                emphasized: emphasized, heading: heading)
                }
            } else {
                result = result + styledReadingText(marker, size: size, strong: strong,
                                            emphasized: emphasized, heading: heading)
            }
            remaining = remaining[range.upperBound...]
        }
        result = result + styledReadingText(String(remaining), size: size, strong: strong,
                                    emphasized: emphasized, heading: heading)
        return result
    }

    @ViewBuilder private func displayedFormula(_ token: MathToken) -> some View {
        switch formulaCache.result(for: token, fontSize: fontSize * 1.12, displayScale: displayScale) {
        case .image(let rendered):
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    SwiftUI.Image(nsImage: rendered.image)
                        .renderingMode(.template)
                        .interpolation(.high)
                        .frame(minWidth: geometry.size.width)
                        .accessibilityLabel(token.formula)
                }
            }
            .frame(height: rendered.image.size.height + 10)
            .contextMenu {
                Button("复制公式源码") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token.original, forType: .string)
                }
            }
        case .pending, .failure:
            Text(token.original)
                .font(.system(size: fontSize * 0.9, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func attributedInline(_ node: Markup, size: CGFloat, strong: Bool = false,
                                  emphasized: Bool = false, heading: Bool = false) -> AttributedString {
        if let text = node as? Markdown.Text {
            var result = AttributedString()
            var run = ""
            var runKind: ReadingRun?
            func fragment(_ value: String, kind: ReadingRun) -> AttributedString {
                var part = AttributedString(value)
                part.font = readingFont(for: kind, size: size, strong: strong,
                                        emphasized: emphasized, heading: heading)
                part.baselineOffset = readingBaseline(for: kind, size: size, strong: strong,
                                                      emphasized: emphasized, heading: heading)
                return part
            }
            let characters = Array(text.string)
            for (index, character) in characters.enumerated() {
                let kind = readingRun(for: character, previous: runKind,
                                      next: index + 1 < characters.count ? characters[index + 1] : nil)
                if let previous = runKind, previous != kind {
                    result += fragment(run, kind: previous)
                    run = ""
                }
                run.append(character)
                runKind = kind
            }
            if let kind = runKind { result += fragment(run, kind: kind) }
            return result
        }
        if let code = node as? InlineCode {
            var value = AttributedString(code.code)
            value.font = .system(size: size * 0.9, design: .monospaced)
            return value
        }
        if node is SoftBreak { return AttributedString(" ") }
        if node is LineBreak { return AttributedString("\n") }
        var result = AttributedString()
        for child in node.children {
            result += attributedInline(child, size: size,
                                       strong: strong || node is Strong,
                                       emphasized: emphasized || node is Emphasis,
                                       heading: heading)
        }
        return result
    }

    private func inline(_ node: Markup, size: CGFloat? = nil, strong: Bool = false,
                        emphasized: Bool = false, heading: Bool = false) -> SwiftUI.Text {
        let pointSize = size ?? fontSize
        if let text = node as? Markdown.Text {
            return formulaText(text.string, size: pointSize, strong: strong,
                               emphasized: emphasized, heading: heading)
        }
        if let code = node as? InlineCode {
            return SwiftUI.Text(code.code).font(.system(size: pointSize * 0.9, design: .monospaced))
        }
        if node is SoftBreak { return SwiftUI.Text(" ") }
        if node is LineBreak { return SwiftUI.Text("\n") }
        if node is Strong {
            return node.children.reduce(SwiftUI.Text("")) { $0 + inline($1, size: pointSize, strong: true, emphasized: emphasized, heading: heading) }
        }
        if node is Emphasis {
            return node.children.reduce(SwiftUI.Text("")) { $0 + inline($1, size: pointSize, strong: strong, emphasized: true, heading: heading) }
        }
        if node is Strikethrough {
            return node.children.reduce(SwiftUI.Text("")) { $0 + inline($1, size: pointSize, strong: strong, emphasized: emphasized, heading: heading) }
                .strikethrough()
        }
        var value = SwiftUI.Text("")
        for child in node.children { value = value + inline(child, size: pointSize, strong: strong, emphasized: emphasized, heading: heading) }
        if let link = node as? Markdown.Link, let destination = link.destination {
            var linked = AttributedString()
            for child in link.children {
                linked += attributedInline(child, size: pointSize, strong: strong,
                                           emphasized: emphasized, heading: heading)
            }
            if linked.characters.isEmpty { linked = AttributedString(destination) }
            if let absolute = URL(string: destination), let scheme = absolute.scheme, !scheme.isEmpty {
                linked.link = absolute
            } else if let base = reader.currentURL {
                let beforeFragment = String(destination.split(separator: "#", maxSplits: 1,
                                                              omittingEmptySubsequences: false)[0])
                let rawPath = String(beforeFragment.split(separator: "?", maxSplits: 1,
                                                           omittingEmptySubsequences: false)[0])
                let decodedPath = rawPath.removingPercentEncoding ?? rawPath
                let file = decodedPath.isEmpty ? base
                    : (decodedPath.hasPrefix("/") ? URL(fileURLWithPath: decodedPath)
                       : base.deletingLastPathComponent().appendingPathComponent(decodedPath).standardizedFileURL)
                var target = URLComponents(url: file, resolvingAgainstBaseURL: false)
                let parts = URLComponents(string: destination)
                target?.fragment = parts?.fragment
                target?.query = parts?.query
                linked.link = target?.url ?? file
            }
            linked.foregroundColor = .blue
            return SwiftUI.Text(linked)
        }
        return value
    }

    var body: some View {
        Group {
            if let heading = block as? Heading {
                inline(heading, size: fontSize * (heading.level == 1 ? 1.6 : heading.level == 2 ? 1.5 : 1.25), strong: true, heading: true)
                    .lineSpacing(3)
                    .padding(.top, heading.level == 1 ? 0 : 4)
            } else if let paragraph = block as? Paragraph {
                let parts = paragraphParts(paragraph)
                if parts.contains(where: { if case .image = $0 { return true }; return false }) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            switch part {
                            case .text(let children):
                                children.reduce(SwiftUI.Text("")) { $0 + inline($1) }.lineSpacing(2)
                            case .image(let image):
                                MarkdownImageView(source: image.source ?? "", alternative: alternativeText(image),
                                                  documentURL: reader.currentURL,
                                                  onOpen: { reader.imagePreviewURL = $0 })
                            }
                        }
                    }
                } else if let text = Array(paragraph.children).first as? Markdown.Text,
                   Array(paragraph.children).count == 1,
                   let token = reader.currentMathTokens[text.string], token.display {
                    displayedFormula(token)
                } else {
                    inline(paragraph)
                        .lineSpacing(2)
                        .contextMenu {
                            ForEach(Array(reader.currentMathTokens.values.filter {
                                paragraph.format().contains($0.marker)
                            }.sorted {
                                let content = paragraph.format()
                                return content.range(of: $0.marker)!.lowerBound < content.range(of: $1.marker)!.lowerBound
                            }.enumerated()), id: \.offset) { index, token in
                                Button("复制公式源码 \(index + 1)") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(token.original, forType: .string)
                                }
                            }
                        }
                }
            } else if let list = block as? OrderedList {
                let items = Array(list.children)
                let lastNumber = Int(list.startIndex) + max(items.count - 1, 0)
                let markerWidth = ("\(lastNumber)." as NSString)
                    .size(withAttributes: [.font: systemSerifFont(size: fontSize)]).width
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(list.startIndex) + index).")
                                .font(Font(systemSerifFont(size: fontSize)))
                                .frame(width: markerWidth, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(item.children.enumerated()), id: \.offset) { childIndex, child in
                                    MarkdownBlockView(block: child, fontSize: fontSize,
                                                      path: "\(path).\(index).\(childIndex)")
                                }
                            }
                        }
                        .previewScrollAnchor("\(path).\(index)")
                    }
                }
                .font(.custom("STSongti-SC-Regular", size: fontSize))
            } else if let list = block as? UnorderedList {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(list.children.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("•").frame(width: fontSize * 0.88, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(item.children.enumerated()), id: \.offset) { childIndex, child in
                                    MarkdownBlockView(block: child, fontSize: fontSize,
                                                      path: "\(path).\(index).\(childIndex)")
                                }
                            }
                        }
                        .previewScrollAnchor("\(path).\(index)")
                    }
                }
                .font(.custom("STSongti-SC-Regular", size: fontSize))
            } else if let quote = block as? BlockQuote {
                HStack(alignment: .top, spacing: 15) {
                    Rectangle().fill(.secondary).frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(quote.children.enumerated()), id: \.offset) { index, child in
                            MarkdownBlockView(block: child, fontSize: fontSize,
                                              path: "\(path).\(index)")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } else if let table = block as? Markdown.Table {
                VStack(spacing: 0) {
                    tableRow(Array(table.head.cells), header: true)
                    ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                        tableRow(Array(row.cells), header: false)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if let code = block as? CodeBlock {
                ScrollView(.horizontal) {
                    Text(code.code)
                        .font(.system(size: fontSize * 0.86, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(14)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            } else if block is ThematicBreak {
                Divider()
            } else {
                Text(block.format())
                    .font(.custom("STSongti-SC-Regular", size: fontSize))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("document:\(path)")
        .previewScrollAnchor(path)
    }

    private func tableRow(_ cells: [Markdown.Table.Cell], header: Bool) -> some View {
        let proportions: [CGFloat] = cells.count == 3 ? [0.19, 0.32, 0.49]
            : Array(repeating: 1 / CGFloat(max(cells.count, 1)), count: cells.count)
        return WeightedRowLayout(proportions: proportions) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                inline(cell, size: fontSize * 0.9, strong: header)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 42, alignment: .top)
        .background(header ? Color.primary.opacity(0.05) : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 0.5) }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 0.5) }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 0.5) }
        .overlay {
            GeometryReader { proxy in
                Path { path in
                    var x: CGFloat = 0
                    for fraction in proportions.dropLast() {
                        x += proxy.size.width * fraction
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                }
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            }
        }
    }
}

struct WeightedRowLayout: Layout {
    let proportions: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let requested = proposal.width ?? 760
        let width = requested.isFinite ? max(1, requested) : 760
        let height = subviews.enumerated().map { index, view in
            let columnWidth = index == subviews.count - 1
                ? width * (1 - proportions.dropLast().reduce(0, +))
                : width * proportions[index]
            return view.sizeThatFits(.init(width: columnWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: max(42, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            let width = index == subviews.count - 1 ? bounds.maxX - x : bounds.width * proportions[index]
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: .init(width: width, height: bounds.height))
            x += width
        }
    }
}

@MainActor
final class LightMDAppDelegate: NSObject, NSApplicationDelegate {
    weak var reader: ReaderState?
    private var pendingURLs: [URL] = []
    private var showWindow: (() -> Void)?

    func attach(_ reader: ReaderState, showWindow: @escaping () -> Void) {
        self.reader = reader
        self.showWindow = showWindow
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { reader.open(url) }
        if !urls.isEmpty { showWindow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let reader {
            for url in urls { reader.open(url) }
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        showWindow?()
        application.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            let translations = ["File": "文件", "Edit": "编辑", "View": "显示",
                                "Window": "窗口", "Help": "帮助"]
            for item in NSApp.mainMenu?.items ?? [] {
                if let chinese = translations[item.title] {
                    item.title = chinese
                    item.submenu?.title = chinese
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reader?.confirmCloseAll() == false ? .terminateCancel : .terminateNow
    }
}

private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var reader: ReaderState
    let appDelegate: LightMDAppDelegate

    var body: some View {
        ReaderView(state: reader)
            .onAppear {
                appDelegate.attach(reader, showWindow: { openWindow(id: "main") })
            }
    }
}

@main
struct LightMDApp: App {
    @NSApplicationDelegateAdaptor(LightMDAppDelegate.self) private var appDelegate
    @StateObject private var reader = ReaderState()
    init() { NSWindow.allowsAutomaticWindowTabbing = false }
    var body: some Scene {
        Window("LightMD", id: "main") {
            MainWindowContent(reader: reader, appDelegate: appDelegate)
        }
            .windowStyle(.hiddenTitleBar)
            .windowToolbarStyle(.unifiedCompact)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("新建标签页") { reader.newTab() }
                        .keyboardShortcut("t", modifiers: .command)
                    Button("打开…") { reader.chooseFile() }
                        .keyboardShortcut("o", modifiers: .command)
                }
                CommandGroup(replacing: .saveItem) {
                    Button("保存") { reader.saveCurrent() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("另存为…") { reader.saveAsCurrent() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Divider()
                    Button("关闭标签页") { reader.closeTab(reader.selectedID) }
                        .keyboardShortcut("w", modifiers: .command)
                }
                CommandGroup(replacing: .textEditing) {
                    Button("查找…") { reader.isSearching = true }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("查找下一个") { reader.moveSearch(by: 1) }
                        .keyboardShortcut("g", modifiers: .command)
                    Button("查找上一个") { reader.moveSearch(by: -1) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
                CommandGroup(after: .toolbar) {
                    Button(reader.isEditing ? "阅读模式" : "双栏编辑模式") { reader.toggleMode() }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("显示或隐藏目录") { reader.showsOutline.toggle() }
                        .keyboardShortcut("2", modifiers: .command)
                    Divider()
                    Button("放大字号") { reader.fontSize = min(32, reader.fontSize + 1) }
                        .keyboardShortcut("+", modifiers: .command)
                    Button("缩小字号") { reader.fontSize = max(12, reader.fontSize - 1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("重置字号") { reader.fontSize = 16 }
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
    }
}
