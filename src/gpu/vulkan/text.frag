#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 2) in vec4 aux1;
layout(location = 3) in vec4 aux2;

layout(set = 0, binding = 0) uniform sampler2D atlas; // R8 glyph coverage

layout(push_constant) uniform PC {
    vec4 extent;   // framebuffer width, height in pixels (xy used)
} pc;

layout(location = 0) out vec4 outColor;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void main() {
    // SDF rounded-shadow rect: aux1 = (center.xy, half-size.xy), aux2 = (radius, blur, shadow alpha, drop-y)
    if (uv == vec2(2.0, 2.0)) {
        // Fragment coordinates use the same top-left origin as app pixels.
        vec2 fragpos = gl_FragCoord.xy;
        vec2 local = fragpos - aux1.xy;
        vec2 b = aux1.zw;
        float radius = aux2.x;
        float blur = max(aux2.y, 1.0);
        float shadowA = aux2.z;
        float dropY = aux2.w;
        float d = sdRoundBox(local, b, radius);
        float edge = 1.5;
        float fillA = 1.0 - smoothstep(-edge, edge, d);
        float ds = sdRoundBox(local - vec2(0.0, dropY), b, radius);
        float s = 1.0 - smoothstep(0.0, blur, ds);
        float shadow = shadowA * s * s;
        float fill = color.a * fillA;
        float a = fill + shadow * (1.0 - fill);
        // Store straight-alpha color; the blend stage applies source alpha
        // exactly once, as the software source-over rasterizer does.
        vec3 rgb = a > 0.0 ? color.rgb * fill / a : vec3(0.0);
        // Fragment coordinates use the same top-left origin as app pixels.
        outColor = vec4(rgb.b, rgb.g, rgb.r, a);

        return;
    }
    float a = texture(atlas, uv).r;
    // Void background #04060B blended with the vertex color by coverage.
    // Solid rects sample the reserved white texel (a == 1) -> exact color.
    vec3 bg = vec3(4.0 / 255.0, 6.0 / 255.0, 11.0 / 255.0);
    vec3 c = mix(bg, color.rgb, a);
    // Blend source-over with the same straight-alpha convention as software.
    outColor = vec4(c.b, c.g, c.r, 1.0);
}
