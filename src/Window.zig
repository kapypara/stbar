const std = @import("std");
const build_options = @import("build_options");
pub const c = @import("c");
const types = @import("Types.zig");
const QuadVertex = types.QuadVertex;
pub const Click = types.Click;
pub const BackendPreference = types.BackendPreference;
pub const BarPosition = types.BarPosition;
pub const TitleClip = types.TitleClip;
const ProcLoader = if (build_options.enable_gpu) @import("GlProcs.zig").ProcLoader else void;
const wayland_zig = @import("WaylandBackend.zig");
const WaylandBackend = wayland_zig.WaylandBackend;
const WaylandRenderMode = wayland_zig.WaylandRenderMode;
const x11_zig = if (build_options.enable_x11) @import("X11Backend.zig") else struct {};
const X11Backend = if (build_options.enable_x11) x11_zig.X11Backend else void;
const X11RenderMode = if (build_options.enable_x11) x11_zig.X11RenderMode else void;

pub const ActiveBackend = enum {
    none,
    wayland,
    x11,
};

const BackendStorage = union(ActiveBackend) {
    none: void,
    wayland: WaylandBackend,
    x11: X11Backend,
};

pub const Window = struct {
    pub const X11Handles = if (build_options.enable_x11) struct {
        display: ?*c.Display = null,
        root: c.Window = 0,
        handle: c.Window = 0,
        net_active_window_atom: c.Atom = 0,
        net_wm_name_atom: c.Atom = 0,
        wm_name_atom: c.Atom = 0,
    } else struct {};

    backend_preference: BackendPreference = .auto,
    position: BarPosition = .top,
    backend: BackendStorage = .none,

    // Optional X11 handles (used by X11Backend directly or WaylandBackend's Xwayland root property watcher)
    x11_handles: X11Handles = .{},

    width: i32 = 800,
    height: i32 = 17,
    x: i32 = 0,
    y: i32 = 0,
    input_height: i32 = 0,
    wakeup_fd: c_int = -1,
    target_output: [64]u8 = @splat(0),
    target_output_len: u8 = 0,

    running: bool = true,
    surface_suspended: bool = false,
    docked: bool = true,
    strut_enabled: bool = false,
    pointer_inside: bool = false,
    clicked: bool = false,
    resized: bool = false,
    exposed: bool = false,
    title_dirty: bool = true,
    last_click: Click = .{},

    pub fn setTargetOutput(self: *Window, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, self.target_output.len));
        @memcpy(self.target_output[0..n], name[0..n]);
        self.target_output_len = n;
    }

    /// Note: `self` must remain at a stable memory address after `init` (Wayland listeners reference `&self.backend.wayland`).
    pub fn init(self: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        switch (self.backend_preference) {
            .wayland => try self.initWayland(width, height, .shm),
            .wayland_egl => {
                if (!comptime build_options.enable_gpu) return error.GpuDisabledInBuild;
                try self.initWayland(width, height, .egl);
            },
            .x11 => {
                if (!comptime build_options.enable_x11) return error.X11DisabledInBuild;
                try self.initX11(x, y, width, height, .shm);
            },
            .x11_glx => {
                if (!comptime build_options.enable_x11) return error.X11DisabledInBuild;
                if (!comptime build_options.enable_gpu) return error.GpuDisabledInBuild;
                try self.initX11(x, y, width, height, .glx);
            },
            .auto => {
                if (std.c.getenv("WAYLAND_DISPLAY") != null) {
                    if (self.initWayland(width, height, .shm)) |_| {
                        return;
                    } else |_| {
                        self.backend = .none;
                    }
                    if (comptime build_options.enable_gpu) {
                        if (self.initWayland(width, height, .egl)) |_| {
                            return;
                        } else |_| {
                            self.backend = .none;
                        }
                    }
                }
                if (comptime build_options.enable_x11) {
                    if (self.initX11(x, y, width, height, .shm)) |_| {
                        return;
                    } else |err| {
                        self.backend = .none;
                        if (comptime build_options.enable_gpu) {
                            try self.initX11(x, y, width, height, .glx);
                            return;
                        }
                        return err;
                    }
                }
                return error.NoAvailableDisplayBackend;
            },
        }
    }

    fn initWayland(self: *Window, width: i32, height: i32, render_mode: WaylandRenderMode) !void {
        // Initialize in-place so `&self.backend.wayland` is stable for Wayland listener pointers
        self.backend = .{ .wayland = .{
            .render_mode = render_mode,
            .position = self.position,
            .docked = self.docked,
            .strut_enabled = self.strut_enabled,
            .input_height = self.input_height,
            .wakeup_fd = self.wakeup_fd,
        } };
        errdefer self.backend = .none;

        self.backend.wayland.setTargetOutput(self.target_output[0..self.target_output_len]);
        try self.backend.wayland.init(width, height);

        if (comptime build_options.enable_x11) {
            const wl = &self.backend.wayland;
            self.x11_handles = .{
                .display = wl.aux_x11.dpy,
                .root = wl.aux_x11.root,
                .handle = 0,
                .net_active_window_atom = wl.aux_x11.net_active_window_atom,
                .net_wm_name_atom = wl.aux_x11.net_wm_name_atom,
                .wm_name_atom = wl.aux_x11.wm_name_atom,
            };
        }
        self.syncFromBackend();
    }

    fn initX11(self: *Window, x: i32, y: i32, width: i32, height: i32, render_mode: X11RenderMode) !void {
        if (!comptime build_options.enable_x11) return error.X11DisabledInBuild;
        self.backend = .{ .x11 = .{
            .render_mode = render_mode,
            .position = self.position,
            .docked = self.docked,
            .strut_enabled = self.strut_enabled,
            .input_height = self.input_height,
            .wakeup_fd = self.wakeup_fd,
        } };
        errdefer self.backend = .none;

        try self.backend.x11.init(x, y, width, height);

        const x11 = &self.backend.x11;
        self.x11_handles = .{
            .display = x11.display,
            .root = x11.root,
            .handle = x11.handle,
            .net_active_window_atom = x11.net_active_window_atom,
            .net_wm_name_atom = x11.net_wm_name_atom,
            .wm_name_atom = x11.wm_name_atom,
        };
        self.syncFromBackend();
    }

    pub fn deinit(self: *Window) void {
        switch (self.backend) {
            .none => {},
            .wayland => |*wl| wl.deinit(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.deinit(),
        }
        self.backend = .none;
        self.x11_handles = .{};
    }

    pub fn activeBackend(self: *const Window) ActiveBackend {
        return std.meta.activeTag(self.backend);
    }

    pub fn usesShm(self: *const Window) bool {
        return switch (self.backend) {
            .wayland => |*wl| wl.render_mode == .shm,
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.render_mode == .shm else false,
            .none => false,
        };
    }

    pub fn bufferSize(self: *const Window) struct { w: i32, h: i32 } {
        return switch (self.backend) {
            .wayland => |*wl| blk: {
                const b = wl.bufferSize();
                break :blk .{ .w = b.w, .h = b.h };
            },
            .x11, .none => .{ .w = @max(1, self.width), .h = @max(1, self.height) },
        };
    }

    pub fn presentShm(
        self: *Window,
        bg_count: usize,
        quads: []const QuadVertex,
        opacity: f32,
        title_clip: ?TitleClip,
        request_frame_sync: bool,
    ) !void {
        switch (self.backend) {
            .wayland => |*wl| try wl.presentShm(bg_count, quads, opacity, title_clip, request_frame_sync),
            .x11 => |*x11| if (comptime build_options.enable_x11) try x11.presentShm(bg_count, quads, opacity, title_clip, request_frame_sync),
            .none => {},
        }
    }

    pub fn waitForFrameSync(self: *Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.waitForFrameSync(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.waitForFrameSync(),
            .none => {},
        }
    }

    pub fn getProcLoader(self: *const Window) ProcLoader {
        if (!comptime build_options.enable_gpu) return;
        return switch (self.backend) {
            .wayland => |*wl| wl.getProcLoader(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.getProcLoader() else unreachable,
            .none => unreachable,
        };
    }

    pub fn waylandTitle(self: *const Window) ?[]const u8 {
        return switch (self.backend) {
            .wayland => |*wl| wl.waylandTitle(),
            else => null,
        };
    }

    pub fn setClipboard(self: *Window, text: []const u8) void {
        switch (self.backend) {
            .wayland => |*wl| wl.setClipboard(text),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.setClipboard(text),
            .none => {},
        }
    }

    pub fn setStrut(self: *Window, enabled: bool) void {
        self.strut_enabled = enabled;
        switch (self.backend) {
            .wayland => |*wl| wl.setStrut(enabled),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.setStrut(enabled),
            .none => {},
        }
    }

    pub fn setInputHeight(self: *Window, h: i32) void {
        switch (self.backend) {
            .wayland => |*wl| {
                wl.setInputHeight(h);
                self.input_height = wl.input_height;
            },
            .x11 => |*x11| {
                if (comptime build_options.enable_x11) {
                    x11.setInputHeight(h);
                    self.input_height = x11.input_height;
                }
            },
            .none => {},
        }
    }

    pub fn clearTransparent(self: *Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.clearTransparent(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.clearTransparent(),
            .none => {},
        }
    }

    pub fn updateViewport(self: *const Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.updateViewport(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.updateViewport(),
            .none => {},
        }
    }

    pub fn swapBuffers(self: *const Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.swapBuffers(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.swapBuffers(),
            .none => {},
        }
    }

    pub fn updateTheMessageQueue(self: *Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.updateTheMessageQueue(),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.updateTheMessageQueue(),
            .none => {},
        }
        self.syncFromBackend();
    }

    pub fn waitForEventsOrTimeout(self: *Window, timeout_ms: i32) void {
        switch (self.backend) {
            .wayland => |*wl| wl.waitForEventsOrTimeout(timeout_ms),
            .x11 => |*x11| if (comptime build_options.enable_x11) x11.waitForEventsOrTimeout(timeout_ms),
            .none => {},
        }
        self.syncFromBackend();
    }

    fn syncFromBackend(self: *Window) void {
        switch (self.backend) {
            .none => {},
            .wayland => |*wl| {
                self.width = wl.width;
                self.height = wl.height;
                self.input_height = wl.input_height;
                self.strut_enabled = wl.strut_enabled;
                self.pointer_inside = wl.pointer_inside;
                self.surface_suspended = wl.surface_lost;
                if (!wl.running) self.running = false;
                if (wl.resized) {
                    self.resized = true;
                    wl.resized = false;
                }
                if (wl.exposed) {
                    self.exposed = true;
                    wl.exposed = false;
                }
                if (wl.clicked) {
                    self.clicked = true;
                    self.last_click = wl.last_click;
                    wl.clicked = false;
                }
                if (wl.title_dirty) {
                    self.title_dirty = true;
                    wl.title_dirty = false;
                }
            },
            .x11 => |*x11| {
                if (comptime build_options.enable_x11) {
                    self.width = x11.width;
                    self.height = x11.height;
                    self.input_height = x11.input_height;
                    self.strut_enabled = x11.strut_enabled;
                    self.pointer_inside = x11.pointer_inside;
                    self.surface_suspended = false;
                    if (!x11.running) self.running = false;
                    if (x11.resized) {
                        self.resized = true;
                        x11.resized = false;
                    }
                    if (x11.exposed) {
                        self.exposed = true;
                        x11.exposed = false;
                    }
                    if (x11.clicked) {
                        self.clicked = true;
                        self.last_click = x11.last_click;
                        x11.clicked = false;
                    }
                    if (x11.title_dirty) {
                        self.title_dirty = true;
                        x11.title_dirty = false;
                    }
                }
            },
        }
    }
};
