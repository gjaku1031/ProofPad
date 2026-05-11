import Cocoa
import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - MetalStrokeRenderer (unified baked + live)
//
// 한 페이지 캔버스의 모든 stroke (이미 완료된 baked + 진행 중인 live)를 단일 Metal layer에 그린다.
// CAShapeLayer로 baked를 처리하던 이전 구조에서 발생하던 시각 점프
//   "live(Metal AA) → mouseUp 순간 CAShapeLayer(Quartz AA)로 swap" → 두 rasterizer 차이로 edge 품질이
//   살짝 바뀌는 현상
// 을 제거.
//
// === 데이터 ===
//   bakedBuffer  완료된 모든 stroke의 triangle vertices. 페이지 stroke가 바뀔 때만 재생성 (mouseUp,
//                erase, undo, redo, 페이지 진입, resize, scale 변경).
//   bakedRanges  per-stroke offset/count/color — draw call 당 색이 다르므로 stroke별 분할 draw.
//   liveBuffer   진행 중 stroke. mouseDragged마다 새 점의 segment + cap만 incremental append (O(1)).
//
// === Render ===
//   매 present:
//     1. multisample texture에 clear
//     2. bakedRanges per stroke로 drawPrimitives (색 fragment uniform 변경)
//     3. live stroke 있으면 drawPrimitives
//     4. multisampleResolve → drawable.texture
//     5. presentsWithTransaction=true 패턴 (commit + waitUntilScheduled + drawable.present)
//
// === 큰 함정 ===
//   - setVertexBytes는 4KB 제한이라 stroke 한 두 개만 길어도 크래시. 반드시 MTLBuffer 사용.
//   - presentsWithTransaction=true에서는 cmd.present 대신 drawable.present 직접 호출 필요.
//   - MSAA texture는 drawableSize 바뀌면 재생성 필수.
final class MetalStrokeRenderer {

    /// 공유 device/queue/pipeline. 페이지 수에 비례한 init 비용 회피.
    private let engine: MetalEngine
    var device: MTLDevice { engine.device }
    private var queue: MTLCommandQueue { engine.queue }
    private var pipeline: MTLRenderPipelineState { engine.strokePipeline }
    private var pdfPipeline: MTLRenderPipelineState { engine.pdfPipeline }
    private var pdfSampler: MTLSamplerState { engine.pdfSampler }
    /// 현재 페이지 PDF 비트맵. nil이면 PDF 배경 안 그림 (스트로크만, 투명 배경).
    private var pdfTexture: MTLTexture?

    // MARK: Live stroke (incremental)

    private var liveBuffer: MTLBuffer
    private var liveCapacity: Int
    private var liveCount: Int = 0
    private(set) var liveSamples: [StrokeSample] = []
    var liveSampleCount: Int { liveSamples.count }
    private var liveLastSample: StrokeSample?
    private var liveColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    private var liveActive = false

    // MARK: Baked strokes

    /// per-stroke offset/count/color. drawing 시 stroke별로 color uniform 갈아끼우며 draw call 분할.
    struct BakedRange {
        let start: Int
        let count: Int
        let color: SIMD4<Float>
    }

    /// CPU에서 펼칠 stroke sample — view 좌표 점 + 해당 점의 half-width.
    struct StrokeSample {
        let position: SIMD2<Float>
        let halfWidth: Float
    }

    /// rebuildBaked 호출자가 넘기는 stroke 데이터 — view 좌표 sample + 색.
    /// 페이지 ↔ view 좌표 변환은 호출자 책임 (StrokeCanvasView).
    struct BakedRecipe {
        let samples: [StrokeSample]
        let color: SIMD4<Float>
    }

    private var bakedBuffer: MTLBuffer?
    private var bakedCapacity: Int = 0
    private var bakedRanges: [BakedRange] = []
    /// 현재 bakedBuffer에 들어 있는 vertex 개수. appendBaked가 끝에 추가할 때 시작 offset으로 쓰임.
    /// rebuildBaked는 0으로 reset 후 채워 넣으므로 자동 일관됨.
    private var bakedVertexCount: Int = 0

