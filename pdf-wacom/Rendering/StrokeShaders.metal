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
