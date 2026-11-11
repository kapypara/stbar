const std = @import("std");
const builtin = @import("builtin");
const Window = @import("Window.zig").Window;
const status_zig = @import("StatusMonitor.zig");
const StatusMonitor = status_zig.StatusMonitor;
const BarMode = status_zig.BarMode;

/// Startup bar mode flag:
/// - `.auto_hide`: overlay (`strut = OFF`), 1px top hover sensor (>1s reveal with fade-in, 1 Hz hidden polling)
/// - `.pinned_overlay`: overlay (`strut = OFF`), always visible
/// - `.docked_strut`: reserved 17px top dock (`strut = ON`), always visible
const initial_mode: BarMode = .auto_hide;

/// Active metric sample frequency while visible (`8 Hz`; automatically slows to `1 Hz` while hidden).
const visible_sample_hz: u8 = 8;

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
        .strut_enabled = (initial_mode == .docked_strut),
        .input_height = if (initial_mode == .auto_hide) 1 else 14 + 3,
    };

    // width = 0 auto-detects the active X11 screen width; height = 14 + 3 = 17px
    try window.init(0, 0, 0, 14 + 3);
    defer window.deinit();

    var monitor: StatusMonitor = .{ .window = &window };
    try monitor.init(io, gpa, visible_sample_hz, initial_mode);
    defer monitor.deinit();

    while (window.running) {
        try monitor.step();
    }
}

test {
    _ = @import("formats.zig");
    _ = @import("Segment.zig");
    _ = @import("FontAtlas.zig");
    _ = @import("metrics.zig");
}
