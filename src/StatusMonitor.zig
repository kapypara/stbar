const std = @import("std");

const FontAtlas = @import("FontAtlas.zig").FontAtlas;
const RectDraw = @import("RectDraw.zig").RectDraw;
const segment_zig = @import("Segment.zig");
const Window = @import("Window.zig").Window;
const Texture = @import("Texture.zig").Texture;

const assert = std.debug.assert;
const Segment = segment_zig.Segment;
const MetricEntry = segment_zig.MetricEntry;

pub const StatusMonitor = struct {
    pub const time_width = 23;
    pub const processor_width = 15;
    pub const thermal_width = 13;
    pub const storage_width = 40;
    pub const network_width = 19;
    pub const right_fixed_cells = time_width + processor_width + thermal_width + storage_width + network_width; // 110

    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    rect: RectDraw = undefined,
    font: FontAtlas = undefined,
    window: *Window,

    // Timing
    update_rate: u8 = 0, // metric samples per second (e.g. 8)
    render_rate: u8 = 0, // frames per second (e.g. 60)
    frames_per_sample: u16 = 1,
    ticks: usize = 0,

    // Rect Compute
    rect_height: f32 = 0, // height of glyph rect in NDC
    rect_width_i: i16 = 0, // fixed point (-32768 -> 32767)
    rect_width_f: f32 = 0, // NDC (-1 -> 1)
    rect_y_pos: i16 = 0, // y pos for glyph rect in fixed-point NDC

    cells: []i16 = &.{},
    sample_buffer: []u128 = &.{},

    // Metric storage owned per StatusMonitor instance
    time_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .time = .{} }, .mode = .message, .start_index = 1 },
    },
    processor_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .cpu = .{} }, .mode = .average, .start_index = 0 },
        .{ .metric = .{ .memory = .{} }, .mode = .average, .start_index = 6, .secondary_index = 19 },
    },
    thermal_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .temp = .{} }, .mode = .average, .start_index = 8 },
        .{ .metric = .{ .load = .{} }, .mode = .average, .start_index = 0 },
    },
    storage_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .free_storage = .{} }, .mode = .average, .start_index = 28 },
        .{ .metric = .{ .io = .{} }, .mode = .rate_of_change, .start_index = 1, .secondary_index = 10 },
    },
    network_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .net = .{} }, .mode = .rate_of_change, .start_index = 1, .secondary_index = 10 },
    },
    window_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .window = .{} }, .mode = .message, .start_index = 1 },
    },

    time_segment: Segment = .{
        .color = 0x595959CC,
    },
    processor_segment: Segment = .{
        .color = 0x844242CC,
        .static_overlay = "\n\n\n\u{e000}\u{e001}\n\n\n,\n\n\n\u{e002}\u{e003}",
        .static_offset = 0,
    },
    thermal_load_segment: Segment = .{
        .color = 0x84783CCC,
        .static_overlay = "\n\n.\n\n\u{e006}\u{e007}\n\n\n\u{e004}\u{e005}",
        .static_offset = 0,
    },
    storage_load_segment: Segment = .{
        .color = 0x763C84CC,
        .static_overlay = "\n\n\n.\n\n\u{e010}\u{e011}\n\n\n\n.\n\n\u{e00e}\u{e00f}\n\n\n\n.\n\n\u{e00c}\u{e00d}\n\n\n\n\n.\n\n\nG\u{e012}\u{e013}",
        .static_offset = 1,
    },
    network_load_segment: Segment = .{
        .color = 0x43843CCC,
        .static_overlay = "\n\n\n.\n\n\u{e008}\u{e009}\n\n\n\n.\n\n\u{e00a}\u{e00b}",
        .static_offset = 1,
    },
    window_title_segment: Segment = .{
        .color = 0x00000077,
    },

    segments: [6]*Segment = undefined,

    // Active window marquee state
    title_codepoints: [260]u32 = @splat(0),
    title_len: usize = 0,
    title_fetch_tick: usize = 0,
    title_rotations: usize = 0,

    pub fn deinit(self: *StatusMonitor) void {
        for (&self.segments) |seg| {
            for (seg.metrics) |*entry| {
                entry.metric.deinit(self.io);
            }
        }
        self.rect.deinit();
        self.font.deinit();
        if (self.cells.len > 0) self.allocator.free(self.cells);
        if (self.sample_buffer.len > 0) self.allocator.free(self.sample_buffer);
    }

    pub fn init(self: *StatusMonitor, io: std.Io, allocator: std.mem.Allocator, tick: u8, render_rate: u8) !void {
        assert(tick > 0);
        assert(render_rate > 0);

        self.io = io;
        self.allocator = allocator;
        self.update_rate = if (tick > render_rate) render_rate else tick;
        self.render_rate = render_rate;
        self.frames_per_sample = @max(1, self.render_rate / self.update_rate);

        self.font = try FontAtlas.loadFromJson(io, allocator, "assets/font/tamzen.json");
        errdefer self.font.deinit();

        self.rect = try RectDraw.init();
        errdefer self.rect.deinit();

        var texture = try Texture.init(io, allocator, "assets/font/tamzen.png");
        defer texture.deinit();

        try self.rect.use();
        try self.rect.loadTexture(texture.width, texture.height, texture.rgba);
        try self.rect.setTextureSize(self.font.x_increment, self.font.y_increment);

        // Bind metric slices to segments
        self.time_segment.metrics = &self.time_metrics;
        self.processor_segment.metrics = &self.processor_metrics;
        self.thermal_load_segment.metrics = &self.thermal_metrics;
        self.storage_load_segment.metrics = &self.storage_metrics;
        self.network_load_segment.metrics = &self.network_metrics;
        self.window_title_segment.metrics = &self.window_metrics;

        // Dirty memory is sampled alongside free memory in MemProbe, rendered in storage_load_segment
        self.processor_metrics[1].secondary_segment = &self.storage_load_segment;

        // Wire X11 connection into WindowNameProbe by pointer
        self.window_metrics[0].metric.window.attach(self.window.display, self.window.root);

        self.segments = .{
            &self.time_segment,
            &self.processor_segment,
            &self.thermal_load_segment,
            &self.storage_load_segment,
            &self.network_load_segment,
            &self.window_title_segment,
        };

        // Allocate contiguous sample + frame interpolation buffer for the 7 numeric MetricEntries
        const numeric_metric_count = 7;
        const stride: u16 = @as(u16, self.update_rate) + self.frames_per_sample;
        self.sample_buffer = try allocator.alloc(u128, @as(usize, stride) * numeric_metric_count);
        @memset(self.sample_buffer, 0);

        setSlots(&self.processor_metrics[0], self.sample_buffer, stride, 0, self.update_rate);
        setSlots(&self.processor_metrics[1], self.sample_buffer, stride, 1, self.update_rate);
        setSlots(&self.thermal_metrics[0], self.sample_buffer, stride, 2, self.update_rate);
        setSlots(&self.thermal_metrics[1], self.sample_buffer, stride, 3, self.update_rate);
        setSlots(&self.storage_metrics[0], self.sample_buffer, stride, 4, self.update_rate);
        setSlots(&self.storage_metrics[1], self.sample_buffer, stride, 5, self.update_rate);
        setSlots(&self.network_metrics[0], self.sample_buffer, stride, 6, self.update_rate);

        // Prime cumulative counters (CPU, Disk I/O, Network) so frame 0 starts without boot spikes
        for (self.segments) |seg| {
            for (seg.metrics) |*entry| {
                entry.metric.sample(io) catch {};
            }
        }

        try self.recomputeLayout();
    }

    fn setSlots(entry: *MetricEntry, buffer: []u128, stride: u16, position: u8, sample_count: u8) void {
        const start: usize = @as(usize, stride) * position;
        const mid: usize = start + sample_count;
        const end: usize = @as(usize, stride) * (position + 1);

        entry.sample = buffer[start..mid];
        entry.frames = buffer[mid..end];
    }

    pub fn recomputeLayout(self: *StatusMonitor) !void {
        if (self.cells.len > 0) {
            self.allocator.free(self.cells);
            self.cells = &.{};
        }

        const window_height = @as(f32, @floatFromInt(@max(1, self.window.height)));
        const char_height = @as(f32, @floatFromInt(self.font.char_height));
        self.rect_height = char_height / window_height * 2.0;

        const screen_width = @as(f32, @floatFromInt(@max(1, self.window.width)));
        const char_width = @as(f32, @floatFromInt(self.font.char_width));
        const raw_width_f = char_width / screen_width * 2.0;
        self.rect_width_i = @max(1, @as(i16, @intFromFloat(@ceil(raw_width_f * 32767.0))));
        self.rect_width_f = @as(f32, @floatFromInt(self.rect_width_i)) / 32767.0;

        // 0.52 vertically centers Tamzen inside the 17px bar
        self.rect_y_pos = @intFromFloat(self.rect_height * 32767.0 * 0.52);

        try self.rect.setRectSize(self.rect_width_f, self.rect_height);
        try self.generateCells();

        const cells_count = self.cells.len;
        const time_idx = cells_count -| time_width;
        const proc_idx = time_idx -| processor_width;
        const therm_idx = proc_idx -| thermal_width;
        const stor_idx = therm_idx -| storage_width;
        const net_idx = stor_idx -| network_width;

        self.time_segment.cells = self.cells[time_idx..cells_count];
        self.processor_segment.cells = self.cells[proc_idx..time_idx];
        self.thermal_load_segment.cells = self.cells[therm_idx..proc_idx];
        self.storage_load_segment.cells = self.cells[stor_idx..therm_idx];
        self.network_load_segment.cells = self.cells[net_idx..stor_idx];
        self.window_title_segment.cells = self.cells[0..net_idx];

        // Force full clear + static icon redraw + metric redraw
        try self.clearAllAndDrawStatic();
        for (self.segments) |seg| {
            for (seg.metrics) |*m| {
                m.last_p1 = std.math.maxInt(u64);
                m.last_p2 = std.math.maxInt(u64);
            }
        }
        self.time_metrics[0].metric.time.changed = true;
        self.window_metrics[0].metric.window.changed = true;
    }

    fn generateCells(self: *StatusMonitor) !void {
        const cell_size: u16 = @intCast(self.rect_width_i);
        const char_count: usize = @max(right_fixed_cells + 4, @divTrunc(65535, cell_size));
        self.cells = try self.allocator.alloc(i16, char_count + 1);

        var current_x: i16 = -32768;
        for (self.cells) |*cell| {
            cell.* = current_x;
            current_x +%= self.rect_width_i;
        }
    }

    pub fn update(self: *StatusMonitor) !void {
        if (self.window.resized) {
            self.window.resized = false;
            try self.recomputeLayout();
        }

        if (self.window.clicked) {
            self.window.clicked = false;
            self.handleClick(self.window.last_click.x, self.window.last_click.button);
        }

        if (self.ticks % self.frames_per_sample == 0) {
            const sample_idx: u8 = @intCast((self.ticks / self.frames_per_sample) % self.update_rate);
            for (self.segments) |segment| {
                segment.update(self.io, sample_idx);
            }
        }
    }

    pub fn render(self: *StatusMonitor) !void {
        const sub_frame = self.ticks % self.frames_per_sample;
        var drew_anything = false;

        // 1. Numeric interpolated metrics (both primary and optional secondary channels)
        for (self.segments) |segment| {
            for (segment.metrics) |*m| {
                if (m.metric == .time or m.metric == .window) continue;

                const packed_val = m.frames[sub_frame];
                const v1: u64 = @truncate(packed_val);
                if (v1 != m.last_p1) {
                    m.last_p1 = v1;
                    const s1 = m.metric.print(v1, 0);
                    try self.drawSegment(segment, s1.slice(), m.start_index);
                    drew_anything = true;
                }

                if (m.secondary_index) |sec_offset| {
                    const v2: u64 = @truncate(packed_val >> 64);
                    if (v2 != m.last_p2) {
                        m.last_p2 = v2;
                        const target_seg = m.secondary_segment orelse segment;
                        const s2 = m.metric.print(v2, 1);
                        try self.drawSegment(target_seg, s2.slice(), sec_offset);
                        drew_anything = true;
                    }
                }
            }
        }

        // 2. Wall-clock time segment (updates once per second)
        const time_probe = &self.time_metrics[0].metric.time;
        if (time_probe.changed) {
            time_probe.changed = false;
            try self.drawSegment(&self.time_segment, &time_probe.value, self.time_metrics[0].start_index);
            drew_anything = true;
        }

        // 3. Active window title + marquee rotation for overflowing titles
        if (try self.renderWindowTitle()) {
            drew_anything = true;
        }

        if (drew_anything) {
            try self.rect.flush();
        }

        self.ticks +%= 1;
    }

    fn renderWindowTitle(self: *StatusMonitor) !bool {
        const win_probe = &self.window_metrics[0].metric.window;
        const max_chars = self.window_title_segment.cells.len -| 2;
        if (max_chars == 0) return false;

        if (win_probe.changed) {
            win_probe.changed = false;
            try self.clearSegment(&self.window_title_segment);

            // Filter UTF-8 title down to codepoints present in FontAtlas
            self.title_len = 0;
            if (std.unicode.Utf8View.init(win_probe.slice())) |view| {
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp == '\n' or cp == '\r') continue;
                    if (self.font.getGlyphUV(cp) != null and self.title_len < 252) {
                        self.title_codepoints[self.title_len] = cp;
                        self.title_len += 1;
                    }
                }
            } else |_| {
                for (win_probe.slice()) |b| {
                    if (b >= 32 and b < 127 and self.font.getGlyphUV(b) != null and self.title_len < 252) {
                        self.title_codepoints[self.title_len] = b;
                        self.title_len += 1;
                    }
                }
            }

            if (self.title_len > max_chars and self.title_len + 3 <= self.title_codepoints.len) {
                self.title_codepoints[self.title_len] = ' ';
                self.title_codepoints[self.title_len + 1] = 0x02;
                self.title_codepoints[self.title_len + 2] = ' ';
                self.title_len += 3;
            }

            self.title_fetch_tick = self.ticks;
            self.title_rotations = 0;

            try self.drawCodepoints(&self.window_title_segment, self.title_codepoints[0..@min(self.title_len, max_chars)], 1);
            return true;
        }

        // Marquee scroll after 1 second if title exceeds available cells
        if (self.title_len > max_chars and
            self.ticks > self.title_fetch_tick + self.render_rate and
            (self.ticks - self.title_fetch_tick) % self.frames_per_sample == 0)
        {
            std.mem.rotate(u32, self.title_codepoints[0..self.title_len], 1);
            try self.drawCodepoints(&self.window_title_segment, self.title_codepoints[0..max_chars], 1);

            self.title_rotations += 1;
            if (self.title_rotations >= self.title_len * 2) {
                self.title_fetch_tick = self.ticks + 60 * @as(usize, self.render_rate);
                self.title_rotations = 0;
            }
            return true;
        }

        return false;
    }

    pub fn drawSegment(self: *StatusMonitor, seg: *const Segment, input: []const u8, offset: u8) !void {
        if (input.len == 0 or offset >= seg.cells.len) return;

        const cp_len = try std.unicode.utf8CountCodepoints(input);
        if (cp_len == 0) return;

        var char_stack: [128]u16 = undefined;
        var slot_stack: [128]i16 = undefined;

        var dynamic_chars: ?[]u16 = null;
        var dynamic_slots: ?[]i16 = null;
        defer {
            if (dynamic_chars) |dc| self.allocator.free(dc);
            if (dynamic_slots) |ds| self.allocator.free(ds);
        }

        var characters: []u16 = undefined;
        var slots: []i16 = undefined;
        if (cp_len * 2 > char_stack.len) {
            dynamic_chars = try self.allocator.alloc(u16, cp_len * 2);
            dynamic_slots = try self.allocator.alloc(i16, cp_len * 2);
            characters = dynamic_chars.?;
            slots = dynamic_slots.?;
        } else {
            characters = char_stack[0 .. cp_len * 2];
            slots = slot_stack[0 .. cp_len * 2];
        }

        const view = try std.unicode.Utf8View.init(input);
        var iterator = view.iterator();
        var cell_idx: usize = 0;
        var vert_idx: usize = 0;

        while (iterator.nextCodepoint()) |cp| {
            const target_cell = cell_idx + offset;
            if (target_cell >= seg.cells.len) break;
            cell_idx += 1;

            if (cp == '\n') continue; // Preserve existing static glyph in this cell

            if (self.font.getGlyphUV(cp)) |glyph| {
                const out = vert_idx * 2;
                characters[out..][0..2].* = glyph;
                slots[out..][0..2].* = .{ seg.cells[target_cell], self.rect_y_pos };
                vert_idx += 1;
            }
        }

        if (vert_idx == 0) return;

        try self.rect.setBackgroundColorU32(seg.color);
        try self.rect.setTextureCoordinates(characters[0 .. vert_idx * 2]);
        try self.rect.setRectPoints(slots[0 .. vert_idx * 2]);
        try self.rect.draw(@intCast(vert_idx));
    }

    fn drawCodepoints(self: *StatusMonitor, seg: *const Segment, codepoints: []const u32, offset: u8) !void {
        if (codepoints.len == 0 or offset >= seg.cells.len) return;

        const max_emit = @min(codepoints.len, seg.cells.len - offset);
        var char_stack: [512]u16 = undefined;
        var slot_stack: [512]i16 = undefined;
        const limit = @min(max_emit, char_stack.len / 2);

        var vert_idx: usize = 0;
        for (codepoints[0..limit], 0..) |cp, cell_idx| {
            if (self.font.getGlyphUV(cp)) |glyph| {
                const out = vert_idx * 2;
                char_stack[out..][0..2].* = glyph;
                slot_stack[out..][0..2].* = .{ seg.cells[offset + cell_idx], self.rect_y_pos };
                vert_idx += 1;
            }
        }

        if (vert_idx == 0) return;

        try self.rect.setBackgroundColorU32(seg.color);
        try self.rect.setTextureCoordinates(char_stack[0 .. vert_idx * 2]);
        try self.rect.setRectPoints(slot_stack[0 .. vert_idx * 2]);
        try self.rect.draw(@intCast(vert_idx));
    }

    /// Clears a single segment background in 1 quad draw with zero heap allocations.
    pub fn clearSegment(self: *StatusMonitor, seg: *const Segment) !void {
        if (seg.cells.len == 0) return;
        const space_uv = self.font.getGlyphUV(' ') orelse .{ 0, 0 };
        const start_ndc = @max(-1.0, @as(f32, @floatFromInt(seg.cells[0])) / 32767.0);
        const end_x_i32 = @as(i32, seg.cells[seg.cells.len - 1]) + @as(i32, self.rect_width_i);
        const end_ndc = if (seg == &self.time_segment)
            1.0
        else
            @min(1.0, @as(f32, @floatFromInt(end_x_i32)) / 32767.0);
        const seg_width_ndc = @max(0.0, end_ndc - start_ndc);

        try self.rect.setRectSize(seg_width_ndc, 2.0);
        try self.rect.setBackgroundColorU32(seg.color);
        try self.rect.setTextureCoordinates(&space_uv);
        try self.rect.setRectPoints(&.{ seg.cells[0], 32767 });
        try self.rect.draw(1);
        try self.rect.setRectSize(self.rect_width_f, self.rect_height);
    }

    pub fn clearAllAndDrawStatic(self: *StatusMonitor) !void {
        // Draw right-to-left (matching segment layout) and stamp static icons/separators
        var i = self.segments.len;
        while (i > 0) {
            i -= 1;
            const seg = self.segments[i];
            try self.clearSegment(seg);
            if (seg.static_overlay.len > 0) {
                try self.drawSegment(seg, seg.static_overlay, seg.static_offset);
            }
        }
        try self.rect.flush();
    }

    fn handleClick(self: *StatusMonitor, x_pos: i32, _: u32) void {
        if (self.font.char_width == 0 or self.window.width <= 0) return;
        const clamped_x = std.math.clamp(x_pos, 0, self.window.width);
        const from_right: usize = @intCast(@divTrunc(self.window.width - clamped_x, self.font.char_width));

        const cmd: []const u8 = if (from_right < time_width)
            "cclip -i $(date +%s)\n"
        else if (from_right < time_width + processor_width)
            "konsole -e htop &\n"
        else if (from_right < time_width + processor_width + thermal_width)
            "screenfix &\n"
        else if (from_right < time_width + processor_width + thermal_width + storage_width)
            "dolphin &\n"
        else if (from_right < right_fixed_cells)
            "usb-restart &\n"
        else
            "cclip -i \"$(xdotool getwindowname `xdotool getactivewindow` | tr -d '\\n')\" &\n";

        std.Io.File.stdout().writeStreamingAll(self.io, cmd) catch {};
    }
};
