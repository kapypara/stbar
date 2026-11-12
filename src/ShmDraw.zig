const std = @import("std");
const embedded = @import("tamzen_embedded");
const RectDraw = @import("RectDraw.zig").RectDraw;
const QuadVertex = RectDraw.QuadVertex;

pub const DamageRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const max_damage_rects = 12;
pub const max_cells = 1200;

pub const SlotState = struct {
    width: i32 = 0,
    height: i32 = 0,
    last_opacity_u8: u16 = 0xFFFF, // 0xFFFF forces an initial full-buffer draw
    cell_count: usize = 0,
    bg_sig: u64 = 0,
    cell_uvs: [max_cells]u32 = @splat(0),

    pub fn invalidate(self: *SlotState) void {
        self.last_opacity_u8 = 0xFFFF;
    }
};

pub const ShmDraw = struct {
    fn computeBgSig(bg_quads: []const QuadVertex) u64 {
        var h: u64 = 0x9E3779B97F4A7C15 ^ @as(u64, bg_quads.len);
        for (bg_quads) |q| {
            const s0: u32 = @bitCast(q.size[0]);
            const s1: u32 = @bitCast(q.size[1]);
            const p0: u16 = @bitCast(q.pos[0]);
            const p1: u16 = @bitCast(q.pos[1]);
            const col: u32 = @bitCast(q.color);
            h = (h ^ ((@as(u64, s0) << 32) | s1)) *% 0xBF58476D1CE4E5B9;
            h = (h ^ ((@as(u64, col) << 32) | (@as(u64, p0) << 16) | p1)) *% 0x94D049BB133111EB;
        }
        return h;
    }

    inline fn packUv(uv: [2]u16) u32 {
        return (@as(u32, uv[1]) << 16) | @as(u32, uv[0]);
    }

    inline fn scaleByte(v: u8, alpha_scale: u8) u8 {
        if (alpha_scale == 255) return v;
        return @intCast((@as(u32, v) * @as(u32, alpha_scale) + 127) / 255);
    }

    /// Packs `[R, G, B, A]` scaled by `alpha_scale` into Wayland `WL_SHM_FORMAT_ARGB8888` (`0xAARRGGBB`).
    pub inline fn packArgb(rgba: [4]u8, alpha_scale: u8) u32 {
        if (alpha_scale == 255) {
            return (@as(u32, rgba[3]) << 24) |
                (@as(u32, rgba[0]) << 16) |
                (@as(u32, rgba[1]) << 8) |
                @as(u32, rgba[2]);
        }
        const sr = scaleByte(rgba[0], alpha_scale);
        const sg = scaleByte(rgba[1], alpha_scale);
        const sb = scaleByte(rgba[2], alpha_scale);
        const sa = scaleByte(rgba[3], alpha_scale);
        return (@as(u32, sa) << 24) |
            (@as(u32, sr) << 16) |
            (@as(u32, sg) << 8) |
            @as(u32, sb);
    }

    inline fn buildCellLut(bg_rgba: [4]u8, alpha_scale: u8) [4]u32 {
        var lut: [4]u32 = undefined;
        const bg_packed = packArgb(bg_rgba, alpha_scale);
        inline for (0..4) |code| {
            const fg = embedded.palette[code];
            if (fg[3] == 0) {
                lut[code] = bg_packed;
            } else if (fg[3] == 255) {
                lut[code] = packArgb(.{ fg[0], fg[1], fg[2], 255 }, alpha_scale);
            } else {
                const a: u32 = fg[3];
                const inv_a: u32 = 255 - a;
                const r: u8 = @intCast((@as(u32, bg_rgba[0]) * inv_a + @as(u32, fg[0]) * a + 127) / 255);
                const g: u8 = @intCast((@as(u32, bg_rgba[1]) * inv_a + @as(u32, fg[1]) * a + 127) / 255);
                const b: u8 = @intCast((@as(u32, bg_rgba[2]) * inv_a + @as(u32, fg[2]) * a + 127) / 255);
                const out_a: u8 = @intCast((@as(u32, bg_rgba[3]) * inv_a + 255 * a + 127) / 255);
                lut[code] = packArgb(.{ r, g, b, out_a }, alpha_scale);
            }
        }
        return lut;
    }

    const Span = struct {
        p0: usize,
        p1: usize,
        start_f: f32,
        span_f: f32,
    };

    inline fn spanX(q: QuadVertex, width: i32) Span {
        const w_f: f32 = @floatFromInt(width);
        const nx0 = @max(-1.0, @as(f32, @floatFromInt(q.pos[0])) / 32767.0);
        const left_f = (nx0 + 1.0) * 0.5 * w_f;
        const span_f = q.size[0] * 0.5 * w_f;
        const right_f = left_f + span_f;
        const ix0 = std.math.clamp(@as(i32, @intFromFloat(@ceil(left_f - 0.5))), 0, width);
        const ix1 = std.math.clamp(@as(i32, @intFromFloat(@ceil(right_f - 0.5))), ix0, width);
        return .{
            .p0 = @intCast(ix0),
            .p1 = @intCast(ix1),
            .start_f = left_f,
            .span_f = @max(0.0001, span_f),
        };
    }

    inline fn spanY(q: QuadVertex, height: i32) Span {
        const h_f: f32 = @floatFromInt(height);
        const ny_top = @max(-1.0, @as(f32, @floatFromInt(q.pos[1])) / 32767.0);
        const top_f = (1.0 - ny_top) * 0.5 * h_f;
        const span_f = q.size[1] * 0.5 * h_f;
        const bot_f = top_f + span_f;
        const iy0 = std.math.clamp(@as(i32, @intFromFloat(@ceil(top_f - 0.5))), 0, height);
        const iy1 = std.math.clamp(@as(i32, @intFromFloat(@ceil(bot_f - 0.5))), iy0, height);
        return .{
            .p0 = @intCast(iy0),
            .p1 = @intCast(iy1),
            .start_f = top_f,
            .span_f = @max(0.0001, span_f),
        };
    }

    pub inline fn decodeAtlasCell(uv: [2]u16) struct { col: usize, row: usize } {
        const col: usize = (@as(usize, uv[0]) * embedded.columns + 32767) / 65535;
        const row: usize = (@as(usize, uv[1]) * embedded.rows + 32767) / 65535;
        return .{
            .col = @min(col, embedded.columns - 1),
            .row = @min(row, embedded.rows - 1),
        };
    }

    fn fillRect(pixels: []u32, stride: usize, x0: usize, x1: usize, y0: usize, y1: usize, argb: u32) void {
        if (x0 >= x1 or y0 >= y1) return;
        for (y0..y1) |py| {
            @memset(pixels[py * stride + x0 .. py * stride + x1], argb);
        }
    }

    /// SWAR 2-lane ARGB linear blend for `w` in `0..256` (`0` -> `c0`, `256` -> `c1`).
    pub inline fn lerpArgb256(c0: u32, c1: u32, w: u32) u32 {
        if (w == 0 or c0 == c1) return c0;
        if (w >= 256) return c1;
        const inv_w: u32 = 256 - w;
        const rb = (((c0 & 0x00FF00FF) * inv_w + (c1 & 0x00FF00FF) * w + 0x00800080) >> 8) & 0x00FF00FF;
        const ag = ((((c0 >> 8) & 0x00FF00FF) * inv_w + ((c1 >> 8) & 0x00FF00FF) * w + 0x00800080) >> 8) & 0x00FF00FF;
        return (ag << 8) | rb;
    }

    const AxisTap = struct {
        t0: u8,
        t1: u8,
        w: u16,
    };

    inline fn computeAxisTap(d: usize, dst_n: usize, comptime src_n: usize) AxisTap {
        const num0 = d * src_n;
        const num1 = (d + 1) * src_n;
        const t0 = @min(num0 / dst_n, src_n - 1);
        const t1_raw = @min((num1 - 1) / dst_n, src_n - 1);
        if (t0 == t1_raw) {
            return .{ .t0 = @intCast(t0), .t1 = @intCast(t0), .w = 0 };
        }
        const t1 = @min(t0 + 1, src_n - 1);
        const boundary = t1 * dst_n;
        const above = num1 -| boundary;
        const w = @min(256, (above * 256 + (src_n / 2)) / src_n);
        return .{ .t0 = @intCast(t0), .t1 = @intCast(t1), .w = @intCast(w) };
    }

    inline fn samplePacked2Bit(idx: usize) u2 {
        return @truncate(embedded.packed_2bit[idx >> 2] >> @intCast((idx & 3) * 2));
    }

    fn blitCell(
        pixels: []u32,
        width: i32,
        height: i32,
        q: QuadVertex,
        alpha_scale: u8,
        skip_if_empty: bool,
    ) ?DamageRect {
        const is_empty = (q.uv[0] == RectDraw.uv_empty[0] and q.uv[1] == RectDraw.uv_empty[1]);
        if (is_empty and skip_if_empty) return null;

        const sx = spanX(q, width);
        const sy = spanY(q, height);
        if (sx.p0 >= sx.p1 or sy.p0 >= sy.p1) return null;

        const stride: usize = @intCast(width);

        if (is_empty) {
            const bg_argb = packArgb(q.color, alpha_scale);
            fillRect(pixels, stride, sx.p0, sx.p1, sy.p0, sy.p1, bg_argb);
            return .{
                .x = @intCast(sx.p0),
                .y = @intCast(sy.p0),
                .w = @intCast(sx.p1 - sx.p0),
                .h = @intCast(sy.p1 - sy.p0),
            };
        }

        const lut = buildCellLut(q.color, alpha_scale);
        const cell = decodeAtlasCell(q.uv);
        const atlas_x0 = cell.col * embedded.char_width;
        const atlas_y0 = cell.row * embedded.char_height;
        const cell_w = sx.p1 - sx.p0;
        const cell_h = sy.p1 - sy.p0;

        if (cell_w == embedded.char_width and cell_h == embedded.char_height) {
            for (0..embedded.char_height) |dy| {
                const src_base = (atlas_y0 + dy) * embedded.width + atlas_x0;
                const dst_row = pixels[(sy.p0 + dy) * stride + sx.p0 ..][0..embedded.char_width];
                for (0..embedded.char_width) |dx| {
                    dst_row[dx] = lut[samplePacked2Bit(src_base + dx)];
                }
            }
        } else {
            // Precompute rational box-coverage X taps once per cell (`<= 64` px fast path)
            var x_taps_buf: [64]AxisTap = undefined;
            const use_x_cache = cell_w <= x_taps_buf.len;
            if (use_x_cache) {
                for (0..cell_w) |dx| {
                    x_taps_buf[dx] = computeAxisTap(dx, cell_w, embedded.char_width);
                }
            }

            for (0..cell_h) |dy| {
                const y_tap = computeAxisTap(dy, cell_h, embedded.char_height);
                const src_row0 = (atlas_y0 + y_tap.t0) * embedded.width + atlas_x0;
                const src_row1 = (atlas_y0 + y_tap.t1) * embedded.width + atlas_x0;
                const dst_row = pixels[(sy.p0 + dy) * stride + sx.p0 ..][0..cell_w];

                if (y_tap.w == 0) {
                    for (0..cell_w) |dx| {
                        const x_tap = if (use_x_cache) x_taps_buf[dx] else computeAxisTap(dx, cell_w, embedded.char_width);
                        const c00 = samplePacked2Bit(src_row0 + x_tap.t0);
                        if (x_tap.w == 0) {
                            dst_row[dx] = lut[c00];
                        } else {
                            const c10 = samplePacked2Bit(src_row0 + x_tap.t1);
                            dst_row[dx] = if (c00 == c10) lut[c00] else lerpArgb256(lut[c00], lut[c10], x_tap.w);
                        }
                    }
                } else {
                    for (0..cell_w) |dx| {
                        const x_tap = if (use_x_cache) x_taps_buf[dx] else computeAxisTap(dx, cell_w, embedded.char_width);
                        const c00 = samplePacked2Bit(src_row0 + x_tap.t0);
                        const c01 = samplePacked2Bit(src_row1 + x_tap.t0);
                        if (x_tap.w == 0) {
                            dst_row[dx] = if (c00 == c01) lut[c00] else lerpArgb256(lut[c00], lut[c01], y_tap.w);
                        } else {
                            const c10 = samplePacked2Bit(src_row0 + x_tap.t1);
                            const c11 = samplePacked2Bit(src_row1 + x_tap.t1);
                            if (c00 == c10 and c00 == c01 and c00 == c11) {
                                dst_row[dx] = lut[c00];
                            } else {
                                const top = lerpArgb256(lut[c00], lut[c10], x_tap.w);
                                const bot = lerpArgb256(lut[c01], lut[c11], x_tap.w);
                                dst_row[dx] = lerpArgb256(top, bot, y_tap.w);
                            }
                        }
                    }
                }
            }
        }

        return .{
            .x = @intCast(sx.p0),
            .y = @intCast(sy.p0),
            .w = @intCast(cell_w),
            .h = @intCast(cell_h),
        };
    }

    fn appendDamage(out: *[max_damage_rects]DamageRect, count: *usize, rect: DamageRect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        const n = count.*;
        if (n > 0) {
            var prev = &out[n - 1];
            const prev_x1 = prev.x + prev.w;
            const rect_x1 = rect.x + rect.w;
            const gap = @max(14, rect.w * 2);
            // Coalesce adjacent or nearby horizontal glyph updates on the same row band
            if (prev.y == rect.y and prev.h == rect.h and rect.x <= prev_x1 + gap and rect_x1 >= prev.x - gap) {
                const nx0 = @min(prev.x, rect.x);
                const nx1 = @max(prev_x1, rect_x1);
                prev.x = nx0;
                prev.w = nx1 - nx0;
                return;
            }
            if (n == max_damage_rects) {
                const nx0 = @min(prev.x, rect.x);
                const ny0 = @min(prev.y, rect.y);
                const nx1 = @max(prev_x1, rect_x1);
                const ny1 = @max(prev.y + prev.h, rect.y + rect.h);
                prev.* = .{ .x = nx0, .y = ny0, .w = nx1 - nx0, .h = ny1 - ny0 };
                return;
            }
        }
        out[n] = rect;
        count.* = n + 1;
    }

    /// Renders `quads` into `pixels` (`width * height`), updating only changed glyph cells when
    /// possible and returning exact buffer-space damage rectangles for `wl_surface_damage_buffer`.
    pub fn renderSlot(
        slot: *SlotState,
        pixels: []u32,
        width: i32,
        height: i32,
        bg_count: usize,
        quads: []const QuadVertex,
        opacity: f32,
        damage_out: *[max_damage_rects]DamageRect,
    ) usize {
        if (width <= 0 or height <= 0 or pixels.len < @as(usize, @intCast(width * height))) {
            return 0;
        }

        const clamped_op = std.math.clamp(opacity, 0.0, 1.0);
        const alpha_scale: u8 = @intFromFloat(@round(clamped_op * 255.0));

        const clamped_bg = @min(bg_count, quads.len);
        const raw_cells = quads[clamped_bg..];
        const cell_quads = raw_cells[0..@min(raw_cells.len, max_cells)];

        if (slot.cell_count != cell_quads.len) {
            slot.cell_count = cell_quads.len;
            slot.last_opacity_u8 = 0xFFFF;
        }

        if (alpha_scale == 0 or quads.len == 0) {
            if (slot.last_opacity_u8 == 0 and slot.width == width and slot.height == height) {
                return 0;
            }
            @memset(pixels[0..@intCast(width * height)], 0);
            slot.width = width;
            slot.height = height;
            slot.last_opacity_u8 = 0;
            damage_out[0] = .{ .x = 0, .y = 0, .w = width, .h = height };
            return 1;
        }

        const next_bg_sig = computeBgSig(quads[0..clamped_bg]);
        const full_redraw = (slot.width != width or
            slot.height != height or
            slot.last_opacity_u8 != alpha_scale or
            slot.bg_sig != next_bg_sig);

        if (full_redraw) {
            const stride: usize = @intCast(width);
            @memset(pixels[0..@intCast(width * height)], 0);

            for (quads[0..clamped_bg]) |bg_q| {
                const sx = spanX(bg_q, width);
                const sy = spanY(bg_q, height);
                const argb = packArgb(bg_q.color, alpha_scale);
                fillRect(pixels, stride, sx.p0, sx.p1, sy.p0, sy.p1, argb);
            }

            for (cell_quads, 0..) |cq, idx| {
                slot.cell_uvs[idx] = packUv(cq.uv);
                _ = blitCell(pixels, width, height, cq, alpha_scale, true);
            }

            slot.width = width;
            slot.height = height;
            slot.last_opacity_u8 = alpha_scale;
            slot.bg_sig = next_bg_sig;
            damage_out[0] = .{ .x = 0, .y = 0, .w = width, .h = height };
            return 1;
        }

        var damage_count: usize = 0;
        for (cell_quads, 0..) |cq, idx| {
            const p_uv = packUv(cq.uv);
            if (p_uv == slot.cell_uvs[idx]) continue;
            slot.cell_uvs[idx] = p_uv;
            if (blitCell(pixels, width, height, cq, alpha_scale, false)) |rect| {
                appendDamage(damage_out, &damage_count, rect);
            }
        }
        return damage_count;
    }
};

