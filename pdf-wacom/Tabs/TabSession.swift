import Foundation

// 열린 탭들의 URL 목록을 ~/Library/Application Support/pdf-wacom/session.json에 저장.
// 다음 실행 시 AppDelegate가 읽어서 자동 복원.
enum TabSession {

    static let fileName = "session.json"

    private static var sessionURL: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("pdf-wacom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    struct Entry: Codable {
        var url: URL
    }

    struct Snapshot: Codable {
        var entries: [Entry]
    }

    static func save(documents: [NoteDocument]) {
        guard let url = sessionURL else { return }
        let entries = documents.compactMap { doc -> Entry? in
            guard let u = doc.fileURL else { return nil }   // untitled는 복원 대상 아님
            return Entry(url: u)
        }
        let snapshot = Snapshot(entries: entries)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url)
        } catch {
            // best-effort
        }
    }

    static func loadURLs() -> [URL] {
        guard let url = sessionURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return []
        }
        return snapshot.entries.map { $0.url }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
