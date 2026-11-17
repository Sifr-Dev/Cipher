//! VT parser + grid behavior tests.
const std = @import("std");
const grid_mod = @import("grid.zig");
const vt = @import("vt.zig");
const pty_mod = @import("pty.zig");

fn feed(g: *grid_mod.Grid, p: *vt.Parser, s: []const u8) !void {
    try p.feed(g, s);
}

test "plain text lands in cells with cursor advance" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 10, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "hello");
    const line = g.lineAt(0);
    try std.testing.expectEqual(@as(u21, 'h'), line.cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'o'), line.cells[4].cp);
    try std.testing.expectEqual(@as(u32, 5), g.cx);
    std.debug.print("VT_PLAIN_OK\n", .{});
}

test "SGR colors and reset" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 10, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "\x1b[31mA\x1b[1;32mB\x1b[0mC");
    const line = g.lineAt(0);
    try std.testing.expectEqual(grid_mod.PALETTE_FLAG | 1, line.cells[0].fg);
    try std.testing.expectEqual(grid_mod.PALETTE_FLAG | 2, line.cells[1].fg);
    try std.testing.expect(line.cells[1].attrs.bold);
    try std.testing.expectEqual(grid_mod.DEFAULT_COLOR, line.cells[2].fg);
    try std.testing.expect(!line.cells[2].attrs.bold);
    std.debug.print("VT_SGR_OK\n", .{});
}

test "truecolor 38;2;r;g;b" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 10, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "\x1b[38;2;10;20;30mX");
    try std.testing.expectEqual(@as(u32, 0xFF0A141E), g.lineAt(0).cells[0].fg);
    std.debug.print("VT_TRUECOLOR_OK\n", .{});
}

test "256-palette 38;5;n and bright 90-97" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 10, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "\x1b[38;5;200mA\x1b[91mB");
    const line = g.lineAt(0);
    try std.testing.expectEqual(grid_mod.PALETTE_FLAG | 200, line.cells[0].fg);
    try std.testing.expectEqual(grid_mod.PALETTE_FLAG | 9, line.cells[1].fg);
    std.debug.print("VT_PALETTE256_OK\n", .{});
}

test "CUP cursor positioning and CUF/CUB" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 20, 5);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "\x1b[3;5HX");
    // after printing X at (col 4,row 2) the cursor advanced to 5
    try std.testing.expectEqual(@as(u32, 5), g.cx);
    try std.testing.expectEqual(@as(u32, 2), g.cy);
    try std.testing.expectEqual(@as(u21, 'X'), g.lineAt(2).cells[4].cp);
    try feed(&g, &p, "\x1b[2C\x1b[1DY"); // cx 5 -> 7 -> 6, Y at col 6
    try std.testing.expectEqual(@as(u21, 'Y'), g.lineAt(2).cells[6].cp);
    std.debug.print("VT_CURSOR_OK\n", .{});
}

test "line wrap at right edge" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 4, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "abcdef");
    // 'a'..'d' on line 0, 'e','f' wrapped to line 1 (deferred wrap)
    try std.testing.expectEqual(@as(u21, 'd'), g.lineAt(0).cells[3].cp);
    try std.testing.expectEqual(@as(u21, 'e'), g.lineAt(1).cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'f'), g.lineAt(1).cells[1].cp);
    try std.testing.expect(g.lineAt(0).wrapped);
    std.debug.print("VT_WRAP_OK\n", .{});
}

test "scrolling pushes lines into scrollback" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 5, 2);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "one\r\ntwo\r\nthree");
    // 2 visible rows; "one" scrolled off, "two"/"three" visible
    const vis = g.screenLines();
    try std.testing.expectEqual(@as(usize, 2), vis.len);
    try std.testing.expectEqual(@as(u21, 't'), vis[0].cells[0].cp); // "two"
    try std.testing.expectEqual(@as(u21, 't'), vis[1].cells[0].cp); // "three"
    // scrollback holds "one"
    try std.testing.expectEqual(@as(u21, 'o'), g.lineAt(0).cells[0].cp);
    const snap = try g.captureText(std.testing.allocator, true);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", snap);
    std.debug.print("VT_SCROLL_OK\n", .{});
}

