#import "RmlUi_Renderer_Metal.h"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <simd/simd.h>
#include <RmlUi/Core/Core.h>

// ---- Embedded Metal shader source -----------------------------------------------
// Compiled at runtime via newLibraryWithSource: — avoids Xcode build phase issues.
static NSString* const kRmlUiShaderSource = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 transform;
    float2   translation;
    float2   _padding;
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
    float2 world_pos     = in.position + u.translation;
    out.clip_position    = u.transform * float4(world_pos, 0.0, 1.0);
    out.color            = in.color; // already normalized to [0,1] by the vertex fetch unit
    out.texcoord         = in.texcoord;
    return out;
}

fragment float4 rmlui_fragment_color(VertexOut in [[stage_in]])
{
    return in.color;
}

fragment float4 rmlui_fragment_texture(VertexOut in         [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp         [[sampler(0)]])
{
    return in.color * tex.sample(samp, in.texcoord);
}
)MSL";

// ---- Internal data types --------------------------------------------------------

struct Uniforms {
    simd_float4x4 transform;
    simd_float2   translation;
    simd_float2   _padding;
};

struct MetalGeometry {
    id<MTLBuffer> vertex_buffer;
    id<MTLBuffer> index_buffer;
    NSUInteger    index_count;
};

struct MetalTexture {
    id<MTLTexture> texture;
    int width;
    int height;
};

// ---- Renderer private data -------------------------------------------------------

struct RenderInterface_Metal::Data {
    id<MTLDevice>              device;
    id<MTLCommandQueue>        command_queue;

    id<MTLRenderPipelineState> pipeline_color;    // untextured
    id<MTLRenderPipelineState> pipeline_texture;  // textured
    id<MTLSamplerState>        sampler;

    id<MTLCommandBuffer>          current_command_buffer   = nil;
    id<MTLRenderCommandEncoder>   current_encoder          = nil;

    int viewport_width  = 0;
    int viewport_height = 0;

    bool scissor_enabled = false;
    MTLScissorRect scissor_rect = {0, 0, 1, 1};

    Rml::Matrix4f transform;         // current model transform (identity = nullptr)
    bool has_transform = false;

    Rml::Matrix4f projection;        // orthographic projection, recalculated on viewport change
};

// ---- Helper: build orthographic projection ---------------------------------------
// RmlUi origin is top-left, +Y down. Metal NDC origin is center, +Y up.
// We map pixel coords -> NDC by: x' = 2x/W - 1, y' = 1 - 2y/H
static simd_float4x4 OrthoMatrix(float w, float h)
{
    float sx = 2.0f / w;
    float sy = -2.0f / h;
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0][0] = sx;
    m.columns[1][1] = sy;
    m.columns[3][0] = -1.0f;
    m.columns[3][1] =  1.0f;
    return m;
}

static simd_float4x4 RmlMatrixToSimd(const Rml::Matrix4f& m)
{
    simd_float4x4 result;
    // Rml::Matrix4f is column-major, same as simd
    for (int col = 0; col < 4; ++col)
        for (int row = 0; row < 4; ++row)
            result.columns[col][row] = m[col][row];
    return result;
}

// ---- Build pipeline states -------------------------------------------------------

