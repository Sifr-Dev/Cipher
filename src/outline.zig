//! From-zero `glyf` table reader: decodes simple and composite glyph
//! outlines into point lists, per the OpenType specification.
//!
//! Output is a flattened list of contours; each contour owns a contiguous
//! slice of `Point`. Composite glyphs are resolved recursively (max depth 4):
//! child outlines are transformed by their component's 2x2 matrix + offset
//! and appended into the parent. Quadratic-curve expansion happens later,
//! at rasterization time.
//! Components whose arguments are point indices (ARGS_ARE_XY_VALUES clear)
//! are supported as well: translation is derived from the shared point.
const std = @import("std");
const font = @import("font.zig");

pub const Error = error{
    MissingGlyf,
    MalformedGlyph,
    TooDeep,
    OutOfMemory,
};

pub const Point = struct {
    x: f64,
    y: f64,
    on_curve: bool,
};

pub const Contour = struct {
    start: usize,
    len: usize,
};

pub const Outline = struct {
    points: []Point,
    contours: []Contour,
    x_min: f64,
    y_min: f64,
    x_max: f64,
    y_max: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Outline) void {
        self.allocator.free(self.points);
        self.allocator.free(self.contours);
    }
};

const F = struct {
    fn i16be(bytes: []const u8, at: usize) i16 {
        return std.mem.readInt(i16, bytes[at..][0..2], .big);
    }
    fn u16be(bytes: []const u8, at: usize) u16 {
        return std.mem.readInt(u16, bytes[at..][0..2], .big);
    }
};

const Flags = struct {
    const on_curve = 0x01;
    const x_short = 0x02;
    const y_short = 0x04;
    const repeat = 0x08;
    const x_same_or_positive = 0x10;
    const y_same_or_positive = 0x20;
};

const CompFlags = struct {
    const arg_words = 0x0001;
    const args_are_xy_values = 0x0002;
    const we_have_a_scale = 0x0008;
    const more_components = 0x0020;
    const we_have_an_xy_scale = 0x0040;
    const we_have_a_2x2 = 0x0080;
    const we_have_instructions = 0x0100;
};

pub fn parseGlyph(f: *const font.Font, glyph_id: u16, allocator: std.mem.Allocator) Error!Outline {
    return parseGlyphDepth(f, glyph_id, allocator, 0);
}

fn parseGlyphDepth(f: *const font.Font, glyph_id: u16, allocator: std.mem.Allocator, depth: u8) Error!Outline {
    if (depth > 4) return Error.TooDeep;
    var builder = Builder{
        .points = .empty,
        .contours = .empty,
    };
    errdefer {
        builder.points.deinit(allocator);
        builder.contours.deinit(allocator);
    }
    try parseGlyphInto(f, glyph_id, allocator, &builder, depth);

    if (builder.points.items.len == 0) {
        const points = try allocator.alloc(Point, 0);
        const contours = try allocator.alloc(Contour, 0);
        return .{
            .points = points,
            .contours = contours,
            .x_min = 0,
            .y_min = 0,
            .x_max = 0,
            .y_max = 0,
            .allocator = allocator,
        };
    }

    var x_min: f64 = builder.points.items[0].x;
    var y_min: f64 = builder.points.items[0].y;
    var x_max: f64 = x_min;
    var y_max: f64 = y_min;
    for (builder.points.items) |p| {
        x_min = @min(x_min, p.x);
        y_min = @min(y_min, p.y);
        x_max = @max(x_max, p.x);
        y_max = @max(y_max, p.y);
    }

    return .{
        .points = try builder.points.toOwnedSlice(allocator),
        .contours = try builder.contours.toOwnedSlice(allocator),
        .x_min = x_min,
        .y_min = y_min,
        .x_max = x_max,
        .y_max = y_max,
        .allocator = allocator,
    };
}

const Builder = struct {
    points: std.ArrayList(Point),
    contours: std.ArrayList(Contour),
};

