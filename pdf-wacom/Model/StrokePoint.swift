import Foundation

// PDF 페이지 로컬 좌표(좌하단 원점, 포인트 단위).
// t는 stroke 시작 기준 ms. pressure는 0...1 정규화 필압이며, 미지원 입력은 defaultPressure를 쓴다.
struct StrokePoint: Codable, Equatable {
    static let defaultPressure: Float = 0.65

    var x: Float
    var y: Float
    var t: Float
    var pressure: Float

    init(x: Float, y: Float, t: Float, pressure: Float = Self.defaultPressure) {
        self.x = x
        self.y = y
        self.t = t
        self.pressure = Self.clampedPressure(pressure)
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, t, pressure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Float.self, forKey: .x)
        y = try container.decode(Float.self, forKey: .y)
        t = try container.decode(Float.self, forKey: .t)
        let decodedPressure = try container.decodeIfPresent(Float.self, forKey: .pressure)
        pressure = Self.clampedPressure(decodedPressure ?? Self.defaultPressure)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(t, forKey: .t)
        try container.encode(pressure, forKey: .pressure)
    }

    private static func clampedPressure(_ pressure: Float) -> Float {
        guard pressure.isFinite else { return defaultPressure }
        return min(max(pressure, 0), 1)
    }
}
