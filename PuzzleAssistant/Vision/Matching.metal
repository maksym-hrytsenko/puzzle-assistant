#include <metal_stdlib>
using namespace metal;

struct MatchParams {
    uint pixelCount;      // masked template pixels
    uint originX;         // reference position of output element (0, 0)
    uint originY;
    uint outWidth;
    uint outHeight;
    float sumT2;          // Σ over pixels and channels of (T - mean T)²
    float meanL;
    float meanA;
    float meanB;
    float colorWeight;
};

/// sRGB (8-bit, not linearized by the sampler) -> Lab in OpenCV's 8-bit convention.
kernel void rgbToLab(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<half, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float3 c = src.read(gid).rgb;
    float3 lin = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    float x = (0.412453 * lin.r + 0.357580 * lin.g + 0.180423 * lin.b) / 0.950456;
    float y = 0.212671 * lin.r + 0.715160 * lin.g + 0.072169 * lin.b;
    float z = (0.019334 * lin.r + 0.119193 * lin.g + 0.950227 * lin.b) / 1.088754;
    float3 t = float3(x, y, z);
    float3 f = select(7.787 * t + 16.0 / 116.0, pow(t, 1.0 / 3.0), t > 0.008856);
    float l = y > 0.008856 ? 116.0 * f.y - 16.0 : 903.3 * y;
    float3 lab = float3(l * 255.0 / 100.0, 500.0 * (f.x - f.y) + 128.0, 200.0 * (f.y - f.z) + 128.0);
    dst.write(half4(half3(lab), 1.0h), gid);
}

/// Masked normalized cross-correlation of a piece template against every
/// position of the reference, minus a penalty for the mean colour difference
/// (NCC alone ignores the overall hue).
kernel void maskedMatch(texture2d<half, access::read> ref [[texture(0)]],
                        device const float4 *values [[buffer(0)]],   // xyz = T - mean T
                        device const ushort2 *offsets [[buffer(1)]], // pixel position in the template
                        constant MatchParams &p [[buffer(2)]],
                        device float *out [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.outWidth || gid.y >= p.outHeight) return;
    uint2 base = uint2(p.originX + gid.x, p.originY + gid.y);
    float3 sumI = 0.0;
    float3 sumI2 = 0.0;
    float sumTI = 0.0;
    for (uint i = 0; i < p.pixelCount; i++) {
        float3 v = float3(ref.read(base + uint2(offsets[i])).xyz);
        sumI += v;
        sumI2 += v * v;
        sumTI += dot(values[i].xyz, v);
    }
    float n = float(p.pixelCount);
    float3 variance = sumI2 - sumI * sumI / n;
    float varI = max(variance.x + variance.y + variance.z, 1e-3);
    float ncc = sumTI / sqrt(max(p.sumT2 * varI, 1e-6));
    float3 diff = (sumI / n - float3(p.meanL, p.meanA, p.meanB)) * float3(0.5, 1.0, 1.0);
    out[gid.y * p.outWidth + gid.x] = ncc - p.colorWeight * length(diff);
}
