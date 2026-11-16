//! From-zero glyph atlas builder: rasterizes printable ASCII (32..126) from
//! the parsed font into a fixed-grid R8 canvas and emits the instance
//! records the GPU text shader consumes. No font libraries anywhere.
//!
//! Layout: 10x10 grid of CELL x CELL cells into ATLAS x ATLAS. Each glyph is
//! rasterized with its origin at (ORIGIN_X, BASELINE_Y) inside its cell, so
//! the shader can blit the whole cell at (pen_x - ORIGIN_X, baseline - BASELINE_Y).
const std = @import("std");
const font = @import("font.zig");
const outline = @import("outline.zig");
const rasterize = @import("rasterize.zig");

pub const CELL: usize = 48;
pub const COLS: usize = 10;
pub const ATLAS: usize = CELL * COLS;
pub const PX_EM: u32 = 36;
pub const ORIGIN_X: f64 = 2.0;
pub const BASELINE_Y: f64 = 36.0;

pub const Instance = extern struct {
    dst_x: f32,
    dst_y: f32,
    src_x: f32,
    src_y: f32,
};

pub const Atlas = struct {
    pixels: [ATLAS * ATLAS]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Atlas {
        return .{
            .pixels = undefined,
            .allocator = allocator,
        };
    }

    fn cellOf(cp: u7) struct { col: usize, row: usize } {
        const index: usize = cp; // cp - 32 folded in by caller
        return .{ .col = index % COLS, .row = index / COLS };
    }

    pub fn build(self: *Atlas, parsed: *const font.Font, allocator: std.mem.Allocator) !void {
        @memset(&self.pixels, 0);
        const scale = @as(f64, @floatFromInt(PX_EM)) / @as(f64, @floatFromInt(parsed.head.units_per_em));

        var canvas = try rasterize.Canvas.init(allocator, CELL, CELL);
        defer canvas.deinit();

        var cp: u7 = 0;
        while (cp <= 94) : (cp += 1) { // 32..126
            canvas.clear(0);
            const codepoint: u32 = @as(u32, cp) + 32;
            const glyph = parsed.cmapGlyph(codepoint) orelse 0;
            if (glyph != 0) {
                var out = try outline.parseGlyph(parsed, glyph, allocator);
                defer out.deinit();
                for (out.points) |*p| {
                    const gx = p.x;
                    const gy = p.y;
                    p.x = gx * scale + ORIGIN_X;
                    p.y = BASELINE_Y - gy * scale;
                }
                try rasterize.fillGlyph(&canvas, &out, 0, 0);
            }
            const cell = cellOf(cp);
            for (0..CELL) |row| {
                const dst_y = (cell.row * CELL + row) * ATLAS + cell.col * CELL;
                const src_y = row * CELL;
                for (0..CELL) |col| {
                    self.pixels[dst_y + col] = canvas.pixels[src_y + col];
                }
            }
        }
    }

    /// Instances for a string rasterized at pen origin (frame coords, y-down).
    pub fn instancesFor(parsed: *const font.Font, allocator: std.mem.Allocator, text: []const u8, pen_x: f64, baseline_y: f64) ![]Instance {
        var instances = std.ArrayList(Instance).empty;
        defer instances.deinit(allocator);

        const scale = @as(f64, @floatFromInt(PX_EM)) / @as(f64, @floatFromInt(parsed.head.units_per_em));
        var pen = pen_x;

        var index: usize = 0;
        while (index < text.len) {
            const seq_len = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
            const codepoint = std.unicode.utf8Decode(text[index..][0..seq_len]) catch break;
            const glyph = parsed.cmapGlyph(codepoint) orelse 0;
            if (codepoint >= 32 and codepoint <= 126) {
                const cell = cellOf(@intCast(codepoint - 32));
                try instances.append(allocator, .{
                    .dst_x = @floatCast(pen - ORIGIN_X),
                    .dst_y = @floatCast(baseline_y - BASELINE_Y),
                    .src_x = @floatFromInt(cell.col * CELL),
                    .src_y = @floatFromInt(cell.row * CELL),
                });
            }
            pen += @as(f64, @floatFromInt(parsed.glyphAdvance(glyph))) * scale;
            index += seq_len;
        }

        return try instances.toOwnedSlice(allocator);
    }
};