    // MARK: MSAA / pipeline state

    /// 4x MSAA — Metal triangle edge가 픽셀에 raw aligned되면 계단(jagged) 보임.
    /// multisample texture에 그리고 drawable로 resolve. sample count는 engine과 동일.
    private var sampleCount: Int { engine.sampleCount }
    private var multisampleTexture: MTLTexture?

    private let capSegments = 12   // round cap fan 분할 수

    // MARK: Frame pacing

    /// in-flight frame 제어 — Semaphore로 main 스레드 거치지 않고 GPU 완료 시점에 직접 release.
    ///
    /// 이전 구조(`Int` + `DispatchQueue.main.async { framesInFlight -= 1 }`)는 main이 mouseDragged
    /// 이벤트로 바쁠 때 async decrement가 main runloop 끝까지 대기되어 카운터가 stuck.
    /// 그 사이 event들은 cap에 막혀 present skip → 한참 뒤에 decrement 처리되면 누적된 점이 한 번에 표시
    /// (= 사용자가 보는 "삐걱").
    ///
    /// Semaphore.signal은 Metal queue의 completedHandler 스레드에서 즉시 호출되어 main 점유 무관.
    /// cap=2 (double-buffering) — 한 vsync 사이에 2 frame을 큐잉할 수 있어 흐름이 끊기지 않음.
    private let maxFramesInFlight = 2
    private let inFlightSemaphore = DispatchSemaphore(value: 2)

    /// 마지막 draw 시 viewportPoints — 외부에서 rebuildBaked 시 같은 viewport 기준으로 점 변환 가능.
    private(set) var lastViewportPoints: CGSize = .zero
    private var scaleFactor: Float = 2

    // MARK: - Input prediction
    //
    // 펜 입력 → 화면 표시까지 inherent latency가 macOS/Wacom 환경에서 30~50ms 존재.
    // 마지막 2점의 속도를 extrapolate해 현재 frame에 한 샘플 분량 만큼 앞서 ink를 그린다.
    // 사용자 인식: 잉크가 펜 끝을 LEAD → "딱 따라온다"는 체감.
    //
    // 보수적 strength (1.0 = 한 샘플 거리). 펜 stop / direction change에서 미세한 overshoot 발생 가능하나
    // 다음 mouseDragged에서 즉시 보정되어 1 frame 내 사라짐.
    //
    // 구현: liveBuffer에 안 쓰고 매 draw마다 setVertexBytes로 transient upload — GPU race 회피.
    private static let predictionStrength: Float = 1.0
    private var predictedTailVerts: [SIMD2<Float>] = []

    // MARK: - Synthetic cursor
    //
    // 시스템 NSCursor를 숨겨도 사용자가 "펜 위치"를 시각으로 확인할 수 있도록 Metal pass 안에서
    // 직접 작은 링을 그린다. WindowServer 커서 lag 0 — ink와 완전히 동기.
    //
    // 구현: 마지막 live point에 annulus (도넛). 외부 반지름 ~7pt, 두께 1.5pt.
    // 색은 어두운 회색 50% 알파 — PDF 배경이 무엇이든 잘 보이게.
    private static let cursorOuterRadius: Float = 7.0
    private static let cursorThickness: Float = 1.5
    private static let cursorSegments = 24
    private var cursorVerts: [SIMD2<Float>] = []
    /// 펜 모드에서만 true. 지우개 모드면 시스템 NSCursor가 eraser 모양으로 보이므로 중복 indicator 회피.
    var renderSyntheticCursor: Bool = true

    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    // MARK: - Init

    init?() {
        guard let engine = MetalEngine.shared else { return nil }
        self.engine = engine

        let initialCapacity = 100_000
        guard let buf = engine.device.makeBuffer(
            length: initialCapacity * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ) else { return nil }
        self.liveBuffer = buf
        self.liveCapacity = initialCapacity
    }

