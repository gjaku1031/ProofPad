import Cocoa
import Metal
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

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // MARK: Live stroke (incremental)

    private var liveBuffer: MTLBuffer
    private var liveCapacity: Int
    private var liveCount: Int = 0
    private(set) var livePoints: [SIMD2<Float>] = []
    private var liveLastPoint: SIMD2<Float>?
    private var liveColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    private var liveHalfWidth: Float = 1
    private var liveActive = false

    // MARK: Baked strokes

    /// per-stroke offset/count/color. drawing 시 stroke별로 color uniform 갈아끼우며 draw call 분할.
    struct BakedRange {
        let start: Int
        let count: Int
        let color: SIMD4<Float>
    }

    /// rebuildBaked 호출자가 넘기는 stroke 데이터 — view 좌표 점 + 색 + 두께.
    /// 페이지 ↔ view 좌표 변환은 호출자 책임 (StrokeCanvasView).
    struct BakedRecipe {
        let points: [SIMD2<Float>]
        let color: SIMD4<Float>
        let halfWidth: Float
    }

    private var bakedBuffer: MTLBuffer?
    private var bakedCapacity: Int = 0
    private var bakedRanges: [BakedRange] = []

    // MARK: MSAA / pipeline state

    /// 4x MSAA — Metal triangle edge가 픽셀에 raw aligned되면 계단(jagged) 보임.
    /// multisample texture에 그리고 drawable로 resolve.
    private let sampleCount = 4
    private var multisampleTexture: MTLTexture?

    private let capSegments = 12   // round cap fan 분할 수

    // MARK: Frame pacing

    /// 동시에 in-flight 가능한 frame 수. cap=1 → 한 vsync에 1 present.
    /// 초과되면 present skip하고 점만 누적 → 다음 present 때 최신 state로 표시.
    private let maxFramesInFlight = 1
    private var framesInFlight = 0

    /// 마지막 draw 시 viewportPoints — 외부에서 rebuildBaked 시 같은 viewport 기준으로 점 변환 가능.
    private(set) var lastViewportPoints: CGSize = .zero
    private var scaleFactor: Float = 2

    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    // MARK: - Init

    init?(pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { return nil }
        self.queue = q

        guard let library = dev.makeDefaultLibrary() else {
            assertionFailure("Default Metal library not found")
            return nil
        }
        guard let vfn = library.makeFunction(name: "stroke_vertex"),
              let ffn = library.makeFunction(name: "stroke_fragment") else {
            assertionFailure("Stroke shader functions not found")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.rasterSampleCount = sampleCount   // MSAA
        // 투명 배경 위에 alpha 합성되어야 PDF 배경(아래 layer)이 비친다.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            assertionFailure("Pipeline create failed: \(error)")
            return nil
        }

        let initialCapacity = 100_000
        guard let buf = dev.makeBuffer(
            length: initialCapacity * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ) else { return nil }
        self.liveBuffer = buf
        self.liveCapacity = initialCapacity
    }

    // MARK: - Live stroke API (호출자 = StrokeCanvasView.mouseDown/Dragged/Up)

    func beginLiveStroke(color nsColor: NSColor, width strokeWidth: CGFloat, scale: CGFloat) {
        livePoints.removeAll(keepingCapacity: true)
        liveLastPoint = nil
        liveCount = 0
        liveActive = true
        let c = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        liveColor = SIMD4<Float>(Float(c.redComponent),
                                 Float(c.greenComponent),
                                 Float(c.blueComponent),
                                 Float(c.alphaComponent))
        liveHalfWidth = Float(max(strokeWidth, 0.5)) * 0.5
        scaleFactor = Float(scale)
    }

    func appendLivePoint(_ p: CGPoint) {
        let new = SIMD2<Float>(Float(p.x), Float(p.y))
        livePoints.append(new)

        // 새로 필요한 vertex: segment(6) + cap(capSegments*3). 첫 점은 cap만.
        var needed = capSegments * 3
        if liveLastPoint != nil { needed += 6 }
        ensureLiveCapacity(liveCount + needed)

        let stride = MemoryLayout<SIMD2<Float>>.stride
        let ptr = liveBuffer.contents()
            .advanced(by: liveCount * stride)
            .assumingMemoryBound(to: SIMD2<Float>.self)
        var writeIdx = 0

        // segment from lastPoint → new
        if let prev = liveLastPoint {
            let d = new - prev
            let len = simd_length(d)
            if len > 0.0001 {
                let dir = d / len
                let perp = SIMD2<Float>(-dir.y, dir.x) * liveHalfWidth
                ptr[writeIdx + 0] = prev + perp
                ptr[writeIdx + 1] = prev - perp
                ptr[writeIdx + 2] = new + perp
                ptr[writeIdx + 3] = prev - perp
                ptr[writeIdx + 4] = new - perp
                ptr[writeIdx + 5] = new + perp
                writeIdx += 6
            }
        }

        // round cap at new — segment join도 메꿔 노치 방지
        writeCap(at: new, radius: liveHalfWidth, ptr: ptr, writeStart: writeIdx)
        writeIdx += capSegments * 3

        liveCount += writeIdx
        liveLastPoint = new
    }

    func endLiveStroke() {
        livePoints.removeAll(keepingCapacity: true)
        liveLastPoint = nil
        liveCount = 0
        liveActive = false
    }

    // MARK: - Baked rebuild API (호출자 = StrokeCanvasView)

    /// 모든 baked stroke geometry를 view 좌표로 펼쳐서 bakedBuffer에 채운다.
    /// stroke 변경(mouseUp, erase, undo, redo) 또는 viewport 변경 시 호출.
    func rebuildBaked(_ recipes: [BakedRecipe]) {
        bakedRanges.removeAll(keepingCapacity: true)
        // 우선 필요한 vertex 수 계산 → 큰 버퍼 한 번에 확보 후 채워 넣기.
        var totalVerts = 0
        for r in recipes {
            totalVerts += capSegments * 3 * r.points.count       // cap per point
            if r.points.count >= 2 {
                totalVerts += 6 * (r.points.count - 1)            // segments
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
            writeStrokeGeometry(points: r.points,
                                halfWidth: r.halfWidth,
                                into: base,
                                cursor: &cursor)
            let strokeCount = cursor - strokeStart
            if strokeCount > 0 {
                bakedRanges.append(BakedRange(start: strokeStart,
                                              count: strokeCount,
                                              color: r.color))
            }
        }
    }

    /// pageStrokes가 비어있을 때 — bakedBuffer를 비운다.
    func clearBaked() {
        bakedRanges.removeAll(keepingCapacity: true)
    }

    // MARK: - Drawing

    func draw(in layer: CAMetalLayer, viewportPoints: CGSize) {
        guard viewportPoints.width > 0, viewportPoints.height > 0 else { return }
        guard framesInFlight < maxFramesInFlight else { return }
        guard let drawable = layer.nextDrawable() else { return }
        ensureMultisampleTexture(matching: layer.drawableSize)
        guard let msTexture = multisampleTexture else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }

        framesInFlight += 1
        lastViewportPoints = viewportPoints

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = msTexture
        passDesc.colorAttachments[0].resolveTexture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .multisampleResolve
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
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
            }

            encoder.endEncoding()
        }

        cmd.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.framesInFlight -= 1
            }
        }
        // presentsWithTransaction=false 표준 패턴 — main 스레드 block 없이 큐잉만.
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Geometry helpers

    /// stroke 전체 (segments + caps)를 base buffer에 채워 넣는다. cursor를 advance.
    private func writeStrokeGeometry(points: [SIMD2<Float>],
                                     halfWidth: Float,
                                     into base: UnsafeMutablePointer<SIMD2<Float>>,
                                     cursor: inout Int) {
        let n = points.count
        guard n >= 1 else { return }

        if n == 1 {
            writeCap(at: points[0], radius: halfWidth, ptr: base, writeStart: cursor)
            cursor += capSegments * 3
            return
        }

        for i in 0..<(n - 1) {
            let a = points[i]
            let b = points[i + 1]
            let d = b - a
            let len = simd_length(d)
            if len < 0.0001 { continue }
            let dir = d / len
            let perp = SIMD2<Float>(-dir.y, dir.x) * halfWidth
            base[cursor + 0] = a + perp
            base[cursor + 1] = a - perp
            base[cursor + 2] = b + perp
            base[cursor + 3] = a - perp
            base[cursor + 4] = b - perp
            base[cursor + 5] = b + perp
            cursor += 6
        }
        for p in points {
            writeCap(at: p, radius: halfWidth, ptr: base, writeStart: cursor)
            cursor += capSegments * 3
        }
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
