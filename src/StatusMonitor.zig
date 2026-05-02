const std = @import("std");
const segment = @import("segment.zig");
const renderer = @import("renderer.zig");
const types = @import("types.zig");
const format = @import("format.zig");

// Assuming these are defined elsewhere in your Zig project
const Rect = types.Rect;
const Font = types.Font;
const Segment = segment.Segment;
const SegmentDraw = segment.SegmentDraw;

pub const StatusMonitor = struct {
    allocator: std.mem.Allocator,
    screen: *renderer.Renderer,
    rect: *Rect,
    font_cache: *Font,

    // Timing
    tick_rate: u8,
    update_rate: u8,
    update_interval: u8,
    update_leftover: u8,
    period_ns: u64,
    start_time: i64,
    program_counter: i64 = 0,

    // Segments
    time: SegmentDraw,
    free_memory: Segment,
    cpu_usage: Segment,
    temperature: Segment,
    system_load: Segment,
    free_space: Segment,
    dirty_memory: Segment,
    io_write: Segment,
    io_read: Segment,
    net_tx: Segment,
    net_rx: Segment,
    window_title: SegmentDraw,

    // State
    window_title_buf: std.ArrayList(u16),
    window_fetch_time: i64 = 0,
    window_name_rotation: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        scrn: *renderer.Renderer,
        prep_rect: *Rect,
        font: *Font,
        tick: u8,
        update: u8,
    ) !StatusMonitor {
        const actual_update = if (update > tick) update else tick;
        
        var self = StatusMonitor{
            .allocator = allocator,
            .screen = scrn,
            .rect = prep_rect,
            .font_cache = font,
            .tick_rate = tick,
            .update_rate = actual_update,
            .update_interval = actual_update / tick,
            .update_leftover = actual_update % tick,
            .period_ns = (1_000_000_000 / @as(u64, actual_update)),
            .start_time = std.time.nanoTimestamp(),
            .window_title_buf = std.ArrayList(u16).init(allocator),
            // Placeholders - initialized in segmentsInit
            .time = undefined, .free_memory = undefined, .cpu_usage = undefined,
            .temperature = undefined, .system_load = undefined, .free_space = undefined,
            .dirty_memory = undefined, .io_write = undefined, .io_read = undefined,
            .net_tx = undefined, .net_rx = undefined, .window_title = undefined,
        };

        try self.segmentsInit();
        return self;
    }

    pub fn deinit(self: *StatusMonitor) void {
        self.window_title_buf.deinit();
    }

    fn segmentsInit(self: *StatusMonitor) !void {
        const screen_w = self.screen.getWidth();
        const char_w = self.font_cache.getCharWidth();
        const char_count = screen_w / char_w;
        const y_pos: f32 = 0.9 - (@as(f32, @floatFromInt(char_w)) / @as(f32, @floatFromInt(screen_w)));

        // Generate Slots (OpenGL Coordinates)
        var slots = try self.allocator.alloc(f32, char_count + 1);
        defer self.allocator.free(slots);
        for (slots, 0..) |*slot, i| {
            slot.* = (@as(f32, @floatFromInt(char_w * i)) / (@as(f32, @floatFromInt(screen_w)) / 2.0)) - 1.0;
        }

        // Initialize segments (Simplified for brevity, following your C++ pattern)
        // In Zig, we'd likely pass a slice of slots to each segment
        self.free_memory = Segment.init(segment.FREE_MEM_CONFIG, slots, y_pos);
        self.drawSegment(u16, &self.free_memory, &[_]u16{ 0xE002, 0xE003 }); // Icon glyphs
        
        // ... Repeat for other segments ...
    }

    /// Generic draw function (Handles both UTF-8 strings and UTF-16)
    pub fn drawSegment(self: *StatusMonitor, comptime T: type, seg: anytype, input: []const T) void {
        if (input.len == 0) return;

        const limit = @min(seg.getMaxCharacters() - seg.getOffset(), input.len);
        
        // Pre-allocate buffers for GL data
        var characters = std.ArrayList(f32).init(self.allocator);
        var slots = std.ArrayList(f32).init(self.allocator);
        defer { characters.deinit(); slots.deinit(); }

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

    fn cycle(self: *StatusMonitor) !void {
        // Draw Time
        self.drawSegment(u8, &self.time, format.getDate());

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

        // Zig Concurrency: Instead of std::async (which is heavy), 
        // we use a Thread Pool or simply sequential updates if latency is low.
        // For a status bar, sequential is often safer and easier to debug.
        self.free_memory.newTick(tick_idx, format.getFreeMemory());
        self.cpu_usage.newTick(tick_idx, format.getCpuUsage());
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