    // MARK: - Live stroke API (호출자 = StrokeCanvasView.mouseDown/Dragged/Up)

    func beginLiveStroke(color nsColor: NSColor, scale: CGFloat) {
        liveSamples.removeAll(keepingCapacity: true)
        liveLastSample = nil
        liveCount = 0
        liveActive = true
        let c = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        liveColor = SIMD4<Float>(Float(c.redComponent),
                                 Float(c.greenComponent),
                                 Float(c.blueComponent),
                                 Float(c.alphaComponent))
        scaleFactor = Float(scale)
    }

    func appendLiveSample(_ sample: StrokeSample) {
        let new = normalizedSample(sample)
        liveSamples.append(new)

        // 새로 필요한 vertex: segment(6) + cap(capSegments*3). 첫 점은 cap만.
        var needed = capSegments * 3
        if liveLastSample != nil { needed += 6 }
        ensureLiveCapacity(liveCount + needed)

        let stride = MemoryLayout<SIMD2<Float>>.stride
        let ptr = liveBuffer.contents()
            .advanced(by: liveCount * stride)
            .assumingMemoryBound(to: SIMD2<Float>.self)
        var writeIdx = 0

        // segment from lastPoint → new
        if let prev = liveLastSample {
            writeIdx += writeSegment(from: prev, to: new, ptr: ptr, writeStart: writeIdx)
        }

        // round cap at new — segment join도 메꿔 노치 방지
        writeCap(at: new.position, radius: new.halfWidth, ptr: ptr, writeStart: writeIdx)
        writeIdx += capSegments * 3

        liveCount += writeIdx
        liveLastSample = new
    }

    func endLiveStroke() {
        liveSamples.removeAll(keepingCapacity: true)
        liveLastSample = nil
        liveCount = 0
        liveActive = false
    }

    // MARK: - Baked rebuild API (호출자 = StrokeCanvasView)

    /// 모든 baked stroke geometry를 view 좌표로 펼쳐서 bakedBuffer에 채운다.
    /// erase / undo가 remove로 들어올 때, layout(resize, backing scale 변경) 시 호출.
    /// **새 stroke 1개만 추가될 때는 appendBaked를 써라 — O(N×M) 대신 O(M)이라 grading 누적 무관.**
    func rebuildBaked(_ recipes: [BakedRecipe]) {
        bakedRanges.removeAll(keepingCapacity: true)
        bakedVertexCount = 0
        // 우선 필요한 vertex 수 계산 → 큰 버퍼 한 번에 확보 후 채워 넣기.
        var totalVerts = 0
        for r in recipes {
            totalVerts += capSegments * 3 * r.samples.count       // cap per point
            if r.samples.count >= 2 {
                totalVerts += 6 * (r.samples.count - 1)            // segments
            }
        }
        guard totalVerts > 0 else {
            bakedBuffer = nil
            bakedCapacity = 0
            return
        }
        ensureBakedCapacity(totalVerts)
        guard let buf = bakedBuffer else { return }

        let base = buf.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        var cursor = 0

        for r in recipes {
            let strokeStart = cursor
            writeStrokeGeometry(samples: r.samples,
                                into: base,
                                cursor: &cursor)
            let strokeCount = cursor - strokeStart
            if strokeCount > 0 {
                bakedRanges.append(BakedRange(start: strokeStart,
                                              count: strokeCount,
                                              color: r.color))
            }
        }
        bakedVertexCount = cursor
    }

