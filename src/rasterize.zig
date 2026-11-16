//! From-zero glyph rasterizer: flattens quadratic Bézier outlines and fills
//! them with a scanline non-zero winding rule. No font/graphics libraries.
//! Works in pixel space: coordinates are expected pre-scaled.
const std = @import("std");
const outline = @import("outline.zig");
const font = @import("font.zig");

pub const Point = outline.Point;

const Seg = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

pub const Canvas = struct {
    width: usize,
    height: usize,
    pixels: []u8, // 1 byte per pixel coverage 0..255
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Canvas {
        return .{
            .width = width,
            .height = height,
            .pixels = try allocator.alloc(u8, width * height),
            .allocator = allocator,
        };
    }

    pub fn clear(self: *Canvas, value: u8) void {
        @memset(self.pixels, value);
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }

    fn set(self: *Canvas, x: usize, y: usize, value: u8) void {
        self.pixels[y * self.width + x] = value;
    }
};

/// Flatten one glyph outline (already scaled to pixel coordinates, y-up baseline at `origin_y`)
/// into line segments, then fill with non-zero winding.
pub fn fillGlyph(canvas: *Canvas, out: *const outline.Outline, origin_x: f64, origin_y: f64) !void {
    var segments = std.ArrayList(Seg).empty;
    defer segments.deinit(canvas.allocator);

    for (out.contours) |contour| {
        const points = out.points[contour.start .. contour.start + contour.len];
        try flattenContour(points, origin_x, origin_y, &segments, canvas.allocator);
    }

    // 4x4 supersampled scanline fill with non-zero winding.
    const SAMPLES = 4;
    const SAMPLE_STEP = 1.0 / @as(f64, SAMPLES);

    for (0..canvas.height) |y| {
        for (0..SAMPLES) |sub_y| {
            const sy = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sub_y)) + 0.5) * SAMPLE_STEP;
            var xs = std.ArrayList(struct { x: f64, winding: i32 }).empty;
            defer xs.deinit(canvas.allocator);

            for (segments.items) |seg| {
                const y0 = seg.y0;
                const y1 = seg.y1;
                if (y0 == y1) continue;
                const min_y = @min(y0, y1);
                const max_y = @max(y0, y1);
                if (sy < min_y or sy >= max_y) continue;
                const t = (sy - y0) / (y1 - y0);
                const x = seg.x0 + t * (seg.x1 - seg.x0);
                const winding: i32 = if (y1 > y0) 1 else -1;
                try xs.append(canvas.allocator, .{ .x = x, .winding = winding });
            }
            std.mem.sort(@TypeOf(xs.items[0]), xs.items, {}, struct {
                fn lessThan(_: void, a: @TypeOf(xs.items[0]), b: @TypeOf(xs.items[0])) bool {
                    return a.x < b.x;
                }
            }.lessThan);

            var winding: i32 = 0;
            var index: usize = 0;
            while (index < xs.items.len) {
                winding += xs.items[index].winding;
                var j = index + 1;
                while (j < xs.items.len and xs.items[j].x == xs.items[index].x) : (j += 1) {
                    winding += xs.items[j].winding;
                }
                const x_end = if (j < xs.items.len) xs.items[j].x else @as(f64, @floatFromInt(canvas.width)) + 1.0;
                if (winding != 0) {
                    // Fill [x_cursor_group_start, x_end) with this winding run.
                    fillSpan(canvas, y, sub_y, xs.items[index].x, x_end, SAMPLES);
                }
                index = j;
            }
        }
    }
}

fn fillSpan(canvas: *Canvas, y: usize, sub_y: usize, x_start: f64, x_end: f64, comptime samples: usize) void {
    _ = sub_y;
    const unit: u16 = 16; // ceil(255 / 16) — 4x4 supersampling grid, clamped on store
    const SAMPLES: f64 = @floatFromInt(samples);
    var x_i: usize = if (x_start < 0) 0 else @intFromFloat(@floor(x_start));
    // Clamp to canvas width; x_end is exclusive.
    while (x_i < canvas.width and @as(f64, @floatFromInt(x_i)) < x_end) : (x_i += 1) {
        for (0..samples) |sub_x| {
            const sx = @as(f64, @floatFromInt(x_i)) + (@as(f64, @floatFromInt(sub_x)) + 0.5) / SAMPLES;
            if (sx < x_start or sx >= x_end) continue;
            const current = canvas.pixels[y * canvas.width + x_i];
            canvas.pixels[y * canvas.width + x_i] = @intCast(@min(255, @as(u16, current) + unit));
        }
    }
}