static id<MTLRenderPipelineState> BuildPipeline(id<MTLDevice> device,
                                                 id<MTLLibrary> library,
                                                 NSString* frag_name,
                                                 MTLPixelFormat pixel_format)
{
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction   = [library newFunctionWithName:@"rmlui_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:frag_name];

    if (!desc.vertexFunction)
        NSLog(@"[RmlUi] Metal: 'rmlui_vertex' not found in library");
    if (!desc.fragmentFunction)
        NSLog(@"[RmlUi] Metal: '%@' not found in library", frag_name);
    if (!desc.vertexFunction || !desc.fragmentFunction)
        return nil;

    // Vertex layout: matches Rml::Vertex (20 bytes per vertex)
    MTLVertexDescriptor* vd = [MTLVertexDescriptor new];
    // attribute 0: float2 position, offset 0
    vd.attributes[0].format      = MTLVertexFormatFloat2;
    vd.attributes[0].offset      = 0;
    vd.attributes[0].bufferIndex = 0;
    // attribute 1: uchar4 color (normalized), offset 8
    vd.attributes[1].format      = MTLVertexFormatUChar4Normalized;
    vd.attributes[1].offset      = 8;
    vd.attributes[1].bufferIndex = 0;
    // attribute 2: float2 texcoord, offset 12
    vd.attributes[2].format      = MTLVertexFormatFloat2;
    vd.attributes[2].offset      = 12;
    vd.attributes[2].bufferIndex = 0;
    // buffer 0: stride 20
    vd.layouts[0].stride         = 20;
    vd.layouts[0].stepFunction   = MTLVertexStepFunctionPerVertex;
    desc.vertexDescriptor = vd;

    // Premultiplied alpha blending
    MTLRenderPipelineColorAttachmentDescriptor* ca = desc.colorAttachments[0];
    ca.pixelFormat                 = pixel_format;
    ca.blendingEnabled             = YES;
    ca.sourceRGBBlendFactor        = MTLBlendFactorOne;
    ca.destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    ca.sourceAlphaBlendFactor      = MTLBlendFactorOne;
    ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    NSError* error = nil;
    id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pso)
        Rml::Log::Message(Rml::Log::LT_ERROR, "Metal pipeline error: %s",
                          error.localizedDescription.UTF8String);
    return pso;
}

// ---- Constructor / Destructor ----------------------------------------------------

RenderInterface_Metal::RenderInterface_Metal(id<MTLDevice> device, MTKView* view)
{
    m_data = new Data();
    m_data->device = device;
    m_data->command_queue = [device newCommandQueue];

    // Compile shaders from embedded source at runtime.
    // This avoids relying on Xcode's "Compile Metal Sources" build phase.
    NSError* error = nil;
    MTLCompileOptions* opts = [MTLCompileOptions new];
    opts.languageVersion = MTLLanguageVersion2_4;
    id<MTLLibrary> library = [device newLibraryWithSource:kRmlUiShaderSource
                                                  options:opts
                                                    error:&error];
    if (!library) {
        NSLog(@"[RmlUi] Metal shader compilation failed: %@",
              error.localizedDescription);
        return;
    }

    MTLPixelFormat fmt = view.colorPixelFormat;
    NSLog(@"[RmlUi] Building Metal pipelines for pixel format %lu", (unsigned long)fmt);
    m_data->pipeline_color   = BuildPipeline(device, library, @"rmlui_fragment_color",   fmt);
    m_data->pipeline_texture = BuildPipeline(device, library, @"rmlui_fragment_texture", fmt);
    NSLog(@"[RmlUi] Pipelines: color=%s texture=%s",
          m_data->pipeline_color   ? "OK" : "FAILED",
          m_data->pipeline_texture ? "OK" : "FAILED");

    // Bilinear sampler
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter    = MTLSamplerMinMagFilterLinear;
    sd.magFilter    = MTLSamplerMinMagFilterLinear;
    sd.mipFilter    = MTLSamplerMipFilterNearest;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    m_data->sampler = [device newSamplerStateWithDescriptor:sd];

    m_data->transform = Rml::Matrix4f::Identity();
}

RenderInterface_Metal::~RenderInterface_Metal()
{
    delete m_data;
}

// ---- Frame control ---------------------------------------------------------------

void RenderInterface_Metal::SetViewport(int width, int height)
{
    if (!m_data) return;
    m_data->viewport_width  = width;
    m_data->viewport_height = height;
    // Reset scissor to full viewport
    m_data->scissor_rect = {0, 0, (NSUInteger)width, (NSUInteger)height};
}

