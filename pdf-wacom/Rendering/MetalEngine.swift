import Cocoa
import Metal

// MARK: - MetalEngine (shared)
//
// 앱 전체에서 1개 인스턴스. PDF 페이지마다 MetalStrokeRenderer가 만들어지는데,
// 그때 매번 device/queue/pipeline/sampler를 새로 만들면 페이지 수에 비례해 startup 비용 증가
// (30페이지 → 60개 pipeline state 컴파일 + 30개 command queue).
//
// 이걸 모두 1개로 공유. renderer는 이 instance를 참조하기만 하고, 자기는 per-page state(buffer/texture)만 유지.
//
// 효과:
//   - pipeline 컴파일 비용 30x → 1x (앱 launch / PDF 열기 빠르게)
//   - 메모리 절감 (queue + pipeline + sampler 중복 제거)
//   - Metal driver 입장에서도 같은 pipeline 재사용 — encoder switch cost 0.
final class MetalEngine {
    static let shared: MetalEngine? = MetalEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    /// Stroke segment + cap geometry용. blend on, MSAA.
    let strokePipeline: MTLRenderPipelineState
    /// PDF full-screen quad용. blend off, MSAA (per-sample shading 안 함).
    let pdfPipeline: MTLRenderPipelineState
    let pdfSampler: MTLSamplerState

    /// 4× MSAA — 모든 renderer가 동일 sample count 사용 (pipeline 호환).
    let sampleCount: Int = 4

    private init?(pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = dev
        guard let q = dev.makeCommandQueue() else { return nil }
        self.queue = q

        guard let library = dev.makeDefaultLibrary() else {
            assertionFailure("Default Metal library not found")
            return nil
        }
        guard let vfn = library.makeFunction(name: "stroke_vertex"),
              let ffn = library.makeFunction(name: "stroke_fragment"),
              let pdfV = library.makeFunction(name: "pdf_vertex"),
              let pdfF = library.makeFunction(name: "pdf_fragment") else {
            assertionFailure("Stroke shader functions not found")
            return nil
        }

        // Stroke pipeline — alpha blending on (live stroke가 PDF 위에 합성).
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.rasterSampleCount = sampleCount
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.strokePipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            assertionFailure("Stroke pipeline create failed: \(error)")
            return nil
        }

        // PDF pipeline — opaque base, blend off.
        let pdfDesc = MTLRenderPipelineDescriptor()
        pdfDesc.vertexFunction = pdfV
        pdfDesc.fragmentFunction = pdfF
        pdfDesc.colorAttachments[0].pixelFormat = pixelFormat
        pdfDesc.rasterSampleCount = sampleCount
        pdfDesc.colorAttachments[0].isBlendingEnabled = false
        do {
            self.pdfPipeline = try dev.makeRenderPipelineState(descriptor: pdfDesc)
        } catch {
            assertionFailure("PDF pipeline create failed: \(error)")
            return nil
        }

        let sDesc = MTLSamplerDescriptor()
        sDesc.minFilter = .linear
        sDesc.magFilter = .linear
        sDesc.mipFilter = .notMipmapped
        sDesc.sAddressMode = .clampToEdge
        sDesc.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sDesc) else {
            assertionFailure("Sampler create failed")
            return nil
        }
        self.pdfSampler = smp
    }
}