const ContourBuilder = struct {
    points: std.ArrayList(Point),
};

fn flattenContour(points: []const Point, origin_x: f64, origin_y: f64, segments: *std.ArrayList(Seg), allocator: std.mem.Allocator) !void {
    const n = points.len;
    if (n == 0) return;

    // Step A: insert implied on-curve points between consecutive off-curve points (cyclic).
    var ext = std.ArrayList(Point).empty;
    defer ext.deinit(allocator);
    for (0..n) |i| {
        const cur = points[i];
        const nxt = points[(i + 1) % n];
        try ext.append(allocator, .{ .x = cur.x + origin_x, .y = cur.y + origin_y, .on_curve = cur.on_curve });
        if (!cur.on_curve and !nxt.on_curve) {
            try ext.append(allocator, .{
                .x = (cur.x + nxt.x) / 2.0 + origin_x,
                .y = (cur.y + nxt.y) / 2.0 + origin_y,
                .on_curve = true,
            });
        }
    }

    // Step B: find the first on-curve point to anchor the traversal.
    var anchor: ?usize = null;
    for (0..ext.items.len) |i| {
        if (ext.items[i].on_curve) {
            anchor = i;
            break;
        }
    }
    const anchor_index = anchor orelse return; // No on-curve points at all: nothing to draw.

    const count = ext.items.len;
    var current = ext.items[anchor_index];
    var i = (anchor_index + 1) % count;
    var visited: usize = 0;

    while (visited < count) {
        const p = ext.items[i];
        if (p.on_curve) {
            try segments.append(allocator, .{ .x0 = current.x, .y0 = current.y, .x1 = p.x, .y1 = p.y });
            current = p;
            i = (i + 1) % count;
            visited += 1;
        } else {
            const nxt = ext.items[(i + 1) % count];
            try flattenQuadratic(current.x, current.y, p.x, p.y, nxt.x, nxt.y, 0, segments, allocator);
            current = nxt;
            i = (i + 2) % count;
            visited += 2;
        }
    }

    // Close back to the anchor.
    const start = ext.items[anchor_index];
    if (current.x != start.x or current.y != start.y) {
        try segments.append(allocator, .{ .x0 = current.x, .y0 = current.y, .x1 = start.x, .y1 = start.y });
    }
}

fn flattenQuadratic(x0: f64, y0: f64, cx: f64, cy: f64, x1: f64, y1: f64, depth: u8, segments: *std.ArrayList(Seg), allocator: std.mem.Allocator) !void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len_sq = dx * dx + dy * dy;
    const tol_sq = 0.25 * 0.25; // quarter pixel in scaled coordinates

    var flat = false;
    if (len_sq <= tol_sq) {
        flat = true; // degenerate curve: emit as segment
    } else {
        // Distance from control point to the chord.
        const cross = @abs((cx - x0) * dy - (cy - y0) * dx);
        const dist = cross / @sqrt(len_sq);
        flat = dist <= 0.25 or depth >= 10;
    }

    if (flat) {
        try segments.append(allocator, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 });
        return;
    }

    const mx0 = (x0 + cx) / 2.0;
    const my0 = (y0 + cy) / 2.0;
    const mx1 = (cx + x1) / 2.0;
    const my1 = (cy + y1) / 2.0;
    const mx = (mx0 + mx1) / 2.0;
    const my = (my0 + my1) / 2.0;

    try flattenQuadratic(x0, y0, mx0, my0, mx, my, depth + 1, segments, allocator);
    try flattenQuadratic(mx, my, mx1, my1, x1, y1, depth + 1, segments, allocator);
}
