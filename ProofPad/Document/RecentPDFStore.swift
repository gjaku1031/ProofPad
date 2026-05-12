import Cocoa

// 홈 화면 Recent는 AppKit recent list에만 의존하지 않고 앱이 직접 관리한다.
// 커스텀 탭 호스트와 세션 복원 흐름에서도 같은 규칙으로 20개를 유지하기 위함.
final class RecentPDFStore {
    static let shared = RecentPDFStore()
    static let didChangeNotification = Notification.Name("RecentPDFStore.didChangeNotification")
    static let maxCount = 20

    private static let defaultsKey = "RecentPDFStore.urls.v1"

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let mirrorsToSystemRecents: Bool
    private let systemRecentURLsProvider: () -> [URL]

    init(defaults: UserDefaults = .standard,
         defaultsKey: String = RecentPDFStore.defaultsKey,
         mirrorsToSystemRecents: Bool = true,
         systemRecentURLsProvider: @escaping () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.mirrorsToSystemRecents = mirrorsToSystemRecents
        self.systemRecentURLsProvider = systemRecentURLsProvider
    }

    func noteOpened(_ url: URL) {
        let normalizedURL = Self.normalizedPDFURL(url)
        guard let normalizedURL else { return }

        var urls = loadStoredURLs()
        let key = Self.dedupeKey(for: normalizedURL)
        urls.removeAll { Self.dedupeKey(for: $0) == key }
        urls.insert(normalizedURL, at: 0)
        save(Self.trimmed(Self.uniquePDFURLs(urls)))

        if mirrorsToSystemRecents {
            NSDocumentController.shared.noteNewRecentDocumentURL(normalizedURL)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func recentURLs(includeSystemRecents: Bool = true) -> [URL] {
        var urls = loadStoredURLs()
        if includeSystemRecents {
            urls.append(contentsOf: systemRecentURLsProvider())
        }
        return Self.trimmed(Self.existingURLs(Self.uniquePDFURLs(urls)))
    }

    private func loadStoredURLs() -> [URL] {
        guard let data = defaults.data(forKey: defaultsKey),
              let urls = try? JSONDecoder().decode([URL].self, from: data) else {
            return []
        }
        return Self.existingURLs(urls.compactMap(Self.normalizedPDFURL))
    }

    private func save(_ urls: [URL]) {
        guard let data = try? JSONEncoder().encode(urls) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func normalizedPDFURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return nil }
        return url.standardizedFileURL
    }

    private static func uniquePDFURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            guard let normalized = normalizedPDFURL(url) else { continue }
            let key = dedupeKey(for: normalized)
            guard seen.insert(key).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func trimmed(_ urls: [URL]) -> [URL] {
        Array(urls.prefix(maxCount))
    }

    private static func existingURLs(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func dedupeKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
