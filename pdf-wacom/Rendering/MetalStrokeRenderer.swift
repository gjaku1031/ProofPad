import Cocoa
import Metal
import QuartzCore
import simd

// 진행중(live) stroke 전용 Metal 렌더러 — incremental geometry.
//
// 새 점이 들어올 때마다 그 점의 segment + cap만 vertex buffer 끝에 append하고
// vertexCount만 증가. 전체 재생성하지 않는다 — per-event 작업 O(1).
//
// 큰 함정: setVertexBytes는 4KB 제한이라 stroke가 조금만 길어져도 크래시.
// 반드시 MTLBuffer를 직접 관리해야 함.
final class MetalStrokeRenderer {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // 누적 vertex buffer (storageModeShared — CPU가 직접 쓰고 GPU가 읽음).
    private var vertexBuffer: MTLBuffer
    private var vertexCapacity: Int     // vertex 단위
    private var vertexCount: Int = 0    // 현재 채워진 vertex 수

    // 진행중 stroke 상태
    private(set) var points: [SIMD2<Float>] = []
    private var lastPoint: SIMD2<Float>?
    private var color: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    private var width: Float = 2
    private var halfWidth: Float = 1
    private var scaleFactor: Float = 2

    private let capSegments = 12   // round cap fan 분할 수

    // 동시에 in-flight 가능한 frame 수.
    //
    // cap = 1로 둠 — display는 60Hz라 한 refresh마다 한 번 present되면 충분.
    // 더 많이 queue하면 LAST 점이 디스플레이까지 닿는 latency가 그만큼 늘어남
    //   (cap=2: 최악 33ms, cap=1: 최악 16ms)
    //
    // 이 cap을 초과하면 present skip하고 점은 vertex buffer에 그대로 누적된다.
    // 다음 present 시 누적된 모든 점이 한 번에 그려짐 — 점은 절대 소실되지 않고
    // 단지 화면 표시 frequency만 throttle된다.
    //
    // 메인 스레드가 nextDrawable() 호출에서 stall되어 글씨가 끊겨 보이는 것을 방지하는 것이 목적.
    private let maxFramesInFlight = 1
    private var framesInFlight = 0

    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

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

        // 초기 vertex 용량: 약 1M point 정도까지는 grow 없이 (점당 ~42 vertex).
        let initialVertexCapacity = 100_000
        guard let buf = dev.makeBuffer(
            length: initialVertexCapacity * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ) else { return nil }
        self.vertexBuffer = buf
        self.vertexCapacity = initialVertexCapacity
    }

    // MARK: - Stroke state

    func beginStroke(color nsColor: NSColor, width strokeWidth: CGFloat, scale: CGFloat) {
        points.removeAll(keepingCapacity: true)
        lastPoint = nil
        vertexCount = 0
        let c = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        self.color = SIMD4<Float>(Float(c.redComponent),
                                  Float(c.greenComponent),
                                  Float(c.blueComponent),
                                  Float(c.alphaComponent))
        self.width = Float(max(strokeWidth, 0.5))
        self.halfWidth = self.width * 0.5
        self.scaleFactor = Float(scale)
    }

    func appendPoint(_ p: CGPoint) {
        let new = SIMD2<Float>(Float(p.x), Float(p.y))
        points.append(new)

        // 새로 필요한 vertex 수: segment(6) + cap(capSegments*3). 첫 점은 cap만.
        var needed = capSegments * 3
        if lastPoint != nil { needed += 6 }
        ensureCapacity(vertexCount + needed)

        let stride = MemoryLayout<SIMD2<Float>>.stride
        let ptr = vertexBuffer.contents()
            .advanced(by: vertexCount * stride)
            .assumingMemoryBound(to: SIMD2<Float>.self)
        var writeIdx = 0

        // segment from lastPoint → new
        if let prev = lastPoint {
            let d = new - prev
            let len = simd_length(d)
            if len > 0.0001 {
                let dir = d / len
                let perp = SIMD2<Float>(-dir.y, dir.x) * halfWidth
                ptr[writeIdx + 0] = prev + perp
                ptr[writeIdx + 1] = prev - perp
                ptr[writeIdx + 2] = new + perp
                ptr[writeIdx + 3] = prev - perp
                ptr[writeIdx + 4] = new - perp
                ptr[writeIdx + 5] = new + perp
                writeIdx += 6
            }
        }

        // cap at new (round) — segment join도 메꿔 노치 방지
        let twoPi: Float = .pi * 2
        for i in 0..<capSegments {
            let a0 = twoPi * Float(i) / Float(capSegments)
            let a1 = twoPi * Float(i + 1) / Float(capSegments)
            let v0 = new + SIMD2<Float>(cos(a0), sin(a0)) * halfWidth
            let v1 = new + SIMD2<Float>(cos(a1), sin(a1)) * halfWidth
            ptr[writeIdx + 0] = new
            ptr[writeIdx + 1] = v0
            ptr[writeIdx + 2] = v1
            writeIdx += 3
        }

        vertexCount += writeIdx
        lastPoint = new
    }

    func clear() {
        points.removeAll(keepingCapacity: true)
        lastPoint = nil
        vertexCount = 0
    }

    private func ensureCapacity(_ needed: Int) {
        guard needed > vertexCapacity else { return }
        let newCap = max(vertexCapacity * 2, needed)
        let stride = MemoryLayout<SIMD2<Float>>.stride
        guard let newBuf = device.makeBuffer(length: newCap * stride,
                                             options: .storageModeShared) else { return }
        // 기존 데이터 복사
        memcpy(newBuf.contents(), vertexBuffer.contents(), vertexCount * stride)
        vertexBuffer = newBuf
        vertexCapacity = newCap
    }

    // MARK: - Drawing

    func draw(in layer: CAMetalLayer, viewportPoints: CGSize) {
        guard viewportPoints.width > 0, viewportPoints.height > 0 else { return }
        // in-flight 가 가득 차 있으면 present skip — 점은 vertex buffer에 이미 쓰였으므로
        // 다음 이벤트의 present에서 누적 결과로 표시된다.
        guard framesInFlight < maxFramesInFlight else { return }
        guard let drawable = layer.nextDrawable() else { return }
        guard let cmd = queue.makeCommandBuffer() else { return }

        framesInFlight += 1

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: passDesc) {
            if vertexCount > 0 {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                var uniforms = StrokeUniforms(
                    viewportPoints: SIMD2<Float>(Float(viewportPoints.width),
                                                  Float(viewportPoints.height)),
                    scaleFactor: scaleFactor
                )
                encoder.setVertexBytes(&uniforms,
                                       length: MemoryLayout<StrokeUniforms>.size,
                                       index: 1)
                var col = color
                encoder.setFragmentBytes(&col,
                                         length: MemoryLayout<SIMD4<Float>>.size,
                                         index: 0)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: 0,
                                       vertexCount: vertexCount)
            }
            encoder.endEncoding()
        }

        cmd.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.framesInFlight -= 1
            }
        }
        cmd.present(drawable)
        cmd.commit()
    }
}

private struct StrokeUniforms {
    var viewportPoints: SIMD2<Float>
    var scaleFactor: Float
}
