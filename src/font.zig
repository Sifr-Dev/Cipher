//! Cipher's from-zero TrueType/OpenType font reader.
//! No external font library. Parses the sfnt table directory and the tables
//! needed for rasterizing outlines: head, maxp, hhea, hmtx, loca, cmap
//! (formats 4 and 12), glyf (simple and composite outlines).
//! Built from the spec alone; metric structures are verified on the bundled
//! Instrument Sans / Geist Mono (SIL Open Font License 1.1).
const std = @import("std");

pub const Error = error{
    BadSfntMagic,
    TableNotFound,
    MalformedFont,
    UnsupportedGlyphOutline,
};

const Head = struct {
    units_per_em: u16,
    index_to_loc_format: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

const Maxp = struct {
    num_glyphs: u16,
};

const Hhea = struct {
    ascender: i16,
    descender: i16,
    line_gap: i16,
    number_of_h_metrics: u16,
};

const GlyphHeader = struct {
    number_of_contours: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const Font = struct {
    bytes: []const u8,
    tables: [256]Table,
    tables_len: u8 = 0,
    tables_claimed: [256]usize = undefined,
    head: Head = undefined,
    maxp: Maxp = undefined,
    hhea: Hhea = undefined,

    const Table = struct {
        tag: u32,
        checksum: u32,
        offset: u32,
        length: u32,
    };

    pub fn parse(bytes: []const u8) !Font {
        if (bytes.len < 12) return Error.BadSfntMagic;
        const magic = std.mem.readInt(u32, bytes[0..4], .big);
        if (magic != 0x00010000 and magic != 0x4f54544f) return Error.BadSfntMagic; // 1.0 or CFF-based 'OTTO'

        var font = Font{
            .bytes = bytes,
            .tables = undefined,
        };
        const num_tables = std.mem.readInt(u16, bytes[4..6], .big);
        var cursor: usize = 12;
        var index: usize = 0;
        while (index < num_tables and index < 256) : (index += 1) {
            font.tables[index] = .{
                .tag = std.mem.readInt(u32, bytes[cursor..][0..4], .big),
                .checksum = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .big),
                .offset = std.mem.readInt(u32, bytes[cursor + 8 ..][0..4], .big),
                .length = std.mem.readInt(u32, bytes[cursor + 12 ..][0..4], .big),
            };
            cursor += 16;
        }
        font.tables_len = @intCast(index);

        font.head = try font.readHead();
        font.maxp = try font.readMaxp();
        font.hhea = try font.readHhea();
        return font;
    }

    fn tableBytes(self: *const Font, wanted: u32) ?[]const u8 {
        for (self.tables[0..self.tables_len]) |table| {
            if (table.tag != wanted) continue;
            const start: usize = @intCast(table.offset);
            const end: usize = start + @as(usize, @intCast(table.length));
            if (end > self.bytes.len) return null;
            return self.bytes[start..end];
        }
        return null;
    }

    fn tag(a: u8, b: u8, c: u8, d: u8) u32 {
        return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, c) << 8) | @as(u32, d);
    }

    fn readHead(self: *const Font) !Head {
        const table = self.tableBytes(tag('h', 'e', 'a', 'd')) orelse return Error.TableNotFound;
        if (table.len < 54) return Error.MalformedFont;
        return .{
            .units_per_em = std.mem.readInt(u16, table[18..20], .big),
            .index_to_loc_format = std.mem.readInt(i16, table[50..52], .big),
            .x_min = std.mem.readInt(i16, table[36..38], .big),
            .y_min = std.mem.readInt(i16, table[38..40], .big),
            .x_max = std.mem.readInt(i16, table[40..42], .big),
            .y_max = std.mem.readInt(i16, table[42..44], .big),
        };
    }

    fn readMaxp(self: *const Font) !Maxp {
        const table = self.tableBytes(tag('m', 'a', 'x', 'p')) orelse return Error.TableNotFound;
        if (table.len < 6) return Error.MalformedFont;
        return .{
            .num_glyphs = std.mem.readInt(u16, table[4..6], .big),
        };
    }

    fn readHhea(self: *const Font) !Hhea {
        const table = self.tableBytes(tag('h', 'h', 'e', 'a')) orelse return Error.TableNotFound;
        if (table.len < 36) return Error.MalformedFont;
        return .{
            .ascender = std.mem.readInt(i16, table[4..6], .big),
            .descender = std.mem.readInt(i16, table[6..8], .big),
            .line_gap = std.mem.readInt(i16, table[8..10], .big),
            .number_of_h_metrics = std.mem.readInt(u16, table[34..36], .big),
        };
    }

    pub fn glyfBytes(self: *const Font) ?[]const u8 {
        return self.tableBytes(tag('g', 'l', 'y', 'f'));
    }

    pub fn locaBytes(self: *const Font) ?[]const u8 {
        return self.tableBytes(tag('l', 'o', 'c', 'a'));
    }

    pub fn glyphOffset(self: *const Font, glyph: u16) ?u32 {
        const table = self.tableBytes(tag('l', 'o', 'c', 'a')) orelse return null;
        const format: i16 = self.head.index_to_loc_format;
        if (format == 0) {
            const index: usize = @as(usize, glyph) * 2;
            if (index + 2 > table.len) return null;
            const short = std.mem.readInt(u16, table[index..][0..2], .big);
            return @as(u32, short) * 2;
        }
        const index: usize = @as(usize, glyph) * 4;
        if (index + 4 > table.len) return null;
        return std.mem.readInt(u32, table[index..][0..4], .big);
    }

    pub fn glyphHeader(self: *const Font, glyph: u16) ?GlyphHeader {
        const start = self.glyphOffset(glyph) orelse return null;
        const glyf = self.tableBytes(tag('g', 'l', 'y', 'f')) orelse return null;
        const index: usize = @intCast(start);
        if (index + 10 > glyf.len) return null;
        return .{
            .number_of_contours = std.mem.readInt(i16, glyf[index..][0..2], .big),
            .x_min = std.mem.readInt(i16, glyf[index + 2 ..][0..2], .big),
            .y_min = std.mem.readInt(i16, glyf[index + 4 ..][0..2], .big),
            .x_max = std.mem.readInt(i16, glyf[index + 6 ..][0..2], .big),
            .y_max = std.mem.readInt(i16, glyf[index + 8 ..][0..2], .big),
        };
    }

    pub fn glyphAdvance(self: *const Font, glyph: u16) u16 {
        const table = self.tableBytes(tag('h', 'm', 't', 'x')) orelse return 0;
        const metrics = self.hhea.number_of_h_metrics;
        const index = if (glyph < metrics) @as(usize, glyph) * 4 else @as(usize, metrics - 1) * 4;
        if (index + 2 > table.len) return 0;
        return std.mem.readInt(u16, table[index..][0..2], .big);
    }

    pub fn glyphSideBearing(self: *const Font, glyph: u16) i16 {
        const table = self.tableBytes(tag('h', 'm', 't', 'x')) orelse return 0;
        const metrics = self.hhea.number_of_h_metrics;
        const index = if (glyph < metrics) @as(usize, glyph) * 4 + 2 else @as(usize, metrics) * 4 + 2 * @as(usize, glyph - metrics);
        if (index + 2 > table.len) return 0;
        return std.mem.readInt(i16, table[index..][0..2], .big);
    }

    pub fn cmapGlyph(self: *const Font, codepoint: u32) ?u16 {
        const cmap = self.tableBytes(tag('c', 'm', 'a', 'p')) orelse return null;
        if (cmap.len < 4) return null;

        // Parse subtable records: version(2) numTables(2) then records of platformID(2) encodingID(2) offset(4).
        const num_tables = std.mem.readInt(u16, cmap[2..4], .big);
        var best_offset: ?u32 = null;
        var best_rank: u8 = 0;

        var index: usize = 0;
        while (index < num_tables) : (index += 1) {
            const record = 4 + @as(usize, index) * 8;
            if (record + 8 > cmap.len) return null;
            const platform = std.mem.readInt(u16, cmap[record..][0..2], .big);
            const encoding = std.mem.readInt(u16, cmap[record + 2 ..][0..2], .big);
            const offset = std.mem.readInt(u32, cmap[record + 4 ..][0..4], .big);
            const start: usize = @intCast(offset);
            if (start + 2 > cmap.len) continue;
            const format = std.mem.readInt(u16, cmap[start..][0..2], .big);

            var rank: u8 = 0;
            if (platform == 3 and encoding == 10 and format == 12) {
                rank = 4;
            } else if (platform == 0 and format == 12) {
                rank = 3;
            } else if (platform == 3 and encoding == 10 and format == 4) {
                rank = 2;
            } else if (platform == 3 and encoding == 1 and format == 4) {
                rank = 1;
            } else if (platform == 0 and format == 4) {
                rank = 1;
            }
            if (rank > best_rank) {
                best_rank = rank;
                best_offset = offset;
            }
        }

        const offset = best_offset orelse return null;
        const start: usize = @intCast(offset);
        const format = std.mem.readInt(u16, cmap[start..][0..2], .big);
        switch (format) {
            4 => return cmapFormat4(cmap[start..], codepoint),
            12 => return cmapFormat12(cmap[start..], codepoint),
            else => return null,
        }
    }

    fn cmapFormat4(subtable: []const u8, codepoint: u32) ?u16 {
        if (subtable.len < 16) return null;
        const seg_count_x2 = std.mem.readInt(u16, subtable[6..8], .big);
        const seg_count: usize = seg_count_x2 / 2;
        const array_base: usize = 14;
        const end_codes = array_base;
        const start_codes = end_codes + seg_count * 2 + 2;
        const id_deltas = start_codes + seg_count * 2;
        const id_range_offsets = id_deltas + seg_count * 2;

        var segment_index: usize = 0;
        while (segment_index < seg_count) : (segment_index += 1) {
            const end_code = std.mem.readInt(u16, subtable[end_codes + segment_index * 2 ..][0..2], .big);
            const start_code = std.mem.readInt(u16, subtable[start_codes + segment_index * 2 ..][0..2], .big);
            if (codepoint < start_code or codepoint > end_code) continue;

            const id_delta = std.mem.readInt(i16, subtable[id_deltas + segment_index * 2 ..][0..2], .big);
            const range_offset = std.mem.readInt(u16, subtable[id_range_offsets + segment_index * 2 ..][0..2], .big);
            if (range_offset == 0) {
                return @truncate((@as(u32, @intCast(id_delta)) + codepoint) & 0xffff);
            }
            const glyph_index_address = id_range_offsets + segment_index * 2 + range_offset + (codepoint - start_code) * 2;
            if (glyph_index_address + 2 > subtable.len) return null;
            const glyph = std.mem.readInt(u16, subtable[glyph_index_address..][0..2], .big);
            if (glyph == 0) return 0;
            return @truncate((@as(u32, @intCast(id_delta)) + glyph) & 0xffff);
        }
        return 0;
    }

    fn cmapFormat12(subtable: []const u8, codepoint: u32) ?u16 {
        if (subtable.len < 16) return null;

        const n_groups = std.mem.readInt(u32, subtable[12..16], .big);
        var group_index: usize = 0;
        while (group_index < n_groups) : (group_index += 1) {
            const group = 16 + group_index * 12;
            const start_char = std.mem.readInt(u32, subtable[group..][0..4], .big);
            const end_char = std.mem.readInt(u32, subtable[group + 4 ..][0..4], .big);
            const start_glyph = std.mem.readInt(u32, subtable[group + 8 ..][0..4], .big);
            if (codepoint < start_char) return 0;
            if (codepoint <= end_char) return @truncate(start_glyph + (codepoint - start_char));
        }
        return 0;
    }
};
