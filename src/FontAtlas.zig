const std = @import("std");
const Io = std.Io;

/// Maps Unicode codepoints to normalized u16 UV coordinates on the font texture atlas.
/// Uses O(1) direct lookup tables for Latin-1 (0..255) and Private Use Area icons
/// (U+E000..U+E03F), falling back to binary search only for extra Unicode ranges.
pub const FontAtlas = struct {
    pub const uv_absent: [2]u16 = .{ 0, 65535 };
    const pua_base: u32 = 0xE000;
    const pua_count: usize = 64;

    const GlyphCoord = struct {
        code: u32,
        uv: [2]u16,

        pub fn compareByCode(_: void, lhs: GlyphCoord, rhs: GlyphCoord) bool {
            return lhs.code < rhs.code;
        }
    };

    allocator: std.mem.Allocator,
    name: []const u8,
    bitmap_path: []const u8,

    char_width: u16,
    char_height: u16,

    x_increment: f32,
    y_increment: f32,

    columns: u16,
    rows: u16,

    latin1_uvs: [256][2]u16 = @splat(uv_absent),
    pua_uvs: [pua_count][2]u16 = @splat(uv_absent),
    extra_glyphs: []GlyphCoord = &.{},

    pub fn deinit(self: *FontAtlas) void {
        self.allocator.free(self.name);
        self.allocator.free(self.bitmap_path);
        if (self.extra_glyphs.len > 0) {
            self.allocator.free(self.extra_glyphs);
        }
    }

    fn computeUV(columns: u16, rows: u16, index: u16) [2]u16 {
        const col: u32 = index % columns;
        const row: u32 = index / columns;
        const max_u16: u32 = 65535;

        return .{
            @intCast((col * max_u16) / columns),
            @intCast((row * max_u16) / rows),
        };
    }

    inline fn unwrapSlot(uv: [2]u16) ?[2]u16 {
        return if (uv[1] == uv_absent[1] and uv[0] == uv_absent[0]) null else uv;
    }

    /// Returns precomputed UV coordinates in O(1) for Latin-1 and PUA icons.
    pub inline fn getGlyphUV(self: *const FontAtlas, code: u32) ?[2]u16 {
        if (code < 256) {
            return unwrapSlot(self.latin1_uvs[code]);
        }
        if (code >= pua_base and code < pua_base + pua_count) {
            return unwrapSlot(self.pua_uvs[code - pua_base]);
        }
        return self.getExtraGlyphUV(code);
    }

    fn getExtraGlyphUV(self: *const FontAtlas, code: u32) ?[2]u16 {
        var low: usize = 0;
        var high: usize = self.extra_glyphs.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = self.extra_glyphs[mid];
            if (entry.code == code) {
                return entry.uv;
            } else if (entry.code < code) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return null;
    }

    fn insertGlyph(
        latin1_uvs: *[256][2]u16,
        pua_uvs: *[pua_count][2]u16,
        extra_list: *std.ArrayList(GlyphCoord),
        allocator: std.mem.Allocator,
        code: u32,
        uv: [2]u16,
    ) !void {
        if (code < 256) {
            latin1_uvs[code] = uv;
        } else if (code >= pua_base and code < pua_base + pua_count) {
            pua_uvs[code - pua_base] = uv;
        } else {
            try extra_list.append(allocator, .{ .code = code, .uv = uv });
        }
    }

    pub fn loadFromJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !FontAtlas {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var buf: [256 * 1024]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);
        const s = buf[0..amt];

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const columns = @as(u16, @intCast(root.get("columns").?.integer));
        const rows = @as(u16, @intCast(root.get("rows").?.integer));

        const x_inc = 1.0 / @as(f32, @floatFromInt(columns));
        const y_inc = 1.0 / @as(f32, @floatFromInt(rows));

        var latin1_uvs: [256][2]u16 = @splat(uv_absent);
        var pua_uvs: [pua_count][2]u16 = @splat(uv_absent);
        var extra_list: std.ArrayList(GlyphCoord) = .empty;
        errdefer extra_list.deinit(allocator);

        const char_set = root.get("char_set").?.array;
        for (char_set.items) |item| {
            const obj = item.object;
            const type_str = obj.get("type").?.string;
            const index = @as(u16, @intCast(obj.get("index").?.integer));
            const value = @as(u32, @intCast(obj.get("value").?.integer));

            if (std.mem.eql(u8, type_str, "range")) {
                const count = @as(u16, @intCast(obj.get("count").?.integer));
                var i: u16 = 0;
                while (i < count) : (i += 1) {
                    const uv = computeUV(columns, rows, index + i);
                    try insertGlyph(&latin1_uvs, &pua_uvs, &extra_list, allocator, value + i, uv);
                }
            } else {
                const uv = computeUV(columns, rows, index);
                try insertGlyph(&latin1_uvs, &pua_uvs, &extra_list, allocator, value, uv);
            }
        }

        std.sort.pdq(GlyphCoord, extra_list.items, {}, GlyphCoord.compareByCode);

        return FontAtlas{
            .allocator = allocator,
            .name = try allocator.dupe(u8, root.get("name").?.string),
            .bitmap_path = try allocator.dupe(u8, root.get("file").?.string),
            .columns = columns,
            .rows = rows,
            .char_width = @as(u16, @intCast(root.get("char_width").?.integer)),
            .char_height = @as(u16, @intCast(root.get("char_height").?.integer)),
            .x_increment = x_inc,
            .y_increment = y_inc,
            .latin1_uvs = latin1_uvs,
            .pua_uvs = pua_uvs,
            .extra_glyphs = try extra_list.toOwnedSlice(allocator),
        };
    }
};

test "FontAtlas loads tamzen.json into O(1) LUTs and resolves ASCII + PUA glyphs" {
    var atlas = try FontAtlas.loadFromJson(std.testing.io, std.testing.allocator, "assets/font/tamzen.json");
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u16, 7), atlas.char_width);
    try std.testing.expectEqual(@as(u16, 14), atlas.char_height);
    try std.testing.expectEqual(@as(usize, 0), atlas.extra_glyphs.len);
    try std.testing.expect(atlas.getGlyphUV(0) != null);
    try std.testing.expect(atlas.getGlyphUV(0x02) != null);
    try std.testing.expect(atlas.getGlyphUV(' ') != null);
    try std.testing.expect(atlas.getGlyphUV('A') != null);
    try std.testing.expect(atlas.getGlyphUV(0xE000) != null);
    try std.testing.expect(atlas.getGlyphUV(0xE021) != null);
    try std.testing.expect(atlas.getGlyphUV(0xE022) == null);
    try std.testing.expect(atlas.getGlyphUV(0x1F600) == null);
}
