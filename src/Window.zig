const std = @import("std");
pub const c = @import("c");
const ProcLoader = @import("GlProcs.zig").ProcLoader;
const X11Backend = @import("X11Backend.zig").X11Backend;
const WaylandBackend = @import("WaylandBackend.zig").WaylandBackend;
pub const Click = @import("X11Backend.zig").Click;

pub const BackendPreference = enum {
    /// Prefer native Wayland `zwlr_layer_shell_v1` + `EGL` when `WAYLAND_DISPLAY` is active,
    /// falling back automatically to X11/GLX.
    auto,
    /// Require native Wayland `zwlr_layer_shell_v1` + `EGL`.
    wayland,
    /// Force X11 / Xwayland + GLX.
    x11,
};

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
    backend_preference: BackendPreference = .auto,
    backend: BackendStorage = .none,

    // Optional X11 handles (used by X11Backend directly or WaylandBackend's Xwayland root property watcher)
    display: ?*c.Display = null,
    root: c.Window = 0,
    handle: c.Window = 0,
    net_active_window_atom: c.Atom = 0,
    net_wm_name_atom: c.Atom = 0,
    wm_name_atom: c.Atom = 0,

    width: i32 = 800,
    height: i32 = 17,
    x: i32 = 0,
    y: i32 = 0,
    input_height: i32 = 0,

    running: bool = true,
    docked: bool = true,
    strut_enabled: bool = false,
    pointer_inside: bool = false,
    clicked: bool = false,
    resized: bool = false,
    exposed: bool = false,
    title_dirty: bool = true,
    last_click: Click = .{},

    /// Note: `self` must remain at a stable memory address after `init` (Wayland listeners reference `&self.backend.wayland`).
    pub fn init(self: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        switch (self.backend_preference) {
            .wayland => try self.initWayland(width, height),
            .x11 => try self.initX11(x, y, width, height),
            .auto => {
                if (std.c.getenv("WAYLAND_DISPLAY") != null) {
                    self.initWayland(width, height) catch {
                        self.backend = .none;
                        try self.initX11(x, y, width, height);
                    };
                } else {
                    try self.initX11(x, y, width, height);
                }
            },
        }
    }

    fn initWayland(self: *Window, width: i32, height: i32) !void {
        // Initialize in-place so `&self.backend.wayland` is stable for Wayland listener pointers
        self.backend = .{ .wayland = .{
            .docked = self.docked,
            .strut_enabled = self.strut_enabled,
            .input_height = self.input_height,
        } };
        errdefer self.backend = .none;

        try self.backend.wayland.init(width, height);

        const wl = &self.backend.wayland;
        self.display = wl.aux_x11_dpy;
        self.root = wl.aux_x11_root;
        self.handle = 0;
        self.net_active_window_atom = wl.net_active_window_atom;
        self.net_wm_name_atom = wl.net_wm_name_atom;
        self.wm_name_atom = wl.wm_name_atom;
        self.syncFromBackend();
    }

    fn initX11(self: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        self.backend = .{ .x11 = .{
            .docked = self.docked,
            .strut_enabled = self.strut_enabled,
            .input_height = self.input_height,
        } };
        errdefer self.backend = .none;

        try self.backend.x11.init(x, y, width, height);

        const x11 = &self.backend.x11;
        self.display = x11.display;
        self.root = x11.root;
        self.handle = x11.handle;
        self.net_active_window_atom = x11.net_active_window_atom;
        self.net_wm_name_atom = x11.net_wm_name_atom;
        self.wm_name_atom = x11.wm_name_atom;
        self.syncFromBackend();
    }

    pub fn deinit(self: *Window) void {
        switch (self.backend) {
            .none => {},
            .wayland => |*wl| wl.deinit(),
            .x11 => |*x11| x11.deinit(),
        }
        self.backend = .none;
        self.display = null;
    }

    pub fn activeBackend(self: *const Window) ActiveBackend {
        return std.meta.activeTag(self.backend);
    }

    pub fn getProcLoader(self: *const Window) ProcLoader {
        return switch (self.backend) {
            .wayland => |*wl| wl.getProcLoader(),
            .x11 => |*x11| x11.getProcLoader(),
            .none => unreachable,
        };
    }

    pub fn waylandTitle(self: *const Window) ?[]const u8 {
        return switch (self.backend) {
            .wayland => |*wl| wl.waylandTitle(),
            else => null,
        };
    }

    pub fn setStrut(self: *Window, enabled: bool) void {
        self.strut_enabled = enabled;
        switch (self.backend) {
            .wayland => |*wl| wl.setStrut(enabled),
            .x11 => |*x11| x11.setStrut(enabled),
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
                x11.setInputHeight(h);
                self.input_height = x11.input_height;
            },
            .none => {},
        }
    }

    pub fn clearTransparent(self: *Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.clearTransparent(),
            .x11 => |*x11| x11.clearTransparent(),
            .none => {},
        }
    }

    pub fn updateViewport(self: *const Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.updateViewport(),
            .x11 => |*x11| x11.updateViewport(),
            .none => {},
        }
    }

    pub fn swapBuffers(self: *const Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.swapBuffers(),
            .x11 => |*x11| x11.swapBuffers(),
            .none => {},
        }
    }

    pub fn updateTheMessageQueue(self: *Window) void {
        switch (self.backend) {
            .wayland => |*wl| wl.updateTheMessageQueue(),
            .x11 => |*x11| x11.updateTheMessageQueue(),
            .none => {},
        }
        self.syncFromBackend();
    }

    pub fn waitForEventsOrTimeout(self: *Window, timeout_ms: i32) void {
        switch (self.backend) {
            .wayland => |*wl| wl.waitForEventsOrTimeout(timeout_ms),
            .x11 => |*x11| x11.waitForEventsOrTimeout(timeout_ms),
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
                self.width = x11.width;
                self.height = x11.height;
                self.input_height = x11.input_height;
                self.strut_enabled = x11.strut_enabled;
                self.pointer_inside = x11.pointer_inside;
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
            },
        }
    }
};
