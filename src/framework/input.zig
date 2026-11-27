//! Input model for the Cipher framework: evdev keycodes -> semantic keys +
//! unicode chars (US layout; layout handling via xkb keymaps is a documented
//! limitation), modifier tracking, and the Event union apps consume.
const std = @import("std");

pub const Key = enum {
    unknown,
    esc,
    backspace,
    tab,
    enter,
    left_ctrl,
    right_ctrl,
    left_shift,
    right_shift,
    left_alt,
    right_alt,
    caps_lock,
    num_lock,
    scroll_lock,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    space,
    keypad_enter,
    keypad_divide,
    printable, // text-producing key; read `char`
};

/// xkb modifier masks (depressed|latched|locked): shift=bit0, caps=bit1,
/// ctrl=bit2, alt(mod1)=bit3.
pub const Mods = struct {
    raw: u32 = 0,
    pub fn shift(self: Mods) bool {
        return self.raw & 0x1 != 0;
    }
    pub fn caps(self: Mods) bool {
        return self.raw & 0x2 != 0;
    }
    pub fn ctrl(self: Mods) bool {
        return self.raw & 0x4 != 0;
    }
    pub fn alt(self: Mods) bool {
        return self.raw & 0x8 != 0;
    }
};

pub const KeyEvent = struct {
    code: u32,
    key: Key,
    char: ?u21,
    mods: Mods,
    pressed: bool,
};

pub const MouseButton = struct {
    button: u32, // BTN_LEFT=0x110, BTN_MIDDLE=0x112, BTN_RIGHT=0x111
    pressed: bool,
};

/// Input-method (IME) event, from the compositor's text-input-v3 object.
/// The runtime applies these to the focused text field; apps only see them
/// when they opt into raw handling (e.g. a custom editor).
pub const ImeEvent = union(enum) {
    /// The compositor's text-input focus entered/left our surface.
    enter: void,
    leave: void,
    /// Composition text to display (never inserted). `cursor_begin` and
    /// `cursor_end` are byte offsets into it, or -1 when the cursor is hidden.
    preedit: struct { text: []const u8, cursor_begin: i32, cursor_end: i32 },
    /// Text the input method wants inserted at the cursor.
    commit: []const u8,
    /// Delete `before` bytes before and `after` bytes after the cursor.
    delete_surrounding: struct { before: u32, after: u32 },
    /// The compositor applied everything up to this commit serial.
    done: u32,
    /// The user triggered an action (submit) on the field.
    action: u32,
    /// BCP 47 language chosen by the input method.
    language: []const u8,
};

/// Framework-level event delivered to App.onEvent.
pub const Event = union(enum) {
    key: KeyEvent,
    mouse_move: struct { x: f32, y: f32 },
    mouse_button: MouseButton,
    wheel: struct { dx: f32, dy: f32 }, // dy>0 = scroll down
    resize: struct { w: u32, h: u32 },
    paste: []const u8, // clipboard text or dropped file paths
    focus: bool,
    close, // compositor asked to close the window
    /// Raw IME traffic, for apps that render their own editor. The default
    /// text field consumes these before the app sees them.
    ime: ImeEvent,
};

pub const KeyMapResult = struct { key: Key, char: ?u21 };

fn letter(code: u32) u21 {
    // evdev: 16..25 = q..p, 30..38 = a..l, 44..50 = z..m
    return switch (code) {
        16...25 => "qwertyuiop"[code - 16],
        30...38 => "asdfghjkl"[code - 30],
        44...50 => "zxcvbnm"[code - 44],
        else => '?',
    };
}

