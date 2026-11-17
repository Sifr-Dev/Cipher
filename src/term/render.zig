//! Terminal rendering: resolve cell colors (xterm 256-palette, bold, reverse)
//! and expand the visible grid into GPU quads (bg rect + glyph per cell).
const std = @import("std");
const grid_mod = @import("grid.zig");
const atlas_mod = @import("../ui/text/atlas.zig");
const gpu_text = @import("../gpu/vulkan/text.zig");
const runtime = @import("../framework/runtime.zig");

pub const THEME_FG: u32 = 0xFFC8C8C8;
pub const THEME_BG: u32 = 0xFF0A0D13;
pub const CURSOR_COLOR: u32 = 0xFF659EFF;

/// xterm 256-palette as 0xAARRGGBB.
pub fn paletteColor(idx: u8) u32 {
    if (idx < 16) {
        const base = [16][3]u8{
            .{ 0x00, 0x00, 0x00 }, .{ 0xCD, 0x00, 0x00 }, .{ 0x00, 0xCD, 0x00 }, .{ 0xCD, 0xCD, 0x00 },
            .{ 0x00, 0x00, 0xEE }, .{ 0xCD, 0x00, 0xCD }, .{ 0x00, 0xCD, 0xCD }, .{ 0xE5, 0xE5, 0xE5 },
            .{ 0x7F, 0x7F, 0x7F }, .{ 0xFF, 0x00, 0x00 }, .{ 0x00, 0xFF, 0x00 }, .{ 0xFF, 0xFF, 0x00 },
            .{ 0x5C, 0x5C, 0xFF }, .{ 0xFF, 0x00, 0xFF }, .{ 0x00, 0xFF, 0xFF }, .{ 0xFF, 0xFF, 0xFF },
        };
        const c = base[idx];
        return 0xFF000000 | (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
    }
    if (idx < 232) {
        const n = idx - 16;
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        const r = levels[(n / 36) % 6];
        const g = levels[(n / 6) % 6];
        const b = levels[n % 6];
        return 0xFF000000 | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
    }
    const v = 8 + (idx - 232) * 10;
    return 0xFF000000 | (@as(u32, v) << 16) | (@as(u32, v) << 8) | v;
}

/// Resolve a cell color to 0xAARRGGBB.
pub fn resolveColor(c: u32, is_fg: bool, bold: bool, default: u32) u32 {
    if (c == grid_mod.DEFAULT_COLOR) return default;
    if (c & grid_mod.PALETTE_FLAG != 0) {
        var idx: u8 = @intCast(c & 0xFF);
        // bold brightens the 8 base fg colors
        if (is_fg and bold and idx < 8) idx += 8;
        return paletteColor(idx);
    }
    if (c & grid_mod.TRUECOLOR_FLAG != 0) return 0xFF000000 | (c & 0xFFFFFF);
    return c | 0xFF000000;
}

/// Append quads for one cell. Returns quads added (0, 1 or 2).
pub fn cellQuad(
    atlas: *atlas_mod.TextAtlas,
    out: []gpu_text.Quad,
    n: usize,
    x: f32,
    y: f32,
    cell_w: f32,
    cell_h: f32,
    cell: grid_mod.Cell,
    fg_default: u32,
    bg_default: u32,
) !usize {
    var added: usize = 0;
    const reverse = cell.attrs.reverse;
    var fg = resolveColor(cell.fg, true, cell.attrs.bold, fg_default);
    var bg = resolveColor(cell.bg, false, false, bg_default);
    if (reverse) {
        const t = fg;
        fg = bg;
        bg = t;
    }
    if (bg != bg_default or reverse) {
        if (n + added >= out.len) return error.TooManyQuads;
        out[n + added] = .{
            .x = x,
            .y = y,
            .w = cell_w,
            .h = cell_h,
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .color = runtime.rgba01(bg),
        };
        added += 1;
    }
    if (cell.cp != ' ' and cell.cp != 0) {
        const g = try atlas.glyph(cell.cp);
        if (g.w > 0 and g.h > 0) {
            if (n + added >= out.len) return error.TooManyQuads;
            const aw = @as(f32, @floatFromInt(atlas.atlas_w));
            const ah = @as(f32, @floatFromInt(atlas.atlas_h));
            out[n + added] = .{
                .x = x + g.bearing_x,
                .y = y + @as(f32, @floatFromInt(atlas.font.ascender)) * atlas.scale - g.top,
                .w = @floatFromInt(g.w),
                .h = @floatFromInt(g.h),
                .u0 = @as(f32, @floatFromInt(g.atlas_x)) / aw,
                .v0 = @as(f32, @floatFromInt(g.atlas_y)) / ah,
                .u1 = @as(f32, @floatFromInt(g.atlas_x + g.w)) / aw,
                .v1 = @as(f32, @floatFromInt(g.atlas_y + g.h)) / ah,
                .color = runtime.rgba01(fg),
            };
            added += 1;
        }
    }
    return added;
}

/// Render the whole visible grid into `out` starting at quad index n.
/// Returns the new quad count. `cell_w`/`cell_h` are the cell metrics.
pub fn renderGrid(
    atlas: *atlas_mod.TextAtlas,
    g: *grid_mod.Grid,
    out: []gpu_text.Quad,
    n: usize,
    origin_x: f32,
    origin_y: f32,
    cell_w: f32,
    cell_h: f32,
) !usize {
    var count = n;
    const lines = g.screenLines();
    for (lines, 0..) |line, row| {
        const y = origin_y + @as(f32, @floatFromInt(row)) * cell_h;
        for (line.cells, 0..) |cell, col| {
            const x = origin_x + @as(f32, @floatFromInt(col)) * cell_w;
            count += try cellQuad(atlas, out, count, x, y, cell_w, cell_h, cell, THEME_FG, THEME_BG);
        }
    }
    // cursor block (hidden while the view is scrolled into scrollback)
    if (g.cursor_visible and g.atBottom()) {
        const cx = origin_x + @as(f32, @floatFromInt(g.cx)) * cell_w;
        const cy = origin_y + @as(f32, @floatFromInt(g.cy)) * cell_h;
        if (count < out.len) {
            out[count] = .{
                .x = cx,
                .y = cy + cell_h - 3,
                .w = cell_w,
                .h = 2,
                .u0 = 0,
                .v0 = 0,
                .u1 = 0,
                .v1 = 0,
                .color = runtime.rgba01(CURSOR_COLOR),
            };
            count += 1;
        }
    }
    return count;
}

/// Cell metrics for a mono atlas: width = advance of 'M', height = line height.
pub fn cellMetrics(atlas: *atlas_mod.TextAtlas) struct { w: f32, h: f32 } {
    const m = atlas.glyph('M') catch return .{ .w = 8, .h = 16 };
    const f = atlas.font;
    const h = @as(f32, @floatFromInt(f.ascender - f.descender + f.line_gap)) * atlas.scale;
    return .{ .w = m.advance, .h = h };
}

test "palette: base, cube, grayscale vectors" {
    try std.testing.expectEqual(@as(u32, 0xFFCD0000), paletteColor(1));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), paletteColor(15));
    try std.testing.expectEqual(@as(u32, 0xFF000000), paletteColor(16)); // cube origin
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), paletteColor(196)); // cube red corner (16+180)
    try std.testing.expectEqual(@as(u32, 0xFF080808), paletteColor(232)); // gray ramp start
    try std.testing.expectEqual(@as(u32, 0xFFEEEEEE), paletteColor(255));
    std.debug.print("PALETTE_OK\n", .{});
}

