const std = @import("std");
const c = @import("c");
const ProcLoader = @import("GlProcs.zig").ProcLoader;
const Click = @import("X11Backend.zig").Click;
const KwinTitleWatcher = @import("KwinTitleWatcher.zig").KwinTitleWatcher;

const EGL_PLATFORM_WAYLAND_KHR: c.EGLenum = 0x31D8;
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

pub const WaylandBackend = struct {
    const max_toplevels = 64;

    const ToplevelSlot = struct {
        owner: ?*WaylandBackend = null,
        handle: ?*c.struct_zwlr_foreign_toplevel_handle_v1 = null,
        title: [256]u8 = @splat(0),
        title_len: u16 = 0,
        pending_activated: bool = false,
        activated: bool = false,
    };

    wl_display: ?*c.struct_wl_display = null,
    wl_registry: ?*c.struct_wl_registry = null,
    wl_compositor: ?*c.struct_wl_compositor = null,
    wl_seat: ?*c.struct_wl_seat = null,
    wl_pointer: ?*c.struct_wl_pointer = null,
    wl_surface: ?*c.struct_wl_surface = null,
    egl_window: ?*c.struct_wl_egl_window = null,

    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,

    toplevel_manager: ?*c.struct_zwlr_foreign_toplevel_manager_v1 = null,
    toplevels: [max_toplevels]ToplevelSlot = @splat(.{}),
    has_foreign_toplevel: bool = false,
    active_title: [256]u8 = @splat(0),
    active_title_len: usize = 0,

    // Event-driven KWin Scripting + D-Bus title listener for KDE Plasma Wayland
    kwin_watcher: KwinTitleWatcher = .{},

    // Optional event-driven Xwayland root property watcher when neither wlr-foreign-toplevel nor KWin D-Bus is active
    aux_x11_dpy: ?*c.Display = null,
    aux_x11_root: c.Window = 0,
    net_active_window_atom: c.Atom = 0,
    net_wm_name_atom: c.Atom = 0,
    wm_name_atom: c.Atom = 0,

    egl_display: c.EGLDisplay = c.EGL_NO_DISPLAY,
    egl_context: c.EGLContext = c.EGL_NO_CONTEXT,
    egl_surface: c.EGLSurface = c.EGL_NO_SURFACE,
    egl_config: c.EGLConfig = null,

    requested_width: i32 = 0,
    width: i32 = 1920,
    height: i32 = 17,
    input_height: i32 = 0,
    applied_input_height: i32 = -1,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,

    configured: bool = false,
    running: bool = true,
    docked: bool = true,
    strut_enabled: bool = false,
    pointer_inside: bool = false,
    clicked: bool = false,
    resized: bool = false,
    exposed: bool = false,
    title_dirty: bool = true,
    last_click: Click = .{},

    /// Note: `self` must reside at a stable address before calling `init` because Wayland
    /// listeners store `self` as their callback user-data pointer.
    pub fn init(self: *WaylandBackend, width: i32, height: i32) !void {
        self.requested_width = width;
        if (width > 0) self.width = width;
        self.height = height;

        self.wl_display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer self.deinit();

        const dpy = self.wl_display.?;
        self.wl_registry = c.wl_display_get_registry(dpy) orelse return error.WaylandRegistryFailed;
        _ = c.wl_registry_add_listener(self.wl_registry, &registry_listener, self);

        if (c.wl_display_roundtrip(dpy) < 0) return error.WaylandRoundtripFailed;
        if (self.wl_compositor == null) return error.NoWaylandCompositor;
        if (self.layer_shell == null) return error.NoLayerShell;

        // Flush seat capability & initial toplevel advertisements if bound
        _ = c.wl_display_roundtrip(dpy);

        try self.createLayerSurface();
        try self.createEglContext();

        if (!self.has_foreign_toplevel) {
            if (self.kwin_watcher.init()) {
                self.title_dirty = true;
            } else {
                self.initAuxX11Watcher();
            }
        }
    }

    pub fn deinit(self: *WaylandBackend) void {
        self.kwin_watcher.deinit();
        if (self.aux_x11_dpy) |x_dpy| {
            _ = c.XCloseDisplay(x_dpy);
            self.aux_x11_dpy = null;
        }

        if (self.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            if (self.egl_surface != c.EGL_NO_SURFACE) {
                _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
                self.egl_surface = c.EGL_NO_SURFACE;
            }
            if (self.egl_context != c.EGL_NO_CONTEXT) {
                _ = c.eglDestroyContext(self.egl_display, self.egl_context);
                self.egl_context = c.EGL_NO_CONTEXT;
            }
            _ = c.eglTerminate(self.egl_display);
            self.egl_display = c.EGL_NO_DISPLAY;
        }

        if (self.egl_window) |win| {
            c.wl_egl_window_destroy(win);
            self.egl_window = null;
        }

        for (&self.toplevels) |*slot| {
            if (slot.handle) |h| {
                c.zwlr_foreign_toplevel_handle_v1_destroy(h);
                slot.handle = null;
            }
        }
        if (self.toplevel_manager) |mgr| {
            c.zwlr_foreign_toplevel_manager_v1_destroy(mgr);
            self.toplevel_manager = null;
        }

        if (self.layer_surface) |ls| {
            c.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.wl_surface) |surf| {
            c.wl_surface_destroy(surf);
            self.wl_surface = null;
        }
        if (self.layer_shell) |shell| {
            c.zwlr_layer_shell_v1_destroy(shell);
            self.layer_shell = null;
        }
        if (self.wl_pointer) |ptr| {
            c.wl_pointer_destroy(ptr);
            self.wl_pointer = null;
        }
        if (self.wl_seat) |seat| {
            c.wl_seat_destroy(seat);
            self.wl_seat = null;
        }
        if (self.wl_compositor) |comp| {
            c.wl_compositor_destroy(comp);
            self.wl_compositor = null;
        }
        if (self.wl_registry) |reg| {
            c.wl_registry_destroy(reg);
            self.wl_registry = null;
        }
        if (self.wl_display) |dpy| {
            c.wl_display_disconnect(dpy);
            self.wl_display = null;
        }
    }

    pub fn getProcLoader(_: *const WaylandBackend) ProcLoader {
        return eglLoadProc;
    }

    fn eglLoadProc(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return @ptrCast(c.eglGetProcAddress(name));
    }

    pub fn waylandTitle(self: *const WaylandBackend) ?[]const u8 {
        if (self.has_foreign_toplevel) {
            return self.active_title[0..self.active_title_len];
        }
        if (self.kwin_watcher.active) {
            return self.kwin_watcher.slice();
        }
        return null;
    }

    fn createLayerSurface(self: *WaylandBackend) !void {
        const dpy = self.wl_display.?;
        const comp = self.wl_compositor.?;
        const shell = self.layer_shell.?;

        self.wl_surface = c.wl_compositor_create_surface(comp) orelse return error.CreateSurfaceFailed;
        self.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            shell,
            self.wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "zigbar",
        ) orelse return error.CreateLayerSurfaceFailed;

        _ = c.zwlr_layer_surface_v1_add_listener(self.layer_surface, &layer_surface_listener, self);

        const req_w: u32 = if (self.requested_width > 0) @intCast(self.requested_width) else 0;
        const anchor: u32 = if (self.requested_width > 0)
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT
        else
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

        c.zwlr_layer_surface_v1_set_size(self.layer_surface, req_w, @intCast(self.height));
        c.zwlr_layer_surface_v1_set_anchor(self.layer_surface, anchor);
        c.zwlr_layer_surface_v1_set_exclusive_zone(
            self.layer_surface,
            if (self.strut_enabled) self.height else 0,
        );
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            self.layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        const initial_input_h = if (self.input_height > 0) self.input_height else self.height;
        self.stageInputRegion(initial_input_h);

        // Initial bufferless commit to receive `zwlr_layer_surface_v1.configure` with output width
        c.wl_surface_commit(self.wl_surface);
        if (c.wl_display_roundtrip(dpy) < 0 or !self.configured) {
            return error.LayerSurfaceConfigureFailed;
        }
        // Re-stage 1px input region if output width updated during initial configure
        if (self.applied_input_height == 1) {
            self.stageInputRegion(1);
        }
        self.resized = false;
        self.exposed = false;
    }

    fn createEglContext(self: *WaylandBackend) !void {
        const dpy = self.wl_display.?;

        self.egl_display = c.eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, @ptrCast(dpy), null);
        if (self.egl_display == c.EGL_NO_DISPLAY) {
            self.egl_display = c.eglGetDisplay(@ptrCast(dpy));
        }
        if (self.egl_display == c.EGL_NO_DISPLAY) return error.EglGetDisplayFailed;

        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(self.egl_display, &major, &minor) != c.EGL_TRUE) {
            return error.EglInitializeFailed;
        }
        if (c.eglBindAPI(c.EGL_OPENGL_API) != c.EGL_TRUE) {
            return error.EglBindOpenGlFailed;
        }

        const cfg_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_DEPTH_SIZE,      0,
            c.EGL_NONE,
        };
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(self.egl_display, &cfg_attribs, &self.egl_config, 1, &num_configs) != c.EGL_TRUE or num_configs == 0) {
            return error.EglChooseConfigFailed;
        }

        const ctx_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 3,
            c.EGL_CONTEXT_MINOR_VERSION, 2,
            c.EGL_CONTEXT_OPENGL_PROFILE_MASK, c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            c.EGL_NONE,
        };
        self.egl_context = c.eglCreateContext(self.egl_display, self.egl_config, c.EGL_NO_CONTEXT, &ctx_attribs);
        if (self.egl_context == c.EGL_NO_CONTEXT) {
            const fallback_attribs = [_]c.EGLint{c.EGL_NONE};
            self.egl_context = c.eglCreateContext(self.egl_display, self.egl_config, c.EGL_NO_CONTEXT, &fallback_attribs);
        }
        if (self.egl_context == c.EGL_NO_CONTEXT) return error.EglCreateContextFailed;

        self.egl_window = c.wl_egl_window_create(
            self.wl_surface,
            @max(1, self.width),
            @max(1, self.height),
        ) orelse return error.WlEglWindowCreateFailed;

        self.egl_surface = c.eglCreatePlatformWindowSurface(
            self.egl_display,
            self.egl_config,
            @ptrCast(self.egl_window),
            null,
        );
        if (self.egl_surface == c.EGL_NO_SURFACE) {
            self.egl_surface = c.eglCreateWindowSurface(
                self.egl_display,
                self.egl_config,
                self.egl_window,
                null,
            );
        }
        if (self.egl_surface == c.EGL_NO_SURFACE) return error.EglCreateSurfaceFailed;

        if (c.eglMakeCurrent(self.egl_display, self.egl_surface, self.egl_surface, self.egl_context) != c.EGL_TRUE) {
            return error.EglMakeCurrentFailed;
        }

        // Hardware VSync pacing (interval = 1)
        _ = c.eglSwapInterval(self.egl_display, 1);

        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        self.updateViewport();
        self.clearTransparent();
    }

    fn initAuxX11Watcher(self: *WaylandBackend) void {
        const dpy = c.XOpenDisplay(null) orelse return;
        self.aux_x11_dpy = dpy;
        const screen = c.DefaultScreen(dpy);
        self.aux_x11_root = c.RootWindow(dpy, screen);
        self.net_active_window_atom = c.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", c.False);
        self.net_wm_name_atom = c.XInternAtom(dpy, "_NET_WM_NAME", c.False);
        self.wm_name_atom = c.XInternAtom(dpy, "WM_NAME", c.False);
        _ = c.XSelectInput(dpy, self.aux_x11_root, c.PropertyChangeMask);
        _ = c.XFlush(dpy);
    }

    pub fn setStrut(self: *WaylandBackend, enabled: bool) void {
        if (self.strut_enabled == enabled) return;
        self.strut_enabled = enabled;

        const ls = self.layer_surface orelse return;
        const surf = self.wl_surface orelse return;
        const dpy = self.wl_display orelse return;

        c.zwlr_layer_surface_v1_set_exclusive_zone(ls, if (enabled) self.height else 0);
        c.wl_surface_commit(surf);
        _ = c.wl_display_flush(dpy);
    }

    pub fn setInputHeight(self: *WaylandBackend, h: i32) void {
        const target = if (h <= 1) @as(i32, 1) else self.height;
        self.input_height = target;
        if (self.applied_input_height == target) return;

        const surf = self.wl_surface orelse return;
        const dpy = self.wl_display orelse return;

        self.stageInputRegion(target);
        c.wl_surface_commit(surf);
        _ = c.wl_display_flush(dpy);
    }

    fn stageInputRegion(self: *WaylandBackend, target: i32) void {
        const comp = self.wl_compositor orelse return;
        const surf = self.wl_surface orelse return;
        self.input_height = target;
        self.applied_input_height = target;

        if (target <= 1) {
            if (c.wl_compositor_create_region(comp)) |region| {
                c.wl_region_add(region, 0, 0, @max(1, self.width), 1);
                c.wl_surface_set_input_region(surf, region);
                c.wl_region_destroy(region);
            }
        } else {
            // `null` restores full surface input acceptance across the bar
            c.wl_surface_set_input_region(surf, null);
        }
    }

    pub fn clearTransparent(self: *WaylandBackend) void {
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        self.swapBuffers();
    }

    pub fn updateViewport(self: *const WaylandBackend) void {
        c.glViewport(0, 0, self.width, self.height);
    }

    pub fn swapBuffers(self: *const WaylandBackend) void {
        if (self.egl_display != c.EGL_NO_DISPLAY and self.egl_surface != c.EGL_NO_SURFACE) {
            _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);
        }
    }

    pub fn updateTheMessageQueue(self: *WaylandBackend) void {
        if (self.wl_display) |wl_dpy| {
            while (c.wl_display_prepare_read(wl_dpy) != 0) {
                if (c.wl_display_dispatch_pending(wl_dpy) < 0) {
                    self.running = false;
                    return;
                }
            }
            _ = c.wl_display_flush(wl_dpy);

            var pfd = c.struct_pollfd{
                .fd = c.wl_display_get_fd(wl_dpy),
                .events = c.POLLIN,
                .revents = 0,
            };
            if (c.poll(&pfd, 1, 0) > 0 and (pfd.revents & (c.POLLIN | c.POLLERR | c.POLLHUP)) != 0) {
                if (c.wl_display_read_events(wl_dpy) < 0) {
                    self.running = false;
                    return;
                }
            } else {
                c.wl_display_cancel_read(wl_dpy);
            }

            if (c.wl_display_dispatch_pending(wl_dpy) < 0) {
                self.running = false;
                return;
            }
        }

        if (self.kwin_watcher.active) {
            if (self.kwin_watcher.pump()) {
                self.title_dirty = true;
            }
        }

        if (self.aux_x11_dpy) |x_dpy| {
            var event: c.XEvent = undefined;
            var pending = c.XEventsQueued(x_dpy, c.QueuedAfterReading);
            while (pending > 0) : (pending = c.XEventsQueued(x_dpy, c.QueuedAlready)) {
                _ = c.XNextEvent(x_dpy, &event);
                if (event.type == c.PropertyNotify) {
                    const atom = event.xproperty.atom;
                    if (atom == self.net_active_window_atom or
                        atom == self.net_wm_name_atom or
                        atom == self.wm_name_atom)
                    {
                        self.title_dirty = true;
                    }
                }
            }
        }
    }

    /// `timeout_ms < 0` sleeps indefinitely in kernel `poll()` until an input/compositor/title event arrives.
    pub fn waitForEventsOrTimeout(self: *WaylandBackend, timeout_ms: i32) void {
        const wl_dpy = self.wl_display orelse return;
        if (timeout_ms == 0) {
            _ = c.wl_display_flush(wl_dpy);
            if (self.aux_x11_dpy) |x_dpy| _ = c.XFlush(x_dpy);
            return;
        }

        if (self.kwin_watcher.active) {
            if (self.kwin_watcher.pump()) {
                self.title_dirty = true;
                return;
            }
        }

        if (self.aux_x11_dpy) |x_dpy| {
            if (c.XPending(x_dpy) > 0) return;
        }

        while (c.wl_display_prepare_read(wl_dpy) != 0) {
            if (c.wl_display_dispatch_pending(wl_dpy) < 0) {
                self.running = false;
            }
            return;
        }
        _ = c.wl_display_flush(wl_dpy);

        var pfds: [3]c.struct_pollfd = undefined;
        pfds[0] = .{
            .fd = c.wl_display_get_fd(wl_dpy),
            .events = c.POLLIN,
            .revents = 0,
        };
        var nfds: c.nfds_t = 1;
        const kwin_fd = self.kwin_watcher.fd();
        if (kwin_fd >= 0) {
            pfds[nfds] = .{
                .fd = kwin_fd,
                .events = c.POLLIN,
                .revents = 0,
            };
            nfds += 1;
        }
        if (self.aux_x11_dpy) |x_dpy| {
            pfds[nfds] = .{
                .fd = c.ConnectionNumber(x_dpy),
                .events = c.POLLIN,
                .revents = 0,
            };
            nfds += 1;
        }

        const ready = c.poll(&pfds, nfds, timeout_ms);
        if (ready > 0 and (pfds[0].revents & (c.POLLIN | c.POLLERR | c.POLLHUP)) != 0) {
            if (c.wl_display_read_events(wl_dpy) < 0) {
                self.running = false;
                return;
            }
        } else {
            c.wl_display_cancel_read(wl_dpy);
        }
    }

    // --- Wayland Protocol Listeners ---

    const registry_listener = c.struct_wl_registry_listener{
        .global = registryGlobal,
        .global_remove = registryGlobalRemove,
    };

    fn registryGlobal(
        data: ?*anyopaque,
        registry: ?*c.struct_wl_registry,
        name: u32,
        interface_ptr: [*c]const u8,
        version: u32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface_ptr);

        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.wl_compositor = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_compositor_interface,
                @min(version, 4),
            ));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.zwlr_layer_shell_v1_interface,
                @min(version, 4),
            ));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            if (self.wl_seat == null) {
                // Bind version 1 so `wl_pointer_listener` needs only the base 5 callbacks
                self.wl_seat = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.wl_seat_interface,
                    1,
                ));
                _ = c.wl_seat_add_listener(self.wl_seat, &seat_listener, self);
            }
        } else if (std.mem.eql(u8, iface, "zwlr_foreign_toplevel_manager_v1")) {
            self.toplevel_manager = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.zwlr_foreign_toplevel_manager_v1_interface,
                @min(version, 3),
            ));
            self.has_foreign_toplevel = true;
            _ = c.zwlr_foreign_toplevel_manager_v1_add_listener(
                self.toplevel_manager,
                &toplevel_manager_listener,
                self,
            );
        }
    }

    fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

    const layer_surface_listener = c.struct_zwlr_layer_surface_v1_listener{
        .configure = layerSurfaceConfigure,
        .closed = layerSurfaceClosed,
    };

    fn layerSurfaceConfigure(
        data: ?*anyopaque,
        ls: ?*c.struct_zwlr_layer_surface_v1,
        serial: u32,
        new_w: u32,
        new_h: u32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        c.zwlr_layer_surface_v1_ack_configure(ls, serial);

        const resolved_w: i32 = if (new_w > 0) @intCast(new_w) else self.width;
        const resolved_h: i32 = if (new_h > 0) @intCast(new_h) else self.height;
        const size_changed = (resolved_w != self.width or resolved_h != self.height);
        const width_changed = (resolved_w != self.width);

        self.width = resolved_w;
        self.height = resolved_h;

        if (size_changed) {
            if (self.egl_window) |win| {
                c.wl_egl_window_resize(win, @max(1, self.width), @max(1, self.height), 0, 0);
            }
            if (width_changed and self.applied_input_height == 1) {
                self.stageInputRegion(1);
            }
            if (self.configured) {
                self.resized = true;
            }
        }
        self.configured = true;
        self.exposed = true;
    }

    fn layerSurfaceClosed(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.running = false;
    }

    const seat_listener = c.struct_wl_seat_listener{
        .capabilities = seatCapabilities,
        .name = seatName,
    };

    fn seatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const has_pointer = (caps & c.WL_SEAT_CAPABILITY_POINTER) != 0;
        if (has_pointer and self.wl_pointer == null) {
            self.wl_pointer = c.wl_seat_get_pointer(seat);
            if (self.wl_pointer) |ptr| {
                _ = c.wl_pointer_add_listener(ptr, &pointer_listener, self);
            }
        } else if (!has_pointer and self.wl_pointer != null) {
            c.wl_pointer_destroy(self.wl_pointer);
            self.wl_pointer = null;
            self.pointer_inside = false;
        }
    }

    fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

    const pointer_listener = c.struct_wl_pointer_listener{
        .enter = pointerEnter,
        .leave = pointerLeave,
        .motion = pointerMotion,
        .button = pointerButton,
        .axis = pointerAxis,
    };

    fn pointerEnter(
        data: ?*anyopaque,
        _: ?*c.struct_wl_pointer,
        _: u32,
        _: ?*c.struct_wl_surface,
        sx: c.wl_fixed_t,
        sy: c.wl_fixed_t,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.pointer_x = @divTrunc(sx, 256);
        self.pointer_y = @divTrunc(sy, 256);
        self.pointer_inside = true;
    }

    fn pointerLeave(
        data: ?*anyopaque,
        _: ?*c.struct_wl_pointer,
        _: u32,
        _: ?*c.struct_wl_surface,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.pointer_inside = false;
    }

    fn pointerMotion(
        data: ?*anyopaque,
        _: ?*c.struct_wl_pointer,
        _: u32,
        sx: c.wl_fixed_t,
        sy: c.wl_fixed_t,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.pointer_x = @divTrunc(sx, 256);
        self.pointer_y = @divTrunc(sy, 256);
    }

    fn pointerButton(
        data: ?*anyopaque,
        _: ?*c.struct_wl_pointer,
        _: u32,
        _: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));

        const mapped_btn: u32 = switch (button) {
            BTN_LEFT => 1,
            BTN_MIDDLE => 2,
            BTN_RIGHT => 3,
            else => 0,
        };
        if (mapped_btn != 0) {
            self.last_click = .{
                .x = self.pointer_x,
                .y = self.pointer_y,
                .button = mapped_btn,
            };
            self.clicked = true;
        }
    }

    fn pointerAxis(
        _: ?*anyopaque,
        _: ?*c.struct_wl_pointer,
        _: u32,
        _: u32,
        _: c.wl_fixed_t,
    ) callconv(.c) void {}

    // --- Optional wlr-foreign-toplevel-management-unstable-v1 Listeners ---

    const toplevel_manager_listener = c.struct_zwlr_foreign_toplevel_manager_v1_listener{
        .toplevel = toplevelManagerToplevel,
        .finished = toplevelManagerFinished,
    };

    fn toplevelManagerToplevel(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_foreign_toplevel_manager_v1,
        handle: ?*c.struct_zwlr_foreign_toplevel_handle_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        const h = handle orelse return;

        for (&self.toplevels) |*slot| {
            if (slot.handle == null) {
                slot.* = .{
                    .owner = self,
                    .handle = h,
                };
                _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(h, &toplevel_handle_listener, slot);
                return;
            }
        }
        // Table full: release handle cleanly instead of leaking proxy
        c.zwlr_foreign_toplevel_handle_v1_destroy(h);
    }

    fn toplevelManagerFinished(
        data: ?*anyopaque,
        mgr: ?*c.struct_zwlr_foreign_toplevel_manager_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (mgr != null) c.zwlr_foreign_toplevel_manager_v1_destroy(mgr);
        self.toplevel_manager = null;
    }

    const toplevel_handle_listener = c.struct_zwlr_foreign_toplevel_handle_v1_listener{
        .title = toplevelTitle,
        .app_id = toplevelAppId,
        .output_enter = toplevelOutputEnter,
        .output_leave = toplevelOutputLeave,
        .state = toplevelState,
        .done = toplevelDone,
        .closed = toplevelClosed,
        .parent = toplevelParent,
    };

    fn toplevelTitle(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_foreign_toplevel_handle_v1,
        raw_title: [*c]const u8,
    ) callconv(.c) void {
        const slot: *ToplevelSlot = @ptrCast(@alignCast(data.?));
        if (raw_title == null) {
            slot.title_len = 0;
        } else {
            const span = std.mem.span(raw_title);
            const n = @min(span.len, 255);
            @memcpy(slot.title[0..n], span[0..n]);
            slot.title_len = @intCast(n);
        }
        if (slot.activated) {
            if (slot.owner) |owner| owner.refreshActiveToplevelTitle();
        }
    }

    fn toplevelAppId(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: [*c]const u8) callconv(.c) void {}
    fn toplevelOutputEnter(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn toplevelOutputLeave(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn toplevelParent(_: ?*anyopaque, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1, _: ?*c.struct_zwlr_foreign_toplevel_handle_v1) callconv(.c) void {}

    fn toplevelState(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_foreign_toplevel_handle_v1,
        states: [*c]c.struct_wl_array,
    ) callconv(.c) void {
        const slot: *ToplevelSlot = @ptrCast(@alignCast(data.?));
        var is_active = false;
        if (states != null and states.*.data != null and states.*.size >= @sizeOf(u32)) {
            const count = states.*.size / @sizeOf(u32);
            const vals: [*]const u32 = @ptrCast(@alignCast(states.*.data));
            for (vals[0..count]) |st| {
                if (st == c.ZWLR_FOREIGN_TOPLEVEL_HANDLE_V1_STATE_ACTIVATED) {
                    is_active = true;
                    break;
                }
            }
        }
        slot.pending_activated = is_active;
    }

    fn toplevelDone(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_foreign_toplevel_handle_v1,
    ) callconv(.c) void {
        const slot: *ToplevelSlot = @ptrCast(@alignCast(data.?));
        slot.activated = slot.pending_activated;
        if (slot.owner) |owner| owner.refreshActiveToplevelTitle();
    }

    fn toplevelClosed(
        data: ?*anyopaque,
        h: ?*c.struct_zwlr_foreign_toplevel_handle_v1,
    ) callconv(.c) void {
        const slot: *ToplevelSlot = @ptrCast(@alignCast(data.?));
        const owner = slot.owner;
        if (h != null) c.zwlr_foreign_toplevel_handle_v1_destroy(h);
        slot.* = .{};
        if (owner) |o| o.refreshActiveToplevelTitle();
    }

    fn refreshActiveToplevelTitle(self: *WaylandBackend) void {
        var found = false;
        for (&self.toplevels) |*slot| {
            if (slot.handle != null and slot.activated) {
                const len: usize = slot.title_len;
                if (!std.mem.eql(u8, self.active_title[0..self.active_title_len], slot.title[0..len])) {
                    @memcpy(self.active_title[0..len], slot.title[0..len]);
                    self.active_title_len = len;
                    self.title_dirty = true;
                }
                found = true;
                break;
            }
        }
        if (!found and self.active_title_len != 0) {
            self.active_title_len = 0;
            self.title_dirty = true;
        }
    }
};