fn parseGlyphInto(f: *const font.Font, glyph_id: u16, allocator: std.mem.Allocator, builder: *Builder, depth: u8) Error!void {
    if (depth > 4) return Error.TooDeep;
    const glyf = f.glyfBytes() orelse return Error.MissingGlyf;
    const range = f.glyphByteRange(glyph_id) orelse return Error.MalformedGlyph;
    if (range.len == 0) {
        // Empty glyph (e.g., space): no outlines, successfully parsed as zero contours.
        return;
    }
    const start: usize = @intCast(range.offset);
    if (start + 10 > glyf.len) return Error.MalformedGlyph;

    const number_of_contours = F.i16be(glyf, start);
    if (number_of_contours >= 0) {
        try parseSimple(glyf, start, @intCast(number_of_contours), allocator, builder);
        return;
    }
    try parseComposite(f, glyf, start, allocator, builder, depth);
}

fn parseSimple(glyf: []const u8, start: usize, contour_count: usize, allocator: std.mem.Allocator, builder: *Builder) Error!void {
    if (contour_count == 0) {
        // Empty contour list is legal (e.g., space glyph): nothing to add.
        return;
    }

    var pos = start + 10;
    const end_points = try allocator.alloc(u16, contour_count);
    defer allocator.free(end_points);
    for (0..contour_count) |i| {
        end_points[i] = F.u16be(glyf, pos);
        pos += 2;
    }

    const instruction_length = F.u16be(glyf, pos);
    pos += 2 + @as(usize, instruction_length);

    const total_points: usize = @as(usize, end_points[contour_count - 1]) + 1;
    const flags = try allocator.alloc(u8, total_points);
    defer allocator.free(flags);

    var point_index: usize = 0;
    while (point_index < total_points) {
        if (pos >= glyf.len) return Error.MalformedGlyph;
        const flag = glyf[pos];
        pos += 1;
        flags[point_index] = flag;
        point_index += 1;
        if (flag & Flags.repeat != 0 and point_index < total_points) {
            if (pos >= glyf.len) return Error.MalformedGlyph;
            const repeat: usize = glyf[pos];
            pos += 1;
            var r: usize = 0;
            while (r < repeat and point_index < total_points) : (r += 1) {
                flags[point_index] = flag;
                point_index += 1;
            }
        }
    }

    const x_deltas = try allocator.alloc(i32, total_points);
    defer allocator.free(x_deltas);
    const y_deltas = try allocator.alloc(i32, total_points);
    defer allocator.free(y_deltas);

    // X coordinates.
    var i: usize = 0;
    while (i < total_points) : (i += 1) {
        const flag = flags[i];
        if (flag & Flags.x_short != 0) {
            if (pos >= glyf.len) return Error.MalformedGlyph;
            const raw = glyf[pos];
            pos += 1;
            x_deltas[i] = if (flag & Flags.x_same_or_positive != 0) @as(i32, raw) else -@as(i32, raw);
        } else if (flag & Flags.x_same_or_positive != 0) {
            x_deltas[i] = 0;
        } else {
            if (pos + 2 > glyf.len) return Error.MalformedGlyph;
            x_deltas[i] = F.i16be(glyf, pos);
            pos += 2;
        }
    }

    // Y coordinates.
    i = 0;
    while (i < total_points) : (i += 1) {
        const flag = flags[i];
        if (flag & Flags.y_short != 0) {
            if (pos >= glyf.len) return Error.MalformedGlyph;
            const raw = glyf[pos];
            pos += 1;
            y_deltas[i] = if (flag & Flags.y_same_or_positive != 0) @as(i32, raw) else -@as(i32, raw);
        } else if (flag & Flags.y_same_or_positive != 0) {
            y_deltas[i] = 0;
        } else {
            if (pos + 2 > glyf.len) return Error.MalformedGlyph;
            y_deltas[i] = F.i16be(glyf, pos);
            pos += 2;
        }
    }

    var contour_start: usize = 0;
    var contour_index: usize = 0;
    var x: f64 = 0;
    var y: f64 = 0;
    for (0..total_points) |point_i| {
        x += @as(f64, @floatFromInt(x_deltas[point_i]));
        y += @as(f64, @floatFromInt(y_deltas[point_i]));
        try builder.points.append(allocator, .{
            .x = x,
            .y = y,
            .on_curve = (flags[point_i] & Flags.on_curve) != 0,
        });
        if (contour_index < contour_count and point_i == end_points[contour_index]) {
            const contour_start_index = builder.points.items.len - (point_i - contour_start + 1);
            try builder.contours.append(allocator, .{
                .start = contour_start_index,
                .len = point_i - contour_start + 1,
            });
            contour_start = point_i + 1;
            contour_index += 1;
        }
    }
}

