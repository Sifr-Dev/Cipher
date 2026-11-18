//! Immediate-mode UI on top of layout.zig + the text atlas: each frame the
//! app calls begin(), declares widgets (panel/button/label), then end();
//! end() runs the flexbox layout and emits DrawCmds (rects + text runs) that
//! a renderer replays — CPU framebuffer or GPU quads.
const std = @import("std");
const layout = @import("layout.zig");
const atlas_mod = @import("text/atlas.zig");
const input = @import("../framework/input.zig");

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
pub const COLOR_FOCUS_RING: u32 = 0xFF659EFF; // accent — keyboard focus indicator

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
    events: []const input.Event = &.{}, // input events from the last event drain
    states: std.ArrayList(StateEntry), // persistent per-widget state (small N, linear scan)
    // Keyboard focus model (immediate-mode): each focusable widget claims a
    // position in declaration order per frame; focus_index names the position
    // that owns focus. Tab presses are applied at end() (one frame lag, same
    // convention as prev_rects hit testing). kb_focus_id feeds the focus ring.
    focus_index: u32 = 0,
    focus_cursor: u32 = 0,
    kb_focus_id: u32 = 0,
    pending_tab: i32 = 0,
    activate_pressed: bool = false,
    kb_arrow_left: bool = false,
    kb_arrow_right: bool = false,
    kb_arrow_up: bool = false,
    kb_arrow_down: bool = false,
    kb_shift: bool = false,
    // Focus-visible behavior: the ring only shows after the user presses Tab
    // (keyboard semantics), never after mouse use. Matches toolkit focus-visible.
    kb_visible: bool = false,
    scale: f32 = 1, // HiDPI: layout runs in logical px; emission multiplies by scale
    // Text input focus snapshot (used by the IME/text-input protocol path).
    // Captured at the end of the textInput widget each frame when focused.

    pub const WidgetState = union(enum) {
        slider: f32,
        checkbox: bool,
        list: struct { scroll: f32 = 0, sel: i32 = -1 },
        text: struct { buf: [4096]u8 = undefined, len: usize = 0, cursor: usize = 0 },
        tabs: i32,
        none: void,
    };

    pub const StateEntry = struct { id: u32, state: WidgetState };

    pub fn init(base: std.mem.Allocator, atlas: *atlas_mod.TextAtlas) Ui {
        return .{
            .arena = std.heap.ArenaAllocator.init(base),
            .atlas = atlas,
            .stack = .empty,
            .cmds = .empty,
            .base_allocator = base,
            .prev_rects = std.AutoHashMap(u32, layout.Rect).init(base),
            .states = .empty,
        };
    }

    pub fn deinit(self: *Ui) void {
        self.states.deinit(self.base_allocator);
        self.arena.deinit();
        self.prev_rects.deinit();
    }

    /// Persistent per-widget state slot (survives the per-frame arena reset).
    /// Returned pointer is valid until the next wstate call.
    pub fn wstate(self: *Ui, id: u32, default: WidgetState) !*WidgetState {
        for (self.states.items) |*e| {
            if (e.id == id) return &e.state;
        }
        try self.states.append(self.base_allocator, .{ .id = id, .state = default });
        return &self.states.items[self.states.items.len - 1].state;
    }

    /// Append a raw rect draw command (for custom widgets).
    pub fn addRect(self: *Ui, r: layout.Rect, color: u32) !void {
        try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = self.scaledRect(r), .color = color } });
    }

    /// Append a raw text draw command (for custom widgets).
    pub fn addText(self: *Ui, x: f32, baseline: f32, str: []const u8, color: u32) !void {
        const s = self.scale;
        try self.cmds.append(self.allocator(), .{ .text = .{ .x = x * s, .baseline = baseline * s, .str = str, .color = color } });
    }

    pub fn allocator(self: *Ui) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn newNode(self: *Ui) !*layout.Node {
        const n = try self.allocator().create(layout.Node);
        n.* = .{};
        n.children = .empty;
        return n;
    }

    /// Rect in device px (layout works in logical px).
    fn scaledRect(self: *const Ui, r: layout.Rect) layout.Rect {
        if (self.scale == 1) return r;
        return .{ .x = r.x * self.scale, .y = r.y * self.scale, .w = r.w * self.scale, .h = r.h * self.scale };
    }

    fn lineHeight(self: *const Ui) f32 {
        const f = self.atlas.font;
        return @as(f32, @floatFromInt(f.ascender - f.descender + f.line_gap)) * self.atlas.scale / self.scale;
    }

    fn ascentPx(self: *const Ui) f32 {
        return @as(f32, @floatFromInt(self.atlas.font.ascender)) * self.atlas.scale / self.scale;
    }

    pub fn begin(self: *Ui, w: f32, h: f32, mx: f32, my: f32, mdown: bool, mpressed: bool, scale: f32) !void {
        _ = self.arena.reset(.free_all);
        self.scale = if (scale > 0) scale else 1;
        self.stack = .empty;
        self.cmds = .empty;
        self.hot = 0;
        self.next_id = 1;
        self.focus_cursor = 0;
        self.kb_focus_id = 0;
        self.pending_tab = 0;
        self.activate_pressed = false;
        self.kb_arrow_left = false;
        self.kb_arrow_right = false;
        self.kb_arrow_up = false;
        self.kb_arrow_down = false;
        self.kb_shift = false;
        for (self.events) |ev| switch (ev) {
            .key => |k| {
                if (!k.pressed) continue;
                if (k.mods.shift()) self.kb_shift = true;
                switch (k.key) {
                    .tab => self.pending_tab += if (k.mods.shift()) @as(i32, -1) else 1,
                    .enter, .keypad_enter, .space => self.activate_pressed = true,
                    .left => self.kb_arrow_left = true,
                    .right => self.kb_arrow_right = true,
                    .up => self.kb_arrow_up = true,
                    .down => self.kb_arrow_down = true,
                    else => {},
                }
            },
            else => {},
        };
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

    pub fn current(self: *Ui) *layout.Node {
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
        // own the string for this frame: callers often pass stack-backed
        // buffers that die before buildQuads consumes drawCmds
        const owned = try self.allocator().dupe(u8, str);
        const n = try self.newNode();
        n.kind = .label;
        n.text = owned;
        n.color = color;
        n.content_w = try self.atlas.measure(owned) / self.scale;
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
        n.text = try self.allocator().dupe(u8, str);
        n.id = id;
        n.content_w = try self.atlas.measure(str) / self.scale + 2 * pad_x;
        n.content_h = self.lineHeight() + 2 * pad_y;
        n.pad = pad_x;
        try self.current().addChild(self.allocator(), n);

        // Hit test against the rect from the PREVIOUS frame (standard
        // immediate-mode behavior; the arena is reset each frame).
        const prev = self.prev_rects.get(id) orelse layout.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const kb = self.beginFocusable(id);
        const clicked = self.mouse_pressed and prev.contains(self.mouse_x, self.mouse_y);
        if (prev.contains(self.mouse_x, self.mouse_y)) self.hot = id;
        if (clicked) {
            self.active = id;
            self.focus_index = kb.pos;
        }
        n.color = if (self.active == id) COLOR_BUTTON_ACTIVE else if (self.hot == id or kb.focused) COLOR_BUTTON_HOT else COLOR_BUTTON;
        return clicked or (kb.focused and self.activate_pressed);
    }

    pub const KbFocus = struct { pos: u32, focused: bool };

    /// Claim a declaration-order position for a focusable widget. The widget
    /// that receives focus gets KbFocus{.focused = true} this frame; the id is
    /// recorded so end() can draw the ring around its node.
    pub fn beginFocusable(self: *Ui, id: u32) KbFocus {
        const pos = self.focus_cursor;
        self.focus_cursor += 1;
        const focused = pos == self.focus_index;
        if (focused) self.kb_focus_id = id;
        return .{ .pos = pos, .focused = focused };
    }

    /// Paint a 1px accent ring around a node's rect (drawn above everything).
    fn paintFocusRing(self: *Ui, ring_rect: layout.Rect) !void {
        const rect = self.scaledRect(ring_rect);
        const c = COLOR_FOCUS_RING;
        const t: f32 = 1 * self.scale;
        try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = t }, .color = c } });
        try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y + rect.h - t, .w = rect.w, .h = t }, .color = c } });
        try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .w = t, .h = rect.h }, .color = c } });
        try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = .{ .x = rect.x + rect.w - t, .y = rect.y, .w = t, .h = rect.h }, .color = c } });
    }

    pub fn spacer(self: *Ui, px: f32) !void {
        const n = try self.newNode();
        n.content_w = 0;
        n.content_h = px;
        n.w = .{ .fixed = 0 };
        n.h = .{ .fixed = px };
        try self.current().addChild(self.allocator(), n);
    }

    /// Pass A: emit only backgrounds (panel + button rects). Widgets drawn
    /// during onFrame paint on top of these; labels/texts come in pass B.
    fn emitBackgrounds(self: *Ui, n: *layout.Node) !void {
        switch (n.kind) {
            .panel, .button => {
                try self.cmds.append(self.allocator(), .{ .rect = .{ .rect = self.scaledRect(n.rect), .color = n.color } });
            },
            else => {},
        }
        for (n.children.items) |c| try self.emitBackgrounds(c);
    }

    /// Pass B: emit foreground (labels + button-centered text) and persist rects.
    fn emitForeground(self: *Ui, n: *layout.Node) !void {
        switch (n.kind) {
            .label => {
                const s = self.scale;
                try self.cmds.append(self.allocator(), .{ .text = .{
                    .x = (n.rect.x + n.pad) * s,
                    .baseline = (n.rect.y + self.ascentPx()) * s,
                    .str = n.text,
                    .color = n.color,
                } });
            },
            .button => {
                const tw = try self.atlas.measure(n.text) / self.scale;
                const s = self.scale;
                try self.cmds.append(self.allocator(), .{ .text = .{
                    .x = (n.rect.x + (n.rect.w - tw) / 2) * s,
                    .baseline = (n.rect.y + (n.rect.h - self.lineHeight()) / 2 + self.ascentPx()) * s,
                    .str = n.text,
                    .color = if (n.color == COLOR_BUTTON_ACTIVE) COLOR_VOID else COLOR_TEXT,
                } });
            },
            else => {},
        }
        if (n.id != 0) {
            try self.prev_rects.put(n.id, n.rect);
        }
        if (self.kb_visible and n.id != 0 and n.id == self.kb_focus_id) try self.paintFocusRing(n.rect);
        for (n.children.items) |c| try self.emitForeground(c);
    }

    pub fn end(self: *Ui) !void {
        if (self.pending_tab != 0) {
            self.kb_visible = true;
            if (self.focus_cursor > 0) {
                const total: i64 = @intCast(self.focus_cursor);
                const idx = @mod(@as(i64, @intCast(self.focus_index)) + self.pending_tab, total);
                self.focus_index = @intCast(idx);
            }
        }
        _ = self.stack.pop(); // root
        layout.layout(self.root, .{ .x = 0, .y = 0, .w = self.frame_w, .h = self.frame_h });
        // onFrame-time widget draws currently sit in self.cmds; we need
        // panel/button backgrounds BELOW them. Stash, emit backgrounds,
        // then the widget cmds, then the foreground.
        const alloc = self.allocator();
        const saved = try alloc.dupe(DrawCmd, self.cmds.items);
        self.cmds.clearRetainingCapacity();
        try self.emitBackgrounds(self.root);
        try self.cmds.appendSlice(alloc, saved);
        try self.emitForeground(self.root);
    }

    /// Find the rect of the widget with the given id from the last end() pass.
    pub fn widgetRect(self: *const Ui, id: u32) ?layout.Rect {
        return self.prev_rects.get(id);
    }

    pub fn drawCmds(self: *const Ui) []const DrawCmd {
        return self.cmds.items;
    }
};
