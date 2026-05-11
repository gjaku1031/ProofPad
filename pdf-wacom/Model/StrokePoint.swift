import Foundation

// PDF 페이지 로컬 좌표(좌하단 원점, 포인트 단위).
// t는 stroke 시작 기준 ms — 필압은 미지원이지만 향후 보간/리플레이/디버그에 유용.
struct StrokePoint: Codable, Equatable {
    var x: Float
    var y: Float
    var t: Float
}