test "erase in line/display" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 5, 2);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "abcde\x1b[1;3H\x1b[K");
    const line = g.lineAt(0);
    try std.testing.expectEqual(@as(u21, 'a'), line.cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'b'), line.cells[1].cp);
    try std.testing.expectEqual(@as(u21, ' '), line.cells[2].cp);
    try std.testing.expectEqual(@as(u21, ' '), line.cells[4].cp);
    try feed(&g, &p, "\x1b[2J");
    for (g.lineAt(0).cells) |c| try std.testing.expectEqual(@as(u21, ' '), c.cp);
    std.debug.print("VT_ERASE_OK\n", .{});
}

test "alt screen enter/leave preserves main" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 5, 2);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "main");
    try feed(&g, &p, "\x1b[?1049h");
    try std.testing.expect(g.alt != null);
    try feed(&g, &p, "alt!");
    try std.testing.expectEqual(@as(u21, 'a'), g.lineAt(0).cells[0].cp);
    try feed(&g, &p, "\x1b[?1049l");
    try std.testing.expect(g.alt == null);
    try std.testing.expectEqual(@as(u21, 'm'), g.lineAt(0).cells[0].cp);
    std.debug.print("VT_ALTSCREEN_OK\n", .{});
}

test "OSC title and 7501 parsed" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 5, 2);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "\x1b]2;my title\x07\x1b]7501;agent=claude\x1b\\");
    try std.testing.expectEqualStrings("my title", vt.Parser.last_title[0..vt.Parser.last_title_len]);
    try std.testing.expectEqualStrings("agent=claude", vt.Parser.last_osc_7501[0..vt.Parser.last_osc_7501_len]);
    std.debug.print("VT_OSC_OK\n", .{});
}

test "UTF-8 multibyte chars" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 10, 2);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "héllo→"); // é = 2 bytes, → = 3 bytes
    const line = g.lineAt(0);
    try std.testing.expectEqual(@as(u21, 'h'), line.cells[0].cp);
    try std.testing.expectEqual(@as(u21, 0xE9), line.cells[1].cp);
    try std.testing.expectEqual(@as(u21, 0x2192), line.cells[5].cp);
    try std.testing.expectEqual(@as(u32, 6), g.cx);
    std.debug.print("VT_UTF8_OK\n", .{});
}

test "scroll region (DECSTBM)" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 5, 4);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "L1\r\nL2\r\nL3\r\nL4");
    try feed(&g, &p, "\x1b[2;3r"); // region rows 2..3
    try feed(&g, &p, "\x1b[2;1H"); // cursor to row 2
    try feed(&g, &p, "\n"); // newline inside region scrolls region only
    // L1 and L4 untouched
    try std.testing.expectEqual(@as(u21, 'L'), g.lineAt(0).cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'L'), g.lineAt(3).cells[0].cp);
    std.debug.print("VT_SCROLLREGION_OK\n", .{});
}

test "insert/delete chars and lines" {
    var g = try grid_mod.Grid.init(std.testing.allocator, 6, 3);
    defer g.deinit();
    var p = vt.Parser{};
    try feed(&g, &p, "abcdef");
    try feed(&g, &p, "\x1b[1;1H\x1b[2P"); // delete 2 chars at start
    const line = g.lineAt(0);
    try std.testing.expectEqual(@as(u21, 'c'), line.cells[0].cp);
    try std.testing.expectEqual(@as(u21, ' '), line.cells[5].cp);
    std.debug.print("VT_DELCHARS_OK\n", .{});
}

test "parser benchmark: 5 MB of mixed output" {
    // page allocator: representative of the server process (testing allocator
    // adds per-allocation safety checks that dominate here)
    const alloc = std.heap.page_allocator;
    var g = try grid_mod.Grid.init(alloc, 200, 50);
    defer g.deinit();
    var p = vt.Parser{};
    const chunk = "hello world \x1b[32mgreen\x1b[0m plain \x1b[1;31mbold red\x1b[0m\r\n0123456789\r\n";
    var data = std.ArrayList(u8).empty;
    defer data.deinit(alloc);
    while (data.items.len < 5 * 1024 * 1024) try data.appendSlice(alloc, chunk);
    const t0 = pty_mod.nowNs();
    try p.feed(&g, data.items);
    const t1 = pty_mod.nowNs();
    const mbps = @as(f64, @floatFromInt(data.items.len)) / (@as(f64, @floatFromInt(t1 - t0)) / 1e9) / 1e6;
    std.debug.print("VT_BENCH_OK bytes={d} ms={d} MBps={d:.1}\n", .{ data.items.len, @divTrunc(t1 - t0, 1_000_000), mbps });
    try std.testing.expect(mbps > 15); // debug build; ReleaseFast measures ~54 MB/s (see worklog)
}
