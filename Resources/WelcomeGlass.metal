#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Original bounded lens over an opaque decorative Canvas. Coordinates are in points.
[[ stitchable ]] half4 zhihuiWelcomeGlass(float2 position, SwiftUI::Layer layer,
                                        float2 viewport, float2 center, float radius,
                                        float time, float force, float night) {
    half4 original = layer.sample(position);
    float2 q = (position - center) / max(radius, 1.0f);
    float distance = length(q);
    if (distance > 1.025f) { return original; }

    float edge = smoothstep(0.50f, 0.98f, distance);
    float depth = sqrt(max(0.001f, 1.0f - distance * distance));
    float thickness = min(32.0f, radius * 0.15f);
    float2 displacement = -q * thickness * (0.62f * depth + 0.30f * edge);
    displacement += float2(sin(time * 0.75f + q.y * 3.0f), cos(time * 0.63f + q.x * 3.0f))
                    * (1.4f * force * max(0.0f, 1.0f - distance * distance));
    displacement = clamp(displacement, float2(-38.0f), float2(38.0f));
    float2 split = q * edge * (0.70f + 0.70f * clamp(force, 0.0f, 1.0f));
    float2 sampling = position + displacement;
    float2 lower = float2(0.5f);
    float2 upper = max(lower, viewport - 0.5f);
    half4 red = layer.sample(clamp(sampling + split, lower, upper));
    half4 green = layer.sample(clamp(sampling, lower, upper));
    half4 blue = layer.sample(clamp(sampling - split, lower, upper));
    float alpha = float(green.a);
    float3 color = float3(red.r, green.g, blue.b);

    float3 normal = normalize(float3(q, depth));
    float gloss = pow(max(0.0f, dot(normal, normalize(float3(-0.45f, -0.65f, 0.68f)))), 28.0f);
    float rim = exp(-pow((distance - 0.970f) * 70.0f, 2.0f));
    float fresnel = pow(1.0f - depth, 3.0f);
    float shade = smoothstep(0.25f, 0.97f, distance) * max(0.0f, q.y) * 0.07f;
    color *= 1.0f - shade;
    color += alpha * (float3(0.20f, 0.39f, 0.67f) * fresnel * 0.035f
                       + float3(1.0f) * (gloss * 0.30f + rim * mix(0.22f, 0.36f, night)));
    half4 lens = half4(half3(clamp(color, float3(0.0f), float3(alpha))), half(alpha));
    float coverage = 1.0f - smoothstep(0.990f, 1.008f, distance);
    return mix(original, lens, half(coverage));
}