/// Map an evdev keycode to (Key, char) assuming a US layout.
pub fn mapKey(code: u32, shift: bool, caps: bool) KeyMapResult {
    switch (code) {
        1 => return .{ .key = .esc, .char = null },
        14 => return .{ .key = .backspace, .char = 0x08 },
        15 => return .{ .key = .tab, .char = 0x09 },
        28 => return .{ .key = .enter, .char = 0x0D },
        29 => return .{ .key = .left_ctrl, .char = null },
        97 => return .{ .key = .right_ctrl, .char = null },
        42 => return .{ .key = .left_shift, .char = null },
        54 => return .{ .key = .right_shift, .char = null },
        56 => return .{ .key = .left_alt, .char = null },
        100 => return .{ .key = .right_alt, .char = null },
        58 => return .{ .key = .caps_lock, .char = null },
        69 => return .{ .key = .num_lock, .char = null },
        70 => return .{ .key = .scroll_lock, .char = null },
        59...68 => return .{ .key = @enumFromInt(@intFromEnum(Key.f1) + (code - 59)), .char = null },
        87 => return .{ .key = .f11, .char = null },
        88 => return .{ .key = .f12, .char = null },
        102 => return .{ .key = .home, .char = null },
        103 => return .{ .key = .up, .char = null },
        104 => return .{ .key = .page_up, .char = null },
        105 => return .{ .key = .left, .char = null },
        106 => return .{ .key = .right, .char = null },
        107 => return .{ .key = .end, .char = null },
        108 => return .{ .key = .down, .char = null },
        109 => return .{ .key = .page_down, .char = null },
        110 => return .{ .key = .insert, .char = null },
        111 => return .{ .key = .delete, .char = null },
        57 => return .{ .key = .space, .char = ' ' },
        96 => return .{ .key = .keypad_enter, .char = 0x0D },
        98 => return .{ .key = .keypad_divide, .char = '/' },
        55 => return .{ .key = .printable, .char = '*' },
        // keypad 71..83: 789-456+123-0.
        71...73 => return .{ .key = .printable, .char = "789"[code - 71] },
        74 => return .{ .key = .printable, .char = '-' },
        75...77 => return .{ .key = .printable, .char = "456"[code - 75] },
        78 => return .{ .key = .printable, .char = '+' },
        79...81 => return .{ .key = .printable, .char = "123"[code - 79] },
        82 => return .{ .key = .printable, .char = '0' },
        83 => return .{ .key = .printable, .char = '.' },
        // digits row 2..11
        2...11 => {
            const unshifted = "1234567890";
            const shifted = "!@#$%^&*()";
            const i: usize = code - 2;
            return .{ .key = .printable, .char = if (shift) shifted[i] else unshifted[i] };
        },
        12 => return .{ .key = .printable, .char = if (shift) '_' else '-' },
        13 => return .{ .key = .printable, .char = if (shift) '+' else '=' },
        26 => return .{ .key = .printable, .char = if (shift) '{' else '[' },
        27 => return .{ .key = .printable, .char = if (shift) '}' else ']' },
        39 => return .{ .key = .printable, .char = if (shift) ':' else ';' },
        40 => return .{ .key = .printable, .char = if (shift) '"' else '\'' },
        41 => return .{ .key = .printable, .char = if (shift) '~' else '`' },
        43 => return .{ .key = .printable, .char = if (shift) '|' else '\\' },
        51 => return .{ .key = .printable, .char = if (shift) '<' else ',' },
        52 => return .{ .key = .printable, .char = if (shift) '>' else '.' },
        53 => return .{ .key = .printable, .char = if (shift) '?' else '/' },
        16...25, 30...38, 44...50 => {
            const l = letter(code);
            const upper = shift != caps;
            return .{ .key = .printable, .char = if (upper) l - 32 else l };
        },
        else => return .{ .key = .unknown, .char = null },
    }
}

test "mapKey: letters, shift, caps, digits, specials, nav" {
    try std.testing.expectEqual(Key.printable, mapKey(30, false, false).key);
    try std.testing.expectEqual(@as(?u21, 'a'), mapKey(30, false, false).char);
    try std.testing.expectEqual(@as(?u21, 'A'), mapKey(30, true, false).char);
    try std.testing.expectEqual(@as(?u21, 'A'), mapKey(30, false, true).char);
    try std.testing.expectEqual(@as(?u21, 'a'), mapKey(30, true, true).char); // shift XOR caps
    try std.testing.expectEqual(@as(?u21, 'q'), mapKey(16, false, false).char);
    try std.testing.expectEqual(@as(?u21, 'z'), mapKey(44, false, false).char);
    try std.testing.expectEqual(@as(?u21, '!'), mapKey(2, true, false).char);
    try std.testing.expectEqual(@as(?u21, '1'), mapKey(2, false, false).char);
    try std.testing.expectEqual(@as(?u21, ')'), mapKey(11, true, false).char);
    try std.testing.expectEqual(@as(?u21, '0'), mapKey(11, false, false).char);
    try std.testing.expectEqual(Key.backspace, mapKey(14, false, false).key);
    try std.testing.expectEqual(@as(?u21, 0x08), mapKey(14, false, false).char);
    try std.testing.expectEqual(Key.enter, mapKey(28, false, false).key);
    try std.testing.expectEqual(Key.esc, mapKey(1, false, false).key);
    try std.testing.expectEqual(Key.up, mapKey(103, false, false).key);
    try std.testing.expectEqual(Key.delete, mapKey(111, false, false).key);
    try std.testing.expectEqual(Key.f5, mapKey(63, false, false).key);
    try std.testing.expectEqual(@as(?u21, ' '), mapKey(57, false, false).char);
    try std.testing.expectEqual(@as(?u21, '?'), mapKey(53, true, false).char);
    try std.testing.expectEqual(@as(?u21, '/'), mapKey(53, false, false).char);
    try std.testing.expectEqual(Key.unknown, mapKey(999, false, false).key);
    try std.testing.expectEqual(@as(?u21, '5'), mapKey(76, false, false).char);
    std.debug.print("INPUT_MAP_OK\n", .{});
}
