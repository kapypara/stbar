const std = @import("std");
const Io = std.Io;

/// Represents a mapping of character codes to UV coordinates on a texture atlas.
pub const FontAtlas = struct {
    const GlyphCoord = struct {
        code: u16, // UTF Glyph Code
        index: u16, // Index on the texture

        // Used for binary search
        pub fn compareByCode(_: void, lhs: GlyphCoord, rhs: GlyphCoord) bool {
            return std.math.order(lhs.code, rhs.code) == .lt;
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

    // Sorted slice for efficient O(log n) lookups
    glyphs: []GlyphCoord,

    pub fn deinit(self: *FontAtlas) void {
        self.allocator.free(self.name);
        self.allocator.free(self.bitmap_path);
        self.allocator.free(self.glyphs);
    }

    /// Comptue the UV for any given glyph coord
    fn computeUV(self: *const FontAtlas, g: GlyphCoord) [2]u16 {
        const col = g.index % self.columns;
        const row = g.index / self.columns;

        // Multiply the column/row index by the maximum u16 value, 
        // then divide by total columns/rows to get the exact scaled coordinate.
        const max_u16: u32 = 65535; 

        return .{
            @intCast((col * max_u16) / self.columns),
            @intCast((row * max_u16) / self.rows),
        };
    }

    /// Finds the UV coordinates for a specific character code, or null if absent.
    pub fn getGlyphUV(self: *const FontAtlas, code: u32) ?[2]u16 {
        var low: usize = 0;
        var high: usize = self.glyphs.len;

        // bin search
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.glyphs[mid].code == code) {
                return self.computeUV(self.glyphs[mid]);
            } else if (self.glyphs[mid].code < code) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return null;
    }

    pub fn loadFromJson(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !FontAtlas {

        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var buf: [1024*1024]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);
        const s = buf[0..amt];

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        const columns = @as(u16, @intCast(root.get("columns").?.integer));
        const rows = @as(u16, @intCast(root.get("rows").?.integer));

        const x_inc = 1.0 / @as(f32, @floatFromInt(columns));
        const y_inc = 1.0 / @as(f32, @floatFromInt(rows));

        var glyph_list: std.ArrayList(GlyphCoord) = .empty;
        errdefer glyph_list.deinit(allocator);

        const char_set = root.get("char_set").?.array;
        for (char_set.items) |item| {
            const obj = item.object;
            const type_str = obj.get("type").?.string;

            const index = @as(u16, @intCast(obj.get("index").?.integer));
            const value = @as(u16, @intCast(obj.get("value").?.integer));

            if (std.mem.eql(u8, type_str, "range")) {
                const count = @as(u16, @intCast(obj.get("count").?.integer));
                var i: u16 = 0;
                while (i < count) : (i += 1) {
                    try glyph_list.append(allocator, .{ .code = value + i, .index = index + i });
                }
            } else {
                try glyph_list.append(allocator, .{ .code = value, .index = index });
            }
        }

        // Sort for binary search lookups
        std.sort.pdq(GlyphCoord, glyph_list.items, {}, GlyphCoord.compareByCode);

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
            .glyphs = try glyph_list.toOwnedSlice(allocator),
        };
    }
};

test "FontAtlas loads tamzen.json and resolves ASCII + PUA glyphs" {
    var atlas = try FontAtlas.loadFromJson(std.testing.io, std.testing.allocator, "assets/font/tamzen.json");
    defer atlas.deinit();

    try std.testing.expectEqual(@as(u16, 7), atlas.char_width);
    try std.testing.expectEqual(@as(u16, 14), atlas.char_height);
    try std.testing.expect(atlas.getGlyphUV(' ') != null);
    try std.testing.expect(atlas.getGlyphUV('A') != null);
    try std.testing.expect(atlas.getGlyphUV(0xE000) != null);
    try std.testing.expect(atlas.getGlyphUV(0x1F600) == null);
}
