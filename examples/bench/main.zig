//! cipher-bench — hillclimb-style benchmark for the cipher framework.
//!
//! Scenes (nanoui-compatible, same-party comparisons):
//!   text       300 labels whose numbers change every frame   (17x18 grid)
//!   boxes      600 moving, color-cycling rects               (no radius/shadow yet)
//!   dashboard  12 cards: title, big number, progress bar     (4x3)
//!
//! Protocol per invocation: `--warmup N` frames ignored, then `--frames M`
//! measured frames, `--repeats R` repeats. The framework (with
//! CIPHER_FRAME_TIMING=1) prints one CIPHER_BENCH line per 300 measured
//! frames; run per scene so every repeat dumps its own mean window.
//!
//! Run:
//!   CIPHER_FRAME_TIMING=1 zig build run-bench --release -- --scene text
//!   CIPHER_FRAME_TIMING=1 CIPHER_FORCE_SOFTWARE=1 zig build run-bench --release -- --scene text
//!
//! Note: WSI render_ms is vsync-wait dominated (not GPU time without
//! timestamps); compare build/layout/encode across machines and paths.
const std = @import("std");
const cipher = @import("cipher");

const Scene = enum { text, boxes, dashboard };

const WinW: f32 = 1120;
const WinH: f32 = 640;

pub const Bench = struct {
    scene: Scene = .text,
    frame: u64 = 0,
    warmup: u64 = 30,
    frames: u64 = 300,
    repeats: u64 = 3,

    pub fn onEvent(self: *Bench, rt: *cipher.runtime.Runtime, ev: cipher.input.Event) void {
        switch (ev) {
            .key => |k| {
                if (k.pressed and k.key == .esc) rt.requestQuit();
            },
            .close => rt.requestQuit(),
            else => {},
        }
        _ = self;
    }

    pub fn onFrame(self: *Bench, rt: *cipher.runtime.Runtime) !void {
        const u = rt.ui() orelse return;
        self.frame += 1;
        const f = self.frame;
        switch (self.scene) {
            .text => try sceneText(u, f, rt),
            .boxes => try sceneBoxes(u, f, rt),
            .dashboard => try sceneDashboard(u, f, rt),
        }
        if (self.frame >= self.warmup + self.frames * self.repeats) rt.requestQuit();
    }
};

fn sceneText(u: *cipher.ui.Ui, f: u64, rt: *cipher.runtime.Runtime) !void {
    _ = rt;
    try u.panel(.{ .fixed = WinW }, .{ .fixed = WinH }, 8, 4);
    var row: usize = 0;
    while (row < 18) : (row += 1) {
        try u.panel(.{ .fixed = WinW - 16 }, .{ .fixed = 32 }, 2, 2);
        u.current().dir = .row;
        var col: usize = 0;
        while (col < 17) : (col += 1) {
            var buf: [32]u8 = undefined;
            const n = (f *% 2654435761 +% row *% 97 +% col *% 613) % 100000;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?";
            try u.label(s, cipher.ui.COLOR_TEXT);
        }
        u.endPanel();
    }
    u.endPanel();
}

fn sceneBoxes(u: *cipher.ui.Ui, f: u64, rt: *cipher.runtime.Runtime) !void {
    _ = rt;
    // Full-window canvas: 600 colored rects, deterministic bounce, hue cycling.
    try u.panel(.{ .fixed = WinW }, .{ .fixed = WinH }, 0, 0);
    var i: usize = 0;
    const t: f32 = @floatFromInt(f % 100000);
    while (i < 600) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const x = WinW * (0.5 + 0.48 * sin32(fi * 1.7 + t * 0.021));
        const y = WinH * (0.5 + 0.45 * cos32(fi * 2.3 + t * 0.017));
        const size = 18.0 + 10.0 * sin32(fi * 0.31 + t * 0.05);
        const hue = (f / 4 + i *% 37) % 360;
        const rgb = hsv(hue, 0.75, 0.9);
        const col: u32 = 0xFF000000 | (@as(u32, rgb[0]) << 16) | (@as(u32, rgb[1]) << 8) | @as(u32, rgb[2]);
        try u.addRect(.{ .x = x, .y = y, .w = size, .h = size }, col);
    }
    u.endPanel();
}

