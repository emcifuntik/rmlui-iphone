// RmlUi Metal shaders
// Vertex layout matches Rml::Vertex: float2 position | uchar4 colour | float2 tex_coord (20 bytes)

#include <metal_stdlib>
using namespace metal;

// Uniforms pushed per-draw
struct Uniforms {
    float4x4 transform;   // orthographic projection * model transform
    float2 translation;   // per-draw pixel-space translation
    float2 _padding;
};

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]]; // MTLVertexFormatUChar4Normalized → normalized float4
    float2 texcoord [[attribute(2)]];
};

struct VertexOut {
    float4 clip_position [[position]];
    float4 color;
    float2 texcoord;
};

vertex VertexOut rmlui_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& u [[buffer(1)]])
{
    VertexOut out;
    float2 world_pos = in.position + u.translation;
    out.clip_position = u.transform * float4(world_pos, 0.0, 1.0);
    out.color         = in.color; // already normalized to [0,1] by the vertex fetch unit
    out.texcoord      = in.texcoord;
    return out;
}

// Fragment shader: solid color (untextured geometry)
fragment float4 rmlui_fragment_color(VertexOut in [[stage_in]])
{
    return in.color;
}

// Fragment shader: color * texture (textured geometry)
fragment float4 rmlui_fragment_texture(VertexOut in          [[stage_in]],
                                       texture2d<float> tex  [[texture(0)]],
                                       sampler samp          [[sampler(0)]])
{
    return in.color * tex.sample(samp, in.texcoord);
}
