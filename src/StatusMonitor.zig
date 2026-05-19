const std = @import("std");

const FontAtlas = @import("FontAtlas.zig").FontAtlas;
const RectDraw = @import("RectDraw.zig").RectDraw;
const segment_zig = @import("Segment.zig");
const meteric = @import("metrics.zig");
const Window = @import("Window.zig").Window;

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
    rect: RectDraw = undefined,
    font: FontAtlas = undefined,
    window: Window = undefined,

    // Timing
    update_rate: u8 = 0,
    render_rate: u8 = 0,

    cells: []i16 = undefined,

    time_segment: Segment = Segment{
        .metrics = &time_metrics_storage,
    },
    processor_segment: Segment = Segment{
        .metrics = &processor_metrics_storage,
    },
    thermal_load_segment: Segment = Segment{
        .metrics = &thermal_load_metrics_storage,
    },
    storage_load_segment: Segment = Segment{
        .metrics = &storage_metrics_storage,
    },
    network_load_segment: Segment = Segment{
        .metrics = &network_metrics_storage,
    },
    window_title_segment: Segment = Segment{
        .metrics = &window_metrics_storage,
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
    }

    pub fn init(self: *StatusMonitor, allocator: std.mem.Allocator, tick: u8, render_rate: u8) !void {
        // TODO validated Rect
        self.rect = try RectDraw.init();
        self.font = try FontAtlas.loadFromJson(allocator, "assets/font/tamzen.json");

        //
        // 1. You only want ONE anchor point because your Geometry Shader expands it into 4 vertices
        const single_anchor_point = [_]f32{
            -0.5, 0.5, // Top-left anchor position in NDC space
        };

        // Even though you don't use textures, your shaders demand texture logic variables to exist
        const dummy_tex_coords = [_]f32{
            0.0, 0.0,
        };

        // 2. Activate the shader program and bind the VAO
        try self.rect.use();

        // 3. Upload the single anchor point geometry
        try self.rect.setRectPoints(&single_anchor_point);
        
        // 4. Update the layout requirement for your second VBO buffer ("texcoord")
        // Your Fragment Shader reads this, so the vertex attributes MUST be bound
        try self.rect.setTextureCoordinates(&dummy_tex_coords);

        // 5. Explicitly bind a fallback texture slot (0) so your sampler2D doesn't break your color mix 
        try self.rect.loadTexture(1, 1, &.{0, 0, 255, 0}); 

        // 6. Set the layout configuration sizes (working relative to NDC limits)
        try self.rect.setRectSize(1.0, 1.0);  // Width: 1.0, Height: 1.0 in NDC scales
        try self.rect.setTextureSize(0.0, 0.0); // Dummy texture size

        // 7. Set your color uniform to Red 
        try self.rect.setBackgroundColor(1.0, 0.0, 0.0, 0);

        // 8. CRITICAL: Draw exactly 1 point. 
        // The Geometry shader receives this 1 point and outputs 4 vertices (Triangle Strip)
        try self.rect.draw(1);

        // 9. Process instructions immediately
        try self.rect.flush();
        //

        self.allocator = allocator;
        self.update_rate = if (tick > render_rate) render_rate else tick;
        self.render_rate = render_rate;

        assert(tick > 0);
        assert(render_rate > 0);

        const sw: f32 = @floatFromInt(self.window.width);
        const cw: f32 = @floatFromInt(self.font.char_width);
        const y_pos: f32 = 0.9 - (cw / sw);

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

            segment.update();
        }

        // std.debug.print("Size of segments: {d}\n", .{@sizeOf(Segment)});
        // std.debug.print("Bytes in memory: {d}\n", .{@sizeOf(@TypeOf(self.segments))});

        // std.debug.print("Glyphs count: {d}\n", .{self.font.glyphs.len});
        // std.debug.print("Font Bytes in memory: {d}\n", .{@sizeOf(@TypeOf(self.font.glyphs[0])) * self.font.glyphs.len});

        try self.generateCells();

        // test slice
        const test_slice = self.cells[3..5];
        const cells_count = self.cells.len;
        std.debug.print("{any}, fulllength: {d}\n", .{ test_slice, cells_count });

        // only need frames between samples. if buffers are equal only sub 1 (-1) if redner rate is longer sub 2 (-2)
        const discards: u8 = 1; // if (self.render_rate > self.update_rate) 2 else 1; // subing one for now
        const frame_len: u16 = self.render_rate / self.update_rate - discards;
        const sampled_segment_count = 7; // 8; // FIXME

        const stride = frame_len + self.update_rate;
        const total_len = stride * sampled_segment_count;

        print("discards: {} fram_len: {} total_len: {any}\n", .{ discards, frame_len, total_len });

        var buffer = try allocator.alloc(u64, total_len);

        for (buffer, 0..) |*b, i| {
            b.* = i;
        }

        // TODO hardcod these indexes somewhere else. DISGUSTING
        const time_cells_index = cells_count - 22;

        self.time_segment.cells = self.cells[time_cells_index..];
        self.time_segment.metrics[0].start_index = 1;
        // setSlots(&self.time_segment.metrics[0], &buffer, stride, 0, self.update_rate);

        print("update_rate: {any}\n", .{self.update_rate});
        print("frames_len: {any}\n", .{frame_len});
        print("time segment: {any}\n", .{self.time_segment.metrics[0]});

        const processor_cells_index = time_cells_index - 12; // FIXME

        self.processor_segment.cells = self.cells[processor_cells_index..time_cells_index];

        self.processor_segment.metrics[0].start_index = 1; // FIXME
        setSlots(&self.processor_segment.metrics[0], &buffer, stride, 0, self.update_rate);

        self.processor_segment.metrics[1].start_index = 1; // FIXME
        setSlots(&self.processor_segment.metrics[1], &buffer, stride, 1, self.update_rate);

        print("cpu segment: {any}\n", .{self.processor_segment.metrics[0]});
        print("mem segment: {any}\n", .{self.processor_segment.metrics[1]});

        const thermal_cells_index = processor_cells_index - 12; // FIXME

        self.thermal_load_segment.cells = self.cells[thermal_cells_index..processor_cells_index];

        self.thermal_load_segment.metrics[0].start_index = 1; // FIXME
        setSlots(&self.thermal_load_segment.metrics[0], &buffer, stride, 2, self.update_rate);

        self.thermal_load_segment.metrics[1].start_index = 1; // FIXME
        setSlots(&self.thermal_load_segment.metrics[1], &buffer, stride, 3, self.update_rate);

        print("thermal segment: {any}\n", .{self.thermal_load_segment.metrics[0]});
        print("load segment: {any}\n", .{self.thermal_load_segment.metrics[1]});

        const storage_metrics_index = thermal_cells_index - 12; // FIXME

        self.storage_load_segment.cells = self.cells[storage_metrics_index..thermal_cells_index];

        self.storage_load_segment.metrics[0].start_index = 1; // FIXME
        setSlots(&self.storage_load_segment.metrics[0], &buffer, stride, 4, self.update_rate);

        self.storage_load_segment.metrics[1].start_index = 1; // FIXME
        setSlots(&self.storage_load_segment.metrics[1], &buffer, stride, 5, self.update_rate);

        print("free segment: {any}\n", .{self.storage_load_segment.metrics[0]});
        print("IO segment: {any}\n", .{self.storage_load_segment.metrics[1]});

        const network_metrics_index = storage_metrics_index - 12; // FIXME

        self.network_load_segment.cells = self.cells[network_metrics_index..storage_metrics_index];

        self.network_load_segment.metrics[0].start_index = 1; // FIXME
        setSlots(&self.network_load_segment.metrics[0], &buffer, stride, 6, self.update_rate);

        print("NET segment: {any}\n", .{self.network_load_segment.metrics[0]});

        self.window_title_segment.cells = self.cells[0..network_metrics_index];

        self.window_title_segment.metrics[0].start_index = 1; // FIXME
        // setSlots(&self.window_title_segment.metrics[0], &buffer, stride, 7, self.update_rate);

        print("WINDOW segment: {any}\n", .{self.window_title_segment.metrics[0]});

        _ = y_pos;
        // Initialize segments (Simplified for brevity, following your C++ pattern)
        // In Zig, we'd likely pass a slice of slots to each segment
        // self.free_memory = Segment.init(segment.FREE_MEM_CONFIG, slots, y_pos);
        // self.drawSegment(u16, &self.free_memory, &[_]u16{ 0xE002, 0xE003 }); // Icon glyphs

        // std.process.exit(0);
    }

    fn setSlots(self: *MetricEntry, buffer: *[]u64, stride: u16, postion: u8, divider: u8) void {
        const start: u16 = stride * postion;
        const end: u16 = stride * (postion + 1);

        self.sample = buffer.*[start..start+divider];
        self.frames = buffer.*[start+divider..end];
    }

    pub fn update(self: *StatusMonitor) void {
        for (self.segments) |segment| {
            segment.update();
        }
    }

    /// Generate OpenGL Coordinates
    fn generateCells(self: *StatusMonitor) !void {
        const screen_w = self.window.width;
        const char_w = self.font.char_width;

        const char_count: usize = @intCast(@divTrunc(screen_w, char_w));

        self.cells = try self.allocator.alloc(i16, char_count + 1);

        // 1. Calculate the 'step' in NDC space, then scale to i16 range (32767)
        // Step = (char_w / (screen_w / 2)) * 32767
        // Simplified: (char_w * 65534) / screen_w
        const half_width = (@as(f32, @floatFromInt(screen_w)) / 2.0);
        const step_f = (@as(f32, @floatFromInt(char_w)) / half_width) * 32767.0;
        const step = @as(i32, @intFromFloat(step_f));

        // 2. Starting point: -1.0 in i16 space is -32767
        var current_x: i32 = -32767;

        for (self.cells) |*cell| {
            cell.* = @intCast(@max(-32768, @min(32767, current_x)));

            // 3. Just add the step. No floats, no divisions, no index lookups.
            current_x += step;
        }
    }

    /// Generic draw function (Handles both UTF-8 strings and UTF-16)
    pub fn drawSegment(self: *StatusMonitor, comptime T: type, seg: anytype, input: []const T) void {
        if (input.len == 0) return;

        const limit = @min(seg.getMaxCharacters() - seg.getOffset(), input.len);

        // Pre-allocate buffers for GL data
        var characters = std.ArrayList(f32).init(self.allocator);
        var slots = std.ArrayList(f32).init(self.allocator);
        defer {
            characters.deinit();
            slots.deinit();
        }

        for (input[0..limit]) |c| {
            if (c == '\n') continue;
            if (self.font_cache.getGlyphCord(c)) |cord| {
                characters.appendSlice(&[_]f32{ cord.x, cord.y }) catch return;
                slots.appendSlice(&[_]f32{ seg.getSlot(seg.getOffset()), seg.getYpos() }) catch return;
            }
        }

        self.rect.setBackgroundColor(seg.getColor());
        self.rect.setTextureCoordinates(characters.items);
        self.rect.setRectPoints(slots.items);
        self.rect.draw(@intCast(slots.items.len / 2));
    }

    pub fn render(self: *StatusMonitor) !void {
        _ = self;
    }

    fn cycle(self: *StatusMonitor) !void {
        // Draw Time
        // self.drawSegment(u8, &self.time, format.getDate());

        var i: u8 = 0;
        while (i < self.tick_rate) : (i += 1) {
            try self.fetchData(i);
            var k: u8 = 0;
            while (k < self.update_interval) : (k += 1) {
                self.render(k);
            }
        }
        // Handle leftovers...
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

    fn sleep(self: *StatusMonitor) void {
        const now = std.time.nanoTimestamp();
        const elapsed = @as(u64, @intCast(now - self.start_time));
        const sleep_ns = self.period_ns - (elapsed % self.period_ns);
        std.Thread.sleep(sleep_ns);
    }

    pub fn run(self: *StatusMonitor) !noreturn {
        while (true) {
            try self.cycle();
        }
    }
};
