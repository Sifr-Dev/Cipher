//! Glyph atlas + CPU text drawing. Glyphs are rasterized on demand into a
//! shelf-packed single-channel (R8) atlas; drawText blends coverage over an
//! ARGB8888 framebuffer with source-over.
const std = @import("std");
const font = @import("font.zig");
const raster = @import("raster.zig");
const grapheme = @import("grapheme.zig");

pub const GlyphInfo = struct {
    atlas_x: u32,
    atlas_y: u32,
    w: u32,
    h: u32,
    bearing_x: f32, // px from pen position to glyph left edge
    top: f32, // px from baseline up to glyph top edge
    advance: f32, // px pen advance
};

const FontEntry = struct {
    f: font.Font,
    scale: f32,
};

pub const TextAtlas = struct {
    allocator: std.mem.Allocator,
    font: font.Font,
    font_data: []const u8,
    px_size: f32,
    scale: f32,
    /// Additional fonts tried (in order) when the primary font maps a
    /// codepoint to .notdef. Glyphs rasterize into the SAME atlas/texture,
    /// so the GPU path needs no changes.
    fallbacks: std.ArrayList(FontEntry) = .empty,

    atlas: []u8,
    atlas_w: u32,
    atlas_h: u32,
    shelf_x: u32 = 1,
    shelf_y: u32 = 1,
    shelf_h: u32 = 0,

    cache: std.AutoHashMap(u32, GlyphInfo),
    /// Set when a glyph is rasterized after the atlas texture was uploaded;
    /// the runtime re-uploads when set.
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, font_data: []const u8, px_size: f32) !TextAtlas {
        const f = try font.Font.load(font_data);
        // Reserve texel (0,0) as solid white: rect quads sample uv=(0,0) with
        // coverage 1.0 -> exact solid color from the vertex color.
        // (shelf packing starts at (1,1), so (0,0) stays free)
        const w: u32 = 1024;
        const h: u32 = 1024;
        const atlas_buf = try allocator.alloc(u8, @as(usize, w) * h);
        @memset(atlas_buf, 0);
        atlas_buf[0] = 255;
        return .{
            .atlas = atlas_buf,
            .allocator = allocator,
            .font = f,
            .font_data = font_data,
            .px_size = px_size,
            .scale = px_size / @as(f32, @floatFromInt(f.units_per_em)),
            .atlas_w = w,
            .atlas_h = h,
            .cache = std.AutoHashMap(u32, GlyphInfo).init(allocator),
        };
    }

    /// Register a fallback font (its SFNT data must outlive the atlas).
    pub fn addFallback(self: *TextAtlas, font_data: []const u8) !void {
        const f = try font.Font.load(font_data);
        try self.fallbacks.append(self.allocator, .{
            .f = f,
            .scale = self.px_size / @as(f32, @floatFromInt(f.units_per_em)),
        });
    }

    pub fn deinit(self: *TextAtlas) void {
        self.fallbacks.deinit(self.allocator);
        self.cache.deinit();
        self.allocator.free(self.atlas);
    }

    /// UTF-8 decode helper: returns codepoint and byte length.
    pub fn decodeUtf8(s: []const u8) ?struct { cp: u32, len: usize } {
        if (s.len == 0) return null;
        const b0 = s[0];
        if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
        if (b0 & 0xE0 == 0xC0 and s.len >= 2) {
            return .{ .cp = (@as(u32, b0 & 0x1F) << 6) | (s[1] & 0x3F), .len = 2 };
        }
        if (b0 & 0xF0 == 0xE0 and s.len >= 3) {
            return .{ .cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, s[1] & 0x3F) << 6) | (s[2] & 0x3F), .len = 3 };
        }
        if (b0 & 0xF8 == 0xF0 and s.len >= 4) {
            return .{ .cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, s[1] & 0x3F) << 12) | (@as(u32, s[2] & 0x3F) << 6) | (s[3] & 0x3F), .len = 4 };
        }
        return null;
    }

    /// Get (rasterizing and packing on miss) the atlas entry for a codepoint.
    pub fn glyph(self: *TextAtlas, cp: u32) !GlyphInfo {
        if (self.cache.get(cp)) |g| return g;
        var active_font = &self.font;
        var active_scale = self.scale;
        var gid = try self.font.glyphIndex(cp);
        if (gid == 0) {
            for (self.fallbacks.items) |*fe| {
                const fgid = fe.f.glyphIndex(cp) catch 0;
                if (fgid != 0) {
                    active_font = &fe.f;
                    active_scale = fe.scale;
                    gid = fgid;
                    break;
                }
            }
        }
        const advance_units = try active_font.advanceWidth(gid);
        const advance_px = @as(f32, @floatFromInt(advance_units)) * active_scale;
        var info = GlyphInfo{
            .atlas_x = 0,
            .atlas_y = 0,
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .top = 0,
            .advance = advance_px,
        };
        var outline = try active_font.outline(gid, self.allocator);
        defer outline.deinit(self.allocator);
        if (outline.contours.len > 0 and outline.x_max > outline.x_min and outline.y_max > outline.y_min) {
            const gw = @ceil(@as(f32, @floatFromInt(outline.x_max - outline.x_min)) * active_scale) + 2;
            const gh = @ceil(@as(f32, @floatFromInt(outline.y_max - outline.y_min)) * active_scale) + 2;
            const w: u32 = @intFromFloat(gw);
            const h: u32 = @intFromFloat(gh);
            // rasterize tight: font (x_min, y_max) -> pixel (1, 1)
            const segs = try raster.flatten(
                outline.contours,
                active_scale,
                1 - @as(f32, @floatFromInt(outline.x_min)) * active_scale,
                1 + @as(f32, @floatFromInt(outline.y_max)) * active_scale,
                self.allocator,
            );
            defer self.allocator.free(segs);
            const cov = try self.allocator.alloc(u8, @as(usize, w) * h);
            defer self.allocator.free(cov);
            raster.rasterize(segs, w, h, cov);
            // shelf-pack with 1px padding
            if (self.shelf_x + w + 1 > self.atlas_w) {
                self.shelf_x = 1;
                self.shelf_y += self.shelf_h + 1;
                self.shelf_h = 0;
            }
            if (self.shelf_y + h + 1 > self.atlas_h) return error.AtlasFull;
            if (h > self.shelf_h) self.shelf_h = h;
            info.atlas_x = self.shelf_x;
            info.atlas_y = self.shelf_y;
            info.w = w;
            info.h = h;
            info.bearing_x = @as(f32, @floatFromInt(outline.x_min)) * active_scale;
            info.top = @as(f32, @floatFromInt(outline.y_max)) * active_scale;
            for (0..h) |row| {
                const src = cov[row * w ..][0..w];
                const dst = self.atlas[@as(usize, self.shelf_y + @as(u32, @intCast(row))) * self.atlas_w + self.shelf_x ..][0..w];
                @memcpy(dst, src);
            }
            self.shelf_x += w + 1;
        } else {
            info.bearing_x = 0;
            info.top = 0;
        }
        try self.cache.put(cp, info);
        self.dirty = true;
        return info;
    }

    /// Like glyph(), but never fails: on cmap/outline/atlas failure the
    /// .notdef glyph is used (usually an advance-only zero-coverage entry);
    /// if even that is unavailable, a blank advance-only glyph is returned
    /// so text layout never breaks when a single glyph is bad.
    pub fn glyphSafe(self: *TextAtlas, cp: u32) GlyphInfo {
        return self.glyph(cp) catch self.glyph(0) catch .{
            .atlas_x = 0,
            .atlas_y = 0,
            .w = 0,
            .h = 0,
            .bearing_x = 0,
            .top = 0,
            .advance = self.px_size * 0.5,
        };
    }

    /// Eagerly rasterize a codepoint range so the atlas texture can be
    /// uploaded once at startup (glyph rasterization is lazy otherwise).
    pub fn bake(self: *TextAtlas, first: u32, last: u32) !void {
        var cp = first;
        while (cp <= last) : (cp += 1) {
            _ = self.glyph(cp) catch {}; // skip unmappable codepoints
        }
        self.dirty = false; // everything baked is in the CPU atlas already
    }

    /// Width of a string in px at this atlas size (sum of advances).
    pub fn measure(self: *TextAtlas, text: []const u8) !f32 {
        var w: f32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const d = decodeUtf8(text[i..]) orelse {
                i += 1;
                continue;
            };
            const g = self.glyphSafe(d.cp);
            w += g.advance;
            i += d.len;
        }
        return w;
    }

    /// Logical-pixel width when `scale` is the UI's device-pixel scale.
    pub fn measureWidth(self: *TextAtlas, text: []const u8) f32 {
        return (self.measure(text) catch 0) / @max(self.scale, 0.0001);
    }

    /// Grapheme-cluster index nearest a logical x position. Each cluster is
    /// hit at its midpoint; combining sequences cannot split the caret.
    pub fn clusterIndexAt(self: *TextAtlas, text: []const u8, x: f32) usize {
        if (x <= 0) return 0;
        var pen: f32 = 0;
        var i: usize = 0;
        var index: usize = 0;
        while (i < text.len) : (index += 1) {
            const len = grapheme.clusterLen(text[i..]);
            const next = pen + self.measureWidth(text[i .. i + len]);
            if (x < pen + (next - pen) / 2) return index;
            pen = next;
            i += len;
        }
        return index;
    }

    /// Byte offset of the nearest caret in a single text line.
    pub fn cursorByteAt(self: *TextAtlas, text: []const u8, x: f32) usize {
        var i: usize = 0;
        var index = self.clusterIndexAt(text, x);
        while (index > 0 and i < text.len) : (index -= 1) i += grapheme.clusterLen(text[i..]);
        return i;
    }

    /// Draw text with source-over blending into an ARGB8888 u32 framebuffer.
    /// (x, baseline) in pixels, y-down. color is 0xAARRGGBB.
    pub fn drawText(self: *TextAtlas, fb: []u32, fb_w: u32, fb_h: u32, x: f32, baseline: f32, text: []const u8, color: u32) !void {
        var pen = x;
        var i: usize = 0;
        while (i < text.len) {
            const d = decodeUtf8(text[i..]) orelse {
                i += 1;
                continue;
            };
            const g = self.glyphSafe(d.cp);
            if (g.w > 0 and g.h > 0) {
                const gx = @as(i32, @intFromFloat(@round(pen + g.bearing_x)));
                const gy = @as(i32, @intFromFloat(@round(baseline - g.top)));
                const ca = @as(f32, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
                const cr = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const cg = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const cb = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
                for (0..g.h) |row| {
                    const py = gy + @as(i32, @intCast(row));
                    if (py < 0 or py >= @as(i32, @intCast(fb_h))) continue;
                    for (0..g.w) |col| {
                        const cov = self.atlas[@as(usize, g.atlas_y + @as(u32, @intCast(row))) * self.atlas_w + g.atlas_x + @as(u32, @intCast(col))];
                        if (cov == 0) continue;
                        const px = gx + @as(i32, @intCast(col));
                        if (px < 0 or px >= @as(i32, @intCast(fb_w))) continue;
                        const sa = @as(f32, @floatFromInt(cov)) / 255.0 * ca;
                        const idx = @as(usize, @intCast(py)) * fb_w + @as(usize, @intCast(px));
                        const dst = fb[idx];
                        const da = @as(f32, @floatFromInt((dst >> 24) & 0xFF)) / 255.0;
                        const dr = @as(f32, @floatFromInt((dst >> 16) & 0xFF)) / 255.0;
                        const dg = @as(f32, @floatFromInt((dst >> 8) & 0xFF)) / 255.0;
                        const db = @as(f32, @floatFromInt(dst & 0xFF)) / 255.0;
                        const oa = sa + da * (1 - sa);
                        const or_ = if (oa > 0) (cr * sa + dr * da * (1 - sa)) / oa else 0;
                        const og = if (oa > 0) (cg * sa + dg * da * (1 - sa)) / oa else 0;
                        const ob = if (oa > 0) (cb * sa + db * da * (1 - sa)) / oa else 0;
                        fb[idx] = (@as(u32, @intFromFloat(@round(oa * 255))) << 24) |
                            (@as(u32, @intFromFloat(@round(or_ * 255))) << 16) |
                            (@as(u32, @intFromFloat(@round(og * 255))) << 8) |
                            @as(u32, @intFromFloat(@round(ob * 255)));
                    }
                }
            }
            pen += g.advance;
            i += d.len;
        }
    }
};
