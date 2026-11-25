#version 450

// Glyph/rect/SDF-rounded-shadow quad vertex: pixel-space position + atlas
// UV (or sentinel) + color + two vec4 auxiliaries (box geometry + shadow params).
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec4 inAux1;
layout(location = 4) in vec4 inAux2;

layout(push_constant) uniform PC {
    vec4 extent;   // framebuffer width, height in pixels (xy used)
} pc;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) out vec4 aux1;
layout(location = 3) out vec4 aux2;

void main() {
    uv = inUV;
    color = inColor;
    aux1 = inAux1;
    aux2 = inAux2;
    // Pixel coordinates are transformed to normalized device coordinates.
    vec2 ndc = vec2(inPos.x / pc.extent.x * 2.0 - 1.0,
                    inPos.y / pc.extent.y * 2.0 - 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
}
