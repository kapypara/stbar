const std = @import("std");
const builtin = @import("builtin");
const Window = @import("Window.zig").Window;
const Ticker = @import("Ticker.zig").Ticker;
const StatusMonitor = @import("StatusMonitor.zig").StatusMonitor;

const use_debug_gpa = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

pub fn main(_: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (use_debug_gpa) {
        if (debug_allocator.deinit() == .leak) {
            std.debug.print("MEMORY LEAK DETECTED!\n", .{});
        }
    };
    const gpa = if (use_debug_gpa) debug_allocator.allocator() else std.heap.c_allocator;

    var single_threaded_io: std.Io.Threaded = .init_single_threaded;
    const io = single_threaded_io.io();

    var window = Window{
        .docked = true,
    };

    // width = 0 auto-detects the active X11 screen width; height = 14 + 3 = 17px
    try window.init(0, 0, 0, 14 + 3);
    defer window.deinit();

    const tr = 8;
    const rr = 60;

    var ticker = Ticker.init(io, rr, tr);

    var monitor: StatusMonitor = .{ .window = &window };
    try monitor.init(io, gpa, tr, rr);
    defer monitor.deinit();

    while (window.running) {
        window.updateTheMessageQueue();
        try monitor.update();
        try monitor.render();
        ticker.tick();
    }
}

test {
    _ = @import("formats.zig");
    _ = @import("Segment.zig");
    _ = @import("FontAtlas.zig");
    _ = @import("metrics.zig");
}
