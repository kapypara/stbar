const std = @import("std");

const font_zig = @import("FontAtlas.zig");
const FontAtlas = font_zig.FontAtlas;
const RectDraw = @import("RectDraw.zig").RectDraw;
const ShmDraw = @import("ShmDraw.zig");
const actions_zig = @import("Actions.zig");
const PowerFlow = @import("formats.zig").PowerFlow;
const segment_zig = @import("Segment.zig");
const Window = @import("Window.zig").Window;
const ticker_zig = @import("Ticker.zig");

const assert = std.debug.assert;
const Segment = segment_zig.Segment;
const MetricEntry = segment_zig.MetricEntry;
const monotonicNs = ticker_zig.monotonicNs;
const sleepNs = ticker_zig.sleepNs;

pub const BarMode = enum {
    /// Overlay (`strut = OFF`): hides to top 1px strip (zero background polling; sleeps indefinitely in `poll(-1)`)
    /// and fades in after >1s continuous hover.
    auto_hide,
    /// Overlay (`strut = OFF`): stays visible without auto-hiding (toggled via right-click).
    pinned_overlay,
    /// Dock (`strut = ON`): reserves 17px top exclusive zone / strut and stays visible (toggled via middle-click).
    docked_strut,
};

pub const StatusMonitor = struct {
    pub const max_sample_hz = 60;
    pub const max_cells = ShmDraw.max_cells;
    pub const max_segments = 8;
    pub const max_numeric_metrics = 10;

    pub const time_width = 23;
    pub const power_battery_only_width = 7;
    pub const power_desktop_width = 9;
    pub const power_battery_width = 16;
    pub const processor_width = 15;
    pub const thermal_width = 13;
    pub const storage_width = 40;
    pub const network_width = 19;
    pub const base_fixed_cells = time_width + processor_width + thermal_width + storage_width + network_width; // 110

    const PowerLayoutMode = enum {
        hidden,
        battery_only,
        desktop_watts,
        battery_and_watts,
    };

    const hover_reveal_ns: i96 = 1 * std.time.ns_per_s; // >1.0s continuous top-1px hover
    const leave_grace_ns: i96 = 120 * std.time.ns_per_ms; // brief anti-twitch grace on exit
    const fade_in_ns: i96 = 250 * std.time.ns_per_ms; // smooth cubic ease-out reveal
    const fade_out_ns: i96 = 180 * std.time.ns_per_ms; // smooth fade-out on hide
    const marquee_step_ns: i96 = 125 * std.time.ns_per_ms;

    const VisibilityState = enum {
        hidden,
        hover_armed,
        fading_in,
        visible,
        leave_grace,
        fading_out,
    };

    io: std.Io = undefined,

    rect: RectDraw = .{},
    font: FontAtlas = undefined,
    window: *Window,

    // Mode, visibility & monotonic deadlines (framerate-free)
    mode: BarMode = .auto_hide,
    state: VisibilityState = .hidden,
    visible_sample_ns: i96 = std.time.ns_per_s / 8,
    sample_start_ns: i96 = 0,
    next_sample_ns: i96 = 0,
    sample_count: usize = 0,
    consecutive_unpaced_swaps: u8 = 0,

    hover_start_ns: i96 = 0,
    leave_start_ns: i96 = 0,
    fade_start_ns: i96 = 0,
    fade_duration_ns: i96 = fade_in_ns,
    fade_from: f32 = 0.0,
    opacity: f32 = 1.0,
    frame_dirty: bool = true,

    // Rect Compute
    rect_height: f32 = 0, // height of glyph rect in NDC
    rect_width_i: i16 = 0, // fixed point (-32768 -> 32767)
    rect_width_f: f32 = 0, // NDC (-1 -> 1)
    rect_y_pos: i16 = 0, // y pos for glyph rect in fixed-point NDC

    // Inline zero-allocator buffers (`self` lives at a stable stack address in `main`)
    cells_storage: [max_cells]i16 = @splat(0),
    quad_storage: [max_segments + max_cells]RectDraw.QuadVertex = undefined,
    sample_storage: [max_sample_hz * max_numeric_metrics]u128 = @splat(0),

    cells: []i16 = &.{},
    quad_buffer: []RectDraw.QuadVertex = &.{},
    sample_buffer: []u128 = &.{},

    // Metric storage owned per StatusMonitor instance
    time_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .time = .{} }, .mode = .message, .start_index = 1 },
    },
    power_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .power = .{} }, .mode = .average, .start_index = 7 },
        .{ .metric = .{ .battery = .{} }, .mode = .average, .start_index = 0 },
    },
    processor_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .cpu = .{} }, .mode = .average, .start_index = 0 },
        .{ .metric = .{ .memory = .{} }, .mode = .average, .start_index = 6, .secondary_index = 19 },
    },
    thermal_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .temp = .{} }, .mode = .average, .start_index = 8 },
        .{ .metric = .{ .load = .{} }, .mode = .average, .start_index = 0 },
    },
    storage_metrics: [2]MetricEntry = .{
        .{ .metric = .{ .free_storage = .{} }, .mode = .average, .start_index = 28 },
        .{ .metric = .{ .io = .{} }, .mode = .rate_of_change, .start_index = 1, .secondary_index = 10 },
    },
    network_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .net = .{} }, .mode = .rate_of_change, .start_index = 1, .secondary_index = 10 },
    },
    window_metrics: [1]MetricEntry = .{
        .{ .metric = .{ .window = .{} }, .mode = .message, .start_index = 1 },
    },

    time_segment: Segment = .{
        .color = 0x595959CC,
        .on_click = .copy_unix_timestamp,
    },
    power_segment: Segment = .{
        .color = 0x3C6E84CC,
        .on_click = .copy_power_summary,
    },
    processor_segment: Segment = .{
        .color = 0x844242CC,
        .static_overlay = "\n\n\n\u{e000}\u{e001}\n\n\n,\n\n\n\u{e002}\u{e003}",
        .static_offset = 0,
        .on_click = .{ .spawn_if_installed = .{
            .bin = "btop",
            .argv = &.{ "konsole", "-e", "btop" },
            .fallback = &.{ "konsole", "-e", "htop" },
        } },
    },
    thermal_load_segment: Segment = .{
        .color = 0x84783CCC,
        .static_overlay = "\n\n.\n\n\u{e006}\u{e007}\n\n\n\u{e004}\u{e005}",
        .static_offset = 0,
        .on_click = .{ .spawn = &.{"screenfix"} },
    },
    storage_load_segment: Segment = .{
        .color = 0x763C84CC,
        .static_overlay = "\n\n\n.\n\n\u{e010}\u{e011}\n\n\n\n.\n\n\u{e00e}\u{e00f}\n\n\n\n.\n\n\u{e00c}\u{e00d}\n\n\n\n\n.\n\n\nG\u{e012}\u{e013}",
        .static_offset = 1,
        .on_click = .{ .spawn = &.{"dolphin"} },
    },
    network_load_segment: Segment = .{
        .color = 0x43843CCC,
        .static_overlay = "\n\n\n.\n\n\u{e008}\u{e009}\n\n\n\n.\n\n\u{e00a}\u{e00b}",
        .static_offset = 1,
        .on_click = .{ .spawn = &.{"usb-restart"} },
    },
    window_title_segment: Segment = .{
        .color = 0x00000077,
        .on_click = .copy_window_title,
    },

    segments: [7]*Segment = undefined,
    power_layout_mode: PowerLayoutMode = .hidden,
    last_power_flow: PowerFlow = .maintaining,

    // Active window marquee state (monotonic time-driven)
    title_codepoints: [260]u32 = @splat(0),
    title_len: usize = 0,
    marquee_next_ns: i96 = 0,
    title_rotations: usize = 0,

    pub fn deinit(self: *StatusMonitor) void {
        for (&self.segments) |seg| {
            for (seg.metrics) |*entry| {
                entry.metric.deinit(self.io);
            }
        }
        self.rect.deinit();
        self.font.deinit();
    }

    /// Note: `self` must reside at a stable memory address before calling `init` because segments,
    /// metric ring slices, and cell/quad views point directly into `self`'s inline storage.
    pub fn init(
        self: *StatusMonitor,
        io: std.Io,
        sample_hz: u8,
        initial_mode: BarMode,
    ) !void {
        assert(sample_hz >= 1 and sample_hz <= max_sample_hz);

        self.io = io;
        self.mode = initial_mode;
        self.visible_sample_ns = @divTrunc(std.time.ns_per_s, @as(i96, sample_hz));

        self.font = FontAtlas.initEmbedded();
        errdefer self.font.deinit();

        if (!self.window.usesShm()) {
            self.rect = try RectDraw.init(self.window.getProcLoader());
            errdefer self.rect.deinit();

            var embedded_rgba: [@as(usize, font_zig.embedded.width) * @as(usize, font_zig.embedded.height) * 4]u8 = undefined;
            font_zig.embedded.unpackRgba(&embedded_rgba);

            self.rect.use();
            try self.rect.loadTexture(font_zig.embedded.width, font_zig.embedded.height, &embedded_rgba);
            self.rect.setTextureSize(self.font.x_increment, self.font.y_increment);
        }

        // Bind metric slices to segments (`power_segment` slice is configured dynamically by battery presence)
        self.time_segment.metrics = &self.time_metrics;
        self.processor_segment.metrics = &self.processor_metrics;
        self.thermal_load_segment.metrics = &self.thermal_metrics;
        self.storage_load_segment.metrics = &self.storage_metrics;
        self.network_load_segment.metrics = &self.network_metrics;
        self.window_title_segment.metrics = &self.window_metrics;

        // BatteryView reads `capacity_pct` directly from `PowerProbe` with zero extra syscalls
        self.power_metrics[1].metric.battery.source = &self.power_metrics[0].metric.power;

        // Dirty memory is sampled alongside free memory in MemProbe, rendered in storage_load_segment
        self.processor_metrics[1].secondary_segment = &self.storage_load_segment;

        // Wire active-window title source (native Wayland toplevel protocol or event-driven X11 atoms)
        if (self.window.waylandTitle()) |wl_title| {
            self.window_metrics[0].metric.window.setExternalTitle(wl_title);
        } else {
            self.window_metrics[0].metric.window.attach(
                self.window.display,
                self.window.root,
                self.window.handle,
                self.window.net_active_window_atom,
                self.window.net_wm_name_atom,
                self.window.wm_name_atom,
            );
        }
        self.window.title_dirty = false;

        self.segments = .{
            &self.time_segment,
            &self.processor_segment,
            &self.thermal_load_segment,
            &self.storage_load_segment,
            &self.network_load_segment,
            &self.power_segment,
            &self.window_title_segment,
        };

        // Bind inline rolling sample ring buffer for the 9 numeric MetricEntries
        const numeric_metric_count = 9;
        assert(numeric_metric_count <= max_numeric_metrics);
        const ring_len: usize = sample_hz;
        self.sample_buffer = self.sample_storage[0 .. ring_len * numeric_metric_count];
        @memset(self.sample_buffer, 0);

        setSlots(&self.processor_metrics[0], self.sample_buffer, ring_len, 0);
        setSlots(&self.processor_metrics[1], self.sample_buffer, ring_len, 1);
        setSlots(&self.thermal_metrics[0], self.sample_buffer, ring_len, 2);
        setSlots(&self.thermal_metrics[1], self.sample_buffer, ring_len, 3);
        setSlots(&self.storage_metrics[0], self.sample_buffer, ring_len, 4);
        setSlots(&self.storage_metrics[1], self.sample_buffer, ring_len, 5);
        setSlots(&self.network_metrics[0], self.sample_buffer, ring_len, 6);
        setSlots(&self.power_metrics[0], self.sample_buffer, ring_len, 7);
        setSlots(&self.power_metrics[1], self.sample_buffer, ring_len, 8);

        // Discover battery/hwmon topology up front so initial layout chooses the exact compact width
        self.power_metrics[0].metric.power.sample(io) catch {};
        self.power_metrics[1].metric.battery.sample() catch {};

        self.recomputeLayout();

        const now_ns = monotonicNs(io);
        self.seedInitialMetrics(now_ns);
        if (self.currentPowerLayoutMode() != self.power_layout_mode) {
            self.recomputeLayout();
        }
        self.window.setStrut(initial_mode == .docked_strut);
        if (initial_mode == .auto_hide) {
            self.window.setInputHeight(1);
            self.window.clearTransparent();
            self.opacity = 0.0;
            self.frame_dirty = false;
            if (self.window.pointer_inside) {
                self.state = .hover_armed;
                self.hover_start_ns = now_ns;
            } else {
                self.state = .hidden;
            }
        } else {
            self.window.setInputHeight(self.window.height);
            self.opacity = 1.0;
            self.state = .visible;
            self.frame_dirty = true;
        }
    }

    fn seedInitialMetrics(self: *StatusMonitor, now_ns: i96) void {
        for (self.segments) |seg| {
            for (seg.metrics) |*entry| {
                entry.metric.sample(self.io) catch {};
                if (entry.metric == .window or entry.metric == .time) continue;
                const p1 = entry.metric.get(0);
                const p2 = if (entry.metric == .memory or entry.metric == .io or entry.metric == .net)
                    entry.metric.get(1)
                else
                    0;
                const packed_init = (@as(u128, p2) << 64) | @as(u128, p1);
                @memset(entry.sample, packed_init);
                entry.prev = packed_init;
                entry.target = packed_init;
            }
        }
        self.last_power_flow = self.power_metrics[0].metric.power.flow_state;
        self.sample_start_ns = now_ns;
        self.next_sample_ns = now_ns + self.visible_sample_ns;
    }

    fn currentPowerLayoutMode(self: *const StatusMonitor) PowerLayoutMode {
        const pwr = &self.power_metrics[0].metric.power;
        if (!pwr.has_battery) {
            return if (pwr.has_power_sensor) .desktop_watts else .hidden;
        }
        return if (pwr.has_power_sensor) .battery_and_watts else .battery_only;
    }

    fn configurePowerSegment(self: *StatusMonitor) usize {
        const mode = self.currentPowerLayoutMode();
        self.power_layout_mode = mode;

        switch (mode) {
            .hidden => {
                // Sensorless desktop/VM (0 cells)
                self.power_metrics[0].start_index = 0;
                self.power_metrics[0].secondary_index = null;
                self.power_segment.static_offset = 0;
                self.power_segment.static_overlay = "";
                self.power_segment.metrics = self.power_metrics[0..1];
                return 0;
            },
            .battery_only => {
                // Battery without power sensors: " 98%🔋 " (7 cells)
                self.power_metrics[0].start_index = power_battery_only_width;
                self.power_metrics[0].secondary_index = null;
                self.power_segment.static_offset = 3;
                self.power_segment.static_overlay = "%\u{e022}\u{e023}";
                self.power_segment.metrics = self.power_metrics[0..2];
                return power_battery_only_width;
            },
            .desktop_watts => {
                // Desktop with power sensors: " 14.2W⚡ " (9 cells)
                self.power_metrics[0].start_index = 1;
                self.power_metrics[0].secondary_index = null;
                self.power_segment.static_offset = 6;
                self.power_segment.static_overlay = "\u{e024}\u{e025}";
                self.power_segment.metrics = self.power_metrics[0..1];
                return power_desktop_width;
            },
            .battery_and_watts => {
                // Laptop fixed width: " 98%🔋 -14.2W⚡ " / " 64%🔋 +38.5W⚡ " / " 98%🔋  10.0W⚡ " (16 cells)
                self.power_metrics[0].start_index = 7;
                self.power_metrics[0].secondary_index = null;
                self.power_segment.static_offset = 3;
                self.power_segment.static_overlay = "%\u{e022}\u{e023}\n\n\n\n\n\n\n\u{e024}\u{e025}";
                self.power_segment.metrics = self.power_metrics[0..2];
                return power_battery_width;
            },
        }
    }

    fn setSlots(entry: *MetricEntry, buffer: []u128, ring_len: usize, position: usize) void {
        const start = ring_len * position;
        entry.sample = buffer[start .. start + ring_len];
    }

    fn rgbaBytes(rgba: u32) [4]u8 {
        return .{
            @truncate(rgba >> 24),
            @truncate(rgba >> 16),
            @truncate(rgba >> 8),
            @truncate(rgba),
        };
    }

    pub fn recomputeLayout(self: *StatusMonitor) void {
        self.window.updateViewport();
        const power_width = self.configurePowerSegment();

        const window_height = @as(f32, @floatFromInt(@max(1, self.window.height)));
        const char_height = @as(f32, @floatFromInt(self.font.char_height));
        self.rect_height = char_height / window_height * 2.0;

        const screen_width = @as(f32, @floatFromInt(@max(1, self.window.width)));
        const char_width = @as(f32, @floatFromInt(self.font.char_width));
        const raw_width_f = char_width / screen_width * 2.0;
        self.rect_width_i = @max(1, @as(i16, @intFromFloat(@ceil(raw_width_f * 32767.0))));
        self.rect_width_f = @as(f32, @floatFromInt(self.rect_width_i)) / 32767.0;

        // 0.52 vertically centers Tamzen inside the 17px bar
        self.rect_y_pos = @intFromFloat(self.rect_height * 32767.0 * 0.52);

        self.generateCells(base_fixed_cells + power_width);

        const cells_count = self.cells.len;
        const time_idx = cells_count -| time_width;
        const proc_idx = time_idx -| processor_width;
        const therm_idx = proc_idx -| thermal_width;
        const stor_idx = therm_idx -| storage_width;
        const net_idx = stor_idx -| network_width;
        const power_idx = net_idx -| power_width;

        self.time_segment.cell_start = time_idx;
        self.time_segment.cells = self.cells[time_idx..cells_count];

        self.processor_segment.cell_start = proc_idx;
        self.processor_segment.cells = self.cells[proc_idx..time_idx];

        self.thermal_load_segment.cell_start = therm_idx;
        self.thermal_load_segment.cells = self.cells[therm_idx..proc_idx];

        self.storage_load_segment.cell_start = stor_idx;
        self.storage_load_segment.cells = self.cells[stor_idx..therm_idx];

        self.network_load_segment.cell_start = net_idx;
        self.network_load_segment.cells = self.cells[net_idx..stor_idx];

        self.power_segment.cell_start = power_idx;
        self.power_segment.cells = self.cells[power_idx..net_idx];

        self.window_title_segment.cell_start = 0;
        self.window_title_segment.cells = self.cells[0..power_idx];

        // Slice inline batched vertex buffer: segment background rects + N glyph cells
        const bg_quads = self.segments.len;
        assert(bg_quads <= max_segments);
        self.quad_buffer = self.quad_storage[0 .. bg_quads + cells_count];
        if (!self.window.usesShm()) {
            self.rect.ensureCapacity(self.quad_buffer.len);
        }

        self.clearAllAndDrawStatic();
        for (self.segments) |seg| {
            for (seg.metrics) |*m| {
                m.last_p1 = std.math.maxInt(u64);
                m.last_p2 = std.math.maxInt(u64);
            }
        }
        self.time_metrics[0].metric.time.changed = true;
        self.window_metrics[0].metric.window.changed = true;
        self.frame_dirty = true;
    }

    fn generateCells(self: *StatusMonitor, min_fixed_cells: usize) void {
        const cell_size: u16 = @intCast(self.rect_width_i);
        const char_count: usize = @max(min_fixed_cells + 4, @divTrunc(65535, cell_size));
        const total_cells = @min(max_cells, char_count + 1);
        self.cells = self.cells_storage[0..total_cells];

        var current_x: i16 = -32768;
        for (self.cells) |*cell| {
            cell.* = current_x;
            current_x +%= self.rect_width_i;
        }
    }

    fn beginFadeIn(self: *StatusMonitor, now_ns: i96) void {
        const was_asleep = (self.state == .hidden or self.state == .hover_armed);
        self.window.setInputHeight(self.window.height);
        if (was_asleep) {
            // Preserve last-viewed ring buffer & `prev` values so reveal glimpses last state and smoothly catches up
            self.next_sample_ns = now_ns;
        }
        if (self.opacity >= 0.999) {
            self.opacity = 1.0;
            self.state = .visible;
            self.frame_dirty = true;
            return;
        }
        self.state = .fading_in;
        self.fade_from = self.opacity;
        self.fade_start_ns = now_ns;
        const remaining = @as(f64, 1.0 - self.opacity);
        self.fade_duration_ns = @max(1, @as(i96, @intFromFloat(@as(f64, @floatFromInt(fade_in_ns)) * remaining)));
        self.frame_dirty = true;
    }

    fn beginFadeOut(self: *StatusMonitor, now_ns: i96) void {
        if (self.opacity <= 0.001) {
            self.finishHide();
            return;
        }
        self.state = .fading_out;
        self.fade_from = self.opacity;
        self.fade_start_ns = now_ns;
        const remaining = @as(f64, self.opacity);
        self.fade_duration_ns = @max(1, @as(i96, @intFromFloat(@as(f64, @floatFromInt(fade_out_ns)) * remaining)));
        self.frame_dirty = true;
    }

    fn finishHide(self: *StatusMonitor) void {
        self.opacity = 0.0;
        self.state = .hidden;
        self.frame_dirty = false;
        self.window.clearTransparent();
        self.window.setInputHeight(1);
    }

    pub fn setMode(self: *StatusMonitor, next_mode: BarMode, now_ns: i96) void {
        self.mode = next_mode;
        switch (next_mode) {
            .docked_strut => {
                self.window.setStrut(true);
                self.beginFadeIn(now_ns);
            },
            .pinned_overlay => {
                self.window.setStrut(false);
                self.beginFadeIn(now_ns);
            },
            .auto_hide => {
                self.window.setStrut(false);
                if (self.opacity <= 0.001) {
                    self.window.setInputHeight(1);
                    if (self.window.pointer_inside) {
                        self.state = .hover_armed;
                        self.hover_start_ns = now_ns;
                    } else {
                        self.state = .hidden;
                    }
                } else if (self.window.pointer_inside) {
                    if (self.opacity < 0.999) {
                        self.beginFadeIn(now_ns);
                    } else {
                        self.state = .visible;
                    }
                } else {
                    self.beginFadeOut(now_ns);
                }
            },
        }
    }

    pub fn togglePinnedOverlay(self: *StatusMonitor) void {
        const next: BarMode = if (self.mode == .pinned_overlay) .auto_hide else .pinned_overlay;
        self.setMode(next, monotonicNs(self.io));
    }

    pub fn toggleDockedStrut(self: *StatusMonitor) void {
        const next: BarMode = if (self.mode == .docked_strut) .auto_hide else .docked_strut;
        self.setMode(next, monotonicNs(self.io));
    }

    fn advanceVisibility(self: *StatusMonitor, now_ns: i96) void {
        if (self.mode != .auto_hide) {
            if (self.state == .fading_in) {
                const t = std.math.clamp(
                    @as(f32, @floatFromInt(now_ns - self.fade_start_ns)) /
                        @as(f32, @floatFromInt(self.fade_duration_ns)),
                    0.0,
                    1.0,
                );
                const inv = 1.0 - t;
                const eased = 1.0 - inv * inv * inv;
                self.opacity = self.fade_from + (1.0 - self.fade_from) * eased;
                self.frame_dirty = true;
                if (t >= 1.0) {
                    self.opacity = 1.0;
                    self.state = .visible;
                }
            } else if (self.state != .visible) {
                self.beginFadeIn(now_ns);
            }
            return;
        }

        switch (self.state) {
            .hidden => {
                if (self.window.pointer_inside) {
                    self.state = .hover_armed;
                    self.hover_start_ns = now_ns;
                }
            },
            .hover_armed => {
                if (!self.window.pointer_inside) {
                    self.state = .hidden;
                } else if (now_ns - self.hover_start_ns >= hover_reveal_ns) {
                    self.beginFadeIn(now_ns);
                }
            },
            .fading_in => {
                if (!self.window.pointer_inside) {
                    self.beginFadeOut(now_ns);
                } else {
                    const t = std.math.clamp(
                        @as(f32, @floatFromInt(now_ns - self.fade_start_ns)) /
                            @as(f32, @floatFromInt(self.fade_duration_ns)),
                        0.0,
                        1.0,
                    );
                    const inv = 1.0 - t;
                    const eased = 1.0 - inv * inv * inv;
                    self.opacity = self.fade_from + (1.0 - self.fade_from) * eased;
                    self.frame_dirty = true;
                    if (t >= 1.0) {
                        self.opacity = 1.0;
                        self.state = .visible;
                    }
                }
            },
            .visible => {
                if (!self.window.pointer_inside) {
                    self.state = .leave_grace;
                    self.leave_start_ns = now_ns;
                }
            },
            .leave_grace => {
                if (self.window.pointer_inside) {
                    self.state = .visible;
                } else if (now_ns - self.leave_start_ns >= leave_grace_ns) {
                    self.beginFadeOut(now_ns);
                }
            },
            .fading_out => {
                if (self.window.pointer_inside) {
                    self.next_sample_ns = @min(self.next_sample_ns, now_ns);
                    self.beginFadeIn(now_ns);
                } else {
                    const t = std.math.clamp(
                        @as(f32, @floatFromInt(now_ns - self.fade_start_ns)) /
                            @as(f32, @floatFromInt(self.fade_duration_ns)),
                        0.0,
                        1.0,
                    );
                    const eased = t * t * (3.0 - 2.0 * t);
                    self.opacity = self.fade_from * (1.0 - eased);
                    self.frame_dirty = true;
                    if (t >= 1.0) {
                        self.finishHide();
                    }
                }
            },
        }
    }

    pub fn step(self: *StatusMonitor) !void {
        self.window.updateTheMessageQueue();
        if (!self.window.running) return;
        if (self.window.surface_suspended) {
            if (self.mode == .auto_hide and self.state != .hidden) {
                self.opacity = 0.0;
                self.state = .hidden;
                self.frame_dirty = false;
                self.window.setInputHeight(1);
            }
            self.window.waitForEventsOrTimeout(-1);
            return;
        }

        var now_ns = monotonicNs(self.io);

        if (self.window.resized) {
            self.window.resized = false;
            self.recomputeLayout();
            if (self.state == .hidden or self.state == .hover_armed) {
                self.window.clearTransparent();
                self.frame_dirty = false;
            }
        }

        if (self.window.exposed) {
            self.window.exposed = false;
            if (self.state == .hidden or self.state == .hover_armed) {
                self.window.clearTransparent();
            } else {
                self.frame_dirty = true;
            }
        }

        if (self.window.clicked) {
            self.window.clicked = false;
            self.handleClick(self.window.last_click.x, self.window.last_click.button, now_ns);
        }

        self.advanceVisibility(now_ns);

        if (self.window.title_dirty) {
            if (self.window.waylandTitle()) |wl_title| {
                self.window.title_dirty = false;
                self.window_metrics[0].metric.window.setExternalTitle(wl_title);
            } else if (self.state != .hidden and self.state != .hover_armed) {
                self.window.title_dirty = false;
                self.window_metrics[0].metric.window.markDirty();
                self.window_metrics[0].metric.window.sample();
            }
        }

        // Zero polling while hidden: suspend indefinitely in kernel `poll(-1)` until an input event arrives
        if (self.state == .hidden) {
            self.window.waitForEventsOrTimeout(-1);
            return;
        }
        if (self.state == .hover_armed) {
            const hover_rem = (self.hover_start_ns + hover_reveal_ns) - now_ns;
            if (hover_rem > 0) {
                const ceil_ms = @divTrunc(hover_rem + std.time.ns_per_ms - 1, std.time.ns_per_ms);
                self.window.waitForEventsOrTimeout(@intCast(@min(@as(i96, 60_000), ceil_ms)));
            } else {
                self.window.waitForEventsOrTimeout(0);
            }
            return;
        }

        const sample_interval_ns = self.visible_sample_ns;

        if (now_ns >= self.next_sample_ns) {
            const prior_progress = self.interpolationProgress(now_ns);
            for (self.segments) |segment| {
                segment.update(self.io, self.sample_count, prior_progress);
            }
            if (self.currentPowerLayoutMode() != self.power_layout_mode) {
                self.recomputeLayout();
            }
            const next_flow = self.power_metrics[0].metric.power.flow_state;
            if (next_flow != self.last_power_flow) {
                self.last_power_flow = next_flow;
                self.power_metrics[0].last_p1 = std.math.maxInt(u64);
            }
            self.sample_count +%= 1;
            self.sample_start_ns = now_ns;
            self.next_sample_ns += sample_interval_ns;
            if (self.next_sample_ns <= now_ns) {
                self.next_sample_ns = now_ns + sample_interval_ns;
            }
        } else {
            // Keep wall-clock second flips aligned to exact second boundaries (`~4ns` vDSO check)
            self.time_metrics[0].metric.time.sample(self.io) catch {};
        }

        const drew = try self.renderVisible(now_ns);
        if (drew) {
            now_ns = monotonicNs(self.io);
        }

        // During active fades, let hardware VSync (`wl_surface.frame` or `swapBuffers`) pace frames directly
        if (self.state == .fading_in or self.state == .fading_out) {
            self.window.waitForFrameSync();
            return;
        }

        // Otherwise, sleep in kernel `poll()` until the exact next scheduled deadline or input/title event
        var deadline_ns = self.next_sample_ns;
        const wall_ns = ticker_zig.nanoTimestamp(self.io);
        const next_sec_rem_ns = std.time.ns_per_s - @mod(wall_ns, std.time.ns_per_s);
        deadline_ns = @min(deadline_ns, now_ns + next_sec_rem_ns);
        if (self.state == .leave_grace) {
            deadline_ns = @min(deadline_ns, self.leave_start_ns + leave_grace_ns);
        }

        if (self.hasActiveMarquee()) {
            deadline_ns = @min(deadline_ns, self.marquee_next_ns);
        }
        if (self.minNextInterpolationStepNs(now_ns)) |interp_ns| {
            if (drew and interp_ns <= now_ns) {
                // Pace next interpolated frame to hardware VSync (`wl_surface.frame` on SHM, `swapBuffers` on GL)
                self.window.waitForFrameSync();
                return;
            }
            const safe_interp_ns = if (!drew) @max(now_ns + 4 * std.time.ns_per_ms, interp_ns) else interp_ns;
            deadline_ns = @min(deadline_ns, safe_interp_ns);
        }

        const rem_ns = deadline_ns - now_ns;
        if (rem_ns > 0) {
            const ceil_ms = @divTrunc(rem_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
            const timeout_ms: i32 = @intCast(@min(@as(i96, 60_000), ceil_ms));
            self.window.waitForEventsOrTimeout(timeout_ms);
        } else {
            self.window.waitForEventsOrTimeout(0);
        }
    }

    fn interpolationProgress(self: *const StatusMonitor, now_ns: i96) f64 {
        const span = self.next_sample_ns - self.sample_start_ns;
        if (span <= 0) return 1.0;
        const elapsed = now_ns - self.sample_start_ns;
        if (elapsed <= 0) return 0.0;
        if (elapsed >= span) return 1.0;
        return @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(span));
    }

    fn channelNextStepNs(
        sample_start_ns: i96,
        span_ns: i96,
        now_ns: i96,
        prev_v: u64,
        target_v: u64,
        last_v: u64,
    ) ?i96 {
        if (last_v == target_v) return null;
        const diff: u64 = if (target_v > prev_v) target_v - prev_v else prev_v - target_v;
        if (diff == 0) return now_ns;

        const capped_diff: i96 = @intCast(@min(diff, 1_000_000));
        const step_ns = @divTrunc(span_ns, capped_diff);
        // Fast-changing metrics (>= ~125 integer steps/sec) ride hardware VSync every frame
        if (step_ns <= 8 * std.time.ns_per_ms) {
            return now_ns;
        }

        const done_steps: i96 = @intCast(@min(
            if (target_v > prev_v) (last_v -| prev_v) else (prev_v -| last_v),
            diff,
        ));
        return sample_start_ns + @divTrunc((2 * done_steps + 1) * span_ns, 2 * capped_diff) + 1;
    }

    fn minNextInterpolationStepNs(self: *const StatusMonitor, now_ns: i96) ?i96 {
        if (now_ns >= self.next_sample_ns) return null;
        const span_ns = @max(1, self.next_sample_ns - self.sample_start_ns);
        var earliest: ?i96 = null;

        for (self.segments) |segment| {
            for (segment.metrics) |*m| {
                if (m.metric == .time or m.metric == .window) continue;

                const prev_p1: u64 = @truncate(m.prev);
                const target_p1: u64 = @truncate(m.target);
                if (channelNextStepNs(self.sample_start_ns, span_ns, now_ns, prev_p1, target_p1, m.last_p1)) |t1| {
                    earliest = if (earliest) |e| @min(e, t1) else t1;
                }

                if (m.secondary_index != null) {
                    const prev_p2: u64 = @truncate(m.prev >> 64);
                    const target_p2: u64 = @truncate(m.target >> 64);
                    if (channelNextStepNs(self.sample_start_ns, span_ns, now_ns, prev_p2, target_p2, m.last_p2)) |t2| {
                        earliest = if (earliest) |e| @min(e, t2) else t2;
                    }
                }
            }
        }
        return earliest;
    }

    fn hasActiveMarquee(self: *const StatusMonitor) bool {
        const max_chars = self.window_title_segment.cells.len -| 2;
        return max_chars > 0 and self.title_len > max_chars;
    }

    fn renderVisible(self: *StatusMonitor, now_ns: i96) !bool {
        var drew_anything = self.frame_dirty;
        const progress = self.interpolationProgress(now_ns);

        // 1. Numeric interpolated metrics (both primary and optional secondary channels)
        for (self.segments) |segment| {
            for (segment.metrics) |*m| {
                if (m.metric == .time or m.metric == .window) continue;

                const packed_val = m.interpolateAt(progress);
                const v1: u64 = @truncate(packed_val);
                if (v1 != m.last_p1) {
                    m.last_p1 = v1;
                    const s1 = m.metric.print(v1, 0);
                    if (self.drawSegment(segment, s1.slice(), m.start_index)) {
                        drew_anything = true;
                    }
                }

                if (m.secondary_index) |sec_offset| {
                    const v2: u64 = @truncate(packed_val >> 64);
                    if (v2 != m.last_p2) {
                        m.last_p2 = v2;
                        const target_seg = m.secondary_segment orelse segment;
                        const s2 = m.metric.print(v2, 1);
                        if (self.drawSegment(target_seg, s2.slice(), sec_offset)) {
                            drew_anything = true;
                        }
                    }
                }
            }
        }

        // 2. Wall-clock time segment (updates once per second)
        const time_probe = &self.time_metrics[0].metric.time;
        if (time_probe.changed) {
            time_probe.changed = false;
            if (self.drawSegment(&self.time_segment, &time_probe.value, self.time_metrics[0].start_index)) {
                drew_anything = true;
            }
        }

        // 3. Active window title + monotonic marquee rotation for overflowing titles
        if (self.renderWindowTitle(now_ns)) {
            drew_anything = true;
        }

        if (drew_anything) {
            self.frame_dirty = false;
            if (self.window.usesShm()) {
                const want_vsync = self.state == .fading_in or
                    self.state == .fading_out or
                    (if (self.minNextInterpolationStepNs(now_ns)) |t_ns| t_ns <= now_ns + 16 * std.time.ns_per_ms else false);
                try self.window.presentShm(
                    self.segments.len,
                    self.quad_buffer,
                    self.opacity,
                    want_vsync,
                );
                return true;
            }

            const pre_swap_ns = now_ns;
            self.rect.drawBatch(self.quad_buffer, self.opacity);
            self.window.swapBuffers();

            const post_swap_ns = monotonicNs(self.io);
            if (post_swap_ns - pre_swap_ns < 2 * std.time.ns_per_ms) {
                self.consecutive_unpaced_swaps +|= 1;
                if (self.consecutive_unpaced_swaps >= 2 and
                    (self.state == .fading_in or self.state == .fading_out or self.minNextInterpolationStepNs(post_swap_ns) != null))
                {
                    sleepNs(self.io, 8 * std.time.ns_per_ms);
                }
            } else {
                self.consecutive_unpaced_swaps = 0;
            }
            return true;
        }
        self.consecutive_unpaced_swaps = 0;
        return false;
    }

    fn decodeNextCodepoint(input: []const u8, index: *usize) u32 {
        const i = index.*;
        const b = input[i];
        if (b < 0x80) {
            index.* = i + 1;
            return b;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            index.* = i + 1;
            return 0xFFFD;
        };
        if (i + seq_len > input.len) {
            index.* = input.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(input[i .. i + seq_len]) catch {
            index.* = i + 1;
            return 0xFFFD;
        };
        index.* = i + seq_len;
        return cp;
    }

    fn renderWindowTitle(self: *StatusMonitor, now_ns: i96) bool {
        const win_probe = &self.window_metrics[0].metric.window;
        const max_chars = self.window_title_segment.cells.len -| 2;
        if (max_chars == 0) return false;

        if (win_probe.changed) {
            win_probe.changed = false;
            var changed = self.clearSegment(&self.window_title_segment);

            self.title_len = 0;
            const raw = win_probe.slice();
            var byte_idx: usize = 0;
            while (byte_idx < raw.len and self.title_len < 252) {
                const cp = decodeNextCodepoint(raw, &byte_idx);
                if (cp == '\n' or cp == '\r') continue;
                if (self.font.getGlyphUV(cp) != null) {
                    self.title_codepoints[self.title_len] = cp;
                    self.title_len += 1;
                }
            }

            if (self.title_len > max_chars and self.title_len + 3 <= self.title_codepoints.len) {
                self.title_codepoints[self.title_len] = ' ';
                self.title_codepoints[self.title_len + 1] = 0x02;
                self.title_codepoints[self.title_len + 2] = ' ';
                self.title_len += 3;
            }

            self.marquee_next_ns = now_ns + std.time.ns_per_s;
            self.title_rotations = 0;

            if (self.drawCodepoints(&self.window_title_segment, self.title_codepoints[0..@min(self.title_len, max_chars)], 1)) {
                changed = true;
            }
            return changed;
        }

        // Monotonic marquee scroll after 1 second if title exceeds available cells
        if (self.title_len > max_chars and now_ns >= self.marquee_next_ns) {
            std.mem.rotate(u32, self.title_codepoints[0..self.title_len], 1);
            const changed = self.drawCodepoints(&self.window_title_segment, self.title_codepoints[0..max_chars], 1);

            self.title_rotations += 1;
            if (self.title_rotations >= self.title_len * 2) {
                self.marquee_next_ns = now_ns + 60 * std.time.ns_per_s;
                self.title_rotations = 0;
            } else {
                self.marquee_next_ns = now_ns + marquee_step_ns;
            }
            return changed;
        }

        return false;
    }

    pub fn drawSegment(self: *StatusMonitor, seg: *const Segment, input: []const u8, offset: u8) bool {
        if (input.len == 0 or offset >= seg.cells.len or self.quad_buffer.len == 0) return false;

        const base = self.segments.len + seg.cell_start;
        var byte_idx: usize = 0;
        var cell_idx: usize = 0;
        var changed = false;

        while (byte_idx < input.len) {
            const target_cell = cell_idx + offset;
            if (target_cell >= seg.cells.len) break;
            const cp = decodeNextCodepoint(input, &byte_idx);
            cell_idx += 1;

            if (cp == '\n') continue; // Preserve existing static glyph in this cell

            const next_uv = if (cp == ' ')
                RectDraw.uv_empty
            else
                (self.font.getGlyphUV(cp) orelse RectDraw.uv_empty);

            const slot = &self.quad_buffer[base + target_cell];
            if (slot.uv[0] != next_uv[0] or slot.uv[1] != next_uv[1]) {
                slot.uv = next_uv;
                changed = true;
            }
        }
        return changed;
    }

    fn drawCodepoints(self: *StatusMonitor, seg: *const Segment, codepoints: []const u32, offset: u8) bool {
        if (codepoints.len == 0 or offset >= seg.cells.len or self.quad_buffer.len == 0) return false;

        const base = self.segments.len + seg.cell_start;
        const max_emit = @min(codepoints.len, seg.cells.len - offset);
        var changed = false;

        for (codepoints[0..max_emit], 0..) |cp, cell_idx| {
            const next_uv = if (cp == ' ')
                RectDraw.uv_empty
            else
                (self.font.getGlyphUV(cp) orelse RectDraw.uv_empty);

            const slot = &self.quad_buffer[base + offset + cell_idx];
            if (slot.uv[0] != next_uv[0] or slot.uv[1] != next_uv[1]) {
                slot.uv = next_uv;
                changed = true;
            }
        }
        return changed;
    }

    /// Resets all character slots in a segment to empty (culled) UVs in CPU memory.
    pub fn clearSegment(self: *StatusMonitor, seg: *const Segment) bool {
        if (seg.cells.len == 0 or self.quad_buffer.len == 0) return false;
        const base = self.segments.len + seg.cell_start;
        var changed = false;
        for (self.quad_buffer[base .. base + seg.cells.len]) |*q| {
            if (q.uv[0] != RectDraw.uv_empty[0] or q.uv[1] != RectDraw.uv_empty[1]) {
                q.uv = RectDraw.uv_empty;
                changed = true;
            }
        }
        return changed;
    }

    pub fn clearAllAndDrawStatic(self: *StatusMonitor) void {
        if (self.quad_buffer.len < self.segments.len) return;

        const bg_quads = self.segments.len;
        const glyph_size: [2]f32 = .{ self.rect_width_f, self.rect_height };

        for (self.segments, 0..) |seg, seg_idx| {
            const color_bytes = rgbaBytes(seg.color);

            if (seg.cells.len > 0) {
                const start_ndc = @max(-1.0, @as(f32, @floatFromInt(seg.cells[0])) / 32767.0);
                const end_x_i32 = @as(i32, seg.cells[seg.cells.len - 1]) + @as(i32, self.rect_width_i);
                const end_ndc = if (seg == &self.time_segment)
                    1.0
                else
                    @min(1.0, @as(f32, @floatFromInt(end_x_i32)) / 32767.0);
                const seg_width_ndc = @max(0.0, end_ndc - start_ndc);

                self.quad_buffer[seg_idx] = .{
                    .size = .{ seg_width_ndc, 2.0 },
                    .pos = .{ seg.cells[0], 32767 },
                    .uv = RectDraw.uv_solid,
                    .color = color_bytes,
                };
            } else {
                self.quad_buffer[seg_idx] = .{
                    .size = .{ 0.0, 0.0 },
                    .pos = .{ 0, 0 },
                    .uv = RectDraw.uv_empty,
                    .color = color_bytes,
                };
            }

            const base = bg_quads + seg.cell_start;
            for (seg.cells, 0..) |cell_x, local_i| {
                self.quad_buffer[base + local_i] = .{
                    .size = glyph_size,
                    .pos = .{ cell_x, self.rect_y_pos },
                    .uv = RectDraw.uv_empty,
                    .color = color_bytes,
                };
            }

            if (seg.static_overlay.len > 0) {
                _ = self.drawSegment(seg, seg.static_overlay, seg.static_offset);
            }
        }
    }

    fn handleClick(self: *StatusMonitor, x_pos: i32, button: u32, now_ns: i96) void {
        // Right-click (Button3): pin overlay open (strut OFF), or unpin back to auto-hide
        if (button == 3) {
            const next: BarMode = if (self.mode == .pinned_overlay) .auto_hide else .pinned_overlay;
            self.setMode(next, now_ns);
            return;
        }

        // Middle-click (Button2): turn top strut ON at all times, or turn strut OFF & return to auto-hide
        if (button == 2) {
            const next: BarMode = if (self.mode == .docked_strut) .auto_hide else .docked_strut;
            self.setMode(next, now_ns);
            return;
        }

        // Left-click (Button1): hit-test rendered segment background rect and execute declarative `on_click`
        if (button != 1) return;
        if (self.state == .hidden or self.state == .hover_armed or self.opacity <= 0.05) return;
        if (self.window.width <= 0 or self.quad_buffer.len < self.segments.len) return;

        const w_f: f32 = @floatFromInt(self.window.width);
        const px_f: f32 = @as(f32, @floatFromInt(std.math.clamp(x_pos, 0, self.window.width - 1))) + 0.5;

        for (self.segments, 0..) |seg, seg_idx| {
            const bg_q = self.quad_buffer[seg_idx];
            if (bg_q.size[0] <= 0.0) continue;
            const nx0 = @max(-1.0, @as(f32, @floatFromInt(bg_q.pos[0])) / 32767.0);
            const left_px = (nx0 + 1.0) * 0.5 * w_f;
            const right_px = left_px + bg_q.size[0] * 0.5 * w_f;
            if (px_f >= left_px and px_f <= right_px) {
                const pwr = &self.power_metrics[0].metric.power;
                actions_zig.execute(
                    seg.on_click,
                    self.io,
                    self.window,
                    self.window_metrics[0].metric.window.slice(),
                    .{
                        .has_battery = pwr.has_battery,
                        .has_power_sensor = pwr.has_power_sensor,
                        .flow_state = pwr.flow_state,
                        .capacity_pct = pwr.capacity_pct,
                        .effective_tenths_w = pwr.effective_tenths_w,
                    },
                );
                return;
            }
        }
    }
};
