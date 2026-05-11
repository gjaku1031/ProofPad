import Foundation

struct NoteManifest: Codable, Equatable {
    var formatVersion: Int
    var createdAt: Date
    var modifiedAt: Date
    var pageCount: Int
    var coverIsSinglePage: Bool
    var pagesPerSpread: Int?   // optional → 구버전 파일 호환 (없으면 2로 해석)

    static let currentFormatVersion = 1

    var effectivePagesPerSpread: Int {
        let v = pagesPerSpread ?? 2
        return v == 1 ? 1 : 2
    }

    static func newDefault(pageCount: Int) -> NoteManifest {
        let now = Date()
        return NoteManifest(
            formatVersion: currentFormatVersion,
            createdAt: now,
            modifiedAt: now,
            pageCount: pageCount,
            coverIsSinglePage: false,
            pagesPerSpread: 2
        )
    }
}
