//! Minimal JSON: Value union, recursive-descent parser, serializer.
//! Strings are UTF-8; serializer escapes control chars, quote, backslash.
//! Enough for the rex-clone control protocol (one JSON value per line).
const std = @import("std");

pub const Value = union(enum) {
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    arr: []Value,
    obj: []Entry,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(self: *const Value, key: []const u8) ?*const Value {
        if (self.* != .obj) return null;
        for (self.obj) |*e| {
            if (std.mem.eql(u8, e.key, key)) return &e.value;
        }
        return null;
    }

    pub fn strOf(self: *const Value) ?[]const u8 {
        return if (self.* == .str) self.str else null;
    }

    pub fn numOf(self: *const Value) ?f64 {
        return if (self.* == .num) self.num else null;
    }
};

pub const ParseError = error{ UnexpectedEnd, Syntax, OutOfMemory, InvalidCharacter, InvalidNumber, Overflow };

pub const Parser = struct {
    buf: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Value {
        var p = Parser{ .buf = text, .allocator = allocator };
        p.skipWs();
        const v = try p.parseValue();
        p.skipWs();
        return v;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') self.pos += 1 else break;
        }
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.buf.len) self.buf[self.pos] else null;
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWs();
        const c = self.peek() orelse return error.UnexpectedEnd;
        switch (c) {
            '{' => return try self.parseObj(),
            '[' => return try self.parseArr(),
            '"' => return .{ .str = try self.parseStr() },
            't' => {
                try self.expect("true");
                return .{ .bool = true };
            },
            'f' => {
                try self.expect("false");
                return .{ .bool = false };
            },
            'n' => {
                try self.expect("null");
                return .null;
            },
            else => return try self.parseNum(),
        }
    }

    fn expect(self: *Parser, word: []const u8) !void {
        if (self.pos + word.len > self.buf.len) return error.UnexpectedEnd;
        if (!std.mem.eql(u8, self.buf[self.pos .. self.pos + word.len], word)) return error.Syntax;
        self.pos += word.len;
    }

    fn parseNum(self: *Parser) ParseError!Value {
        const start = self.pos;
        while (self.pos < self.buf.len) {
            const c = self.buf[self.pos];
            if (c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E' or (c >= '0' and c <= '9')) self.pos += 1 else break;
        }
        if (self.pos == start) return error.Syntax;
        const text = self.buf[start..self.pos];
        return .{ .num = try std.fmt.parseFloat(f64, text) };
    }

    fn parseStr(self: *Parser) ParseError![]const u8 {
        if (self.peek() != '"') return error.Syntax;
        self.pos += 1;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        while (true) {
            if (self.pos >= self.buf.len) return error.UnexpectedEnd;
            const c = self.buf[self.pos];
            self.pos += 1;
            if (c == '"') break;
            if (c == '\\') {
                if (self.pos >= self.buf.len) return error.UnexpectedEnd;
                const e = self.buf[self.pos];
                self.pos += 1;
                switch (e) {
                    '"' => try out.append(self.allocator, '"'),
                    '\\' => try out.append(self.allocator, '\\'),
                    '/' => try out.append(self.allocator, '/'),
                    'b' => try out.append(self.allocator, 0x08),
                    'f' => try out.append(self.allocator, 0x0C),
                    'n' => try out.append(self.allocator, '\n'),
                    'r' => try out.append(self.allocator, '\r'),
                    't' => try out.append(self.allocator, '\t'),
                    'u' => {
                        if (self.pos + 4 > self.buf.len) return error.Syntax;
                        const hex = self.buf[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const cp = try std.fmt.parseInt(u21, hex, 16);
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return error.Syntax;
                        try out.appendSlice(self.allocator, buf[0..n]);
                    },
                    else => return error.Syntax,
                }
            } else {
                try out.append(self.allocator, c);
            }
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn parseArr(self: *Parser) ParseError!Value {
        self.pos += 1; // [
        var items = std.ArrayList(Value).empty;
        errdefer items.deinit(self.allocator);
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .arr = try items.toOwnedSlice(self.allocator) };
        }
        while (true) {
            const v = try self.parseValue();
            try items.append(self.allocator, v);
            self.skipWs();
            const c = self.peek() orelse return error.UnexpectedEnd;
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == ']') {
                self.pos += 1;
                break;
            }
            return error.Syntax;
        }
        return .{ .arr = try items.toOwnedSlice(self.allocator) };
    }

    fn parseObj(self: *Parser) ParseError!Value {
        self.pos += 1; // {
        var entries = std.ArrayList(Value.Entry).empty;
        errdefer entries.deinit(self.allocator);
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .obj = try entries.toOwnedSlice(self.allocator) };
        }
        while (true) {
            self.skipWs();
            const key = try self.parseStr();
            self.skipWs();
            if (self.peek() != ':') return error.Syntax;
            self.pos += 1;
            const v = try self.parseValue();
            try entries.append(self.allocator, .{ .key = key, .value = v });
            self.skipWs();
            const c = self.peek() orelse return error.UnexpectedEnd;
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == '}') {
                self.pos += 1;
                break;
            }
            return error.Syntax;
        }
        return .{ .obj = try entries.toOwnedSlice(self.allocator) };
    }
};

/// Public wrapper so external modules (CLI pretty-printer) can stream values.
pub fn writeValueIntoPub(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value) !void {
    try writeValueInto(out, allocator, v);
}

