const std = @import("std");

const FontAtlas = @import("FontAtlas.zig").FontAtlas;
const RectDraw = @import("RectDraw.zig").RectDraw;
const segment_zig = @import("Segment.zig");
const meteric = @import("metrics.zig");
const Window = @import("Window.zig").Window;
const Texture = @import("Texture.zig").Texture;

const assert = std.debug.assert;
const print = std.debug.print;

const Segment = segment_zig.Segment;
const MetricEntry = segment_zig.MetricEntry;

var time_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .time = .{} } },
};

var processor_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .cpu = .{} } },
    .{ .metric = .{ .memory = .{} } },
};

var thermal_load_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .temp = .{} } },
    .{ .metric = .{ .load = .{} } },
};

var storage_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .free_storage = .{} } },
    .{ .metric = .{ .io = .{} } },
};

var network_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .net = .{} } },
};

var window_metrics_storage = [_]MetricEntry{
    .{ .metric = .{ .window = .{} } },
};

pub const StatusMonitor = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,

    rect: RectDraw = undefined,
    font: FontAtlas = undefined,
    window: Window = undefined,

    // Timing
    update_rate: u8 = 0,
    render_rate: u8 = 0,
    ticks: usize = 0,

    // Rect Comptue
    rect_height: f32 = undefined, // height of rect in NDC

    rect_width_i: i16 = undefined, // fixed point (-32768 -> 32767)
    rect_width_f: f32 = undefined, // NDC (-1 -> 1)

    rect_y_pos: i16 = undefined, // y pos for rect NDC

    cells: []i16 = undefined,
    sample_buffer: []u128 = undefined,

    time_segment: Segment = Segment{
        .metrics = &time_metrics_storage, .color = 0x595959CC
    },
    processor_segment: Segment = Segment{
        .metrics = &processor_metrics_storage, .color = 0x844242CC
    },
    thermal_load_segment: Segment = Segment{
        .metrics = &thermal_load_metrics_storage, .color = 0x84783CCC
    },
    storage_load_segment: Segment = Segment{
        .metrics = &storage_metrics_storage, .color = 0x763C84CC
    },
    network_load_segment: Segment = Segment{
        .metrics = &network_metrics_storage, .color = 0x43843CCC
    },
    window_title_segment: Segment = Segment{
        .metrics = &window_metrics_storage, .color = 0x00000077
    },

    // State
    segments: [6]*Segment = undefined,

    pub fn deinit(self: *StatusMonitor) void {
        // self.window_title_buf.deinit(self.allocator);
        self.rect.deinit();
        self.font.deinit();

        for (&self.segments) |*segment| {
            _ = segment;
            // segment.deinit();
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.sample_buffer);
    }

    pub fn init(self: *StatusMonitor, io: std.Io, allocator: std.mem.Allocator, tick: u8, render_rate: u8) !void {
        self.font = try FontAtlas.loadFromJson(io, allocator, "assets/font/tamzen.json");
        self.rect = try RectDraw.init();

        var texture = try Texture.init(io, allocator, "assets/font/tamzen.png");
        defer texture.deinit();

        // Rect Compute Set
        const window_height = @as(f32, @floatFromInt(self.window.height));
        const char_height = @as(f32, @floatFromInt(self.font.char_height));

        self.rect_height = char_height / window_height * 2;

        const screen_width = @as(f32, @floatFromInt(self.window.width));
        const char_width = @as(f32, @floatFromInt(self.font.char_width));

        self.rect_width_f = char_width / screen_width * 2;
        self.rect_width_i = @as(i16, @ceil(self.rect_width_f * 32767));

        // 0.52 to make text slightly higher
        self.rect_y_pos = @intFromFloat(self.rect_height * 32767 * 0.52);

        // Activate the shader program and bind the VAO
        try self.rect.use();

        // Set the rect configuration
        try self.rect.loadTexture(texture.width, texture.height, texture.rgba); 
        try self.rect.setRectSize(self.rect_width_f, self.rect_height);
        try self.rect.setTextureSize(self.font.x_increment, self.font.y_increment);

        self.io = io;
        self.allocator = allocator;
        self.update_rate = if (tick > render_rate) render_rate else tick;
        self.render_rate = render_rate;

        assert(tick > 0);
        assert(render_rate > 0);

        self.segments = .{
            &self.time_segment,
            &self.processor_segment,
            &self.thermal_load_segment,
            &self.storage_load_segment,
            &self.network_load_segment,
            &self.window_title_segment,
        };

        main_loop: for (self.segments) |segment| {
            // TODO

            for (segment.metrics) |meteric_entry| {
                var m = meteric_entry.metric;
                if (m == .window) {
                    // std.debug.print("------------------------------ HELLLLO WINDOW INITING HERERE ERERER !@#@@?@?@??@\n", .{});
                    m.window.display = self.window.display;
                    m.window.root = self.window.root;
                    continue :main_loop; // skipping updates for now
                }
            }

            // segment.update(io, 0);
        }

        // std.debug.print("Size of segments: {d}\n", .{@sizeOf(Segment)});
        // std.debug.print("Bytes in memory: {d}\n", .{@sizeOf(@TypeOf(self.segments))});

        // std.debug.print("Glyphs count: {d}\n", .{self.font.glyphs.len});
        // std.debug.print("Font Bytes in memory: {d}\n", .{@sizeOf(@TypeOf(self.font.glyphs[0])) * self.font.glyphs.len});

        try self.generateCells();
        const cells_count = self.cells.len;

        // only need frames between samples. if buffers are equal only sub 1 (-1) if redner rate is longer sub 2 (-2)
        const discards: u8 = 1; // if (self.render_rate > self.update_rate) 2 else 1; // subing one for now
        const frame_len: u16 = self.render_rate / self.update_rate - discards;
        const sampled_segment_count = 7; // 8; // FIXME

        const stride = frame_len + self.update_rate;
        const total_len = stride * sampled_segment_count;

        print("discards: {} fram_len: {} total_len: {any}\n", .{ discards, frame_len, total_len });

        self.sample_buffer = try allocator.alloc(u128, total_len);

        for (self.sample_buffer, 0..) |*b, i| {
            b.* = i;
        }

        // TODO hardcod these indexes somewhere else. DISGUSTING
        const time_cells_index = cells_count - 23;

        self.time_segment.cells = self.cells[time_cells_index..];
        self.time_segment.metrics[0].start_index = 1;
        // setSlots(&self.time_segment.metrics[0], self.sample_buffer, stride, 0, self.update_rate);

        print("update_rate: {any}\n", .{self.update_rate});
        print("frames_len: {any}\n", .{frame_len});
        print("time segment: {any}\n", .{self.time_segment.metrics[0]});

        const processor_cells_index = time_cells_index - 15;

        self.processor_segment.cells = self.cells[processor_cells_index..time_cells_index];

        self.processor_segment.metrics[0].start_index = 1;
        setSlots(&self.processor_segment.metrics[0], &self.sample_buffer, stride, 0, self.update_rate);

        self.processor_segment.metrics[1].start_index = 6;
        setSlots(&self.processor_segment.metrics[1], &self.sample_buffer, stride, 1, self.update_rate);

        print("cpu segment: {any}\n", .{self.processor_segment.metrics[0]});
        print("mem segment: {any}\n", .{self.processor_segment.metrics[1]});

        const thermal_cells_index = processor_cells_index - 13;

        self.thermal_load_segment.cells = self.cells[thermal_cells_index..processor_cells_index];

        self.thermal_load_segment.metrics[0].start_index = 8;
        setSlots(&self.thermal_load_segment.metrics[0], &self.sample_buffer, stride, 2, self.update_rate);

        self.thermal_load_segment.metrics[1].start_index = 1;
        setSlots(&self.thermal_load_segment.metrics[1], &self.sample_buffer, stride, 3, self.update_rate);

        print("thermal segment: {any}\n", .{self.thermal_load_segment.metrics[0]});
        print("load segment: {any}\n", .{self.thermal_load_segment.metrics[1]});

        const storage_metrics_index = thermal_cells_index - 40;

        self.storage_load_segment.cells = self.cells[storage_metrics_index..thermal_cells_index];

        self.storage_load_segment.metrics[0].start_index = 28;
        setSlots(&self.storage_load_segment.metrics[0], &self.sample_buffer, stride, 4, self.update_rate);

        self.storage_load_segment.metrics[1].start_index = 1;
        setSlots(&self.storage_load_segment.metrics[1], &self.sample_buffer, stride, 5, self.update_rate);

        print("free segment: {any}\n", .{self.storage_load_segment.metrics[0]});
        print("IO segment: {any}\n", .{self.storage_load_segment.metrics[1]});

        const network_metrics_index = storage_metrics_index - 19;

        self.network_load_segment.cells = self.cells[network_metrics_index..storage_metrics_index];

        self.network_load_segment.metrics[0].start_index = 1;
        setSlots(&self.network_load_segment.metrics[0], &self.sample_buffer, stride, 6, self.update_rate);

        print("NET segment: {any}\n", .{self.network_load_segment.metrics[0]});

        self.window_title_segment.cells = self.cells[0..network_metrics_index];

        self.window_title_segment.metrics[0].start_index = 1; // FIXME
        // setSlots(&self.window_title_segment.metrics[0], self.sample_buffer, stride, 7, self.update_rate);

        print("WINDOW segment: {any}\n", .{self.window_title_segment.metrics[0]});

        // std.process.exit(0);
        try self.clear();
    }

    fn setSlots(self: *MetricEntry, buffer: *[]u128, stride: u16, postion: u8, divider: u8) void {
        const start: u16 = stride * postion;
        const end: u16 = stride * (postion + 1);

        self.sample = buffer.*[start..start+divider];
        self.frames = buffer.*[start+divider..end];
    }

    pub fn update(self: *StatusMonitor) void {

        if (self.ticks % self.update_rate == 0) {

            const sample_idx = @as(u8, @intCast(self.ticks / self.update_rate % self.update_rate));

            for (self.segments) |segment| {
                segment.update(self.io, sample_idx);
            }
        }

        self.ticks += 1;
    }

    /// Generate OpenGL Coordinates
    fn generateCells(self: *StatusMonitor) !void {
        const cell_size: u16 = @intCast(self.rect_width_i);
        const char_count: usize = @divTrunc(65535, cell_size);
        self.cells = try self.allocator.alloc(i16, char_count + 1);

        // Starting point: -1.0 in i16 space is -32768
        var current_x: i16 = -32768;

        for (self.cells) |*cell| {
            cell.* = current_x;
            current_x +%= self.rect_width_i;
        }

        print("total cells length {}\n", .{self.cells.len});
    }

    pub fn drawSegment(self: *StatusMonitor, seg: *Segment, input: []const u8, offset: u8) !void {

        const cp_len = try std.unicode.utf8CountCodepoints(input);
        if (cp_len == 0) return;

        var characters: []u16 = undefined;
        var slots: []i16 = undefined;

        // fixed stack for short string <64 characters
        var char_stack: [128]u16 = undefined;
        var slot_stack: [128]i16 = undefined;

        // Dynamic fallback only if the string is unusually long
        var dynamic_chars: ?[]u16 = null;
        var dynamic_slots: ?[]i16 = null;
        defer {
            if (dynamic_chars) |dc| self.allocator.free(dc);
            if (dynamic_slots) |ds| self.allocator.free(ds);
        }

        if (cp_len * 2 > 128) {
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
        var i: usize = 0;

        while (iterator.nextCodepoint()) |c| {
            if (c == '\n') continue;

            const glyph = self.font.getGlyphUV(c);
            const idx = i * 2;

            // u and v for rect
            characters[idx..][0..2].* = glyph;

            // x and y for rect
            slots[idx..][0..2].* = .{ seg.cells[i + offset], self.rect_y_pos };

            i += 1;
        }

        try self.rect.setBackgroundColorU32(seg.color);
        try self.rect.setTextureCoordinates(characters);
        try self.rect.setRectPoints(slots);
        try self.rect.draw(@intCast(input.len));
    }

    pub fn render(self: *StatusMonitor) !void {

        const rate: u16 = self.render_rate / self.update_rate - 1;
        const idx = self.ticks % (rate);
        print("\nidx:{}\n", .{idx});

        for (self.segments) |segment| {
            for (segment.metrics) |*m| {

                if (m.metric == .time or m.metric == .window) continue;
                print("{any}\n", .{m});

                const frame_value = m.frames[idx];

                const m_string = m.metric.print(@as(u64, @intCast(frame_value & std.math.maxInt(u64))), 0).slice();
                self.drawSegment(segment, m_string, m.start_index) catch {};
            }
        }
        // const x = &self.time_segment.metrics[0].metric.time.value;
        // const o = self.time_segment.metrics[0].start_index;

        const word = "Waterfox DICKs Hello world HATE HATE HATE HATE HATE HATE HATE HATE HATE HATE penis, Prase the omni messiah 0123456789!";

        // try self.drawSegment(&self.time_segment, x, o);
        try self.drawSegment(&self.window_title_segment, word, 1);

        try self.rect.flush();
    }

    pub fn clear(self: *StatusMonitor) !void {
        const y_pos = self.rect_y_pos; // saving it for later

        // rednering is garbage. so I'm increasing the rect size and redering in the opssite way
        // this only to hide one line of dead pixels

        self.rect_y_pos = 32767;
        try self.rect.setRectSize(self.rect_width_f * 1.01, 2.0); 

        var i = self.segments.len;
        while (i>0) {
            const segment = self.segments[i-1];

            const empty_string = try self.allocator.alloc(u8, segment.cells.len);
            @memset(empty_string, ' ');

            try self.drawSegment(segment, empty_string, 0);
            i -= 1;
        }

        self.rect_y_pos = y_pos;
        try self.rect.setRectSize(self.rect_width_f, self.rect_height);
    }

    fn fetchData(self: *StatusMonitor, tick_idx: u8) !void {
        self.screen.handleEvents();
        if (self.screen.isButtonClicked()) {
            self.handleClick(self.screen.getClickX(), self.screen.getClickButton());
            self.screen.clearClick();
        }

        _ = tick_idx;

        // Zig Concurrency: Instead of std::async (which is heavy),
        // we use a Thread Pool or simply sequential updates if latency is low.
        // For a status bar, sequential is often safer and easier to debug.
        // self.free_memory.newTick(tick_idx, format.getFreeMemory());
        // self.cpu_usage.newTick(tick_idx, format.getCpuUsage());
        // ... etc
    }
};
