const std = @import("std");

/// Represents a mapping of character codes to UV coordinates on a texture atlas.
pub const FontAtlas = struct {
    const GlyphCoord = struct {
        code: u16,
        uv: [2]f32,

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
    
    // Sorted slice for efficient O(log n) lookups
    glyphs: []GlyphCoord,

    pub fn deinit(self: *FontAtlas) void {
        self.allocator.free(self.name);
        self.allocator.free(self.bitmap_path);
        self.allocator.free(self.glyphs);
    }

    /// Finds the UV coordinates for a specific character code.
    pub fn getGlyphUV(self: *const FontAtlas, code: u16) ?[2]f32 {
        var low: usize = 0;
        var high: usize = self.glyphs.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.glyphs[mid].code == code) {
                return self.glyphs[mid].uv;
            } else if (self.glyphs[mid].code < code) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return null;
    }

    pub fn loadFromJson(allocator: std.mem.Allocator, path: []const u8) !FontAtlas {
        const file = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(file);

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            file,
            .{}
        );
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
                    try addGlyph(allocator, &glyph_list, index + i, value + i, columns, x_inc, y_inc);
                }
            } else {
                try addGlyph(allocator, &glyph_list, index, value, columns, x_inc, y_inc);
            }
        }

        // Sort for binary search lookups
        std.sort.pdq(GlyphCoord, glyph_list.items, {}, GlyphCoord.compareByCode);

        return FontAtlas{
            .allocator = allocator,
            .name = try allocator.dupe(u8, root.get("name").?.string),
            .bitmap_path = try allocator.dupe(u8, root.get("file").?.string),
            .char_width = @as(u16, @intCast(root.get("char_width").?.integer)),
            .char_height = @as(u16, @intCast(root.get("char_height").?.integer)),
            .x_increment = x_inc,
            .y_increment = y_inc,
            .glyphs = try glyph_list.toOwnedSlice(allocator),
        };
    }

    fn addGlyph(allocator: std.mem.Allocator, list: *std.ArrayList(GlyphCoord), index: u16, value: u16, cols: u16, x_inc: f32, y_inc: f32) !void {
        const col = @as(f32, @floatFromInt(index % cols));
        const row = @as(f32, @floatFromInt(index / cols));

        try list.append(allocator, .{
            .code = value,
            .uv = .{ x_inc * col, y_inc * row },
        });
    }
};
