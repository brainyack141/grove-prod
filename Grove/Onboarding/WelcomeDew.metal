#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// A convex water lens with a smooth interior and steep refracting rim.
// Sampling the actual scene preserves botanical detail instead of faking blur.
[[ stitchable ]] half4 groveDewLens(float2 position, SwiftUI::Layer layer,
                                   float2 center, float radius, float dark) {
    float2 delta = position - center;
    float r = length(delta) / radius;
    half4 original = layer.sample(position);

    // A soft contact shadow anchors the glass without a rectangular backing.
    float shadow = exp(-pow((length(delta - float2(0, 7)) - radius) / 9.0, 2.0));
    original.rgb *= half(1.0 - shadow * (dark > 0.5 ? 0.10 : 0.09));
    if (r >= 1.0) return original;

    float2 normal = delta / max(length(delta), 0.001);
    float rim = smoothstep(0.68, 1.0, r);
    float magnification = 0.20 * (1.0 - r * r);
    float2 samplePosition = position - delta * magnification - normal * rim * radius * 0.12;
    half4 refracted = layer.sample(samplePosition);
    // Thin neutral body; the transmitted greens remain the only accent.
    half3 tint = dark > 0.5 ? half3(0.27, 0.31, 0.25) : half3(0.98, 0.99, 0.96);
    refracted.rgb = mix(refracted.rgb, tint, half(0.12 + rim * 0.10));

    float edge = smoothstep(0.93, 0.982, r) * (1.0 - smoothstep(0.982, 1.0, r));
    float lighting = dot(normal, normalize(float2(-0.65, -0.76)));
    float highlight = edge * (0.22 + 0.68 * pow(abs(lighting), 5.0));
    refracted.rgb = mix(refracted.rgb, half3(1), half(highlight));
    float innerRim = exp(-pow((r - 0.91) / 0.035, 2.0));
    refracted.rgb *= half(1.0 - innerRim * 0.12 * max(0.0, -lighting));
    float face = exp(-dot((delta / radius - float2(-0.32, -0.55)) * float2(2.0, 5.0),
                          (delta / radius - float2(-0.32, -0.55)) * float2(2.0, 5.0)));
    refracted.rgb = mix(refracted.rgb, half3(1), half(face * 0.18));
    return mix(original, refracted, half(1.0 - smoothstep(0.994, 1.0, r)));
}