pub fn writeValue(allocator: std.mem.Allocator, v: Value) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try writeValueInto(&out, allocator, v);
    return out.toOwnedSlice(allocator);
}

fn writeValueInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .num => |n| {
            if (n == @floor(n) and @abs(n) < 1e15) {
                try out.print(allocator, "{d:.0}", .{n});
            } else {
                try out.print(allocator, "{d}", .{n});
            }
        },
        .str => |s| try writeStrInto(out, allocator, s),
        .arr => |a| {
            try out.append(allocator, '[');
            for (a, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try writeValueInto(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
        .obj => |o| {
            try out.append(allocator, '{');
            for (o, 0..) |e, i| {
                if (i > 0) try out.append(allocator, ',');
                try writeStrInto(out, allocator, e.key);
                try out.append(allocator, ':');
                try writeValueInto(out, allocator, e.value);
            }
            try out.append(allocator, '}');
        },
    }
}

pub fn writeStrInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B, 0x0E...0x1F => try out.print(allocator, "\\u{x:0>4}", .{@as(u5, @truncate(c))}),
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

// ---- base64 (for binary-safe pty output in events) ----
const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i + 3 <= data.len) {
        const n = @as(u32, data[i]) << 16 | @as(u32, data[i + 1]) << 8 | data[i + 2];
        try out.append(allocator, b64_chars[(n >> 18) & 63]);
        try out.append(allocator, b64_chars[(n >> 12) & 63]);
        try out.append(allocator, b64_chars[(n >> 6) & 63]);
        try out.append(allocator, b64_chars[n & 63]);
        i += 3;
    }
    const rem = data.len - i;
    if (rem == 1) {
        const n = @as(u32, data[i]) << 16;
        try out.append(allocator, b64_chars[(n >> 18) & 63]);
        try out.append(allocator, b64_chars[(n >> 12) & 63]);
        try out.appendSlice(allocator, "==");
    } else if (rem == 2) {
        const n = @as(u32, data[i]) << 16 | @as(u32, data[i + 1]) << 8;
        try out.append(allocator, b64_chars[(n >> 18) & 63]);
        try out.append(allocator, b64_chars[(n >> 12) & 63]);
        try out.append(allocator, b64_chars[(n >> 6) & 63]);
        try out.append(allocator, '=');
    }
    return out.toOwnedSlice(allocator);
}

pub fn base64Decode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var acc: u32 = 0;
    var nbits: u32 = 0;
    for (text) |c| {
        if (c == '=') break;
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+' => 62,
            '/' => 63,
            else => return error.InvalidBase64,
        };
        acc = (acc << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            try out.append(allocator, @as(u8, @intCast((acc >> @as(u5, @intCast(nbits))) & 0xFF)));
        }
    }
    return out.toOwnedSlice(allocator);
}

test "json round-trip object with all types" {
    const text = "{\"op\":\"send\",\"pane\":3,\"data\":\"ls -la\\n\",\"wait\":true,\"tags\":[1,2.5,null,false],\"esc\":\"a\\u0001b\\\"c\"}";
    const v = try Parser.parse(std.testing.allocator, text);
    defer freeValue(std.testing.allocator, v);
    try std.testing.expectEqualStrings("send", v.get("op").?.str);
    try std.testing.expectEqual(@as(f64, 3), v.get("pane").?.num);
    try std.testing.expectEqualStrings("ls -la\n", v.get("data").?.str);
    try std.testing.expectEqual(true, v.get("wait").?.bool);
    try std.testing.expectEqual(@as(usize, 4), v.get("tags").?.arr.len);
    try std.testing.expectEqualStrings("a\x01b\"c", v.get("esc").?.str);
    const out = try writeValue(std.testing.allocator, v);
    defer std.testing.allocator.free(out);
    const v2 = try Parser.parse(std.testing.allocator, out);
    defer freeValue(std.testing.allocator, v2);
    try std.testing.expectEqualStrings("ls -la\n", v2.get("data").?.str);
    std.debug.print("JSON_ROUNDTRIP_OK\n", .{});
}

test "base64 round-trip binary" {
    const data = [_]u8{ 0x00, 0xFF, 0x10, 0x83, 0x7F, 'h', 'i', 0x1B, 0x5B, 0x00 };
    const enc = try base64Encode(std.testing.allocator, &data);
    defer std.testing.allocator.free(enc);
    const dec = try base64Decode(std.testing.allocator, enc);
    defer std.testing.allocator.free(dec);
    try std.testing.expectEqualSlices(u8, &data, dec);
    // known vector: "hello" -> "aGVsbG8="
    const h = try base64Encode(std.testing.allocator, "hello");
    defer std.testing.allocator.free(h);
    try std.testing.expectEqualStrings("aGVsbG8=", h);
    std.debug.print("BASE64_OK\n", .{});
}

pub fn freeValue(allocator: std.mem.Allocator, v: Value) void {
    switch (v) {
        .str => |s| allocator.free(s),
        .arr => |a| {
            for (a) |item| freeValue(allocator, item);
            allocator.free(a);
        },
        .obj => |o| {
            for (o) |e| {
                allocator.free(e.key);
                freeValue(allocator, e.value);
            }
            allocator.free(o);
        },
        else => {},
    }
}
