//! Immediate-mode UI on top of layout.zig + the text atlas: each frame the
//! app calls begin(), declares widgets (panel/button/label), then end();
//! end() runs the flexbox layout and emits DrawCmds (rects + text runs) that
//! a renderer replays — CPU framebuffer or GPU quads.
const std = @import("std");
const layout = @import("layout.zig");
const atlas_mod = @import("text/atlas.zig");

pub const DrawCmd = union(enum) {
    rect: struct { rect: layout.Rect, color: u32 },
    text: struct { x: f32, baseline: f32, str: []const u8, color: u32 },
};

// Brand tokens: void #04060B, surface #0A0D13, accent #659EFF, hairline #1C2434.
pub const COLOR_VOID: u32 = 0xFF04060B;
pub const COLOR_SURFACE: u32 = 0xFF0A0D13;
pub const COLOR_PANEL: u32 = 0xFF0A0D13;
pub const COLOR_BUTTON: u32 = 0xFF141A26;
pub const COLOR_BUTTON_HOT: u32 = 0xFF1C2434;
pub const COLOR_BUTTON_ACTIVE: u32 = 0xFF659EFF;
pub const COLOR_TEXT: u32 = 0xFFE8ECF4;
pub const COLOR_TEXT_DIM: u32 = 0xFF8A93A6;