    /// Stroke 1개만 baked buffer 끝에 append. mouseUp으로 새 stroke 추가 시 사용.
    /// **rebuildBaked는 페이지의 모든 stroke를 다시 펼치므로 stroke 누적될수록 무거워져
    /// 채점 워크플로(한 페이지에 동그라미·X 수십~수백)에서 commit이 점점 느려진다.**
    /// 이 path는 O(stroke의 point 수) — N stroke와 무관.
    func appendBaked(_ recipe: BakedRecipe) {
        var needed = capSegments * 3 * recipe.samples.count
        if recipe.samples.count >= 2 {
            needed += 6 * (recipe.samples.count - 1)
        }
        guard needed > 0 else { return }
        ensureBakedCapacity(bakedVertexCount + needed)
        guard let buf = bakedBuffer else { return }

        let base = buf.contents().assumingMemoryBound(to: SIMD2<Float>.self)
        var cursor = bakedVertexCount
        let strokeStart = cursor
        writeStrokeGeometry(samples: recipe.samples,
                            into: base,
                            cursor: &cursor)
        let strokeCount = cursor - strokeStart
        if strokeCount > 0 {
            bakedRanges.append(BakedRange(start: strokeStart,
                                          count: strokeCount,
                                          color: recipe.color))
        }
        bakedVertexCount = cursor
    }

    /// pageStrokes가 비어있을 때 — bakedBuffer를 비운다.
    func clearBaked() {
        bakedRanges.removeAll(keepingCapacity: true)
        bakedVertexCount = 0
    }

    // MARK: - PDF background API

    /// CGImage를 MTLTexture로 업로드해 PDF 배경으로 사용. PDFBackgroundRasterizer가 호출.
    /// MTKTextureLoader가 origin/포맷 변환 자동 처리 — top-left origin이라 셰이더의 UV mapping과 일치.
    func setPDFTexture(from image: CGImage?) {
        guard let image else {
            pdfTexture = nil
            return
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            .SRGB: NSNumber(value: false)
        ]
        do {
            pdfTexture = try loader.newTexture(cgImage: image, options: options)
        } catch {
            assertionFailure("PDF texture load failed: \(error)")
            pdfTexture = nil
        }
    }

    // MARK: - Drawing