fn sceneDashboard(u: *cipher.ui.Ui, f: u64, rt: *cipher.runtime.Runtime) !void {
    _ = rt;
    try u.panel(.{ .fixed = WinW }, .{ .fixed = WinH }, 10, 8);
    var card: usize = 0;
    while (card < 12) : (card += 1) {
        try u.panel(.{ .fixed = WinW - 20 }, .{ .fixed = 150 }, 10, 10);
        u.current().dir = .column;
        var tbuf: [24]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "card {d}", .{card + 1}) catch "card";
        try u.label(title, cipher.ui.COLOR_TEXT_DIM);
        var nbuf: [32]u8 = undefined;
        const val = (f *% 2654435761 +% card *% 7919) % 1000000;
        const num = std.fmt.bufPrint(&nbuf, "{d}", .{val}) catch "?";
        try u.label(num, cipher.ui.COLOR_TEXT);
        const frac = @as(f32, @floatFromInt((f + card *% 37) % 100)) / 100.0;
        try cipher.widgets.progress(u, WinW - 80, frac);
        u.endPanel();
    }
    u.endPanel();
}

fn sin32(x: f32) f32 {
    return @floatCast(std.math.sin(@as(f64, x)));
}
fn cos32(x: f32) f32 {
    return @floatCast(std.math.cos(@as(f64, x)));
}

fn hsv(h_in: u64, s: f32, v: f32) [3]u8 {
    const h: f32 = @floatFromInt(h_in % 360);
    const c = v * s;
    const x = c * (1 - @abs(@mod(h / 60.0, 2) - 1));
    const m = v - c;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (h < 60) {
        r = c;
        g = x;
    } else if (h < 120) {
        r = x;
        g = c;
    } else if (h < 180) {
        g = c;
        b = x;
    } else if (h < 240) {
        g = x;
        b = c;
    } else if (h < 300) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{
        @intFromFloat((r + m) * 255),
        @intFromFloat((g + m) * 255),
        @intFromFloat((b + m) * 255),
    };
}

fn parseScene(s: []const u8) ?Scene {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "boxes")) return .boxes;
    if (std.mem.eql(u8, s, "dashboard")) return .dashboard;
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    for (init.args.vector) |a| try argv.append(alloc, std.mem.span(a));

    var app = Bench{ .scene = .text };
    var i: usize = 1;
    while (i < argv.items.len) : (i += 1) {
        const a = argv.items[i];
        if (std.mem.eql(u8, a, "--scene") and i + 1 < argv.items.len) {
            app.scene = parseScene(argv.items[i + 1]) orelse {
                std.debug.print("cipher-bench: unknown scene {s} (text|boxes|dashboard)\n", .{argv.items[i + 1]});
                std.process.exit(2);
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--warmup") and i + 1 < argv.items.len) {
            app.warmup = std.fmt.parseInt(u64, argv.items[i + 1], 10) catch 30;
            i += 1;
        } else if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.items.len) {
            app.frames = std.fmt.parseInt(u64, argv.items[i + 1], 10) catch 300;
            i += 1;
        } else if (std.mem.eql(u8, a, "--repeats") and i + 1 < argv.items.len) {
            app.repeats = std.fmt.parseInt(u64, argv.items[i + 1], 10) catch 3;
            i += 1;
        } else {
            std.debug.print("cipher-bench: unknown argument {s}\n", .{a});
            std.process.exit(2);
        }
    }

    try cipher.runtime.runWith(Bench, &app, .{
        .title = "cipher-bench",
        .app_id = "cipher-bench",
        .ui_px = 16,
        .width = 1120,
        .height = 640,
    });
}
