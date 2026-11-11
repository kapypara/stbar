const std = @import("std");
const Window = @import("Window.zig").Window;
const Ticker = @import("Ticker.zig").Ticker;
const StatusMonitor = @import("StatusMonitor.zig").StatusMonitor;

pub fn main(init: std.process.Init) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.debug.print("MEMORY LEAK DETECTED!\n", .{});
        }
    }

    const io = init.io;

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
        window.updateViewport();
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
