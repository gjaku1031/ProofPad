import Foundation

// MARK: - InkFeelSettings
//
// 앱 전역 필기감 기본값. 새 stroke를 시작할 때 현재 Snapshot을 Stroke에 복사한다.
// 그래서 사용자가 이후 설정을 바꿔도 이미 저장된 필기의 시각 폭/보정 해석은 안정적으로 유지된다.
final class InkFeelSettings {

    struct Snapshot: Codable, Equatable {
        var stabilization: Double
        var pressureResponse: Double
        var speedThinning: Double
        var pressureStability: Double
        var latencyLead: Double

        static let appDefault = Snapshot(
            stabilization: 0.5,
            pressureResponse: 1.0,
            speedThinning: 1.0,
            pressureStability: 0.65,
            latencyLead: 1.0
        )

        var sanitized: Snapshot {
            Snapshot(
                stabilization: Self.clamp(stabilization, 0...1),
                pressureResponse: Self.clamp(pressureResponse, 0...1.8),
                speedThinning: Self.clamp(speedThinning, 0...1.8),
                pressureStability: Self.clamp(pressureStability, 0...0.9),
                latencyLead: Self.clamp(latencyLead, 0...1.5)
            )
        }

        var pressureAlpha: Double {
            1.0 - sanitized.pressureStability
        }

        static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            guard value.isFinite else { return range.lowerBound }
            return min(max(value, range.lowerBound), range.upperBound)
        }
    }

    static let shared = InkFeelSettings()

    private(set) var current: Snapshot
    var onChange: (() -> Void)?

    private static let defaultsKey = "InkFeelSettings.v1"

    private init() {
        current = Self.loadSnapshot() ?? .appDefault
        current = current.sanitized
    }

    func update(_ snapshot: Snapshot) {
        current = snapshot.sanitized
        save()
        onChange?()
    }

    func resetToAppDefault() {
        update(.appDefault)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
