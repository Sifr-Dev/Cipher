//! From-zero glyph rasterizer: quadratic Bezier flattening + scanline
//! nonzero-winding fill with 4 vertical subsamples per pixel row and exact
//! horizontal coverage. Output is an 8-bit coverage buffer (0..255).
const std = @import("std");
const font = @import("font.zig");

pub const Segment = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

const SS: u32 = 4; // vertical subsamples per pixel row

/// Transform a font-units outline into pixel-space segments (y flipped to
/// y-down), flattening quadratic curves adaptively.
pub fn flatten(contours: []const font.Contour, scale: f32, off_x: f32, off_y: f32, allocator: std.mem.Allocator) ![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    errdefer segs.deinit(allocator);
    for (contours) |contour| {
        const pts = contour.points;
        if (pts.len == 0) continue;
        // Find start: first on-curve point, else midpoint of last+first.
        var start_idx: usize = 0;
        var start: [2]f32 = undefined;
        var found_on = false;
        for (pts, 0..) |p, i| {
            if (p.on_curve) {
                start_idx = i;
                found_on = true;
                break;
            }
        }
        if (found_on) {
            const p = pts[start_idx];
            start = .{ @as(f32, @floatFromInt(p.x)) * scale + off_x, -( @as(f32, @floatFromInt(p.y)) * scale) + off_y };
        } else {
            const a = pts[pts.len - 1];
            const b = pts[0];
            start = .{
                (@as(f32, @floatFromInt(a.x)) + @as(f32, @floatFromInt(b.x))) / 2 * scale + off_x,
                -((@as(f32, @floatFromInt(a.y)) + @as(f32, @floatFromInt(b.y))) / 2 * scale) + off_y,
            };
        }
        var cur = start;
        var ctrl: ?[2]f32 = null;
        const n = pts.len;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const idx = (start_idx + k) % n;
            const p = pts[idx];
            const pt = [2]f32{ @as(f32, @floatFromInt(p.x)) * scale + off_x, -(@as(f32, @floatFromInt(p.y)) * scale) + off_y };
            if (p.on_curve) {
                if (ctrl) |c| {
                    try emitQuad(&segs, allocator, cur, c, pt);
                    ctrl = null;
                } else {
                    try segs.append(allocator, .{ .x0 = cur[0], .y0 = cur[1], .x1 = pt[0], .y1 = pt[1] });
                }
                cur = pt;
            } else {
                if (ctrl) |c| {
                    const mid = [2]f32{ (c[0] + pt[0]) / 2, (c[1] + pt[1]) / 2 };
                    try emitQuad(&segs, allocator, cur, c, mid);
                    cur = mid;
                }
                ctrl = pt;
            }
        }
        // close the contour
        if (ctrl) |c| {
            try emitQuad(&segs, allocator, cur, c, start);
        } else {
            try segs.append(allocator, .{ .x0 = cur[0], .y0 = cur[1], .x1 = start[0], .y1 = start[1] });
        }
    }
    return segs.toOwnedSlice(allocator);
}

fn emitQuad(segs: *std.ArrayList(Segment), allocator: std.mem.Allocator, p0: [2]f32, c: [2]f32, p1: [2]f32) !void {
    // flatness in pixel space: distance of control point from chord
    const chord_dx = p1[0] - p0[0];
    const chord_dy = p1[1] - p0[1];
    const len = @sqrt(chord_dx * chord_dx + chord_dy * chord_dy);
    var flat: f32 = 0;
    if (len > 0) {
        flat = @abs((c[0] - p0[0]) * chord_dy - (c[1] - p0[1]) * chord_dx) / len;
    } else {
        flat = @sqrt((c[0] - p0[0]) * (c[0] - p0[0]) + (c[1] - p0[1]) * (c[1] - p0[1]));
    }
    var steps: u32 = @intFromFloat(@ceil(@sqrt(flat * 2.0)));
    if (steps < 1) steps = 1;
    if (steps > 64) steps = 64;
    var i: u32 = 1;
    var prev = p0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const mt = 1 - t;
        const x = mt * mt * p0[0] + 2 * mt * t * c[0] + t * t * p1[0];
        const y = mt * mt * p0[1] + 2 * mt * t * c[1] + t * t * p1[1];
        try segs.append(allocator, .{ .x0 = prev[0], .y0 = prev[1], .x1 = x, .y1 = y });
        prev = .{ x, y };
    }
}

