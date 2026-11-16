//! From-zero immediate-mode widgets for Cipher's GPU-drawn frame.
//! Widgets emit two kinds of records — colored rects (fills/borders) and
//! colored glyph instances — which the GPU consumes in order:
//! ring -> ui rects -> text.
//!
//! Immediate mode: widgets are re-evaluated every frame from pointer state;
//! there is no retained widget tree. Pointer events come from Cipher's
//! wl_pointer handler (see gpuframe.zig); coordinates are frame pixels.
//!
//! Visual style is the SIFR V2 contract: square corners, hairline 1 px
//! borders, void/surface/raised fills, bone text, brass reserved for
//! interaction — one accent, nothing decorative.
const std = @import("std");
const flexbox = @import("flexbox.zig");
const font_mod = @import("font.zig");
const atlas_mod = @import("atlas.zig");
const textlayout_mod = @import("textlayout.zig");

pub const RectCmd = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fill_r: f32,
    fill_g: f32,
    fill_b: f32,
    fill_a: f32,
    border_r: f32,
    border_g: f32,
    border_b: f32,
    border_a: f32,
    border_width: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

comptime {
    std.debug.assert(@sizeOf(RectCmd) == 64);
}

pub const VOID = [4]f32{ 4.0 / 255.0, 6.0 / 255.0, 11.0 / 255.0, 1.0 };
pub const SURFACE = [4]f32{ 10.0 / 255.0, 13.0 / 255.0, 19.0 / 255.0, 1.0 };
pub const RAISED = [4]f32{ 23.0 / 255.0, 27.0 / 255.0, 33.0 / 255.0, 1.0 };
pub const LINE = [4]f32{ 45.0 / 255.0, 48.0 / 255.0, 56.0 / 255.0, 1.0 };
pub const TEXT = [4]f32{ 243.0 / 255.0, 247.0 / 255.0, 254.0 / 255.0, 1.0 };
pub const MUTED = [4]f32{ 148.0 / 255.0, 152.0 / 255.0, 161.0 / 255.0, 1.0 };
pub const BRASS = [4]f32{ 234.0 / 255.0, 180.0 / 255.0, 68.0 / 255.0, 1.0 };

pub const Layout = struct {
    rects: []const flexbox.Rect,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.rects);
    }
};

const focus_order = [_]u32{ 1, 2 };

