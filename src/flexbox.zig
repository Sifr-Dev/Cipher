//! From-zero immediate-mode flexbox layout engine for Cipher.
//! Immediate mode: the caller declares sizes + grow factors per frame and
//! gets back concrete frame-space rects — no retained style tree, no
//! invalidation complexity. Only what Cipher's widget set needs:
//! row/column, fixed or grow sizes, gap, padding, main-axis justification.
//!
//! Units are pixels in the parent's coordinate space.
//! Cross-axis: items with a fixed cross size are centered-free top-aligned
//! (start); items with cross size 0 fill the inner cross axis.
const std = @import("std");

pub const Error = error{ OutOfMemory };

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

pub const Direction = enum { row, column };

pub const Justify = enum { start, center, end, space_between };

pub const Item = struct {
    id: u32 = 0,
    /// Fixed main-axis size (width in a row, height in a column). 0 means "only grow".
    size: f64 = 0,
    /// Fixed cross-axis size. 0 fills the inner cross axis.
    cross_size: f64 = 0,
    /// Proportion of leftover main-axis space this item absorbs.
    grow: f64 = 0,
};

pub const Options = struct {
    direction: Direction = .row,
    justify: Justify = .start,
    gap: f64 = 0,
    padding: f64 = 0,
};

fn mainSize(item: Item, direction: Direction) f64 {
    _ = direction;
    return item.size;
}

fn crossSize(item: Item) f64 {
    return item.cross_size;
}

pub fn compute(
    allocator: std.mem.Allocator,
    container: Rect,
    items: []const Item,
    options: Options,
) Error![]Rect {
    const padding = options.padding;
    const inner = Rect{
        .x = container.x + padding,
        .y = container.y + padding,
        .width = @max(0, container.width - 2.0 * padding),
        .height = @max(0, container.height - 2.0 * padding),
    };

    const n = items.len;
    const rects = try allocator.alloc(Rect, n);

    if (n == 0) return rects;

    const is_row = options.direction == .row;
    const inner_main = if (is_row) inner.width else inner.height;
    const inner_cross = if (is_row) inner.height else inner.width;

    // Sum of fixed main sizes and gaps.
    var total_grow: f64 = 0;
    for (items) |item| total_grow += item.grow;

    // First pass: final main sizes, grow distribution before justification.
    var fixed_main: f64 = options.gap * @as(f64, @floatFromInt(n - 1));
    for (items) |item| fixed_main += mainSize(item, options.direction);
    var remaining = inner_main - fixed_main;
    if (remaining < 0) remaining = 0;

    var total_final: f64 = 0;
    for (items, 0..) |item, i| {
        var main = mainSize(item, options.direction);
        if (item.grow > 0 and total_grow > 0) {
            main += (remaining * item.grow) / total_grow;
        }
        rects[i] = if (is_row)
            .{ .x = 0, .y = 0, .width = main, .height = 0 }
        else
            .{ .x = 0, .y = 0, .width = 0, .height = main };
        total_final += main;
    }

    // Slack left after grow consumption goes to justification.
    var slack = inner_main - total_final - options.gap * @as(f64, @floatFromInt(n - 1));
    if (slack < 0) slack = 0;

    var start_offset: f64 = 0;
    var gap = options.gap;
    switch (options.justify) {
        .start => {},
        .center => start_offset = slack / 2.0,
        .end => start_offset = slack,
        .space_between => {
            if (n > 1) gap = options.gap + slack / @as(f64, @floatFromInt(n - 1));
        },
    }

    var cursor: f64 = if (is_row) inner.x + start_offset else inner.y + start_offset;

    for (items, 0..) |item, i| {
        const main = if (is_row) rects[i].width else rects[i].height;
        const cross = if (crossSize(item) > 0) crossSize(item) else inner_cross;

        if (is_row) {
            rects[i] = .{ .x = cursor, .y = inner.y, .width = main, .height = cross };
        } else {
            rects[i] = .{ .x = inner.x, .y = cursor, .width = cross, .height = main };
        }
        cursor += main + gap;
    }

    return rects;
}

test "row layout with gap and padding" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .size = 100 },
        .{ .size = 100 },
    };
    const rects = try compute(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 50 }, &items, .{
        .direction = .row,
        .justify = .start,
        .gap = 10,
        .padding = 10,
    });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(f64, 10), rects[0].x);
    try std.testing.expectEqual(@as(f64, 120), rects[1].x);
    try std.testing.expectEqual(@as(f64, 100), rects[0].width);
    try std.testing.expectEqual(@as(f64, 30), rects[0].height);
}

test "grow distributes leftover space proportionally" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .size = 0, .grow = 2 },
        .{ .size = 100, .grow = 0 },
        .{ .size = 0, .grow = 1 },
    };
    const rects = try compute(allocator, .{ .x = 0, .y = 0, .width = 400, .height = 40 }, &items, .{
        .direction = .row,
        .gap = 10,
        .padding = 0,
    });
    defer allocator.free(rects);

    // fixed total = 120; remaining = 280; grow split 2:1 => 186.67 / 93.33
    try std.testing.expectApproxEqAbs(@as(f64, 0), rects[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 186.667), rects[0].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 196.667), rects[1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), rects[1].width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 306.667), rects[2].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 93.333), rects[2].width, 0.001);
}

test "space_between spreads gaps across the row" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .size = 100 },
        .{ .size = 100 },
        .{ .size = 100 },
    };
    const rects = try compute(allocator, .{ .x = 0, .y = 0, .width = 500, .height = 40 }, &items, .{
        .direction = .row,
        .justify = .space_between,
        .gap = 0,
    });
    defer allocator.free(rects);

    try std.testing.expectEqual(@as(f64, 0), rects[0].x);
    try std.testing.expectEqual(@as(f64, 200), rects[1].x);
    try std.testing.expectEqual(@as(f64, 400), rects[2].x);
}

test "column direction lays out vertically with center justify" {
    const allocator = std.testing.allocator;
    const items = [_]Item{
        .{ .size = 40 },
        .{ .size = 40 },
    };
    const rects = try compute(allocator, .{ .x = 0, .y = 0, .width = 100, .height = 200 }, &items, .{
        .direction = .column,
        .justify = .center,
        .gap = 10,
    });
    defer allocator.free(rects);

    // fixed total = 90; remaining = 110; center offset = 55
    try std.testing.expectEqual(@as(f64, 55), rects[0].y);
    try std.testing.expectEqual(@as(f64, 105), rects[1].y);
    try std.testing.expectEqual(@as(f64, 100), rects[0].width);
}
