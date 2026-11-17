//! From-zero SFNT (TrueType) font parser: table directory, cmap (formats 4
//! and 12), loca/glyf outline extraction (simple + composite glyphs), head,
//! hhea/hmtx metrics. Big-endian reads only; no dependencies, no stdlib font
//! code — everything is parsed by hand from the bytes.
const std = @import("std");

pub const FontError = error{
    NotSfnt,
    Truncated,
    BadTable,
    UnsupportedCmap,
    UnsupportedGlyph,
    OutOfMemory,
};

pub const Point = struct {
    x: i32,
    y: i32,
    on_curve: bool,
};

pub const Contour = struct {
    points: []Point,
};

/// Flattened outline in font units (y-up).
pub const Outline = struct {
    contours: []Contour,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        for (self.contours) |c| allocator.free(c.points);
        allocator.free(self.contours);
    }
};

pub const Font = struct {
    data: []const u8,
    num_glyphs: u16,
    units_per_em: u16,
    index_to_loc_format: i16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    num_h_metrics: u16,

    cmap_off: u32,
    cmap_len: u32,
    glyf_off: u32,
    loca_off: u32,
    head_off: u32,
    hhea_off: u32,
    hmtx_off: u32,
    maxp_off: u32,

    fn u16at(self: *const Font, off: u32) FontError!u16 {
        if (off + 2 > self.data.len) return error.Truncated;
        return std.mem.readInt(u16, self.data[off..][0..2], .big);
    }
    fn i16at(self: *const Font, off: u32) FontError!i16 {
        if (off + 2 > self.data.len) return error.Truncated;
        return std.mem.readInt(i16, self.data[off..][0..2], .big);
    }
    fn u32at(self: *const Font, off: u32) FontError!u32 {
        if (off + 4 > self.data.len) return error.Truncated;
        return std.mem.readInt(u32, self.data[off..][0..4], .big);
    }

    pub fn load(data: []const u8) FontError!Font {
        if (data.len < 12) return error.NotSfnt;
        const scaler = std.mem.readInt(u32, data[0..4], .big);
        // 0x00010000 (TrueType), 'true', 'typ1' are all SFNT-wrapped outlines.
        if (scaler != 0x00010000 and scaler != 0x74727565 and scaler != 0x74797031)
            return error.NotSfnt;
        const num_tables = std.mem.readInt(u16, data[4..6], .big);
        if (12 + @as(usize, num_tables) * 16 > data.len) return error.Truncated;

        var f = Font{
            .data = data,
            .num_glyphs = 0,
            .units_per_em = 1000,
            .index_to_loc_format = 0,
            .ascender = 0,
            .descender = 0,
            .line_gap = 0,
            .num_h_metrics = 0,
            .cmap_off = 0,
            .cmap_len = 0,
            .glyf_off = 0,
            .loca_off = 0,
            .head_off = 0,
            .hhea_off = 0,
            .hmtx_off = 0,
            .maxp_off = 0,
        };
        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            const tag = data[rec..][0..4];
            const off = std.mem.readInt(u32, data[rec + 8 ..][0..4], .big);
            const len = std.mem.readInt(u32, data[rec + 12 ..][0..4], .big);
            if (std.mem.eql(u8, tag, "cmap")) {
                f.cmap_off = off;
                f.cmap_len = len;
            } else if (std.mem.eql(u8, tag, "glyf")) f.glyf_off = off
            else if (std.mem.eql(u8, tag, "loca")) f.loca_off = off
            else if (std.mem.eql(u8, tag, "head")) f.head_off = off
            else if (std.mem.eql(u8, tag, "hhea")) f.hhea_off = off
            else if (std.mem.eql(u8, tag, "hmtx")) f.hmtx_off = off
            else if (std.mem.eql(u8, tag, "maxp")) f.maxp_off = off;
        }
        if (f.cmap_off == 0 or f.glyf_off == 0 or f.loca_off == 0 or
            f.head_off == 0 or f.hhea_off == 0 or f.hmtx_off == 0 or f.maxp_off == 0)
            return error.BadTable;

        f.num_glyphs = try f.u16at(f.maxp_off + 4);
        f.units_per_em = try f.u16at(f.head_off + 18);
        f.index_to_loc_format = try f.i16at(f.head_off + 50);
        f.ascender = try f.i16at(f.hhea_off + 4);
        f.descender = try f.i16at(f.hhea_off + 6);
        f.line_gap = try f.i16at(f.hhea_off + 8);
        f.num_h_metrics = try f.u16at(f.hhea_off + 34);
        return f;
    }

    /// cmap lookup: Unicode codepoint -> glyph index (0 = .notdef).
    pub fn glyphIndex(self: *const Font, codepoint: u32) FontError!u16 {
        const base = self.cmap_off;
        if (base + 4 > self.data.len) return error.Truncated;
        const num_sub = try self.u16at(base + 2);
        var sub_off: u32 = 0;
        var sub_fmt: u16 = 0;
        var best: u32 = 0;
        var best_fmt: u16 = 0;
        var i: usize = 0;
        while (i < num_sub) : (i += 1) {
            const rec = base + 4 + i * 8;
            if (rec + 8 > self.data.len) return error.Truncated;
            const platform = try self.u16at(@intCast(rec));
            const encoding = try self.u16at(@intCast(rec + 2));
            const off = try self.u32at(@intCast(rec + 4));
            // Prefer (3,10) fmt12, then (3,1)/(0,3) fmt4, then (0,0..2) fmt4/6/0.
            var score: u32 = 0;
            if (platform == 3 and encoding == 10) score = 4;
            if (platform == 3 and encoding == 1) score = 3;
            if (platform == 0 and encoding >= 3) score = 3;
            if (platform == 0 and encoding <= 2) score = 2;
            if (platform == 3 and encoding == 0) score = 1;
            if (score > best) {
                best = score;
                sub_off = base + off;
                sub_fmt = try self.u16at(sub_off);
                best_fmt = sub_fmt;
            }
        }
        if (best == 0) return error.UnsupportedCmap;
        return self.cmapLookup(sub_off, best_fmt, codepoint);
    }

    fn cmapLookup(self: *const Font, sub: u32, fmt: u16, cp: u32) FontError!u16 {
        switch (fmt) {
            4 => return self.cmapFormat4(sub, cp),
            12 => return self.cmapFormat12(sub, cp),
            else => return error.UnsupportedCmap,
        }
    }

    fn cmapFormat4(self: *const Font, sub: u32, cp: u32) FontError!u16 {
        if (cp > 0xFFFF) return 0;
        const seg_count_x2 = try self.u16at(sub + 6);
        const seg_count = @as(u32, seg_count_x2) / 2;
        const end_base = sub + 14;
        const start_base = end_base + @as(u32, seg_count_x2) + 2;
        const delta_base = start_base + @as(u32, seg_count_x2);
        const range_base = delta_base + @as(u32, seg_count_x2);
        var seg: u32 = 0;
        while (seg < seg_count) : (seg += 1) {
            const end_code = try self.u16at(end_base + seg * 2);
            if (@as(u32, @as(u16, @intCast(cp))) <= end_code) {
                const start_code = try self.u16at(start_base + seg * 2);
                if (cp < start_code) return 0;
                const id_delta = try self.i16at(delta_base + seg * 2);
                const id_range_off = try self.u16at(range_base + seg * 2);
                if (id_range_off == 0) {
                    return @intCast((@as(i32, @intCast(cp)) + id_delta) & 0xFFFF);
                }
                const glyph_addr = range_base + seg * 2 + @as(u32, id_range_off) +
                    2 * (cp - start_code);
                const gid = try self.u16at(glyph_addr);
                if (gid == 0) return 0;
                return @intCast((@as(i32, gid) + id_delta) & 0xFFFF);
            }
        }
        return 0;
    }

    fn cmapFormat12(self: *const Font, sub: u32, cp: u32) FontError!u16 {
        const num_groups = try self.u32at(sub + 12);
        var lo: u32 = 0;
        var hi: u32 = num_groups;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const g = sub + 16 + mid * 12;
            const start = try self.u32at(g);
            const end = try self.u32at(g + 4);
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                const start_glyph = try self.u32at(g + 8);
                return @intCast(start_glyph + (cp - start));
            }
        }
        return 0;
    }

    /// Advance width in font units.
    pub fn advanceWidth(self: *const Font, gid: u16) FontError!u16 {
        const idx: u32 = if (gid < self.num_h_metrics) gid else self.num_h_metrics - 1;
        return self.u16at(self.hmtx_off + @as(u32, idx) * 4);
    }

    /// Left side bearing in font units.
    pub fn leftSideBearing(self: *const Font, gid: u16) FontError!i16 {
        const idx: u32 = if (gid < self.num_h_metrics) gid else self.num_h_metrics - 1;
        return self.i16at(self.hmtx_off + @as(u32, idx) * 4 + 2);
    }

    fn glyphOffset(self: *const Font, gid: u16) FontError!u32 {
        if (self.index_to_loc_format == 0) {
            const o = try self.u16at(self.loca_off + @as(u32, gid) * 2);
            return @as(u32, o) * 2;
        }
        return self.u32at(self.loca_off + @as(u32, gid) * 4);
    }

    /// Extract the outline of a glyph in font units. Composite glyphs are
    /// resolved recursively (translation + optional 2x2 transform).
    pub fn outline(self: *const Font, gid: u16, allocator: std.mem.Allocator) FontError!Outline {
        var contours: std.ArrayList(Contour) = .empty;
        errdefer {
            for (contours.items) |c| allocator.free(c.points);
            contours.deinit(allocator);
        }
        const start = try self.glyphOffset(gid);
        const end = if (self.index_to_loc_format == 0)
            @as(u32, try self.u16at(self.loca_off + @as(u32, gid + 1) * 2)) * 2
        else
            try self.u32at(self.loca_off + @as(u32, gid + 1) * 4);
        if (end <= start) {
            return Outline{ .contours = try contours.toOwnedSlice(allocator), .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
        }
        const g = self.glyf_off + start;
        if (g + 10 > self.data.len) return error.Truncated;
        const num_contours = try self.i16at(g);
        const x_min = try self.i16at(g + 2);
        const y_min = try self.i16at(g + 4);
        const x_max = try self.i16at(g + 6);
        const y_max = try self.i16at(g + 8);
        if (num_contours >= 0) {
            try self.parseSimple(g + 10, @intCast(num_contours), &contours, allocator);
        } else {
            try self.parseComposite(g + 10, &contours, allocator, 0);
        }
        return Outline{
            .contours = try contours.toOwnedSlice(allocator),
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        };
    }

    fn parseSimple(self: *const Font, off: u32, num_contours: u16, out: *std.ArrayList(Contour), allocator: std.mem.Allocator) FontError!void {
        if (num_contours == 0) return;
        var p = off;
        const end_pts_base = p;
        p += @as(u32, num_contours) * 2;
        const num_points: u32 = if (num_contours > 0) @as(u32, try self.u16at(end_pts_base + @as(u32, num_contours - 1) * 2)) + 1 else 0;
        const instr_len = try self.u16at(p);
        p += 2 + instr_len;
        // flags
        var flags: []u8 = try allocator.alloc(u8, num_points);
        defer allocator.free(flags);
        var i: u32 = 0;
        while (i < num_points) {
            if (p >= self.data.len) return error.Truncated;
            const fl = self.data[p];
            p += 1;
            flags[i] = fl;
            i += 1;
            if (fl & 0x08 != 0) {
                if (p >= self.data.len) return error.Truncated;
                const rep = self.data[p];
                p += 1;
                var r: u32 = 0;
                while (r < rep) : (r += 1) {
                    if (i >= num_points) return error.Truncated;
                    flags[i] = fl;
                    i += 1;
                }
            }
        }
        // x coordinates (deltas)
        var xs: []i32 = try allocator.alloc(i32, num_points);
        defer allocator.free(xs);
        var x: i32 = 0;
        i = 0;
        while (i < num_points) : (i += 1) {
            const fl = flags[i];
            if (fl & 0x02 != 0) {
                if (p >= self.data.len) return error.Truncated;
                const b = self.data[p];
                p += 1;
                x += if (fl & 0x10 != 0) b else -@as(i32, b);
            } else if (fl & 0x10 == 0) {
                const v = try self.i16at(p);
                p += 2;
                x += v;
            }
            xs[i] = x;
        }
        var ys: []i32 = try allocator.alloc(i32, num_points);
        defer allocator.free(ys);
        var y: i32 = 0;
        i = 0;
        while (i < num_points) : (i += 1) {
            const fl = flags[i];
            if (fl & 0x04 != 0) {
                if (p >= self.data.len) return error.Truncated;
                const b = self.data[p];
                p += 1;
                y += if (fl & 0x20 != 0) b else -@as(i32, b);
            } else if (fl & 0x20 == 0) {
                const v = try self.i16at(p);
                p += 2;
                y += v;
            }
            ys[i] = y;
        }
        // build contours
        var c: u32 = 0;
        var pt_start: u32 = 0;
        while (c < num_contours) : (c += 1) {
            const end_pt = try self.u16at(end_pts_base + c * 2);
            const n = end_pt - pt_start + 1;
            const pts = try allocator.alloc(Point, n);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const idx = pt_start + k;
                pts[k] = .{ .x = xs[idx], .y = ys[idx], .on_curve = flags[idx] & 0x01 != 0 };
            }
            try out.append(allocator, .{ .points = pts });
            pt_start = end_pt + 1;
        }
    }

    fn parseComposite(self: *const Font, off: u32, out: *std.ArrayList(Contour), allocator: std.mem.Allocator, depth: u8) FontError!void {
        if (depth > 8) return error.UnsupportedGlyph;
        var p = off;
        while (true) {
            if (p + 4 > self.data.len) return error.Truncated;
            const flags = try self.u16at(p);
            const gid = try self.u16at(p + 2);
            p += 4;
            // args
            var dx: i32 = 0;
            var dy: i32 = 0;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                dx = try self.i16at(p);
                dy = try self.i16at(p + 2);
                p += 4;
            } else {
                if (p + 2 > self.data.len) return error.Truncated;
                dx = @as(i8, @bitCast(self.data[p]));
                dy = @as(i8, @bitCast(self.data[p + 1]));
                p += 2;
            }
            var xx: f32 = 1;
            var xy: f32 = 0;
            var yx: f32 = 0;
            var yy: f32 = 1;
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                xx = @as(f32, @floatFromInt(try self.i16at(p))) / 16384.0;
                yy = xx;
                p += 2;
            } else if (flags & 0x0040 != 0) { // X_AND_Y_SCALE
                xx = @as(f32, @floatFromInt(try self.i16at(p))) / 16384.0;
                yy = @as(f32, @floatFromInt(try self.i16at(p + 2))) / 16384.0;
                p += 4;
            } else if (flags & 0x0080 != 0) { // TWO_BY_TWO
                xx = @as(f32, @floatFromInt(try self.i16at(p))) / 16384.0;
                xy = @as(f32, @floatFromInt(try self.i16at(p + 2))) / 16384.0;
                yx = @as(f32, @floatFromInt(try self.i16at(p + 4))) / 16384.0;
                yy = @as(f32, @floatFromInt(try self.i16at(p + 6))) / 16384.0;
                p += 8;
            }
            var sub = try self.outline(gid, allocator);
            defer sub.deinit(allocator);
            for (sub.contours) |sc| {
                const pts = try allocator.alloc(Point, sc.points.len);
                for (sc.points, 0..) |pt, k| {
                    const fx = @as(f32, @floatFromInt(pt.x));
                    const fy = @as(f32, @floatFromInt(pt.y));
                    pts[k] = .{
                        .x = @intFromFloat(@round(fx * xx + fy * xy + @as(f32, @floatFromInt(dx)))),
                        .y = @intFromFloat(@round(fx * yx + fy * yy + @as(f32, @floatFromInt(dy)))),
                        .on_curve = pt.on_curve,
                    };
                }
                try out.append(allocator, .{ .points = pts });
            }
            if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
        }
    }
};
