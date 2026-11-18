//! Layout + immediate-mode UI tests: flexbox math (fixed/grow/fit, gap, pad,
//! cross stretch) and widget behavior (draw commands, button hit-testing
//! across frames via persisted rects).
const std = @import("std");
const layout = @import("layout.zig");
const ui_mod = @import("ui.zig");
const atlas_mod = @import("text/atlas.zig");

const FONT_PATH = "/usr/share/fonts/liberation/LiberationSans-Regular.ttf";

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const buf = try allocator.alloc(u8, 8 * 1024 * 1024);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try std.posix.read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return try allocator.realloc(buf, off);
}

test "layout: column with pad/gap, fixed child + stretched child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(layout.Node);
    root.* = .{};
    root.dir = .column;
    root.w = .{ .fixed = 400 };
    root.h = .{ .fixed = 300 };
    root.pad = 8;
    root.gap = 10;
    const child_a = try a.create(layout.Node);
    child_a.* = .{};
    child_a.w = .{ .fixed = 100 };
    child_a.h = .{ .fixed = 20 };
    const child_b = try a.create(layout.Node);
    child_b.* = .{};
    child_b.w = .fit; // cross axis (width) stretches
    child_b.h = .{ .fixed = 50 };
    child_b.content_w = 30; // intrinsic, but stretched cross = 384
    try root.addChild(a, child_a);
    try root.addChild(a, child_b);

    layout.layout(root, .{ .x = 0, .y = 0, .w = 400, .h = 300 });
    try std.testing.expectApproxEqAbs(@as(f32, 8), child_a.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), child_a.rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), child_a.rect.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), child_a.rect.h, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 8), child_b.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 38), child_b.rect.y, 0.001); // 8 + 20 + 10
    try std.testing.expectApproxEqAbs(@as(f32, 384), child_b.rect.w, 0.001); // 400 - 2*8
    try std.testing.expectApproxEqAbs(@as(f32, 50), child_b.rect.h, 0.001);
    std.debug.print("LAYOUT_COL_OK A=({d:.1},{d:.1},{d:.1},{d:.1}) B=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{
        child_a.rect.x, child_a.rect.y, child_a.rect.w, child_a.rect.h,
        child_b.rect.x, child_b.rect.y, child_b.rect.w, child_b.rect.h,
    });
}

test "layout: row grow distributes remaining space by fraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try a.create(layout.Node);
    root.* = .{};
    root.dir = .row;
    root.w = .{ .fixed = 300 };
    root.h = .{ .fixed = 100 };
    const mk = struct {
        fn f(al: std.mem.Allocator, w: layout.Size) !*layout.Node {
            const n = try al.create(layout.Node);
            n.* = .{};
            n.w = w;
            n.h = .{ .fixed = 40 };
            return n;
        }
    }.f;
    const c0 = try mk(a, .{ .fixed = 100 });
    const c1 = try mk(a, .{ .grow = 1 });
    const c2 = try mk(a, .{ .grow = 2 });
    try root.addChild(a, c0);
    try root.addChild(a, c1);
    try root.addChild(a, c2);
    layout.layout(root, .{ .x = 0, .y = 0, .w = 300, .h = 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), c0.rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0 / 3.0), c1.rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400.0 / 3.0), c2.rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), c1.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100 + 200.0 / 3.0), c2.rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), c1.rect.h, 0.01);
    std.debug.print("LAYOUT_ROW_OK c1.w={d:.2} c2.w={d:.2} c2.x={d:.2}\n", .{ c1.rect.w, c2.rect.w, c2.rect.x });
}

test "ui: panel+label+button emit draw commands; button click hit-tests across frames" {
    const data = try readFile(FONT_PATH, std.testing.allocator);
    defer std.testing.allocator.free(data);
    var at = try atlas_mod.TextAtlas.init(std.testing.allocator, data, 20);
    defer at.deinit();

    var ui = ui_mod.Ui.init(std.testing.allocator, &at);
    defer ui.deinit();

    // Frame 1: declare UI, no mouse.
    try ui.begin(640, 400, 0, 0, false, false, 1.0);
    try ui.panel(.{ .fixed = 300 }, .{ .fixed = 200 }, 12, 8);
    try ui.label("Cipher", ui_mod.COLOR_TEXT);
    const clicked1 = try ui.button("OK");
    ui.endPanel();
    try ui.end();
    try std.testing.expect(!clicked1);

    // Expect: panel rect, label text, button rect, button text = 4 cmds.
    try std.testing.expectEqual(@as(usize, 4), ui.drawCmds().len);
    var rects: usize = 0;
    var texts: usize = 0;
    var saw_ok = false;
    for (ui.drawCmds()) |c| {
        switch (c) {
            .rect => rects += 1,
            .text => |t| {
                texts += 1;
                if (std.mem.eql(u8, t.str, "OK")) saw_ok = true;
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 2), texts);
    try std.testing.expect(saw_ok);

    // Button rect from frame 1 (id 1): inside panel at pad 12, below the label.
    const br = ui.widgetRect(1) orelse return error.MissingButton;
    try std.testing.expectApproxEqAbs(@as(f32, 12), br.x, 0.01);
    try std.testing.expect(br.y > 12); // below label (label height + gap)
    try std.testing.expect(br.w > 30 and br.h > 20);
    std.debug.print("UI_FRAME1_OK cmds=4 button=({d:.1},{d:.1},{d:.1},{d:.1})\n", .{ br.x, br.y, br.w, br.h });

    // Frame 2: same UI, mouse pressed at button center -> clicked.
    try ui.begin(640, 400, br.x + br.w / 2, br.y + br.h / 2, true, true, 1.0);
    try ui.panel(.{ .fixed = 300 }, .{ .fixed = 200 }, 12, 8);
    try ui.label("Cipher", ui_mod.COLOR_TEXT);
    const clicked2 = try ui.button("OK");
    ui.endPanel();
    try ui.end();
    try std.testing.expect(clicked2);

    // Frame 3: mouse elsewhere -> not clicked.
    try ui.begin(640, 400, 500, 350, true, true, 1.0);
    try ui.panel(.{ .fixed = 300 }, .{ .fixed = 200 }, 12, 8);
    try ui.label("Cipher", ui_mod.COLOR_TEXT);
    const clicked3 = try ui.button("OK");
    ui.endPanel();
    try ui.end();
    try std.testing.expect(!clicked3);
    std.debug.print("UI_CLICK_OK frame2 clicked=true frame3 clicked=false\n", .{});
}
