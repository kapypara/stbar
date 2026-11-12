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
                    const idx = src_base + dx;
                    const code: u2 = @truncate(embedded.packed_2bit[idx >> 2] >> @intCast((idx & 3) * 2));
                    dst_row[dx] = lut[code];
                }
            }
        } else {
            const cw_f: f32 = @floatFromInt(embedded.char_width);
            const ch_f: f32 = @floatFromInt(embedded.char_height);
            for (sy.p0..sy.p1) |py| {
                const vf = ((@as(f32, @floatFromInt(py)) + 0.5 - sy.start_f) / sy.span_f) * ch_f;
                const ty: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(vf))), 0, embedded.char_height - 1));
                const src_base = (atlas_y0 + ty) * embedded.width + atlas_x0;
                const dst_row = pixels[py * stride ..];
                for (sx.p0..sx.p1) |px| {
                    const uf = ((@as(f32, @floatFromInt(px)) + 0.5 - sx.start_f) / sx.span_f) * cw_f;
                    const tx: usize = @intCast(std.math.clamp(@as(i32, @intFromFloat(@floor(uf))), 0, embedded.char_width - 1));
                    const idx = src_base + tx;
                    const code: u2 = @truncate(embedded.packed_2bit[idx >> 2] >> @intCast((idx & 3) * 2));
                    dst_row[px] = lut[code];
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
            // Coalesce adjacent or nearby horizontal glyph updates on the same row band
            if (prev.y == rect.y and prev.h == rect.h and rect.x <= prev_x1 + 14 and rect_x1 >= prev.x - 14) {
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
