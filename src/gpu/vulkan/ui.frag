#version 450

layout(location = 0) out vec4 outColor;

// Must match PushConstants in frame.zig.
layout(push_constant) uniform PushConstants {
    uvec2 extent;   // framebuffer width, height
    uvec2 center;   // circle center in pixels
    uint  radius;   // circle radius in pixels
} pc;

void main() {
    uvec2 gid = uvec2(gl_FragCoord.xy);
    if (gid.x >= pc.extent.x || gid.y >= pc.extent.y) discard;

    // Void background #04060B (exact 8-bit values).
    vec4 color = vec4(4.0 / 255.0, 6.0 / 255.0, 11.0 / 255.0, 1.0);

    // Brass dot #EBB545 as a stand-in for a drawn widget.
    uvec2 d = gid - pc.center;
    uint dist_sq = d.x * d.x + d.y * d.y;
    if (dist_sq <= pc.radius * pc.radius) {
        color = vec4(235.0 / 255.0, 181.0 / 255.0, 69.0 / 255.0, 1.0);
    }

    // Store swizzled BGRA so the host copy is directly wl_shm ARGB8888
    // (little-endian 0xAARRGGBB => bytes B,G,R,A).
    outColor = vec4(color.b, color.g, color.r, color.a);
}