test "ShmDraw recovers exact Tamzen atlas coordinates and performs incremental cell damage" {
    // 1. Verify O(1) integer UV -> (col, row) recovery for all 224 Tamzen cells
    for (0..embedded.rows) |r| {
        for (0..embedded.columns) |col| {
            const uv: [2]u16 = .{
                @intCast((col * 65535) / embedded.columns),
                @intCast((r * 65535) / embedded.rows),
            };
            const decoded = ShmDraw.decodeAtlasCell(uv);
            try std.testing.expectEqual(col, decoded.col);
            try std.testing.expectEqual(r, decoded.row);
        }
    }

    // 2. Verify full draw followed by incremental 1-cell update emits sub-rectangle damage
    const w: i32 = 28;
    const h: i32 = 17;
    var pixels: [w * h]u32 = @splat(0);
    var slot: SlotState = .{};

    const glyph_a_uv = embedded.latin1_uvs['A'];
    const glyph_b_uv = embedded.latin1_uvs['B'];

    var quads = [_]QuadVertex{
        // Solid background spanning full 28x17
        .{
            .size = .{ 2.0, 2.0 },
            .pos = .{ -32768, 32767 },
            .uv = RectDraw.uv_solid,
            .color = .{ 0x59, 0x59, 0x59, 0xCC },
        },
        // Cell 0 at x=0..7
        .{
            .size = .{ 0.5, 14.0 / 17.0 * 2.0 },
            .pos = .{ -32768, 28067 },
            .uv = glyph_a_uv,
            .color = .{ 0x59, 0x59, 0x59, 0xCC },
        },
        // Cell 1 at x=7..14 (empty)
        .{
            .size = .{ 0.5, 14.0 / 17.0 * 2.0 },
            .pos = .{ -16384, 28067 },
            .uv = RectDraw.uv_empty,
            .color = .{ 0x59, 0x59, 0x59, 0xCC },
        },
    };

    var dmg: [max_damage_rects]DamageRect = undefined;
    const n1 = ShmDraw.renderSlot(&slot, &pixels, w, h, 1, &quads, 1.0, &dmg);
    try std.testing.expectEqual(@as(usize, 1), n1);
    try std.testing.expectEqual(@as(i32, w), dmg[0].w);
    try std.testing.expectEqual(@as(i32, h), dmg[0].h);

    // Repeating identical state produces 0 damage rects
    const n2 = ShmDraw.renderSlot(&slot, &pixels, w, h, 1, &quads, 1.0, &dmg);
    try std.testing.expectEqual(@as(usize, 0), n2);

    // Updating only cell 0 emits a single 7x14 cell damage rect
    quads[1].uv = glyph_b_uv;
    const n3 = ShmDraw.renderSlot(&slot, &pixels, w, h, 1, &quads, 1.0, &dmg);
    try std.testing.expectEqual(@as(usize, 1), n3);
    try std.testing.expectEqual(@as(i32, 0), dmg[0].x);
    try std.testing.expectEqual(@as(i32, 7), dmg[0].w);
    try std.testing.expectEqual(@as(i32, 14), dmg[0].h);

    // Changing segment background geometry triggers a full-bar redraw even with identical cells/opacity
    quads[0].color = .{ 0x3C, 0x6E, 0x84, 0xCC };
    const n4 = ShmDraw.renderSlot(&slot, &pixels, w, h, 1, &quads, 1.0, &dmg);
    try std.testing.expectEqual(@as(usize, 1), n4);
    try std.testing.expectEqual(@as(i32, w), dmg[0].w);
    try std.testing.expectEqual(@as(i32, h), dmg[0].h);
}

