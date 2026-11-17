//! cipher-hello — framework smoke app: exercises the runtime + every widget.
const std = @import("std");
const cipher = @import("cipher");

pub const Hello = struct {
    clicks: u32 = 0,
    slider_val: f32 = 30,
    enabled: bool = false,
    tab: i32 = 0,
    text_storage: [256]u8 = undefined,
    frames: u32 = 0,

    pub fn onEvent(self: *Hello, rt: *cipher.runtime.Runtime, ev: cipher.input.Event) void {
        switch (ev) {
            .key => |k| {
                if (k.pressed and k.key == .esc) rt.requestQuit();
            },
            .close => rt.requestQuit(),
            else => {},
        }
        _ = self;
    }

    pub fn onFrame(self: *Hello, rt: *cipher.runtime.Runtime) !void {
        const u = rt.ui() orelse return;
        self.frames += 1;
        try u.panel(.{ .fixed = 460 }, .{ .fixed = 330 }, 16, 10);
        try u.label("Cipher framework — hello", cipher.ui.COLOR_TEXT);
        var buf: [96]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "frames: {d}  clicks: {d}  slider: {d:.0}", .{ self.frames, self.clicks, self.slider_val });
        try u.label(s, cipher.ui.COLOR_TEXT_DIM);
        if (try u.button("Click me (Esc quits)")) self.clicks += 1;
        try cipher.widgets.slider(u, 300, 0, 100, &self.slider_val);
        _ = try cipher.widgets.checkbox(u, "enabled", &self.enabled);
        try cipher.widgets.tabs(u, &[_][]const u8{ "one", "two", "three" }, &self.tab);
        _ = try cipher.widgets.textInput(u, 300, self.text_storage[0..0], "type here");
        try cipher.widgets.progress(u, 300, self.slider_val / 100.0);
        u.endPanel();
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;
    var app = Hello{};
    try cipher.runtime.run(Hello, &app);
}
