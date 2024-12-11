// http://www.equasys.de/colorconversion.html - Online article longer exists
#include <metal_stdlib>

using namespace metal;

// Full-range color format used for JPEG images
// RGB to full-range yCbCr color conversion.
constant float3x3 rgb2YCbCrTransform = float3x3(
   float3(+0.2990, -0.1687, +0.5000),       // column 0
   float3(+0.5870, -0.3313, -0.4187),       // column 1
   float3(+0.1140, +0.5000, -0.0813)        // column 2
);

// Reverse conversion
// Full-range yCbCr to RGB color conversion.
constant float3x3 yCbCr2RGBTransform = float3x3(
      float3(+1.0000, +1.000000, +1.0000),
      float3(+0.0000, -0.344136, +1.7720),
      float3(+1.4000, -0.714136,  0.0000)
);

constant float3 kColorOffsets = float3(0.0000, 0.5000, 0.5000);

// Compute kernel - assume normalised colors in the textures.
// Note: colors in Metal shaders are always in linear RGB space.
kernel void
rgb2ycbcrColorConversion(texture2d<half, access::sample> inputTexture [[ texture(0) ]],
                         texture2d<half, access::write>    textureY   [[ texture(1) ]],
                         texture2d<half, access::write>    textureCb  [[ texture(2) ]],
                         texture2d<half, access::write>    textureCr  [[ texture(3) ]],
                         uint2                                gid     [[thread_position_in_grid]])
{
    // Make sure we don't read or write outside of the texture
    if ((gid.x >= inputTexture.get_width()) ||
        (gid.y >= inputTexture.get_height())) {
        return;
    }

    float3 inputColor = float3(inputTexture.read(gid).rgb);

    // Color offsets are added after the matrix multiplication.
    float3 yCbCr = rgb2YCbCrTransform*inputColor + kColorOffsets;

    float  yChannel = yCbCr.r;   // luminance
    float cbChannel = yCbCr.g;   // chrominance blue difference
    float crChannel = yCbCr.b;   // chrominance red difference

    // Create a pseudo color for the chrominance blue difference channel
    float3 onlyCb;
    onlyCb.r = 0.5; onlyCb.g = cbChannel; onlyCb.b = 0.5;
    float3 onlyCr;
    // Create a pseudo color for the chrominance red difference channel
    onlyCr.r = 0.5; onlyCr.g = 0.5; onlyCr.b = crChannel;

    // Convert back to RGB
    // Color offsets are subtracted before the matrix multiplication.
    float3 rgb2 = yCbCr2RGBTransform * (onlyCb - kColorOffsets);
    float3 rgb3 = yCbCr2RGBTransform * (onlyCr - kColorOffsets);

    // Luminance texture - Gray Scale
    textureY.write(half4(half3(yChannel), 1.0), gid);

    if (gid.x % 2 == 0 && gid.y % 2 == 0) {
        textureCb.write(half4(half3(rgb2), 1.0),
                        uint2(gid.x / 2, gid.y / 2));
        textureCr.write(half4(half3(rgb3), 1.0),
                        uint2(gid.x / 2, gid.y / 2));
    }
}

typedef struct {
    float4 clip_pos [[position]];
    float2 uv;
} ScreenFragment;

vertex ScreenFragment
screen_vert(uint vid [[vertex_id]])
{
    // from "Vertex Shader Tricks" by AMD - GDC 2014
    ScreenFragment out;
    out.clip_pos = float4((float)(vid / 2) * 4.0 - 1.0,
                          (float)(vid % 2) * 4.0 - 1.0,
                          0.0,
                          1.0);
    out.uv = float2((float)(vid / 2) * 2.0,
                    1.0 - (float)(vid % 2) * 2.0);
    return out;
}

/*
 The range of uv: [0.0, 1.0]
 The origin of the Metal texture coord system is at the upper-left of the quad.
 */
fragment half4
screen_frag(ScreenFragment  in  [[stage_in]],
            texture2d<half> tex [[texture(0)]])
{
    constexpr sampler textureSampler(mag_filter::linear,
                                     min_filter::linear);

    half4 out_color = tex.sample(textureSampler, in.uv);
    return out_color;
}