fn parseComposite(f: *const font.Font, glyf: []const u8, start: usize, allocator: std.mem.Allocator, builder: *Builder, depth: u8) Error!void {
    var pos = start + 10;
    while (true) {
        if (pos + 4 > glyf.len) return Error.MalformedGlyph;
        const flags = F.u16be(glyf, pos);
        const glyph_id = F.u16be(glyf, pos + 2);
        pos += 4;

        var arg1: i32 = 0;
        var arg2: i32 = 0;
        if (flags & CompFlags.arg_words != 0) {
            if (pos + 4 > glyf.len) return Error.MalformedGlyph;
            arg1 = F.i16be(glyf, pos);
            arg2 = F.i16be(glyf, pos + 2);
            pos += 4;
        } else {
            if (pos + 2 > glyf.len) return Error.MalformedGlyph;
            arg1 = @as(i8, @bitCast(glyf[pos]));
            arg2 = @as(i8, @bitCast(glyf[pos + 1]));
            pos += 2;
        }

        var a: f64 = 1.0;
        var b: f64 = 0.0;
        var c: f64 = 0.0;
        var d: f64 = 1.0;

        if (flags & CompFlags.we_have_a_scale != 0) {
            if (pos + 2 > glyf.len) return Error.MalformedGlyph;
            const scale = fixed16_16(F.i16be(glyf, pos));
            a = scale;
            d = scale;
            pos += 2;
        } else if (flags & CompFlags.we_have_an_xy_scale != 0) {
            if (pos + 4 > glyf.len) return Error.MalformedGlyph;
            a = fixed16_16(F.i16be(glyf, pos));
            d = fixed16_16(F.i16be(glyf, pos + 2));
            pos += 4;
        } else if (flags & CompFlags.we_have_a_2x2 != 0) {
            if (pos + 8 > glyf.len) return Error.MalformedGlyph;
            a = fixed16_16(F.i16be(glyf, pos));
            b = fixed16_16(F.i16be(glyf, pos + 2));
            c = fixed16_16(F.i16be(glyf, pos + 4));
            d = fixed16_16(F.i16be(glyf, pos + 6));
            pos += 8;
        }

        var e: f64 = 0;
        var ff: f64 = 0;
        var transform_done = false;
        _ = &transform_done;

        // Recursively parse the child into a temporary outline to apply the transform.
        var child = try parseGlyphDepth(f, glyph_id, allocator, depth + 1);
        defer child.deinit();

        if (flags & CompFlags.args_are_xy_values != 0) {
            e = @as(f64, @floatFromInt(arg1));
            ff = @as(f64, @floatFromInt(arg2));
        } else {
            // Point-matching: offset so child point arg1 lands on parent point arg2.
            const child_index: usize = @intCast(arg1);
            const parent_index: usize = @intCast(arg2);
            if (child_index >= child.points.len or parent_index >= builder.points.items.len) {
                return Error.MalformedGlyph;
            }
            const child_origin = transformPoint(a, b, c, d, child.points[child_index]);
            e = builder.points.items[parent_index].x - child_origin.x;
            ff = builder.points.items[parent_index].y - child_origin.y;
        }

        const base = builder.points.items.len;
        for (child.points) |child_point| {
            const transformed = transformPoint(a, b, c, d, child_point);
            try builder.points.append(allocator, .{
                .x = transformed.x + e,
                .y = transformed.y + ff,
                .on_curve = child_point.on_curve,
            });
        }
        for (child.contours) |contour| {
            try builder.contours.append(allocator, .{
                .start = base + contour.start,
                .len = contour.len,
            });
        }

        if (flags & CompFlags.we_have_instructions != 0) {
            if (pos + 2 > glyf.len) return Error.MalformedGlyph;
            const instruction_length = F.u16be(glyf, pos);
            if (pos + 2 + instruction_length > glyf.len) return Error.MalformedGlyph;
            pos += 2 + @as(usize, instruction_length);
        }

        if (flags & CompFlags.more_components == 0) break;
    }
}

fn transformPoint(a: f64, b: f64, c: f64, d: f64, point: Point) Point {
    return .{
        .x = a * point.x + c * point.y,
        .y = b * point.x + d * point.y,
        .on_curve = point.on_curve,
    };
}

fn fixed16_16(raw: i16) f64 {
    return @as(f64, @floatFromInt(raw)) / 65536.0;
}
