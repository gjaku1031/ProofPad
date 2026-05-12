import Foundation
import os.log
import os.signpost

// MARK: - Signposts
//
// Instruments에서 "Points of Interest" track으로 우리 hot path를 시각화하기 위한 helper.
// Profile (⌘I) → Metal System Trace 또는 Time Profiler 템플릿에서 record하면
// 각 interval / event가 timeline에 보임.
//
// Production 빌드에서도 cost는 거의 0 — kernel이 record 활성 안 되어 있으면 즉시 return.
enum Signposts {
    private static let log = OSLog(subsystem: "com.ken.proofpad",
                                   category: .pointsOfInterest)
    static let signposter = OSSignposter(logHandle: log)
}
