const std = @import("std");
const Segment= @import("Segment.zig").Segment;
const RectDraw = @import("RectDraw.zig").RectDraw;
const FontAtlas = @import("FontAtlas.zig").FontAtlas;
const Window = @import("Window.zig").Window;

pub const StatusMonitor = struct {
    allocator: std.mem.Allocator = undefined,
    rect: RectDraw = undefined,
    font: FontAtlas = undefined,
    window: Window = undefined,

    // Timing
    ticks: usize = 0,
    update_smoothing: u8 = 0,

    // Segments
    // time: Segment = .{ .metric_type = .time },
    free_memory: Segment = .{ .metric_type = .memory },
    cpu_usage: Segment = .{ .metric_type = .cpu },
    temperature: Segment = .{ .metric_type = .temp },
    system_load: Segment = .{ .metric_type = .load },
    // free_space: Segment = .{ .metric_type = . },
    // dirty_memory: Segment = .{ .metric_type = . },
    io: Segment = .{ .metric_type = .io },
    net_tx: Segment = .{ .metric_type = .net },
    window_title: Segment = .{ .metric_type = .window },

    // State
    window_title_buf: std.ArrayList(u16) = undefined,
    window_fetch_time: i64 = 0,
    window_name_rotation: u64 = 0,

    pub fn deinit(self: *StatusMonitor) void {
        self.window_title_buf.deinit(self.allocator);
        self.rect.deinit();
        self.font.deinit();
    }

    pub fn init(self: *StatusMonitor, allocator: std.mem.Allocator, tick: u8, update: u8) !void {

        // TODO validated Rect
        self.rect = RectDraw.init();
        self.font = try FontAtlas.loadFromJson(allocator, "assets/font/tamzen.json");

        self.ticks = tick;
        self.update_smoothing = update;

        self.allocator = allocator;
        self.window_title_buf = .empty;

        const screen_w = self.window.width;
        const char_w = self.font.char_width;

        const char_count = @divTrunc(screen_w, char_w);

        const sw: f32 = @floatFromInt(self.window.width);
        const cw: f32 = @floatFromInt(self.font.char_width);
        const y_pos: f32 = 0.9 - (cw / sw);

        // Generate Slots (OpenGL Coordinates)
        // var slots = try self.allocator.alloc(f32, char_count + 1);
        // defer self.allocator.free(slots);
        // for (slots, 0..) |*slot, i| {
        //     slot.* = (@as(f32, @floatFromInt(char_w * i)) / (@as(f32, @floatFromInt(screen_w)) / 2.0)) - 1.0;
        // }

        _ = y_pos;
        _ = char_count;
        // Initialize segments (Simplified for brevity, following your C++ pattern)
        // In Zig, we'd likely pass a slice of slots to each segment
        // self.free_memory = Segment.init(segment.FREE_MEM_CONFIG, slots, y_pos);
        // self.drawSegment(u16, &self.free_memory, &[_]u16{ 0xE002, 0xE003 }); // Icon glyphs
        
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
