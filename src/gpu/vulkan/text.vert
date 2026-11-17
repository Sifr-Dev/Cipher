#version 450

// Glyph/rect quad vertex: pixel-space position + atlas UV + color.
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;

layout(push_constant) uniform PC {
    vec4 extent;   // framebuffer width, height in pixels (xy used)
} pc;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;

void main() {
    uv = inUV;
    color = inColor;
    // Pixel coords are y-down; with a positive-height viewport, NDC y=-1 is
    // the top row, so y=0 (top) maps to -1.
    vec2 ndc = vec2(inPos.x / pc.extent.x * 2.0 - 1.0,
                    inPos.y / pc.extent.y * 2.0 - 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
