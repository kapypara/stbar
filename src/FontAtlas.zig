const std = @import("std");

/// Represents a mapping of character codes to UV coordinates on a texture atlas.
pub const FontAtlas = struct {
    const GlyphCoord = struct {
        code: u16,
        uv: [2]f32,

        // Used for binary search
        pub fn compareByCode(_: void, lhs: GlyphCoord, rhs: GlyphCoord) std.math.Order {
            return std.math.order(lhs.code, rhs.code);
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

        var parser = std.json.Parser.init(allocator, .copy_strings_if_needed);
        defer parser.deinit();

        var tree = try parser.parse(file);
        defer tree.deinit();

        const root = tree.root.Object;

        const columns = @as(u16, @intCast(root.get("columns").?.Integer));
        const rows = @as(u16, @intCast(root.get("rows").?.Integer));
        
        const x_inc = 1.0 / @as(f32, @floatFromInt(columns));
        const y_inc = 1.0 / @as(f32, @floatFromInt(rows));

        var glyph_list = std.ArrayList(GlyphCoord).init(allocator);
        errdefer glyph_list.deinit();

        const char_set = root.get("char_set").?.Array;
        for (char_set.items) |item| {
            const obj = item.Object;
            const type_str = obj.get("type").?.String;
            
            const index = @as(u16, @intCast(obj.get("index").?.Integer));
            const value = @as(u16, @intCast(obj.get("value").?.Integer));

            if (std.mem.eql(u8, type_str, "range")) {
                const count = @as(u16, @intCast(obj.get("count").?.Integer));
                var i: u16 = 0;
                while (i < count) : (i += 1) {
                    try addGlyph(&glyph_list, index + i, value + i, columns, x_inc, y_inc);
                }
            } else {
                try addGlyph(&glyph_list, index, value, columns, x_inc, y_inc);
            }
        }

        // Sort for binary search lookups
        std.sort.pdq(GlyphCoord, glyph_list.items, {}, GlyphCoord.compareByCode);

        return FontAtlas{
            .allocator = allocator,
            .name = try allocator.dupe(u8, root.get("name").?.String),
            .bitmap_path = try allocator.dupe(u8, root.get("file").?.String),
            .char_width = @as(u16, @intCast(root.get("char_width").?.Integer)),
            .char_height = @as(u16, @intCast(root.get("char_height").?.Integer)),
            .x_increment = x_inc,
            .y_increment = y_inc,
            .glyphs = try glyph_list.toOwnedSlice(),
        };
    }

    fn addGlyph(list: *std.ArrayList(GlyphCoord), index: u16, value: u16, cols: u16, x_inc: f32, y_inc: f32) !void {
        const col = @as(f32, @floatFromInt(index % cols));
        const row = @as(f32, @floatFromInt(index / cols));

        try list.append(.{
            .code = value,
            .uv = .{ x_inc * col, y_inc * row },
        });
    }
};
