//! Declarative compile-time configuration for `zigbar`.
//!
//! Customize startup defaults, bar geometry, animation timings, RGBA32 segment colors,
//! PUA icon pairs, fixed cell widths, and left-click commands here, then run `zig build`.
//! All values live in `.rodata` with zero runtime parsing or heap allocation overhead.

const std = @import("std");
const types = @import("Types.zig");
const actions = @import("Actions.zig");

pub const BarMode = types.BarMode;
pub const BarPosition = types.BarPosition;
pub const MarqueeMode = types.MarqueeMode;
pub const BackendPreference = types.BackendPreference;
pub const ClickAction = actions.ClickAction;

pub const SegmentSpec = struct {
    /// Segment background tint in `0xRRGGBBAA` format (glyphs render in crisp white over the tint).
    color: u32,
    /// Static glyph template drawn once per layout (`\n` skips dynamic metric value cells).
    static_overlay: []const u8 = "",
    /// Starting cell offset within the segment for `static_overlay`.
    static_offset: u8 = 0,
    /// Action executed on left-click (`Button1`) inside this segment.
    on_click: ClickAction = .none,
};

pub const OverlaySpec = struct {
    offset: u8,
    overlay: []const u8,
};

// ============================================================================
// 1. Startup CLI Defaults (overridable at launch via `--mode`, `--position`, etc.)
// ============================================================================

/// Default display server backend (`--backend=auto|wayland|wayland-egl|x11|x11-glx`).
pub const default_backend_mode: BackendPreference = .auto;

/// Default startup bar mode (`--mode=auto-hide|pinned|dock`).
pub const default_initial_mode: BarMode = .auto_hide;

/// Default screen edge anchor (`-p, --position=top|bottom`).
pub const default_bar_position: BarPosition = .top;

/// Default overflowing window-title scroll style (`--marquee=smooth|snap`).
pub const default_marquee_mode: MarqueeMode = .smooth;

/// Default metric sample frequency while visible (`--hz=1..60`; 0 Hz while hidden).
pub const default_visible_sample_hz: u8 = 8;

// ============================================================================
// 2. Bar Geometry & Animation Timings
// ============================================================================

/// Logical pixel height of the bar (`14px` Tamzen glyph height + `3px` vertical padding).
pub const bar_height_px: i32 = 17;

/// Vertical glyph alignment factor inside `bar_height_px` (`0.52` centers Tamzen `7x14` inside `17px`).
pub const glyph_vertical_align: f32 = 0.52;

/// Continuous `1px` edge hover duration required before revealing in `auto-hide` mode.
pub const hover_reveal_ns: i96 = 1 * std.time.ns_per_s;

/// Brief pointer-exit grace period before fading out in `auto-hide` mode.
pub const leave_grace_ns: i96 = 120 * std.time.ns_per_ms;

/// Cubic ease-out reveal duration.
pub const fade_in_ns: i96 = 250 * std.time.ns_per_ms;

/// Smoothstep hide duration.
pub const fade_out_ns: i96 = 180 * std.time.ns_per_ms;

/// Pause before scrolling a newly focused overflowing window title.
pub const marquee_initial_pause_ns: i96 = 1 * std.time.ns_per_s;

/// Rest duration at the start of the title after completing `marquee_loops_before_rest` cycles.
pub const marquee_rest_pause_ns: i96 = 60 * std.time.ns_per_s;

/// Number of full marquee rotations before resting.
pub const marquee_loops_before_rest: usize = 2;

/// Atlas glyph codepoint placed between wrapped marquee title loops (`0x02` bullet in Tamzen).
pub const marquee_separator_codepoint: u32 = 0x02;

/// Character step interval in `--marquee=snap` mode (`125ms` = `8 chars/s`).
pub const marquee_snap_step_ns: i96 = 125 * std.time.ns_per_ms;

/// Per-logical-pixel scroll interval in `--marquee=smooth` mode (`16.67ms` = `1 px` per `60Hz` VSync).
pub const marquee_smooth_px_ns: i96 = 16_666_667;

// ============================================================================
// 3. Embedded Tamzen PUA Icon Pairs (each icon spans two 7x14 cells = 14x14 px)
// ============================================================================

pub const icons = struct {
    pub const cpu = "\u{e000}\u{e001}";
    pub const ram = "\u{e002}\u{e003}";
    pub const temp = "\u{e004}\u{e005}";
    pub const load = "\u{e006}\u{e007}";
    pub const net_rx = "\u{e008}\u{e009}";
    pub const net_tx = "\u{e00a}\u{e00b}";
    pub const mem_dirty = "\u{e00c}\u{e00d}";
    pub const disk_write = "\u{e00e}\u{e00f}";
    pub const disk_read = "\u{e010}\u{e011}";
    pub const storage = "\u{e012}\u{e013}";
    pub const battery = "\u{e022}\u{e023}";
    pub const power_bolt = "\u{e024}\u{e025}";
};

// ============================================================================
// 4. RGBA32 Segment Color Palette (`0xRRGGBBAA`)
// ============================================================================