/// Scanline fill (nonzero winding). buf must be width*height bytes; each byte
/// receives 0..255 coverage. Coordinates are pixel-space, y-down.
pub fn rasterize(segments: []const Segment, width: u32, height: u32, buf: []u8) void {
    std.debug.assert(buf.len == @as(usize, width) * height);
    @memset(buf, 0);
    if (segments.len == 0) return;
    var cover = std.heap.page_allocator.alloc(f32, @as(usize, width) * height) catch return;
    defer std.heap.page_allocator.free(cover);
    @memset(cover, 0);
    var xs = std.heap.page_allocator.alloc(f32, segments.len) catch return;
    defer std.heap.page_allocator.free(xs);
    var ws = std.heap.page_allocator.alloc(i32, segments.len) catch return;
    defer std.heap.page_allocator.free(ws);

    var py: u32 = 0;
    while (py < height) : (py += 1) {
        var s: u32 = 0;
        while (s < SS) : (s += 1) {
            const y = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(SS));
            var n: usize = 0;
            for (segments) |seg| {
                const y0 = @min(seg.y0, seg.y1);
                const y1 = @max(seg.y0, seg.y1);
                if (y >= y0 and y < y1) {
                    const t = (y - seg.y0) / (seg.y1 - seg.y0);
                    xs[n] = seg.x0 + t * (seg.x1 - seg.x0);
                    ws[n] = if (seg.y1 > seg.y0) 1 else -1;
                    n += 1;
                }
            }
            // sort crossings by x (insertion sort; n is small per glyph row)
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const xv = xs[i];
                const wv = ws[i];
                var j: usize = i;
                while (j > 0 and xs[j - 1] > xv) : (j -= 1) {
                    xs[j] = xs[j - 1];
                    ws[j] = ws[j - 1];
                }
                xs[j] = xv;
                ws[j] = wv;
            }
            var winding: i32 = 0;
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const w_before = winding;
                winding += ws[k];
                if (w_before != 0) {
                    const xa = xs[k];
                    const xb = if (k + 1 < n) xs[k + 1] else xa;
                    if (xb > xa) {
                        // add covered width [xa, xb) into row accumulator
                        const row = cover[@as(usize, py) * width ..];
                        var px = @as(u32, @intFromFloat(@max(0, @floor(xa))));
                        const px_end = @as(u32, @intFromFloat(@min(@as(f32, @floatFromInt(width)), @ceil(xb))));
                        while (px < px_end) : (px += 1) {
                            const lo = @max(xa, @as(f32, @floatFromInt(px)));
                            const hi = @min(xb, @as(f32, @floatFromInt(px + 1)));
                            if (hi > lo) row[px] += hi - lo;
                        }
                    }
                }
            }
        }
    }
    // normalize: coverage per pixel = sum over SS sub-rows of covered width / SS
    var idx: usize = 0;
    while (idx < buf.len) : (idx += 1) {
        const c = cover[idx] / @as(f32, @floatFromInt(SS));
        buf[idx] = @intFromFloat(@round(@min(1.0, @max(0.0, c)) * 255.0));
    }
}

/// Convenience: rasterize one glyph outline into a freshly allocated buffer of
/// the given pixel size. Returns coverage buffer (caller frees) and the
/// tight ink bounds (in pixels) via out param if non-null.
pub fn rasterizeGlyph(
    outline: *const font.Outline,
    px_size: f32,
    units_per_em: u16,
    width: u32,
    height: u32,
    off_x: f32,
    off_y: f32,
    allocator: std.mem.Allocator,
) ![]u8 {
    const scale = px_size / @as(f32, @floatFromInt(units_per_em));
    const segs = try flatten(outline.contours, scale, off_x, off_y, allocator);
    defer allocator.free(segs);
    const buf = try allocator.alloc(u8, @as(usize, width) * height);
    rasterize(segs, width, height, buf);
    return buf;
}