test "resolveColor: default, palette, bold-brighten, direct, reverse handled by caller" {
    try std.testing.expectEqual(THEME_FG, resolveColor(grid_mod.DEFAULT_COLOR, true, false, THEME_FG));
    try std.testing.expectEqual(paletteColor(1), resolveColor(grid_mod.PALETTE_FLAG | 1, true, false, THEME_FG));
    try std.testing.expectEqual(paletteColor(9), resolveColor(grid_mod.PALETTE_FLAG | 1, true, true, THEME_FG)); // bold brightens
    try std.testing.expectEqual(@as(u32, 0xFF0A141E), resolveColor(0x020A141E, true, false, THEME_FG));
    std.debug.print("RESOLVE_OK\n", .{});
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const buf = try allocator.alloc(u8, 16 * 1024 * 1024);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try std.posix.read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return try allocator.realloc(buf, off);
}

test "renderGrid: SGR-colored grid produces bg+fg quads, cursor bar present" {
    const alloc = std.testing.allocator;
    const data = try readFile("/usr/share/fonts/liberation/LiberationSans-Regular.ttf", alloc);
    defer alloc.free(data);
    var atlas = try atlas_mod.TextAtlas.init(alloc, data, 16);
    defer atlas.deinit();
    const cm = cellMetrics(&atlas);
    try std.testing.expect(cm.w > 0 and cm.h > 0);

    var g = try grid_mod.Grid.init(alloc, 10, 3);
    defer g.deinit();
    var p = @import("vt.zig").Parser{};
    try p.feed(&g, "\x1b[41;97mAB\x1b[0m cd");

    var quads: [256]gpu_text.Quad = undefined;
    const n = try renderGrid(&atlas, &g, &quads, 0, 0, 0, cm.w, cm.h);
    // A,B have red bg + white fg (2 quads each), space has default bg (0 quads),
    // c,d default fg on default bg (1 quad each), cursor bar 1 -> 2+2+1+1+1 = 7
    try std.testing.expectEqual(@as(usize, 7), n);
    // first quad is A's bg = palette 1 (red)
    const bg = quads[0].color;
    try std.testing.expectApproxEqAbs(@as(f32, 0xCD) / 255.0, bg[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0x00) / 255.0, bg[1], 1e-3);
    std.debug.print("RENDER_GRID_OK quads={d} cell={d:.1}x{d:.1}\n", .{ n, cm.w, cm.h });
}
