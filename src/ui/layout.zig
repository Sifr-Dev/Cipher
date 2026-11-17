//! From-zero flexbox-subset layout engine: row/column containers with gap,
//! padding, and fixed / grow / fit sizes, cross-axis stretch. Two passes:
//! measure (bottom-up fit sizes) then arrange (top-down rects).
const std = @import("std");

pub const Dir = enum { row, column };

pub const Size = union(enum) {
    fixed: f32,
    grow: f32, // fraction of remaining main-axis space
    fit: void, // content size (leaves set content_w/h; containers sum children)
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const Kind = enum { none, panel, button, label };

pub const Node = struct {
    dir: Dir = .column,
    gap: f32 = 0,
    pad: f32 = 0,
    w: Size = .fit,
    h: Size = .fit,
    content_w: f32 = 0, // intrinsic size for .fit leaves (e.g. measured text)
    content_h: f32 = 0,
    children: std.ArrayList(*Node) = .empty,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    kind: Kind = .none, // widget payload for the UI layer
    text: []const u8 = "",
    color: u32 = 0,
    id: u32 = 0,

    pub fn addChild(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {
        try self.children.append(allocator, child);
    }
};

/// Bottom-up intrinsic size. Returns (w, h) of the node given available space.
pub fn measure(n: *Node, avail_w: f32, avail_h: f32) [2]f32 {
    // Resolve children first (they may set content sizes).
    const inner_w = if (avail_w > 2 * n.pad) avail_w - 2 * n.pad else 0;
    const inner_h = if (avail_h > 2 * n.pad) avail_h - 2 * n.pad else 0;
    var sum_main: f32 = 0;
    var max_cross: f32 = 0;
    for (n.children.items) |c| {
        const cs = measure(c, inner_w, inner_h);
        const main = if (n.dir == .row) cs[0] else cs[1];
        const cross = if (n.dir == .row) cs[1] else cs[0];
        sum_main += main;
        if (cross > max_cross) max_cross = cross;
    }
    const gaps = if (n.children.items.len > 0) n.gap * @as(f32, @floatFromInt(n.children.items.len - 1)) else 0;
    const content_main = sum_main + gaps;

    const w: f32 = switch (n.w) {
        .fixed => |v| v,
        .fit => if (n.dir == .row) @max(n.content_w, content_main + 2 * n.pad) else @max(n.content_w, max_cross + 2 * n.pad),
        .grow => if (n.dir == .row) @max(n.content_w, content_main + 2 * n.pad) else @max(n.content_h, max_cross + 2 * n.pad),
    };
    const h: f32 = switch (n.h) {
        .fixed => |v| v,
        .fit => if (n.dir == .column) @max(n.content_h, content_main + 2 * n.pad) else @max(n.content_h, max_cross + 2 * n.pad),
        .grow => if (n.dir == .column) @max(n.content_h, content_main + 2 * n.pad) else @max(n.content_h, max_cross + 2 * n.pad),
    };
    return .{ w, h };
}

/// Top-down arrangement: assigns rect to n and recurses.
pub fn arrange(n: *Node, rect: Rect) void {
    n.rect = rect;
    if (n.children.items.len == 0) return;
    const inner_x = rect.x + n.pad;
    const inner_y = rect.y + n.pad;
    const inner_w = @max(0, rect.w - 2 * n.pad);
    const inner_h = @max(0, rect.h - 2 * n.pad);
    const main_avail = if (n.dir == .row) inner_w else inner_h;
    const cross_avail = if (n.dir == .row) inner_h else inner_w;

    // Pass 1: resolve main sizes; grow children share the remainder.
    var fixed_sum: f32 = 0;
    var grow_total: f32 = 0;
    var mains: [1024]f32 = undefined; // plenty for a UI frame; guarded below
    if (n.children.items.len > 1024) return; // safety: cap
    for (n.children.items, 0..) |c, i| {
        const sz = if (n.dir == .row) c.w else c.h;
        const cross_sz = if (n.dir == .row) c.h else c.w;
        const cs = measure(c, inner_w, inner_h);
        const m: f32 = switch (sz) {
            .fixed => |v| v,
            .fit => if (n.dir == .row) cs[0] else cs[1],
            .grow => |g| blk: {
                grow_total += g;
                break :blk 0;
            },
        };
        _ = cross_sz;
        mains[i] = m;
        if (sz != .grow) fixed_sum += m;
    }
    const gaps = n.gap * @as(f32, @floatFromInt(n.children.items.len - 1));
    const remaining = @max(0, main_avail - fixed_sum - gaps);
    if (grow_total > 0) {
        for (n.children.items, 0..) |c, i| {
            const sz = if (n.dir == .row) c.w else c.h;
            if (sz == .grow) mains[i] = remaining * sz.grow / grow_total;
        }
    }

    // Pass 2: place children along the main axis; cross stretches unless fixed.
    var pos: f32 = 0;
    for (n.children.items, 0..) |c, i| {
        const cs = measure(c, inner_w, inner_h);
        const cross_sz = if (n.dir == .row) c.h else c.w;
        const cross: f32 = switch (cross_sz) {
            .fixed => |v| v,
            else => cross_avail,
        };
        const m = mains[i];
        const child_rect: Rect = if (n.dir == .row)
            .{ .x = inner_x + pos, .y = inner_y, .w = m, .h = cross }
        else
            .{ .x = inner_x, .y = inner_y + pos, .w = cross, .h = m };
        _ = cs;
        arrange(c, child_rect);
        pos += m + n.gap;
    }
}

/// Convenience: measure + arrange into the given available rect.
pub fn layout(n: *Node, rect: Rect) void {
    const s = measure(n, rect.w, rect.h);
    const w = if (n.w == .fixed) n.w.fixed else @min(s[0], rect.w);
    const h = if (n.h == .fixed) n.h.fixed else @min(s[1], rect.h);
    arrange(n, .{ .x = rect.x, .y = rect.y, .w = @max(0, w), .h = @max(0, h) });
}
