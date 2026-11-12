const std = @import("std");
const c = @import("c");
const window_zig = @import("Window.zig");
const Window = window_zig.Window;
const BackendPreference = window_zig.BackendPreference;
const status_zig = @import("StatusMonitor.zig");
const StatusMonitor = status_zig.StatusMonitor;
const BarMode = status_zig.BarMode;

/// Default display server backend (`--backend=auto|wayland|wayland-egl|x11`):
/// - `.auto`: native Wayland `zwlr_layer_shell_v1` + `wl_shm` when `WAYLAND_DISPLAY` is set, else X11/GLX
const default_backend_mode: BackendPreference = .auto;

/// Default startup bar mode (`--mode=auto-hide|pinned|dock`):
/// - `.auto_hide`: overlay (`strut = OFF`), 1px top hover sensor (>1s reveal, 0 Hz sleep while hidden)
/// - `.pinned_overlay`: overlay (`strut = OFF`), always visible
/// - `.docked_strut`: reserved 17px top dock (`strut = ON`), always visible
const default_initial_mode: BarMode = .auto_hide;

/// Default metric sample frequency while visible (`--hz=1..60`; 0 Hz while hidden).
const default_visible_sample_hz: u8 = 8;

var stop_requested: std.atomic.Value(bool) = .init(false);

fn onSignal(_: c_int) callconv(.c) void {
    stop_requested.store(true, .release);
}

const CliConfig = struct {
    mode: BarMode = default_initial_mode,
    backend: BackendPreference = default_backend_mode,
    sample_hz: u8 = default_visible_sample_hz,
    exit_early: bool = false,
};

const usage_text =
    \\Usage: zigbar [options]
    \\
    \\Options:
    \\  -m, --mode=<auto-hide|pinned|dock>             Startup bar mode (default: auto-hide)
    \\  -b, --backend=<auto|wayland|wayland-egl|x11>   Display backend (default: auto)
    \\      --hz=<1..60>                               Metric sample rate while visible (default: 8)
    \\  -h, --help                                     Show this help message and exit
    \\
    \\Mouse Controls:
    \\  Hover top 1px (>1s)                            Reveal bar in auto-hide mode
    \\  Left-click segment                             Run segment action (copy time/power/title, open btop/dolphin)
    \\  Right-click                                    Toggle pinned overlay (strut OFF) <-> auto-hide
    \\  Middle-click                                   Toggle 17px docked strut (strut ON) <-> auto-hide
    \\
;

fn parseModeValue(val: []const u8) ?BarMode {
    if (std.mem.eql(u8, val, "auto-hide") or std.mem.eql(u8, val, "autohide") or std.mem.eql(u8, val, "auto_hide")) {
        return .auto_hide;
    }
    if (std.mem.eql(u8, val, "pinned") or std.mem.eql(u8, val, "pinned-overlay") or std.mem.eql(u8, val, "overlay")) {
        return .pinned_overlay;
    }
    if (std.mem.eql(u8, val, "dock") or std.mem.eql(u8, val, "docked") or std.mem.eql(u8, val, "strut")) {
        return .docked_strut;
    }
    return null;
}

fn parseBackendValue(val: []const u8) ?BackendPreference {
    if (std.mem.eql(u8, val, "auto")) return .auto;
    if (std.mem.eql(u8, val, "wayland") or std.mem.eql(u8, val, "wl") or std.mem.eql(u8, val, "shm") or std.mem.eql(u8, val, "wayland-shm")) return .wayland;
    if (std.mem.eql(u8, val, "wayland-egl") or std.mem.eql(u8, val, "wl-egl") or std.mem.eql(u8, val, "egl")) return .wayland_egl;
    if (std.mem.eql(u8, val, "x11") or std.mem.eql(u8, val, "xorg") or std.mem.eql(u8, val, "glx")) return .x11;
    return null;
}

fn writeFd(fd: c_int, msg: []const u8) void {
    _ = c.write(fd, msg.ptr, msg.len);
}

fn parseCli(args: std.process.Args) !CliConfig {
    var cfg: CliConfig = .{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // program name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeFd(1, usage_text);
            cfg.exit_early = true;
            return cfg;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            cfg.mode = parseModeValue(arg["--mode=".len..]) orelse {
                writeFd(2, "zigbar: invalid --mode (expected auto-hide, pinned, or dock)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mode")) {
            const val = it.next() orelse {
                writeFd(2, "zigbar: missing value for --mode\n");
                return error.InvalidArgument;
            };
            cfg.mode = parseModeValue(val) orelse {
                writeFd(2, "zigbar: invalid --mode (expected auto-hide, pinned, or dock)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            cfg.backend = parseBackendValue(arg["--backend=".len..]) orelse {
                writeFd(2, "zigbar: invalid --backend (expected auto, wayland, wayland-egl, or x11)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backend")) {
            const val = it.next() orelse {
                writeFd(2, "zigbar: missing value for --backend\n");
                return error.InvalidArgument;
            };
            cfg.backend = parseBackendValue(val) orelse {
                writeFd(2, "zigbar: invalid --backend (expected auto, wayland, wayland-egl, or x11)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--hz=")) {
            const hz = std.fmt.parseInt(u8, arg["--hz=".len..], 10) catch 0;
            if (hz < 1 or hz > StatusMonitor.max_sample_hz) {
                writeFd(2, "zigbar: invalid --hz (expected 1..60)\n");
                return error.InvalidArgument;
            }
            cfg.sample_hz = hz;
        } else {
            writeFd(2, "zigbar: unrecognized option (try --help)\n");
            return error.InvalidArgument;
        }
    }
    return cfg;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const cli = try parseCli(init.args);
    if (cli.exit_early) return;

    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = onSignal;
    _ = c.sigaction(c.SIGINT, &sa, null);
    _ = c.sigaction(c.SIGTERM, &sa, null);

    // Automatically reap detached child apps spawned via left-click (`btop`, `dolphin`, etc.)
    var sa_chld: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa_chld.sa_flags = c.SA_NOCLDWAIT | c.SA_NOCLDSTOP;
    _ = c.sigaction(c.SIGCHLD, &sa_chld, null);

    var single_threaded_io: std.Io.Threaded = .init_single_threaded;
    const io = single_threaded_io.io();

    var window = Window{
        .backend_preference = cli.backend,
        .docked = true,
        .strut_enabled = (cli.mode == .docked_strut),
        .input_height = if (cli.mode == .auto_hide) 1 else 14 + 3,
    };

    // width = 0 auto-detects the active output width; height = 14 + 3 = 17px
    try window.init(0, 0, 0, 14 + 3);
    defer window.deinit();

    var monitor: StatusMonitor = .{ .window = &window };
    try monitor.init(io, cli.sample_hz, cli.mode);
    defer monitor.deinit();

    while (window.running and !stop_requested.load(.acquire)) {
        try monitor.step();
    }
}

test {
    _ = @import("formats.zig");
    _ = @import("Actions.zig");
    _ = @import("Segment.zig");
    _ = @import("FontAtlas.zig");
    _ = @import("ShmDraw.zig");
    _ = @import("metrics.zig");
}
