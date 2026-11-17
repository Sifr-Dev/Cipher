#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;

layout(set = 0, binding = 0) uniform sampler2D atlas; // R8 glyph coverage

layout(push_constant) uniform PC {
    vec4 extent;
} pc;

layout(location = 0) out vec4 outColor;

void main() {
    float a = texture(atlas, uv).r;
    // Void background #04060B blended with the vertex color by coverage.
    // Solid rects sample the reserved white texel (a == 1) -> exact color.
    vec3 bg = vec3(4.0 / 255.0, 6.0 / 255.0, 11.0 / 255.0);
    vec3 c = mix(bg, color.rgb, a);
    // Store swizzled BGRA so the host copy is directly wl_shm ARGB8888.
    outColor = vec4(c.b, c.g, c.r, 1.0);
}