pub const WidgetContext = struct {
    rects: std.ArrayList(RectCmd) = .empty,
    instances: std.ArrayList(atlas_mod.Instance) = .empty,

    // Pointer state, refreshed by the frame loop from wl_pointer events.
    pointer_x: f64 = -1,
    pointer_y: f64 = -1,
    pointer_down: bool = false,

    // Interaction state machine (immediate mode).
    hover_id: u32 = 0,
    active_id: u32 = 0,
    focus_id: u32 = 0,
    quit_requested: bool = false,

    // Assigned by the frame loop before any widget call.
    font: *const font_mod.Font = undefined,

    pub fn beginFrame(self: *WidgetContext, pointer_x: f64, pointer_y: f64, pointer_down: bool) void {
        self.rects.clearRetainingCapacity();
        self.instances.clearRetainingCapacity();
        // Edge-triggered hover bookkeeping happens inside individual widgets.
        self.pointer_x = pointer_x;
        self.pointer_y = pointer_y;
        self.pointer_down = pointer_down;
    }

    fn addRect(self: *WidgetContext, rect: flexbox.Rect, fill: [4]f32, border: ?[4]f32) !void {
        return self.addRectWidth(rect, fill, border, 1.0);
    }

    fn addRectWidth(self: *WidgetContext, rect: flexbox.Rect, fill: [4]f32, border: ?[4]f32, border_width: f32) !void {
        var border_color: [4]f32 = .{ 0, 0, 0, 0 };
        if (border) |b| {
            border_color = b;
        }
        try self.rects.append(std.heap.page_allocator, .{
            .x = @floatCast(rect.x),
            .y = @floatCast(rect.y),
            .w = @floatCast(rect.width),
            .h = @floatCast(rect.height),
            .fill_r = fill[0],
            .fill_g = fill[1],
            .fill_b = fill[2],
            .fill_a = fill[3],
            .border_r = border_color[0],
            .border_g = border_color[1],
            .border_b = border_color[2],
            .border_a = border_color[3],
            .border_width = border_width,
            ._pad0 = 0,
            ._pad1 = 0,
            ._pad2 = 0,
        });
    }

    /// Static raised panel with a hairline border.
    pub fn panel(self: *WidgetContext, rect: flexbox.Rect) !void {
        try self.addRect(rect, RAISED, LINE);
    }

    /// Text label anchored within a rect (absolute block coordinates).
    pub fn label(
        self: *WidgetContext,
        text: []const u8,
        origin_x: f64,
        block_top: f64,
        max_width: f64,
        alignment: textlayout_mod.Alignment,
        color: [4]f32,
    ) !void {
        var block = try textlayout_mod.layout(self.font, std.heap.page_allocator, text, origin_x, block_top, max_width, alignment, color);
        defer block.deinit();
        for (block.instances) |instance| {
            try self.instances.append(std.heap.page_allocator, instance);
        }
    }

    fn pointInRect(self: *const WidgetContext, rect: flexbox.Rect) bool {
        return self.pointer_x >= rect.x and self.pointer_x < rect.x + rect.width and
            self.pointer_y >= rect.y and self.pointer_y < rect.y + rect.height;
    }

    /// Button: brass border on hover, brass fill on press, bone text at rest.
    /// Returns true on the frame the button is released while pressed.
    pub fn button(self: *WidgetContext, id: u32, rect: flexbox.Rect, text: []const u8) !bool {
        const hovered = self.pointInRect(rect);
        const active = self.active_id == id;

        // Pointer edge tracking for press/release.
        var clicked = false;
        if (hovered) {
            self.hover_id = id;
            if (self.pointer_down and !active) {
                self.active_id = id; // capture the press
            }
        }
        if (active and !self.pointer_down) {
            // Released: emit a click if the pointer is still over the button.
            if (hovered) clicked = true;
            self.active_id = 0;
        }

        if (self.focus_id == id) {
            const ring = flexbox.Rect{
                .x = rect.x - 4.0,
                .y = rect.y - 4.0,
                .width = rect.width + 8.0,
                .height = rect.height + 8.0,
            };
            try self.addRectWidth(ring, .{ 0, 0, 0, 0 }, BRASS, 2.0);
        }

        const fill = if (active) BRASS else RAISED;
        const border = if (hovered or active) BRASS else LINE;
        try self.addRect(rect, fill, border);

        const label_color = if (active) VOID else if (hovered) BRASS else TEXT;
        const scale = @as(f64, @floatFromInt(atlas_mod.PX_EM)) / @as(f64, @floatFromInt(self.font.head.units_per_em));
        const ascent = @as(f64, @floatFromInt(self.font.hhea.ascender)) * scale;
        const descent = @as(f64, @floatFromInt(-self.font.hhea.descender)) * scale;
        const line_height = (ascent + descent) * 1.25;
        const cap_offset = (rect.height - ascent - descent) / 2.0;
        const block_top = rect.y + cap_offset - (line_height - ascent - descent) * 0.0;

        var block = try textlayout_mod.layout(self.font, std.heap.page_allocator, text, rect.x, block_top, rect.width, .center, label_color);
        defer block.deinit();
        for (block.instances) |instance| {
            try self.instances.append(std.heap.page_allocator, instance);
        }

        return clicked;
    }

    /// Tab moves focus through the focusable set (wraps). No visible
    /// focus = no keyboard accessibility; this is the minimum honest ring.
    pub fn cycleFocus(self: *WidgetContext) void {
        const order = focus_order;
        var index: usize = 0;
        while (index < order.len) : (index += 1) {
            if (order[index] == self.focus_id) break;
        }
        self.focus_id = order[if (index < order.len) (index + 1) % order.len else 0];
    }

    /// Deterministic layout for the demo window: a bottom panel with
    /// [CIPHER status | CALIBRATE button | SHUT DOWN button].
    pub fn demoWindowRects(width: f64, height: f64) !struct {
        panel: flexbox.Rect,
        status: flexbox.Rect,
        calibrate: flexbox.Rect,
        shutdown: flexbox.Rect,
        label_y: f64,
    } {
        const button_panel = flexbox.Rect{
            .x = 0,
            .y = height - 88.0,
            .width = width,
            .height = 88.0,
        };
        const inner_pad: f64 = 18.0;
        const inner_x = button_panel.x + inner_pad;
        const inner_width = button_panel.width - 2.0 * inner_pad;
        const items = [_]flexbox.Item{
            .{ .id = 1, .size = 0, .grow = 1 }, // status: takes remaining width
            .{ .id = 2, .size = 210, .grow = 0 }, // CALIBRATE
            .{ .id = 3, .size = 150, .grow = 0 }, // EXIT
        };
        const rects = try flexbox.compute(std.heap.page_allocator, flexbox.Rect{
            .x = inner_x,
            .y = button_panel.y + 14.0,
            .width = inner_width,
            .height = 60.0,
        }, &items, .{
            .direction = .row,
            .justify = .space_between,
            .gap = 16.0,
            .padding = 0,
        });
        defer std.heap.page_allocator.free(rects);

        return .{
            .panel = button_panel,
            .status = rects[0],
            .calibrate = rects[1],
            .shutdown = rects[2],
            .label_y = rects[0].y + 14.0,
        };
    }
};