void RenderInterface_Metal::BeginFrame(id<MTLCommandBuffer> command_buffer,
                                        MTLRenderPassDescriptor* pass_descriptor)
{
    if (!m_data) return;
    m_data->current_command_buffer = command_buffer;
    m_data->current_encoder = [command_buffer renderCommandEncoderWithDescriptor:pass_descriptor];

    // Apply full-viewport viewport
    MTLViewport vp = {0, 0,
                      (double)m_data->viewport_width, (double)m_data->viewport_height,
                      0.0, 1.0};
    [m_data->current_encoder setViewport:vp];

    // Disable scissor initially
    m_data->scissor_enabled = false;
    MTLScissorRect full = {0, 0, (NSUInteger)m_data->viewport_width, (NSUInteger)m_data->viewport_height};
    [m_data->current_encoder setScissorRect:full];

    m_data->has_transform = false;
    m_data->transform = Rml::Matrix4f::Identity();
}

void RenderInterface_Metal::EndFrame()
{
    if (!m_data || !m_data->current_encoder) return;
    [m_data->current_encoder endEncoding];
    m_data->current_encoder = nil;
    m_data->current_command_buffer = nil;
}

// ---- Geometry --------------------------------------------------------------------

Rml::CompiledGeometryHandle
RenderInterface_Metal::CompileGeometry(Rml::Span<const Rml::Vertex> vertices,
                                        Rml::Span<const int> indices)
{
    if (!m_data) return 0;

    auto* geo = new MetalGeometry();

    size_t v_size = vertices.size() * sizeof(Rml::Vertex);
    size_t i_size = indices.size() * sizeof(int);

    geo->vertex_buffer = [m_data->device newBufferWithBytes:vertices.data()
                                                      length:v_size
                                                     options:MTLResourceStorageModeShared];
    geo->index_buffer  = [m_data->device newBufferWithBytes:indices.data()
                                                      length:i_size
                                                     options:MTLResourceStorageModeShared];
    geo->index_count   = (NSUInteger)indices.size();

    return reinterpret_cast<Rml::CompiledGeometryHandle>(geo);
}

void RenderInterface_Metal::RenderGeometry(Rml::CompiledGeometryHandle handle,
                                            Rml::Vector2f translation,
                                            Rml::TextureHandle texture)
{
    if (!m_data || !m_data->current_encoder || !handle) return;

    if (!m_data->pipeline_color || !m_data->pipeline_texture) {
        NSLog(@"[RmlUi] RenderGeometry skipped: Metal pipelines not initialized. "
               "Check that RmlUi.metal compiled into the app bundle (default.metallib).");
        return;
    }

    auto* geo = reinterpret_cast<MetalGeometry*>(handle);
    id<MTLRenderCommandEncoder> enc = m_data->current_encoder;

    // Choose pipeline
    bool has_texture = (texture != 0);
    [enc setRenderPipelineState:has_texture ? m_data->pipeline_texture : m_data->pipeline_color];

    // Build uniforms
    Uniforms u;
    simd_float4x4 proj = OrthoMatrix((float)m_data->viewport_width, (float)m_data->viewport_height);
    if (m_data->has_transform) {
        simd_float4x4 model = RmlMatrixToSimd(m_data->transform);
        u.transform = simd_mul(proj, model);
    } else {
        u.transform = proj;
    }
    u.translation = {translation.x, translation.y};
    u._padding    = {0.0f, 0.0f};

    [enc setVertexBuffer:geo->vertex_buffer offset:0 atIndex:0];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];

    if (has_texture) {
        auto* tex = reinterpret_cast<MetalTexture*>(texture);
        [enc setFragmentTexture:tex->texture atIndex:0];
        [enc setFragmentSamplerState:m_data->sampler atIndex:0];
    }

    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                    indexCount:geo->index_count
                     indexType:MTLIndexTypeUInt32
                   indexBuffer:geo->index_buffer
             indexBufferOffset:0];
}

void RenderInterface_Metal::ReleaseGeometry(Rml::CompiledGeometryHandle handle)
{
    if (!handle) return;
    auto* geo = reinterpret_cast<MetalGeometry*>(handle);
    delete geo;
}

// ---- Textures --------------------------------------------------------------------

