const std = @import("std");
pub const embedded = @import("tamzen_embedded");

/// Maps Unicode codepoints to normalized u16 UV coordinates on the embedded Tamzen font atlas.
/// Uses O(1) direct lookup tables in `.rodata` for Latin-1 (0..255) and Private Use Area icons
/// (U+E000..U+E03F), falling back to binary search only if extra Unicode ranges are present.
pub const FontAtlas = struct {
    pub const uv_absent: [2]u16 = .{ 0, 65535 };
    const pua_base: u32 = 0xE000;
    const pua_count: usize = 64;

    char_width: u16 = embedded.char_width,
    char_height: u16 = embedded.char_height,
    x_increment: f32 = 1.0 / @as(f32, @floatFromInt(embedded.columns)),
    y_increment: f32 = 1.0 / @as(f32, @floatFromInt(embedded.rows)),
    columns: u16 = embedded.columns,
    rows: u16 = embedded.rows,

    pub fn initEmbedded() FontAtlas {
        return .{};
    }

    pub fn deinit(_: *FontAtlas) void {}

    inline fn unwrapSlot(uv: [2]u16) ?[2]u16 {
        return if (uv[1] == uv_absent[1] and uv[0] == uv_absent[0]) null else uv;
    }

    /// Returns precomputed UV coordinates in O(1) for Latin-1 and PUA icons.
    pub inline fn getGlyphUV(_: *const FontAtlas, code: u32) ?[2]u16 {
        if (code < 256) {
            return unwrapSlot(embedded.latin1_uvs[code]);
        }
        if (code >= pua_base and code < pua_base + pua_count) {
            return unwrapSlot(embedded.pua_uvs[code - pua_base]);
        }
        return getExtraGlyphUV(code);
    }

    fn getExtraGlyphUV(code: u32) ?[2]u16 {
        if (comptime embedded.extra_glyphs.len == 0) return null;
        var low: usize = 0;
        var high: usize = embedded.extra_glyphs.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = embedded.extra_glyphs[mid];
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
};

test "Embedded FontAtlas resolves ASCII + PUA glyphs in O(1) with zero heap allocations" {
    var atlas = FontAtlas.initEmbedded();
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u16, 7), atlas.char_width);
    try std.testing.expectEqual(@as(u16, 14), atlas.char_height);
    try std.testing.expectEqual(@as(usize, 0), embedded.extra_glyphs.len);
    try std.testing.expect(atlas.getGlyphUV(0) != null);
    try std.testing.expect(atlas.getGlyphUV(0x02) != null);
    try std.testing.expect(atlas.getGlyphUV(' ') != null);
    try std.testing.expect(atlas.getGlyphUV('A') != null);
    try std.testing.expect(atlas.getGlyphUV(0xE000) != null);
    try std.testing.expect(atlas.getGlyphUV(0xE025) != null);
    try std.testing.expect(atlas.getGlyphUV(0xE026) == null);
    try std.testing.expect(atlas.getGlyphUV(0x1F600) == null);
}
