const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const window_zig = @import("Window.zig");
const Window = window_zig.Window;
const BackendPreference = window_zig.BackendPreference;
const status_zig = @import("StatusMonitor.zig");
const StatusMonitor = status_zig.StatusMonitor;
const BarMode = status_zig.BarMode;

/// Display server backend preference:
/// - `.auto`: native Wayland `zwlr_layer_shell_v1` + `EGL` when `WAYLAND_DISPLAY` is set, else X11/GLX
/// - `.wayland`: require native Wayland layer-shell
/// - `.x11`: force X11 / Xwayland + GLX
const backend_mode: BackendPreference = .auto;

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

var stop_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(_: c_int) callconv(.c) void {
    stop_requested.store(true, .release);
}

pub fn main(_: std.process.Init.Minimal) !void {
    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = onSignal;
    _ = c.sigaction(c.SIGINT, &sa, null);
    _ = c.sigaction(c.SIGTERM, &sa, null);
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
        .backend_preference = backend_mode,
        .docked = true,
        .strut_enabled = (initial_mode == .docked_strut),
        .input_height = if (initial_mode == .auto_hide) 1 else 14 + 3,
    };

    // width = 0 auto-detects the active output width; height = 14 + 3 = 17px
    try window.init(0, 0, 0, 14 + 3);
    defer window.deinit();

    var monitor: StatusMonitor = .{ .window = &window };
    try monitor.init(io, gpa, visible_sample_hz, initial_mode);
    defer monitor.deinit();

    while (window.running and !stop_requested.load(.acquire)) {
        try monitor.step();
    }
}

test {
    _ = @import("formats.zig");
    _ = @import("Segment.zig");
    _ = @import("FontAtlas.zig");
    _ = @import("metrics.zig");
}
