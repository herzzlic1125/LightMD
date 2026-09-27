import Foundation
import CryptoKit

struct ReadingBookmark: Codable, Equatable {
    let path: String
    let fraction: Double
    let atTop: Bool
    let atBottom: Bool
}

struct SavedTab: Codable {
    let path: String?
    let draft: String?
    let baselineSHA256: String?
    let bookmark: ReadingBookmark?
    var externalConflict: Bool? = nil
}

struct SavedSession: Codable {
    let version: Int
    let selectedIndex: Int
    let tabs: [SavedTab]
}

struct SessionStore {
    struct LoadResult {
        let session: SavedSession?
        let error: String?
        let canWrite: Bool
    }

    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0]
        .appendingPathComponent("LightMD", isDirectory: true)
    let url: URL

    init(url: URL = SessionStore.defaultDirectory.appendingPathComponent("session.json")) {
        self.url = url
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadResult(session: nil, error: nil, canWrite: true)
        }
        do {
            let data = try Data(contentsOf: url)
            let session = try JSONDecoder().decode(SavedSession.self, from: data)
            guard session.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return LoadResult(session: session, error: nil, canWrite: true)
        } catch {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("session-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                return LoadResult(session: nil,
                                  error: "上次会话无法读取，原始记录已保存在：\(backup.path)",
                                  canWrite: true)
            } catch {
                return LoadResult(session: nil,
                                  error: "上次会话无法读取，且无法保留原始记录。请检查：\(url.path)",
                                  canWrite: false)
            }
        }
    }

    func save(_ session: SavedSession) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(to: url, options: .atomic)
    }
}
