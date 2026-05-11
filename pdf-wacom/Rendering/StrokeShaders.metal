#include <metal_stdlib>
using namespace metal;

// 펜 stroke를 삼각형으로 직접 렌더하는 최소 셰이더.
// CPU에서 각 segment를 quad(2 tri) + endpoint cap(circular fan)로 펼쳐서 vertex로 보낸다.
// fragment는 균일색.

struct StrokeVertex {
    float2 position;   // view 좌표 (포인트 단위, y-up; backing scale은 셰이더가 적용)
};

struct StrokeVOut {
    float4 position [[position]];
};

struct StrokeUniforms {
    float2 viewportPoints;   // 뷰 크기 (포인트)
    float  scaleFactor;      // backing scale (Retina면 2)
};

vertex StrokeVOut stroke_vertex(uint vid [[vertex_id]],
                                constant StrokeVertex *vertices [[buffer(0)]],
                                constant StrokeUniforms &u [[buffer(1)]]) {
    StrokeVOut out;
    float2 p = vertices[vid].position;
    // 포인트 좌표 → NDC (-1..1). NDC y는 bottom-up이고 우리 view도 y-up이므로 flip 불필요.
    float2 clip = (p / u.viewportPoints) * 2.0 - 1.0;
    out.position = float4(clip.x, clip.y, 0.0, 1.0);
    return out;
}

fragment float4 stroke_fragment(constant float4 &color [[buffer(0)]]) {
    return color;
}

// MARK: - PDF background pass (textured full-screen quad)
//
// Strokes를 PDF 위에 직접 그리기 위해 PDF 자체도 같은 Metal pass에서 먼저 그린다.
// 이렇게 하면 metalLiveLayer를 opaque로 만들 수 있고 WindowServer 합성기에서
// "PDF (CALayer) ↔ stroke (CAMetalLayer, alpha)" blend가 사라져 cursor lag / 합성기 backpressure 제거.
//
// CPU 쪽이 6개 vertex_id를 발사하면 quad 2 triangles를 grafx 좌표계 (-1..+1)로 펼쳐 draw.

struct PDFVOut {
    float4 position [[position]];
    float2 uv;
};

vertex PDFVOut pdf_vertex(uint vid [[vertex_id]]) {
    // (NDC x, NDC y), (UV x, UV y) — UV.y는 텍스처 top-left이 view top-left에 오도록 NDC y와 반대.
    const float4 quad[6] = {
        float4(-1.0,  1.0, 0.0, 0.0),  // top-left
        float4( 1.0,  1.0, 1.0, 0.0),  // top-right
        float4(-1.0, -1.0, 0.0, 1.0),  // bottom-left
        float4( 1.0,  1.0, 1.0, 0.0),
        float4( 1.0, -1.0, 1.0, 1.0),  // bottom-right
        float4(-1.0, -1.0, 0.0, 1.0)
    };
    PDFVOut out;
    out.position = float4(quad[vid].xy, 0.0, 1.0);
    out.uv = quad[vid].zw;
    return out;
}

fragment float4 pdf_fragment(PDFVOut in [[stage_in]],
                              texture2d<float> pdfTexture [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    return pdfTexture.sample(s, in.uv);
}
