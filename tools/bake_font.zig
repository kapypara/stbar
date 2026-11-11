const std = @import("std");
const Io = std.Io;

const uv_absent: [2]u16 = .{ 0, 65535 };
const pua_base: u32 = 0xE000;
const pua_count: usize = 64;

const GlyphCoord = struct {
    code: u32,
    uv: [2]u16,

    fn lessThan(_: void, lhs: GlyphCoord, rhs: GlyphCoord) bool {
        return lhs.code < rhs.code;
    }
};

fn computeUV(columns: u16, rows: u16, index: u16) [2]u16 {
    const col: u32 = index % columns;
    const row: u32 = index / columns;
    return .{
        @intCast((col * 65535) / columns),
        @intCast((row * 65535) / rows),
    };
}

fn paethPredictor(a: u8, b: u8, c_val: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c_val;
    const p: i32 = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c_val;
}

fn decodePngRgba(allocator: std.mem.Allocator, png: []const u8) !struct {
    width: u16,
    height: u16,
    rgba: []u8,
} {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (png.len < 33 or !std.mem.eql(u8, png[0..8], &sig)) return error.InvalidPngSignature;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    var pos: usize = 8;
    while (pos + 12 <= png.len) {
        const chunk_len = std.mem.readInt(u32, png[pos..][0..4], .big);
        const chunk_type = png[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        const data_end = data_start + chunk_len;
        if (data_end + 4 > png.len) return error.TruncatedPngChunk;
        const chunk = png[data_start..data_end];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk.len < 13) return error.InvalidIhdr;
            width = std.mem.readInt(u32, chunk[0..4], .big);
            height = std.mem.readInt(u32, chunk[4..8], .big);
            bit_depth = chunk[8];
            color_type = chunk[9];
            interlace = chunk[12];
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            plte = chunk;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            trns = chunk;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat.appendSlice(allocator, chunk);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
        pos = data_end + 4;
    }

    if (width == 0 or height == 0 or bit_depth != 8 or interlace != 0) {
        return error.UnsupportedPngFormat;
    }

    const bpp: usize = switch (color_type) {
        0 => 1, // Grayscale
        2 => 3, // RGB
        3 => 1, // Indexed palette
        4 => 2, // Grayscale + Alpha
        6 => 4, // RGBA
        else => return error.UnsupportedColorType,
    };

    const stride = width * bpp;
    const raw_len = (stride + 1) * height;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    var in_reader: Io.Reader = .fixed(idat.items);
    var win_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&in_reader, .zlib, &win_buf);
    try decomp.reader.readSliceAll(raw);

    const unfiltered = try allocator.alloc(u8, stride * height);
    defer allocator.free(unfiltered);

    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const dst = unfiltered[y * stride ..][0..stride];
        const prev = if (y > 0) unfiltered[(y - 1) * stride ..][0..stride] else null;

        for (0..stride) |x| {
            const a: u8 = if (x >= bpp) dst[x - bpp] else 0;
            const b: u8 = if (prev) |p| p[x] else 0;
            const c_val: u8 = if (prev != null and x >= bpp) prev.?[x - bpp] else 0;

            dst[x] = switch (filter) {
                0 => src[x],
                1 => src[x] +% a,
                2 => src[x] +% b,
                3 => src[x] +% @as(u8, @intCast((@as(u16, a) + @as(u16, b)) >> 1)),
                4 => src[x] +% paethPredictor(a, b, c_val),
                else => return error.InvalidPngFilter,
            };
        }
    }

    const pixel_count = width * height;
    const rgba = try allocator.alloc(u8, pixel_count * 4);

    for (0..pixel_count) |i| {
        const out = rgba[i * 4 ..][0..4];
        switch (color_type) {
            0 => {
                const g = unfiltered[i];
                out.* = .{ g, g, g, 255 };
            },
            2 => {
                const s = unfiltered[i * 3 ..][0..3];
                out.* = .{ s[0], s[1], s[2], 255 };
            },
            3 => {
                const idx: usize = unfiltered[i];
                if (idx * 3 + 3 > plte.len) return error.PaletteOutOfBounds;
                const a: u8 = if (idx < trns.len) trns[idx] else 255;
                out.* = .{ plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2], a };
            },
            4 => {
                const s = unfiltered[i * 2 ..][0..2];
                out.* = .{ s[0], s[0], s[0], s[1] };
            },
            6 => {
                out.* = unfiltered[i * 4 ..][0..4].*;
            },
            else => unreachable,
        }
    }

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .rgba = rgba,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();
    _ = args_it.next();
    const json_path = args_it.next() orelse return error.MissingJsonPath;
    const png_path = args_it.next() orelse return error.MissingPngPath;
    const out_path = args_it.next() orelse return error.MissingOutputPath;

    const json_bytes = try Io.Dir.cwd().readFileAlloc(io, json_path, gpa, .limited(1024 * 1024));
    defer gpa.free(json_bytes);
    const png_bytes = try Io.Dir.cwd().readFileAlloc(io, png_path, gpa, .limited(4 * 1024 * 1024));
    defer gpa.free(png_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const columns: u16 = @intCast(root.get("columns").?.integer);
    const rows: u16 = @intCast(root.get("rows").?.integer);
    const char_width: u16 = @intCast(root.get("char_width").?.integer);
    const char_height: u16 = @intCast(root.get("char_height").?.integer);

    var latin1_uvs: [256][2]u16 = @splat(uv_absent);
    var pua_uvs: [pua_count][2]u16 = @splat(uv_absent);
    var extra_list: std.ArrayList(GlyphCoord) = .empty;
    defer extra_list.deinit(gpa);

    for (root.get("char_set").?.array.items) |item| {
        const obj = item.object;
        const type_str = obj.get("type").?.string;
        const index: u16 = @intCast(obj.get("index").?.integer);
        const value: u32 = @intCast(obj.get("value").?.integer);
        const count: u16 = if (std.mem.eql(u8, type_str, "range"))
            @intCast(obj.get("count").?.integer)
        else
            1;

        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const code = value + i;
            const uv = computeUV(columns, rows, index + i);
            if (code < 256) {
                latin1_uvs[code] = uv;
            } else if (code >= pua_base and code < pua_base + pua_count) {
                pua_uvs[code - pua_base] = uv;
            } else {
                try extra_list.append(gpa, .{ .code = code, .uv = uv });
            }
        }
    }
    std.sort.pdq(GlyphCoord, extra_list.items, {}, GlyphCoord.lessThan);

    const img = try decodePngRgba(gpa, png_bytes);
    defer gpa.free(img.rgba);

    // Try 2-bit palette compression when <= 4 unique RGBA colors (Tamzen uses 3)
    var palette: [4][4]u8 = @splat(.{ 0, 0, 0, 0 });
    var palette_len: usize = 0;
    var fits_2bit = true;
    const pixel_count = @as(usize, img.width) * @as(usize, img.height);
    for (0..pixel_count) |i| {
        const px = img.rgba[i * 4 ..][0..4].*;
        var found: ?usize = null;
        for (0..palette_len) |p_idx| {
            if (std.mem.eql(u8, &palette[p_idx], &px)) {
                found = p_idx;
                break;
            }
        }
        if (found == null) {
            if (palette_len < 4) {
                palette[palette_len] = px;
                palette_len += 1;
            } else {
                fits_2bit = false;
                break;
            }
        }
    }

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;

    try w.print(
        \\// Auto-generated at build time by tools/bake_font.zig — do not edit manually.
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const char_width: u16 = {d};
        \\pub const char_height: u16 = {d};
        \\pub const columns: u16 = {d};
        \\pub const rows: u16 = {d};
        \\pub const GlyphCoord = struct {{ code: u32, uv: [2]u16 }};
        \\
    , .{ img.width, img.height, char_width, char_height, columns, rows });

    try w.writeAll("pub const latin1_uvs: [256][2]u16 = .{\n");
    for (latin1_uvs) |uv| {
        try w.print("    .{{ {d}, {d} }},\n", .{ uv[0], uv[1] });
    }
    try w.writeAll("};\n");

    try w.writeAll("pub const pua_uvs: [64][2]u16 = .{\n");
    for (pua_uvs) |uv| {
        try w.print("    .{{ {d}, {d} }},\n", .{ uv[0], uv[1] });
    }
    try w.writeAll("};\n");

    try w.writeAll("pub const extra_glyphs: []const GlyphCoord = &.{\n");
    for (extra_list.items) |g| {
        try w.print("    .{{ .code = {d}, .uv = .{{ {d}, {d} }} }},\n", .{ g.code, g.uv[0], g.uv[1] });
    }
    try w.writeAll("};\n");

    if (fits_2bit) {
        const packed_len = (pixel_count + 3) / 4;
        try w.writeAll("pub const palette: [4][4]u8 = .{\n");
        for (palette) |c_rgba| {
            try w.print("    .{{ {d}, {d}, {d}, {d} }},\n", .{ c_rgba[0], c_rgba[1], c_rgba[2], c_rgba[3] });
        }
        try w.writeAll("};\n");
        try w.print("pub const packed_2bit: [{d}]u8 = .{{\n    ", .{packed_len});
        for (0..packed_len) |byte_idx| {
            var b: u8 = 0;
            for (0..4) |sub| {
                const px_idx = byte_idx * 4 + sub;
                if (px_idx < pixel_count) {
                    const px = img.rgba[px_idx * 4 ..][0..4].*;
                    var code: u2 = 0;
                    for (0..palette_len) |p_idx| {
                        if (std.mem.eql(u8, &palette[p_idx], &px)) {
                            code = @intCast(p_idx);
                            break;
                        }
                    }
                    b |= @as(u8, code) << @intCast(sub * 2);
                }
            }
            try w.print("0x{X:0>2},", .{b});
            if ((byte_idx + 1) % 24 == 0) try w.writeAll("\n    ");
        }
        try w.writeAll(
            \\
            \\};
            \\pub fn unpackRgba(dest: *[@as(usize, width) * @as(usize, height) * 4]u8) void {
            \\    const pixel_total = @as(usize, width) * @as(usize, height);
            \\    for (0..pixel_total) |i| {
            \\        const code: u2 = @truncate(packed_2bit[i >> 2] >> @intCast((i & 3) * 2));
            \\        dest[i * 4 ..][0..4].* = palette[code];
            \\    }
            \\}
            \\
        );
    } else {
        try w.print("pub const raw_rgba: [{d}]u8 = .{{\n    ", .{img.rgba.len});
        for (img.rgba, 0..) |b, idx| {
            try w.print("0x{X:0>2},", .{b});
            if ((idx + 1) % 24 == 0) try w.writeAll("\n    ");
        }
        try w.writeAll(
            \\
            \\};
            \\pub fn unpackRgba(dest: *[@as(usize, width) * @as(usize, height) * 4]u8) void {
            \\    @memcpy(dest, &raw_rgba);
            \\}
            \\
        );
    }

    const out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, out.written());
}