Rml::TextureHandle RenderInterface_Metal::LoadTexture(Rml::Vector2i& texture_dimensions,
                                                       const Rml::String& source)
{
    if (!m_data) return 0;

    NSString* path = [NSString stringWithUTF8String:source.c_str()];
    UIImage*  image = [UIImage imageNamed:path];
    if (!image) {
        // Try loading from the bundle by path
        image = [UIImage imageWithContentsOfFile:
                 [[NSBundle mainBundle] pathForResource:path ofType:nil]];
    }
    if (!image) return 0;

    CGImageRef cg_image = image.CGImage;
    size_t w = CGImageGetWidth(cg_image);
    size_t h = CGImageGetHeight(cg_image);
    texture_dimensions = {(int)w, (int)h};

    // Render CGImage into an RGBA bitmap
    std::vector<uint8_t> pixels(w * h * 4, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg_image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
    id<MTLTexture> mtl_tex = [m_data->device newTextureWithDescriptor:td];
    [mtl_tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
               mipmapLevel:0
                 withBytes:pixels.data()
               bytesPerRow:w * 4];

    auto* tex = new MetalTexture{mtl_tex, (int)w, (int)h};
    return reinterpret_cast<Rml::TextureHandle>(tex);
}

Rml::TextureHandle RenderInterface_Metal::GenerateTexture(Rml::Span<const Rml::byte> source,
                                                           Rml::Vector2i source_dimensions)
{
    if (!m_data) return 0;

    int w = source_dimensions.x;
    int h = source_dimensions.y;

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:w
                                                                                  height:h
                                                                               mipmapped:NO];
    id<MTLTexture> mtl_tex = [m_data->device newTextureWithDescriptor:td];
    [mtl_tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
               mipmapLevel:0
                 withBytes:source.data()
               bytesPerRow:w * 4];

    auto* tex = new MetalTexture{mtl_tex, w, h};
    return reinterpret_cast<Rml::TextureHandle>(tex);
}

void RenderInterface_Metal::ReleaseTexture(Rml::TextureHandle texture_handle)
{
    if (!texture_handle) return;
    auto* tex = reinterpret_cast<MetalTexture*>(texture_handle);
    delete tex;
}

// ---- Scissor / Clip --------------------------------------------------------------

void RenderInterface_Metal::EnableScissorRegion(bool enable)
{
    if (!m_data || !m_data->current_encoder) return;
    m_data->scissor_enabled = enable;

    if (!enable) {
        MTLScissorRect full = {0, 0, (NSUInteger)m_data->viewport_width, (NSUInteger)m_data->viewport_height};
        [m_data->current_encoder setScissorRect:full];
    } else {
        [m_data->current_encoder setScissorRect:m_data->scissor_rect];
    }
}

void RenderInterface_Metal::SetScissorRegion(Rml::Rectanglei region)
{
    if (!m_data) return;

    // Clamp to viewport bounds to avoid Metal validation errors
    int x = Rml::Math::Max(region.Left(), 0);
    int y = Rml::Math::Max(region.Top(), 0);
    int w = Rml::Math::Max(region.Width(), 0);
    int h = Rml::Math::Max(region.Height(), 0);

    // Clamp right / bottom edges
    w = Rml::Math::Min(x + w, m_data->viewport_width)  - x;
    h = Rml::Math::Min(y + h, m_data->viewport_height) - y;
    if (w <= 0) w = 1;
    if (h <= 0) h = 1;

    m_data->scissor_rect = {(NSUInteger)x, (NSUInteger)y, (NSUInteger)w, (NSUInteger)h};

    if (m_data->scissor_enabled && m_data->current_encoder)
        [m_data->current_encoder setScissorRect:m_data->scissor_rect];
}

// ---- Transform -------------------------------------------------------------------

void RenderInterface_Metal::SetTransform(const Rml::Matrix4f* transform)
{
    if (!m_data) return;
    if (transform) {
        m_data->transform     = *transform;
        m_data->has_transform = true;
    } else {
        m_data->transform     = Rml::Matrix4f::Identity();
        m_data->has_transform = false;
    }
}