    func draw(in layer: CAMetalLayer, viewportPoints: CGSize) {
        guard viewportPoints.width > 0, viewportPoints.height > 0 else { return }
        // cap 검사 — 즉시 timeout이면 in-flight 가득 → skip. (block 안 함.)
        guard inFlightSemaphore.wait(timeout: .now()) == .success else {
            Signposts.signposter.emitEvent("drawSkip")
            return
        }
        let drawState = Signposts.signposter.beginInterval("draw")
        defer { Signposts.signposter.endInterval("draw", drawState) }
        guard let drawable = layer.nextDrawable() else {
            inFlightSemaphore.signal(); return
        }
        ensureMultisampleTexture(matching: layer.drawableSize)
        guard let msTexture = multisampleTexture else {
            inFlightSemaphore.signal(); return
        }
        guard let cmd = queue.makeCommandBuffer() else {
            inFlightSemaphore.signal(); return
        }

        lastViewportPoints = viewportPoints

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = msTexture
        passDesc.colorAttachments[0].resolveTexture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .multisampleResolve
        // PDF 배경이 모든 pixel 채울 거지만, 첫 layout 전 등 텍스처 없을 때 흰색이 자연스러움.
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) {

            // 0) PDF 배경 — 같은 pass에서 먼저 그려 base가 됨. opaque layer + WindowServer 합성 우회.
            if let tex = pdfTexture {
                encoder.setRenderPipelineState(pdfPipeline)
                encoder.setFragmentTexture(tex, index: 0)
                encoder.setFragmentSamplerState(pdfSampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            // 이후 stroke 파이프라인.
            encoder.setRenderPipelineState(pipeline)
            var uniforms = StrokeUniforms(
                viewportPoints: SIMD2<Float>(Float(viewportPoints.width),
                                              Float(viewportPoints.height)),
                scaleFactor: scaleFactor
            )
            encoder.setVertexBytes(&uniforms,
                                   length: MemoryLayout<StrokeUniforms>.size,
                                   index: 1)

            // 1) baked
            if let buf = bakedBuffer, !bakedRanges.isEmpty {
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                for range in bakedRanges {
                    var col = range.color
                    encoder.setFragmentBytes(&col,
                                             length: MemoryLayout<SIMD4<Float>>.size,
                                             index: 0)
                    encoder.drawPrimitives(type: .triangle,
                                           vertexStart: range.start,
                                           vertexCount: range.count)
                }
            }

            // 2) live (있을 때만)
            if liveCount > 0 {
                encoder.setVertexBuffer(liveBuffer, offset: 0, index: 0)
                var col = liveColor
                encoder.setFragmentBytes(&col,
                                         length: MemoryLayout<SIMD4<Float>>.size,
                                         index: 0)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: 0,
                                       vertexCount: liveCount)

                // 3) predicted tail — 마지막 두 점의 velocity로 한 샘플 앞 위치까지 ink를 확장.
                // 같은 색 fragment uniform 재사용. setVertexBytes로 transient (race-free).
                let predictedCount = buildPredictedTail()
                if predictedCount > 0 {
                    predictedTailVerts.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return }
                        encoder.setVertexBytes(
                            base,
                            length: predictedCount * MemoryLayout<SIMD2<Float>>.stride,
                            index: 0
                        )
                        encoder.drawPrimitives(type: .triangle,
                                               vertexStart: 0,
                                               vertexCount: predictedCount)
                    }
                }

                // 4) synthetic cursor — 펜 모드에서만 (지우개는 시스템 NSCursor가 표시).
                let cursorCount = renderSyntheticCursor ? buildCursorRing() : 0
                if cursorCount > 0 {
                    var cursorColor = SIMD4<Float>(0.15, 0.15, 0.18, 0.55)
                    encoder.setFragmentBytes(
                        &cursorColor,
                        length: MemoryLayout<SIMD4<Float>>.size,
                        index: 0
                    )
                    cursorVerts.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return }
                        encoder.setVertexBytes(
                            base,
                            length: cursorCount * MemoryLayout<SIMD2<Float>>.stride,
                            index: 0
                        )
                        encoder.drawPrimitives(type: .triangle,
                                               vertexStart: 0,
                                               vertexCount: cursorCount)
                    }
                }
            }

            encoder.endEncoding()
        }

        // GPU 완료 시 Metal queue 스레드에서 즉시 semaphore release — main 점유 무관.
        cmd.addCompletedHandler { [weak self] _ in
            Signposts.signposter.emitEvent("gpuDone")
            self?.inFlightSemaphore.signal()
        }
        // presentsWithTransaction=false 표준 패턴 — main 스레드 block 없이 큐잉만.
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Prediction

    /// 마지막 두 livePoint 차이를 velocity로 extrapolate → predicted = last + delta * strength.
    /// segment + cap geometry를 predictedTailVerts에 쓰고 vertex count 반환.
    /// 점이 2개 미만이거나 동일 위치면 0 반환.
    private func buildPredictedTail() -> Int {
        predictedTailVerts.removeAll(keepingCapacity: true)
        guard liveActive, liveSamples.count >= 2 else { return 0 }
        let last = liveSamples[liveSamples.count - 1]
        let prev = liveSamples[liveSamples.count - 2]
        let delta = last.position - prev.position
        let deltaLen = simd_length(delta)
        guard deltaLen > 0.0001 else { return 0 }

        let predictedPosition = last.position + delta * Self.predictionStrength
        let predicted = StrokeSample(position: predictedPosition, halfWidth: last.halfWidth)
        let segDir = predicted.position - last.position
        let segLen = simd_length(segDir)
        guard segLen > 0.0001 else { return 0 }

        predictedTailVerts.reserveCapacity(6 + capSegments * 3)
        // segment last → predicted
        _ = appendSegmentVertices(from: last, to: predicted, into: &predictedTailVerts)
        // round cap at predicted
        let twoPi: Float = .pi * 2
        for i in 0..<capSegments {
            let a0 = twoPi * Float(i) / Float(capSegments)
            let a1 = twoPi * Float(i + 1) / Float(capSegments)
            predictedTailVerts.append(predicted.position)
            predictedTailVerts.append(predicted.position + SIMD2<Float>(cos(a0), sin(a0)) * predicted.halfWidth)
            predictedTailVerts.append(predicted.position + SIMD2<Float>(cos(a1), sin(a1)) * predicted.halfWidth)
        }
        return predictedTailVerts.count
    }

    /// 마지막 live point에 도넛(annulus) geometry를 cursorVerts에 쓰고 vertex count 반환.
    /// 시스템 커서 hide 상태에서 사용자가 펜 위치를 시각으로 확인 가능하게.
    private func buildCursorRing() -> Int {
        cursorVerts.removeAll(keepingCapacity: true)
        guard liveActive, let center = liveSamples.last?.position else { return 0 }
        let R = Self.cursorOuterRadius
        let r = R - Self.cursorThickness
        let N = Self.cursorSegments
        let twoPi: Float = .pi * 2
        cursorVerts.reserveCapacity(N * 6)
        for i in 0..<N {
            let a0 = twoPi * Float(i) / Float(N)
            let a1 = twoPi * Float(i + 1) / Float(N)
            let oi  = center + SIMD2<Float>(cos(a0), sin(a0)) * R
            let oi1 = center + SIMD2<Float>(cos(a1), sin(a1)) * R
            let ii  = center + SIMD2<Float>(cos(a0), sin(a0)) * r
            let ii1 = center + SIMD2<Float>(cos(a1), sin(a1)) * r
            // 두 삼각형으로 한 segment 채움 (outer-inner-outer / outer-inner-inner)
            cursorVerts.append(oi)
            cursorVerts.append(ii)
            cursorVerts.append(oi1)
            cursorVerts.append(oi1)
            cursorVerts.append(ii)
            cursorVerts.append(ii1)
        }
        return cursorVerts.count
    }

    // MARK: - Geometry helpers

    /// stroke 전체 (segments + caps)를 base buffer에 채워 넣는다. cursor를 advance.
    private func writeStrokeGeometry(samples: [StrokeSample],
                                     into base: UnsafeMutablePointer<SIMD2<Float>>,
                                     cursor: inout Int) {
        let normalizedSamples = samples.map(normalizedSample)
        let n = normalizedSamples.count
        guard n >= 1 else { return }

        if n == 1 {
            let sample = normalizedSamples[0]
            writeCap(at: sample.position, radius: sample.halfWidth, ptr: base, writeStart: cursor)
            cursor += capSegments * 3
            return
        }

        for i in 0..<(n - 1) {
            cursor += writeSegment(from: normalizedSamples[i],
                                   to: normalizedSamples[i + 1],
                                   ptr: base,
                                   writeStart: cursor)
        }
        for sample in normalizedSamples {
            writeCap(at: sample.position, radius: sample.halfWidth, ptr: base, writeStart: cursor)
            cursor += capSegments * 3
        }
    }

    @discardableResult
    private func writeSegment(from a: StrokeSample,
                              to b: StrokeSample,
                              ptr: UnsafeMutablePointer<SIMD2<Float>>,
                              writeStart: Int) -> Int {
        let d = b.position - a.position
        let len = simd_length(d)
        guard len >= 0.0001 else { return 0 }
        let dir = d / len
        let normal = SIMD2<Float>(-dir.y, dir.x)
        let aPerp = normal * a.halfWidth
        let bPerp = normal * b.halfWidth
        ptr[writeStart + 0] = a.position + aPerp
        ptr[writeStart + 1] = a.position - aPerp
        ptr[writeStart + 2] = b.position + bPerp
        ptr[writeStart + 3] = a.position - aPerp
        ptr[writeStart + 4] = b.position - bPerp
        ptr[writeStart + 5] = b.position + bPerp
        return 6
    }

    @discardableResult
    private func appendSegmentVertices(from a: StrokeSample,
                                       to b: StrokeSample,
                                       into vertices: inout [SIMD2<Float>]) -> Int {
        let d = b.position - a.position
        let len = simd_length(d)
        guard len >= 0.0001 else { return 0 }
        let dir = d / len
        let normal = SIMD2<Float>(-dir.y, dir.x)
        let aPerp = normal * a.halfWidth
        let bPerp = normal * b.halfWidth
        vertices.append(a.position + aPerp)
        vertices.append(a.position - aPerp)
        vertices.append(b.position + bPerp)
        vertices.append(a.position - aPerp)
        vertices.append(b.position - bPerp)
        vertices.append(b.position + bPerp)
        return 6
    }

    /// round cap (triangle fan을 triangle list로 풀어서) — write start부터 capSegments*3 vertex 채움.
    private func writeCap(at center: SIMD2<Float>,
                          radius: Float,
                          ptr: UnsafeMutablePointer<SIMD2<Float>>,
                          writeStart: Int) {
        let twoPi: Float = .pi * 2
        for i in 0..<capSegments {
            let a0 = twoPi * Float(i) / Float(capSegments)
            let a1 = twoPi * Float(i + 1) / Float(capSegments)
            let v0 = center + SIMD2<Float>(cos(a0), sin(a0)) * radius
            let v1 = center + SIMD2<Float>(cos(a1), sin(a1)) * radius
            ptr[writeStart + i * 3 + 0] = center
            ptr[writeStart + i * 3 + 1] = v0
            ptr[writeStart + i * 3 + 2] = v1
        }
    }

    private func normalizedSample(_ sample: StrokeSample) -> StrokeSample {
        let halfWidth: Float
        if sample.halfWidth.isFinite {
            halfWidth = max(sample.halfWidth, 0.3)
        } else {
            halfWidth = 0.5
        }
        return StrokeSample(position: sample.position, halfWidth: halfWidth)
    }

    // MARK: - Buffer / texture management

    private func ensureLiveCapacity(_ needed: Int) {
        guard needed > liveCapacity else { return }
        let newCap = max(liveCapacity * 2, needed)
        let stride = MemoryLayout<SIMD2<Float>>.stride
        guard let newBuf = device.makeBuffer(length: newCap * stride,
                                             options: .storageModeShared) else { return }
        memcpy(newBuf.contents(), liveBuffer.contents(), liveCount * stride)
        liveBuffer = newBuf
        liveCapacity = newCap
    }

    private func ensureBakedCapacity(_ needed: Int) {
        if let _ = bakedBuffer, needed <= bakedCapacity { return }
        let newCap = max(bakedCapacity * 2, max(needed, 8_192))
        let stride = MemoryLayout<SIMD2<Float>>.stride
        guard let newBuf = device.makeBuffer(length: newCap * stride,
                                             options: .storageModeShared) else { return }
        // appendBaked로 buffer 키울 때 기존 vertex 보존. rebuildBaked는 호출 전 bakedVertexCount=0이라
        // 이 memcpy가 no-op이라 비용 없음.
        if let oldBuf = bakedBuffer, bakedVertexCount > 0 {
            memcpy(newBuf.contents(), oldBuf.contents(), bakedVertexCount * stride)
        }
        bakedBuffer = newBuf
        bakedCapacity = newCap
    }

    /// drawableSize에 맞춰 multisample texture lazy 생성. 크기 바뀌면 재생성.
    private func ensureMultisampleTexture(matching drawableSize: CGSize) {
        let w = Int(drawableSize.width)
        let h = Int(drawableSize.height)
        guard w > 0, h > 0 else { return }
        if let tex = multisampleTexture, tex.width == w, tex.height == h { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.textureType = .type2DMultisample
        desc.sampleCount = sampleCount
        desc.storageMode = .private
        desc.usage = .renderTarget
        multisampleTexture = device.makeTexture(descriptor: desc)
    }
}

private struct StrokeUniforms {
    var viewportPoints: SIMD2<Float>
    var scaleFactor: Float
}