pub const colors = struct {
    pub const time: u32 = 0x595959CC;
    pub const power: u32 = 0x3C6E84CC;
    pub const processor: u32 = 0x844242CC;
    pub const thermal: u32 = 0x84783CCC;
    pub const storage: u32 = 0x763C84CC;
    pub const network: u32 = 0x43843CCC;
    pub const window_title: u32 = 0x00000077;
};

// ============================================================================
// 5. Fixed Segment Cell Widths (right-aligned right-to-left; window title gets the rest)
// ============================================================================

pub const widths = struct {
    pub const time: usize = 23;
    pub const power_battery_only: usize = 7;
    pub const power_desktop: usize = 9;
    pub const power_battery: usize = 16;
    pub const processor: usize = 15;
    pub const thermal: usize = 13;
    pub const storage: usize = 40;
    pub const network: usize = 19;

    pub const base_fixed_cells: usize = time + processor + thermal + storage + network;
};

// ============================================================================
// 6. Segment Appearance, Static Overlays & Left-Click Actions
// ============================================================================

pub const segments = struct {
    pub const time: SegmentSpec = .{
        .color = colors.time,
        .on_click = .copy_unix_timestamp,
    };

    pub const power: SegmentSpec = .{
        .color = colors.power,
        .on_click = .copy_power_summary,
    };

    pub const processor: SegmentSpec = .{
        .color = colors.processor,
        .static_overlay = "\n\n\n" ++ icons.cpu ++ "\n\n\n,\n\n\n" ++ icons.ram,
        .static_offset = 0,
        .on_click = .{ .spawn_if_installed = .{
            .bin = "btop",
            .argv = &.{ "konsole", "-e", "btop" },
            .fallback = &.{ "konsole", "-e", "htop" },
        } },
    };

    pub const thermal: SegmentSpec = .{
        .color = colors.thermal,
        .static_overlay = "\n\n.\n\n" ++ icons.load ++ "\n\n\n" ++ icons.temp,
        .static_offset = 0,
        .on_click = .{ .spawn = &.{"screenfix"} },
    };

    pub const storage: SegmentSpec = .{
        .color = colors.storage,
        .static_overlay = "\n\n\n.\n\n" ++ icons.disk_read ++
            "\n\n\n\n.\n\n" ++ icons.disk_write ++
            "\n\n\n\n.\n\n" ++ icons.mem_dirty ++
            "\n\n\n\n\n.\n\n\nG" ++ icons.storage,
        .static_offset = 1,
        .on_click = .{ .spawn = &.{"dolphin"} },
    };

    pub const network: SegmentSpec = .{
        .color = colors.network,
        .static_overlay = "\n\n\n.\n\n" ++ icons.net_rx ++ "\n\n\n\n.\n\n" ++ icons.net_tx,
        .static_offset = 1,
        .on_click = .{ .spawn = &.{"usb-restart"} },
    };

    pub const window_title: SegmentSpec = .{
        .color = colors.window_title,
        .on_click = .copy_window_title,
    };
};

/// Dynamic static overlays selected automatically for `segments.power` based on host battery/hwmon sensors.
pub const power_overlays = struct {
    pub const battery_only: OverlaySpec = .{
        .offset = 3,
        .overlay = "%" ++ icons.battery,
    };
    pub const desktop_watts: OverlaySpec = .{
        .offset = 6,
        .overlay = icons.power_bolt,
    };
    pub const battery_and_watts: OverlaySpec = .{
        .offset = 3,
        .overlay = "%" ++ icons.battery ++ "\n\n\n\n\n\n\n" ++ icons.power_bolt,
    };
};

test "config static overlays and fixed cell widths match exact layout invariants" {
    try std.testing.expectEqual(@as(usize, 110), widths.base_fixed_cells);
    try std.testing.expectEqualStrings(
        "\n\n\n\u{e000}\u{e001}\n\n\n,\n\n\n\u{e002}\u{e003}",
        segments.processor.static_overlay,
    );
    try std.testing.expectEqualStrings(
        "\n\n.\n\n\u{e006}\u{e007}\n\n\n\u{e004}\u{e005}",
        segments.thermal.static_overlay,
    );
    try std.testing.expectEqualStrings(
        "\n\n\n.\n\n\u{e010}\u{e011}\n\n\n\n.\n\n\u{e00e}\u{e00f}\n\n\n\n.\n\n\u{e00c}\u{e00d}\n\n\n\n\n.\n\n\nG\u{e012}\u{e013}",
        segments.storage.static_overlay,
    );
    try std.testing.expectEqualStrings(
        "\n\n\n.\n\n\u{e008}\u{e009}\n\n\n\n.\n\n\u{e00a}\u{e00b}",
        segments.network.static_overlay,
    );
    try std.testing.expectEqualStrings(
        "%\u{e022}\u{e023}\n\n\n\n\n\n\n\u{e024}\u{e025}",
        power_overlays.battery_and_watts.overlay,
    );
}