test "ShmDraw HiDPI scaling preserves crisp 2x integer blocks and smooth 1.5x coverage AA" {
    const bg_col: [4]u8 = .{ 0x3C, 0x6E, 0x84, 0xCC };
    const bg_argb = ShmDraw.packArgb(bg_col, 255);
    const fg_argb = ShmDraw.packArgb(.{ 255, 255, 255, 255 }, 255);
    const glyph_a_uv = embedded.latin1_uvs['A'];

    const quads = [_]QuadVertex{
        .{
            .size = .{ 2.0, 2.0 },
            .pos = .{ -32768, 32767 },
            .uv = RectDraw.uv_solid,
            .color = bg_col,
        },
        // Full-width single glyph cell (`14x28` at 2x, `11x21` at ~1.5x)
        .{
            .size = .{ 2.0, 2.0 },
            .pos = .{ -32768, 32767 },
            .uv = glyph_a_uv,
            .color = bg_col,
        },
    };

    // 1. Exact 2.0x integer scale (`14x28` buffer for a `7x14` cell): zero intermediate blur
    var px_2x: [14 * 28]u32 = @splat(0);
    var slot_2x: SlotState = .{};
    var dmg: [max_damage_rects]DamageRect = undefined;
    _ = ShmDraw.renderSlot(&slot_2x, &px_2x, 14, 28, 1, &quads, 1.0, &dmg);
    var fg_2x_count: usize = 0;
    for (px_2x) |p| {
        // Every pixel at 2x must be strictly pure background or pure foreground (zero blur)
        try std.testing.expect(p == bg_argb or p == fg_argb);
        if (p == fg_argb) fg_2x_count += 1;
    }
    try std.testing.expect(fg_2x_count > 0);
    // Each 2x2 block must be uniform
    for (0..14) |ty| {
        for (0..7) |tx| {
            const p00 = px_2x[(ty * 2) * 14 + (tx * 2)];
            try std.testing.expectEqual(p00, px_2x[(ty * 2) * 14 + (tx * 2 + 1)]);
            try std.testing.expectEqual(p00, px_2x[(ty * 2 + 1) * 14 + (tx * 2)]);
            try std.testing.expectEqual(p00, px_2x[(ty * 2 + 1) * 14 + (tx * 2 + 1)]);
        }
    }

    // 2. Fractional ~1.5x scale (`11x21` buffer for a `7x14` cell): produces coverage-blended edge pixels
    var px_15x: [11 * 21]u32 = @splat(0);
    var slot_15x: SlotState = .{};
    _ = ShmDraw.renderSlot(&slot_15x, &px_15x, 11, 21, 1, &quads, 1.0, &dmg);
    var blended_count: usize = 0;
    for (px_15x) |p| {
        if (p != bg_argb and p != fg_argb) blended_count += 1;
    }
    try std.testing.expect(blended_count > 0);
}