pub const Ui = struct {
    arena: std.heap.ArenaAllocator,
    atlas: *atlas_mod.TextAtlas,
    root: *layout.Node = undefined,
    stack: std.ArrayList(*layout.Node),
    cmds: std.ArrayList(DrawCmd),
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_pressed: bool = false,
    hot: u32 = 0,
    active: u32 = 0,
    next_id: u32 = 1,
    frame_w: f32 = 0,
    frame_h: f32 = 0,
    base_allocator: std.mem.Allocator,
    prev_rects: std.AutoHashMap(u32, layout.Rect), // survives frame arena resets

    pub fn init(base: std.mem.Allocator, atlas: *atlas_mod.TextAtlas) Ui {
        return .{
            .arena = std.heap.ArenaAllocator.init(base),
            .atlas = atlas,
            .stack = .empty,
            .cmds = .empty,
            .base_allocator = base,
            .prev_rects = std.AutoHashMap(u32, layout.Rect).init(base),
        };
    }

    pub fn deinit(self: *Ui) void {
        self.arena.deinit();
        self.prev_rects.deinit();
    }

    fn allocator(self: *Ui) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn newNode(self: *Ui) !*layout.Node {
        const n = try self.allocator().create(layout.Node);
        n.* = .{};
        n.children = .empty;
        return n;
    }

    fn lineHeight(self: *const Ui) f32 {
        const f = self.atlas.font;
        return @as(f32, @floatFromInt(f.ascender - f.descender + f.line_gap)) * self.atlas.scale;
    }

    fn ascentPx(self: *const Ui) f32 {
        return @as(f32, @floatFromInt(self.atlas.font.ascender)) * self.atlas.scale;
    }

    pub fn begin(self: *Ui, w: f32, h: f32, mx: f32, my: f32, mdown: bool, mpressed: bool) !void {
        _ = self.arena.reset(.free_all);
        self.stack = .empty;
        self.cmds = .empty;
        self.hot = 0;
        self.next_id = 1;
        self.frame_w = w;
        self.frame_h = h;
        self.mouse_x = mx;
        self.mouse_y = my;
        self.mouse_down = mdown;
        self.mouse_pressed = mpressed;
        self.root = try self.newNode();
        self.root.dir = .column;
        self.root.w = .{ .fixed = w };
        self.root.h = .{ .fixed = h };
        try self.stack.append(self.allocator(), self.root);
    }

    fn current(self: *Ui) *layout.Node {
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Open a container panel; returns nothing — children are declared until
    /// endPanel().
    pub fn panel(self: *Ui, w: layout.Size, h: layout.Size, pad: f32, gap: f32) !void {
        const n = try self.newNode();
        n.dir = .column;
        n.w = w;
        n.h = h;
        n.pad = pad;
        n.gap = gap;
        n.kind = .panel;
        n.color = COLOR_PANEL;
        try self.current().addChild(self.allocator(), n);
        try self.stack.append(self.allocator(), n);
    }

    pub fn endPanel(self: *Ui) void {
        _ = self.stack.pop();
    }

    pub fn label(self: *Ui, str: []const u8, color: u32) !void {
        const n = try self.newNode();
        n.kind = .label;
        n.text = str;
        n.color = color;
        n.content_w = try self.atlas.measure(str);
        n.content_h = self.lineHeight();
        try self.current().addChild(self.allocator(), n);
    }

    /// A button. Returns true on the frame the mouse is pressed inside it.
    pub fn button(self: *Ui, str: []const u8) !bool {
        const id = self.next_id;
        self.next_id += 1;
        const pad_x: f32 = 14;
        const pad_y: f32 = 8;
        const n = try self.newNode();
        n.kind = .button;
        n.text = str;
        n.id = id;
        n.content_w = try self.atlas.measure(str) + 2 * pad_x;
        n.content_h = self.lineHeight() + 2 * pad_y;
        n.pad = pad_x;
        try self.current().addChild(self.allocator(), n);

        // Hit test against the rect from the PREVIOUS frame (standard
        // immediate-mode behavior; the arena is reset each frame).
        const prev = self.prev_rects.get(id) orelse layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const clicked = self.mouse_pressed and prev.contains(self.mouse_x, self.mouse_y);
        if (prev.contains(self.mouse_x, self.mouse_y)) self.hot = id;
        if (clicked) self.active = id;
        n.color = if (self.active == id) COLOR_BUTTON_ACTIVE else if (self.hot == id) COLOR_BUTTON_HOT else COLOR_BUTTON;
        return clicked;
    }

    pub fn spacer(self: *Ui, px: f32) !void {
        const n = try self.newNode();
        n.content_w = 0;
        n.content_h = px;
        n.w = .{ .fixed = 0 };
        n.h = .{ .fixed = px };
        try self.current().addChild(self.allocator(), n);
    }

    fn emitWalk(self: *Ui, n: *layout.Node) !void {
        switch (n.kind) {
            .panel, .button => {
                try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = n.rect, .color = n.color } });
            },
            .label => {
                try self.cmds.append(self.allocator(), .{ .text = .{
                    .x = n.rect.x + n.pad,
                    .baseline = n.rect.y + self.ascentPx(),
                    .str = n.text,
                    .color = n.color,
                } });
            },
            .none => {},
        }
        if (n.kind == .button) {
            // Button label centered in the button rect.
            const tw = try self.atlas.measure(n.text);
            try self.cmds.append(self.allocator(), .{ .text = .{
                .x = n.rect.x + (n.rect.w - tw) / 2,
                .baseline = n.rect.y + (n.rect.h - self.lineHeight()) / 2 + self.ascentPx(),
                .str = n.text,
                .color = if (n.color == COLOR_BUTTON_ACTIVE) COLOR_VOID else COLOR_TEXT,
            } });
            // Persist the rect for next frame's hit test.
            try self.prev_rects.put(n.id, n.rect);
        }
        for (n.children.items) |c| try self.emitWalk(c);
    }

    pub fn end(self: *Ui) !void {
        _ = self.stack.pop(); // root
        layout.layout(self.root, .{ .x = 0, .y = 0, .w = self.frame_w, .h = self.frame_h });
        try self.emitWalk(self.root);
    }

    /// Find the rect of the widget with the given id from the last end() pass.
    pub fn widgetRect(self: *const Ui, id: u32) ?layout.Rect {
        return self.prev_rects.get(id);
    }

    pub fn drawCmds(self: *const Ui) []const DrawCmd {
        return self.cmds.items;
    }
};
