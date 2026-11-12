const std = @import("std");
const c = @import("c");
const ProcLoader = @import("GlProcs.zig").ProcLoader;
const QuadVertex = @import("RectDraw.zig").RectDraw.QuadVertex;
const shm_draw_zig = @import("ShmDraw.zig");
const ShmDraw = shm_draw_zig.ShmDraw;
const ShmSlotState = shm_draw_zig.SlotState;
const DamageRect = shm_draw_zig.DamageRect;
const max_damage_rects = shm_draw_zig.max_damage_rects;
const Click = @import("X11Backend.zig").Click;
const KwinTitleWatcher = @import("KwinTitleWatcher.zig").KwinTitleWatcher;

const EGL_PLATFORM_WAYLAND_KHR: c.EGLenum = 0x31D8;
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const BTN_MIDDLE: u32 = 0x112;

pub const WaylandRenderMode = enum {
    shm,
    egl,
};

pub const WaylandBackend = struct {
    const max_toplevels = 64;
    const max_outputs = 16;
    const shm_slot_count = 3;

    pub const OutputSlot = struct {
        owner: ?*WaylandBackend = null,
        global_name: u32 = 0,
        bound_version: u32 = 0,
        handle: ?*c.struct_wl_output = null,
        name: [64]u8 = @splat(0),
        name_len: u8 = 0,
        scale: i32 = 1,
        ready: bool = false,

        pub fn nameSlice(self: *const OutputSlot) []const u8 {
            return self.name[0..self.name_len];
        }
    };

    const ShmBufferSlot = struct {
        wl_buffer: ?*c.struct_wl_buffer = null,
        pixel_offset: usize = 0,
        busy: bool = false,
        state: ShmSlotState = .{},
    };

    const ToplevelSlot = struct {
        owner: ?*WaylandBackend = null,
        handle: ?*c.struct_zwlr_foreign_toplevel_handle_v1 = null,
        title: [256]u8 = @splat(0),
        title_len: u16 = 0,
        pending_activated: bool = false,
        activated: bool = false,
    };

    render_mode: WaylandRenderMode = .shm,
    compositor_version: u32 = 1,

    wl_display: ?*c.struct_wl_display = null,
    wl_registry: ?*c.struct_wl_registry = null,
    wl_compositor: ?*c.struct_wl_compositor = null,
    wl_shm: ?*c.struct_wl_shm = null,
    wl_seat: ?*c.struct_wl_seat = null,
    wl_pointer: ?*c.struct_wl_pointer = null,
    wl_surface: ?*c.struct_wl_surface = null,
    frame_cb: ?*c.struct_wl_callback = null,
    egl_window: ?*c.struct_wl_egl_window = null,

    // Native `wl_shm` triple-buffered shared memory pool (`memfd_create`)
    shm_pool: ?*c.struct_wl_shm_pool = null,
    shm_map: ?*anyopaque = null,
    shm_map_bytes: usize = 0,
    shm_width: i32 = 0,
    shm_height: i32 = 0,
    shm_slots: [shm_slot_count]ShmBufferSlot = @splat(.{}),
    needs_configure_commit: bool = false,

    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    wp_viewporter: ?*c.struct_wp_viewporter = null,
    wp_viewport: ?*c.struct_wp_viewport = null,
    fractional_scale_mgr: ?*c.struct_wp_fractional_scale_manager_v1 = null,
    fractional_scale_obj: ?*c.struct_wp_fractional_scale_v1 = null,
    entered_output: ?*c.struct_wl_output = null,
    scale_120: u32 = 120,
    has_preferred_fractional_scale: bool = false,
    has_preferred_buffer_scale: bool = false,
    applied_buffer_scale: i32 = 1,
    applied_vp_w: i32 = -1,
    applied_vp_h: i32 = -1,
    outputs: [max_outputs]OutputSlot = @splat(.{}),
    bound_output: ?*c.struct_wl_output = null,
    target_output: [64]u8 = @splat(0),
    target_output_len: u8 = 0,
    surface_lost: bool = false,
    pending_surface_rebind: bool = false,
    logged_waiting_output: bool = false,

    // Native in-process Wayland clipboard (`ext-data-control-v1` -> `wlr-data-control-v1` -> `wl_data_device`)
    ext_data_manager: ?*c.struct_ext_data_control_manager_v1 = null,
    ext_data_device: ?*c.struct_ext_data_control_device_v1 = null,
    ext_data_source: ?*c.struct_ext_data_control_source_v1 = null,
    pending_ext_offer: ?*c.struct_ext_data_control_offer_v1 = null,
    ext_data_denied: bool = false,

    wlr_data_manager: ?*c.struct_zwlr_data_control_manager_v1 = null,
    wlr_data_device: ?*c.struct_zwlr_data_control_device_v1 = null,
    wlr_data_source: ?*c.struct_zwlr_data_control_source_v1 = null,
    pending_wlr_offer: ?*c.struct_zwlr_data_control_offer_v1 = null,
    wlr_data_denied: bool = false,

    wl_data_manager: ?*c.struct_wl_data_device_manager = null,
    wl_data_device: ?*c.struct_wl_data_device = null,
    wl_data_source: ?*c.struct_wl_data_source = null,
    pending_wl_offer: ?*c.struct_wl_data_offer = null,
    dnd_wl_offer: ?*c.struct_wl_data_offer = null,

    last_button_serial: u32 = 0,
    clipboard_buf: [512]u8 = @splat(0),
    clipboard_len: usize = 0,

    toplevel_manager: ?*c.struct_zwlr_foreign_toplevel_manager_v1 = null,
    toplevels: [max_toplevels]ToplevelSlot = @splat(.{}),
    has_foreign_toplevel: bool = false,
    active_title: [256]u8 = @splat(0),
    active_title_len: usize = 0,

    // Event-driven KWin Scripting + D-Bus title listener for KDE Plasma Wayland
    kwin_watcher: KwinTitleWatcher = .{},
    kwin_needs_pump: bool = true,

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
    wakeup_fd: c_int = -1,
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
        if (self.render_mode == .shm and self.wl_shm == null) return error.NoWlShm;

        // Flush seat capability, wl_output connector names, & initial toplevel advertisements
        _ = c.wl_display_roundtrip(dpy);

        if (self.hasMatchingOutput()) {
            try self.createLayerSurface();
            switch (self.render_mode) {
                .shm => {
                    try self.recreateShmBuffers();
                    self.clearTransparent();
                },
                .egl => try self.createEglContext(),
            }
        } else {
            self.surface_lost = true;
            if (self.target_output_len > 0 and !self.logged_waiting_output) {
                self.logged_waiting_output = true;
                var msg_buf: [140]u8 = undefined;
                if (std.fmt.bufPrint(
                    &msg_buf,
                    "zigbar: output '{s}' not currently connected; waiting for hotplug...\n",
                    .{self.target_output[0..self.target_output_len]},
                )) |msg| {
                    _ = c.write(2, msg.ptr, msg.len);
                } else |_| {}
            }
            if (self.render_mode == .egl) {
                try self.createEglContext();
            }
        }

        if (!self.has_foreign_toplevel) {
            if (self.kwin_watcher.init()) {
                self.title_dirty = true;
            } else {
                self.initAuxX11Watcher();
            }
        }
    }

    pub fn setTargetOutput(self: *WaylandBackend, name: []const u8) void {
        const n: u8 = @intCast(@min(name.len, self.target_output.len));
        @memcpy(self.target_output[0..n], name[0..n]);
        self.target_output_len = n;
    }

    pub fn findOutputSlot(outputs: []const OutputSlot, target: []const u8) ?usize {
        if (target.len == 0) {
            for (outputs, 0..) |*slot, idx| {
                if (slot.handle != null and slot.ready) return idx;
            }
            return null;
        }
        for (outputs, 0..) |*slot, idx| {
            if (slot.handle != null and slot.ready and std.mem.eql(u8, slot.nameSlice(), target)) {
                return idx;
            }
        }
        for (outputs, 0..) |*slot, idx| {
            if (slot.handle != null and slot.ready and std.ascii.eqlIgnoreCase(slot.nameSlice(), target)) {
                return idx;
            }
        }
        return null;
    }

    fn hasMatchingOutput(self: *const WaylandBackend) bool {
        return findOutputSlot(&self.outputs, self.target_output[0..self.target_output_len]) != null;
    }

    fn selectTargetOutput(self: *const WaylandBackend) ?*c.struct_wl_output {
        if (self.target_output_len == 0) return null;
        const idx = findOutputSlot(&self.outputs, self.target_output[0..self.target_output_len]) orelse return null;
        return self.outputs[idx].handle;
    }

    /// Computes physical buffer dimension for `logical_px` at `scale_120` (`120` = `1.0x`),
    /// rounding halfway away from zero per `fractional-scale-v1` specification.
    pub fn scaledDim(logical_px: i32, scale_120: u32) i32 {
        const l: u64 = @intCast(@max(1, logical_px));
        const s: u64 = @max(60, scale_120);
        return @intCast(@max(1, (l * s + 60) / 120));
    }

    pub fn effectiveScale120(self: *const WaylandBackend) u32 {
        if (self.wp_viewport != null) {
            return @max(60, self.scale_120);
        }
        if (self.compositor_version >= 3) {
            const int_s: u32 = @max(1, (self.scale_120 + 60) / 120);
            return int_s * 120;
        }
        return 120;
    }

    pub fn bufferSize(self: *const WaylandBackend) struct { w: i32, h: i32 } {
        const s = self.effectiveScale120();
        return .{
            .w = scaledDim(self.width, s),
            .h = scaledDim(self.height, s),
        };
    }

    fn seedInitialScaleFromOutputs(self: *WaylandBackend, chosen_output: ?*c.struct_wl_output) u32 {
        if (chosen_output) |target| {
            for (&self.outputs) |*slot| {
                if (slot.handle == target and slot.ready) {
                    return @as(u32, @intCast(@max(1, slot.scale))) * 120;
                }
            }
        }
        for (&self.outputs) |*slot| {
            if (slot.handle != null and slot.ready) {
                return @as(u32, @intCast(@max(1, slot.scale))) * 120;
            }
        }
        return 120;
    }

    fn stageSurfaceScale(self: *WaylandBackend) void {
        const surf = self.wl_surface orelse return;
        const log_w = @max(1, self.width);
        const log_h = @max(1, self.height);

        if (self.wp_viewport) |vp| {
            if (self.compositor_version >= 3 and self.applied_buffer_scale != 1) {
                c.wl_surface_set_buffer_scale(surf, 1);
                self.applied_buffer_scale = 1;
            }
            if (self.applied_vp_w != log_w or self.applied_vp_h != log_h) {
                c.wp_viewport_set_destination(vp, log_w, log_h);
                self.applied_vp_w = log_w;
                self.applied_vp_h = log_h;
            }
        } else if (self.compositor_version >= 3) {
            const int_scale: i32 = @intCast(@max(1, self.effectiveScale120() / 120));
            if (self.applied_buffer_scale != int_scale) {
                c.wl_surface_set_buffer_scale(surf, int_scale);
                self.applied_buffer_scale = int_scale;
            }
        }
    }

    fn syncEglWindow(self: *WaylandBackend) void {
        if (self.render_mode != .egl) return;
        self.stageSurfaceScale();
        if (self.egl_window) |win| {
            const buf = self.bufferSize();
            c.wl_egl_window_resize(win, buf.w, buf.h, 0, 0);
        }
    }

    fn onScaleChanged(self: *WaylandBackend) void {
        if (!self.configured or self.wl_surface == null) return;
        self.syncEglWindow();
        self.resized = true;
        self.exposed = true;
    }

    fn releaseOutputSlot(slot: *OutputSlot) void {
        if (slot.handle) |out| {
            if (slot.bound_version >= 3) {
                c.wl_output_release(out);
            } else {
                c.wl_output_destroy(out);
            }
        }
        slot.* = .{};
    }

    pub fn deinit(self: *WaylandBackend) void {
        self.kwin_watcher.deinit();
        if (self.aux_x11_dpy) |x_dpy| {
            _ = c.XCloseDisplay(x_dpy);
            self.aux_x11_dpy = null;
        }

        if (self.frame_cb) |cb| {
            c.wl_callback_destroy(cb);
            self.frame_cb = null;
        }
        self.destroyShmBuffers();

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

        if (self.fractional_scale_obj) |fs| {
            c.wp_fractional_scale_v1_destroy(fs);
            self.fractional_scale_obj = null;
        }
        if (self.wp_viewport) |vp| {
            c.wp_viewport_destroy(vp);
            self.wp_viewport = null;
        }
        if (self.layer_surface) |ls| {
            c.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.wl_surface) |surf| {
            c.wl_surface_destroy(surf);
            self.wl_surface = null;
        }
        self.bound_output = null;
        self.entered_output = null;
        for (&self.outputs) |*out_slot| {
            releaseOutputSlot(out_slot);
        }
        if (self.fractional_scale_mgr) |mgr| {
            c.wp_fractional_scale_manager_v1_destroy(mgr);
            self.fractional_scale_mgr = null;
        }
        if (self.wp_viewporter) |vpr| {
            c.wp_viewporter_destroy(vpr);
            self.wp_viewporter = null;
        }
        if (self.layer_shell) |shell| {
            c.zwlr_layer_shell_v1_destroy(shell);
            self.layer_shell = null;
        }
        self.deinitClipboard();
        if (self.wl_pointer) |ptr| {
            c.wl_pointer_destroy(ptr);
            self.wl_pointer = null;
        }
        if (self.wl_seat) |seat| {
            c.wl_seat_destroy(seat);
            self.wl_seat = null;
        }
        if (self.wl_shm) |shm| {
            c.wl_shm_destroy(shm);
            self.wl_shm = null;
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

    fn teardownLayerSurface(self: *WaylandBackend) void {
        if (self.frame_cb) |cb| {
            c.wl_callback_destroy(cb);
            self.frame_cb = null;
        }
        if (self.render_mode == .egl and self.egl_display != c.EGL_NO_DISPLAY) {
            _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.egl_context);
            if (self.egl_surface != c.EGL_NO_SURFACE) {
                _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
                self.egl_surface = c.EGL_NO_SURFACE;
            }
            if (self.egl_window) |win| {
                c.wl_egl_window_destroy(win);
                self.egl_window = null;
            }
        }
        for (&self.shm_slots) |*slot| {
            slot.busy = false;
            slot.state.invalidate();
        }
        if (self.fractional_scale_obj) |fs| {
            c.wp_fractional_scale_v1_destroy(fs);
            self.fractional_scale_obj = null;
        }
        if (self.wp_viewport) |vp| {
            c.wp_viewport_destroy(vp);
            self.wp_viewport = null;
        }
        if (self.layer_surface) |ls| {
            c.zwlr_layer_surface_v1_destroy(ls);
            self.layer_surface = null;
        }
        if (self.wl_surface) |surf| {
            c.wl_surface_destroy(surf);
            self.wl_surface = null;
        }
        self.bound_output = null;
        self.entered_output = null;
        self.has_preferred_fractional_scale = false;
        self.has_preferred_buffer_scale = false;
        self.applied_buffer_scale = 1;
        self.applied_vp_w = -1;
        self.applied_vp_h = -1;
        self.configured = false;
        self.pointer_inside = false;
        self.applied_input_height = -1;
        self.needs_configure_commit = false;
        self.surface_lost = true;
        self.pending_surface_rebind = true;
    }

    fn tryRecoverLayerSurface(self: *WaylandBackend) void {
        if (!self.surface_lost) return;
        self.pending_surface_rebind = false;
        if (!self.hasMatchingOutput()) return;

        self.createLayerSurface() catch {
            self.teardownLayerSurface();
            self.pending_surface_rebind = false;
            return;
        };

        switch (self.render_mode) {
            .shm => {
                self.recreateShmBuffers() catch {
                    self.teardownLayerSurface();
                    self.pending_surface_rebind = false;
                    return;
                };
                if (self.input_height <= 1) {
                    self.clearTransparent();
                }
            },
            .egl => {
                self.createEglSurface() catch {
                    self.teardownLayerSurface();
                    self.pending_surface_rebind = false;
                    return;
                };
            },
        }

        self.surface_lost = false;
        self.resized = true;
        self.exposed = true;
    }

    fn createLayerSurface(self: *WaylandBackend) !void {
        const dpy = self.wl_display.?;
        const comp = self.wl_compositor.?;
        const shell = self.layer_shell.?;

        const chosen_output = self.selectTargetOutput();
        self.bound_output = chosen_output;
        self.entered_output = chosen_output;
        self.scale_120 = self.seedInitialScaleFromOutputs(chosen_output);
        self.has_preferred_fractional_scale = false;
        self.has_preferred_buffer_scale = false;
        self.applied_buffer_scale = 1;
        self.applied_vp_w = -1;
        self.applied_vp_h = -1;
        self.configured = false;
        self.applied_input_height = -1;

        self.wl_surface = c.wl_compositor_create_surface(comp) orelse return error.CreateSurfaceFailed;
        _ = c.wl_surface_add_listener(self.wl_surface, &surface_listener, self);

        if (self.wp_viewporter) |vpr| {
            self.wp_viewport = c.wp_viewporter_get_viewport(vpr, self.wl_surface);
        }
        if (self.wp_viewport != null) {
            if (self.fractional_scale_mgr) |fsm| {
                self.fractional_scale_obj = c.wp_fractional_scale_manager_v1_get_fractional_scale(fsm, self.wl_surface);
                if (self.fractional_scale_obj) |fs| {
                    _ = c.wp_fractional_scale_v1_add_listener(fs, &fractional_scale_listener, self);
                }
            }
        }

        self.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            shell,
            self.wl_surface,
            chosen_output,
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

        if (self.wl_surface != null) {
            try self.createEglSurface();
        } else {
            // Surfaceless context allows shader/VBO initialization while waiting for target output hotplug
            if (c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, self.egl_context) != c.EGL_TRUE) {
                return error.EglMakeCurrentFailed;
            }
            c.glClearColor(0.0, 0.0, 0.0, 0.0);
        }
    }

    fn createEglSurface(self: *WaylandBackend) !void {
        self.stageSurfaceScale();
        const buf = self.bufferSize();
        self.egl_window = c.wl_egl_window_create(
            self.wl_surface,
            buf.w,
            buf.h,
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

    fn destroyShmBuffers(self: *WaylandBackend) void {
        for (&self.shm_slots) |*slot| {
            if (slot.wl_buffer) |buf| {
                c.wl_buffer_destroy(buf);
                slot.wl_buffer = null;
            }
            slot.busy = false;
            slot.pixel_offset = 0;
            slot.state.invalidate();
        }
        if (self.shm_pool) |pool| {
            c.wl_shm_pool_destroy(pool);
            self.shm_pool = null;
        }
        if (self.shm_map) |ptr| {
            _ = c.munmap(ptr, self.shm_map_bytes);
            self.shm_map = null;
            self.shm_map_bytes = 0;
        }
        self.shm_width = 0;
        self.shm_height = 0;
    }

    fn recreateShmBuffers(self: *WaylandBackend) !void {
        const shm = self.wl_shm orelse return error.NoWlShm;
        self.destroyShmBuffers();

        const buf = self.bufferSize();
        const w: i32 = buf.w;
        const h: i32 = buf.h;
        const stride: i32 = w * 4;
        const pixels_per_slot: usize = @intCast(w * h);
        const frame_bytes: usize = pixels_per_slot * @sizeOf(u32);
        const pool_bytes: usize = frame_bytes * shm_slot_count;

        const fd = c.memfd_create("zigbar-shm", c.MFD_CLOEXEC);
        if (fd < 0) return error.MemfdCreateFailed;
        errdefer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(pool_bytes)) < 0) {
            return error.ShmFtruncateFailed;
        }

        const mapped = c.mmap(null, pool_bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (mapped == null or @intFromPtr(mapped) == std.math.maxInt(usize)) {
            return error.ShmMmapFailed;
        }
        self.shm_map = mapped;
        self.shm_map_bytes = pool_bytes;
        errdefer {
            _ = c.munmap(mapped.?, pool_bytes);
            self.shm_map = null;
            self.shm_map_bytes = 0;
        }

        self.shm_pool = c.wl_shm_create_pool(shm, fd, @intCast(pool_bytes)) orelse return error.WlShmPoolFailed;
        // Both `mmap` and Wayland's `create_pool` hold kernel references; close extra fd immediately
        _ = c.close(fd);

        for (&self.shm_slots, 0..) |*slot, idx| {
            const byte_offset: i32 = @intCast(idx * frame_bytes);
            slot.pixel_offset = idx * pixels_per_slot;
            slot.busy = false;
            slot.state.invalidate();
            slot.wl_buffer = c.wl_shm_pool_create_buffer(
                self.shm_pool,
                byte_offset,
                w,
                h,
                stride,
                c.WL_SHM_FORMAT_ARGB8888,
            ) orelse return error.WlShmBufferFailed;
            _ = c.wl_buffer_add_listener(slot.wl_buffer, &shm_buffer_listener, slot);
        }

        self.shm_width = w;
        self.shm_height = h;
    }

    fn slotPixels(self: *const WaylandBackend, slot: *const ShmBufferSlot) []u32 {
        const pixels_per_slot: usize = @intCast(self.shm_width * self.shm_height);
        const base: [*]u32 = @ptrCast(@alignCast(self.shm_map.?));
        return base[slot.pixel_offset .. slot.pixel_offset + pixels_per_slot];
    }

    fn acquireShmSlot(self: *WaylandBackend) *ShmBufferSlot {
        for (&self.shm_slots) |*slot| {
            if (!slot.busy) return slot;
        }
        self.updateTheMessageQueue();
        for (&self.shm_slots) |*slot| {
            if (!slot.busy) return slot;
        }
        return &self.shm_slots[0];
    }

    fn damageSurface(self: *WaylandBackend, x: i32, y: i32, w: i32, h: i32) void {
        const surf = self.wl_surface orelse return;
        if (self.compositor_version >= 4) {
            c.wl_surface_damage_buffer(surf, x, y, w, h);
        } else {
            const s: i64 = @intCast(self.effectiveScale120());
            if (s == 120) {
                c.wl_surface_damage(surf, x, y, w, h);
            } else {
                const lx0: i32 = @intCast(@divFloor(@as(i64, x) * 120, s));
                const ly0: i32 = @intCast(@divFloor(@as(i64, y) * 120, s));
                const lx1: i32 = @intCast(@divFloor(@as(i64, x + w) * 120 + s - 1, s));
                const ly1: i32 = @intCast(@divFloor(@as(i64, y + h) * 120 + s - 1, s));
                c.wl_surface_damage(surf, lx0, ly0, @max(1, lx1 - lx0), @max(1, ly1 - ly0));
            }
        }
    }

    pub fn presentShm(
        self: *WaylandBackend,
        bg_count: usize,
        quads: []const QuadVertex,
        opacity: f32,
        request_frame_sync: bool,
    ) !void {
        const surf = self.wl_surface orelse return;
        const dpy = self.wl_display orelse return;

        const buf = self.bufferSize();
        const target_w = buf.w;
        const target_h = buf.h;
        if (self.shm_pool == null or self.shm_width != target_w or self.shm_height != target_h) {
            try self.recreateShmBuffers();
        }

        const slot = self.acquireShmSlot();
        var dmg: [max_damage_rects]DamageRect = undefined;
        const dmg_count = ShmDraw.renderSlot(
            &slot.state,
            self.slotPixels(slot),
            self.shm_width,
            self.shm_height,
            bg_count,
            quads,
            opacity,
            &dmg,
        );

        if (dmg_count == 0) {
            if (self.needs_configure_commit) {
                self.needs_configure_commit = false;
                self.stageSurfaceScale();
                c.wl_surface_commit(surf);
                _ = c.wl_display_flush(dpy);
            }
            return;
        }

        if (request_frame_sync and self.frame_cb == null) {
            self.frame_cb = c.wl_surface_frame(surf);
            if (self.frame_cb) |cb| {
                _ = c.wl_callback_add_listener(cb, &frame_listener, self);
            }
        }

        slot.busy = true;
        self.needs_configure_commit = false;
        self.stageSurfaceScale();
        c.wl_surface_attach(surf, slot.wl_buffer, 0, 0);
        for (dmg[0..dmg_count]) |r| {
            self.damageSurface(r.x, r.y, r.w, r.h);
        }
        c.wl_surface_commit(surf);
        _ = c.wl_display_flush(dpy);
    }

    pub fn waitForFrameSync(self: *WaylandBackend) void {
        if (self.render_mode != .shm) return;
        var spins: u8 = 0;
        while (self.running and self.frame_cb != null and spins < 4) : (spins += 1) {
            self.waitForEventsOrTimeout(34);
            if (self.wl_display) |wl_dpy| {
                if (c.wl_display_dispatch_pending(wl_dpy) < 0) {
                    self.running = false;
                    break;
                }
            }
            if (self.clicked or self.resized) break;
        }
    }

    pub fn clearTransparent(self: *WaylandBackend) void {
        switch (self.render_mode) {
            .egl => {
                if (self.egl_surface != c.EGL_NO_SURFACE) {
                    c.glClear(c.GL_COLOR_BUFFER_BIT);
                    self.swapBuffers();
                }
            },
            .shm => {
                const surf = self.wl_surface orelse return;
                const dpy = self.wl_display orelse return;
                if (self.frame_cb) |cb| {
                    c.wl_callback_destroy(cb);
                    self.frame_cb = null;
                }
                const buf = self.bufferSize();
                const target_w = buf.w;
                const target_h = buf.h;
                if (self.shm_pool == null or self.shm_width != target_w or self.shm_height != target_h) {
                    self.recreateShmBuffers() catch return;
                }
                for (&self.shm_slots) |*s| s.state.invalidate();
                const slot = self.acquireShmSlot();
                @memset(self.slotPixels(slot), 0);
                slot.state.width = self.shm_width;
                slot.state.height = self.shm_height;
                slot.state.last_opacity_u8 = 0;
                slot.busy = true;
                self.needs_configure_commit = false;
                self.stageSurfaceScale();
                c.wl_surface_attach(surf, slot.wl_buffer, 0, 0);
                self.damageSurface(0, 0, self.shm_width, self.shm_height);
                c.wl_surface_commit(surf);
                _ = c.wl_display_flush(dpy);
            },
        }
    }

    pub fn updateViewport(self: *const WaylandBackend) void {
        if (self.render_mode == .egl) {
            const buf = self.bufferSize();
            c.glViewport(0, 0, buf.w, buf.h);
        }
    }

    pub fn swapBuffers(self: *const WaylandBackend) void {
        if (self.render_mode == .egl and self.egl_display != c.EGL_NO_DISPLAY and self.egl_surface != c.EGL_NO_SURFACE) {
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

            var pfds: [2]c.struct_pollfd = undefined;
            pfds[0] = .{
                .fd = c.wl_display_get_fd(wl_dpy),
                .events = c.POLLIN,
                .revents = 0,
            };
            var nfds: c.nfds_t = 1;
            const kwin_fd = self.kwin_watcher.fd();
            if (kwin_fd >= 0) {
                pfds[1] = .{
                    .fd = kwin_fd,
                    .events = c.POLLIN,
                    .revents = 0,
                };
                nfds = 2;
            }

            const ready = c.poll(&pfds, nfds, 0);
            if (ready > 0 and (pfds[0].revents & (c.POLLIN | c.POLLERR | c.POLLHUP)) != 0) {
                if (c.wl_display_read_events(wl_dpy) < 0) {
                    self.running = false;
                    return;
                }
            } else {
                c.wl_display_cancel_read(wl_dpy);
            }
            if (ready > 0 and nfds == 2 and pfds[1].revents != 0) {
                self.kwin_needs_pump = true;
            }

            if (c.wl_display_dispatch_pending(wl_dpy) < 0) {
                self.running = false;
                return;
            }
            if (self.surface_lost and self.pending_surface_rebind) {
                self.tryRecoverLayerSurface();
            }
        }

        if (self.kwin_watcher.active and self.kwin_needs_pump) {
            self.kwin_needs_pump = false;
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

    /// `timeout_ms < 0` sleeps indefinitely in kernel `poll()` until an input/compositor/title/signal event arrives.
    pub fn waitForEventsOrTimeout(self: *WaylandBackend, timeout_ms: i32) void {
        const wl_dpy = self.wl_display orelse return;
        if (timeout_ms == 0) {
            _ = c.wl_display_flush(wl_dpy);
            if (self.aux_x11_dpy) |x_dpy| _ = c.XFlush(x_dpy);
            return;
        }
        if (self.surface_lost and self.pending_surface_rebind and self.hasMatchingOutput()) {
            return;
        }

        if (self.kwin_watcher.active and self.kwin_needs_pump) {
            self.kwin_needs_pump = false;
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

        var pfds: [4]c.struct_pollfd = undefined;
        pfds[0] = .{
            .fd = c.wl_display_get_fd(wl_dpy),
            .events = c.POLLIN,
            .revents = 0,
        };
        var nfds: c.nfds_t = 1;
        var kwin_idx: ?usize = null;
        const kwin_fd = self.kwin_watcher.fd();
        if (kwin_fd >= 0) {
            kwin_idx = nfds;
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
        var wake_idx: ?usize = null;
        if (self.wakeup_fd >= 0) {
            wake_idx = nfds;
            pfds[nfds] = .{
                .fd = self.wakeup_fd,
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
        if (ready > 0) {
            if (kwin_idx) |ki| {
                if (pfds[ki].revents != 0) {
                    self.kwin_needs_pump = true;
                }
            }
            if (wake_idx) |wi| {
                if (pfds[wi].revents != 0) {
                    var drain: [32]u8 = undefined;
                    _ = c.read(self.wakeup_fd, &drain, drain.len);
                }
            }
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
            const bound_ver = @min(version, 6);
            self.compositor_version = bound_ver;
            self.wl_compositor = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_compositor_interface,
                bound_ver,
            ));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.wl_shm = @ptrCast(c.wl_registry_bind(
                registry,
                name,
                &c.wl_shm_interface,
                1,
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
        } else if (std.mem.eql(u8, iface, "ext_data_control_manager_v1")) {
            if (self.ext_data_manager == null) {
                self.ext_data_manager = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.ext_data_control_manager_v1_interface,
                    1,
                ));
            }
        } else if (std.mem.eql(u8, iface, "zwlr_data_control_manager_v1")) {
            if (self.wlr_data_manager == null) {
                self.wlr_data_manager = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.zwlr_data_control_manager_v1_interface,
                    1,
                ));
            }
        } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
            if (self.wl_data_manager == null) {
                self.wl_data_manager = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.wl_data_device_manager_interface,
                    1,
                ));
            }
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            if (self.wp_viewporter == null) {
                self.wp_viewporter = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.wp_viewporter_interface,
                    1,
                ));
            }
        } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            if (self.fractional_scale_mgr == null) {
                self.fractional_scale_mgr = @ptrCast(c.wl_registry_bind(
                    registry,
                    name,
                    &c.wp_fractional_scale_manager_v1_interface,
                    1,
                ));
            }
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            for (&self.outputs) |*slot| {
                if (slot.handle == null) {
                    const bound_ver = @min(version, 4);
                    const out_handle: ?*c.struct_wl_output = @ptrCast(c.wl_registry_bind(
                        registry,
                        name,
                        &c.wl_output_interface,
                        bound_ver,
                    ));
                    if (out_handle) |out| {
                        slot.* = .{
                            .owner = self,
                            .global_name = name,
                            .bound_version = bound_ver,
                            .handle = out,
                            .scale = 1,
                            .ready = (bound_ver < 2),
                        };
                        _ = c.wl_output_add_listener(out, &output_listener, slot);
                        if (slot.ready and self.surface_lost) {
                            self.pending_surface_rebind = true;
                        }
                    }
                    break;
                }
            }
        }
    }

    fn registryGlobalRemove(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        for (&self.outputs) |*slot| {
            if (slot.handle != null and slot.global_name == name) {
                if (self.entered_output == slot.handle) {
                    self.entered_output = null;
                }
                if (self.bound_output != null and slot.handle == self.bound_output) {
                    self.teardownLayerSurface();
                }
                releaseOutputSlot(slot);
                break;
            }
        }
    }

    const output_listener = c.struct_wl_output_listener{
        .geometry = outputGeometry,
        .mode = outputMode,
        .done = outputDone,
        .scale = outputScale,
        .name = outputName,
        .description = outputDescription,
    };

    fn outputGeometry(
        _: ?*anyopaque,
        _: ?*c.struct_wl_output,
        _: i32,
        _: i32,
        _: i32,
        _: i32,
        _: i32,
        _: [*c]const u8,
        _: [*c]const u8,
        _: i32,
    ) callconv(.c) void {}

    fn outputMode(
        _: ?*anyopaque,
        _: ?*c.struct_wl_output,
        _: u32,
        _: i32,
        _: i32,
        _: i32,
    ) callconv(.c) void {}

    fn outputDone(data: ?*anyopaque, _: ?*c.struct_wl_output) callconv(.c) void {
        const slot: *OutputSlot = @ptrCast(@alignCast(data.?));
        slot.ready = true;
        if (slot.owner) |owner| {
            if (owner.surface_lost) {
                owner.pending_surface_rebind = true;
            } else if (!owner.has_preferred_fractional_scale and !owner.has_preferred_buffer_scale) {
                const active_out = owner.entered_output orelse owner.bound_output;
                if (active_out == null or active_out == slot.handle) {
                    const next_s: u32 = @as(u32, @intCast(@max(1, slot.scale))) * 120;
                    if (next_s != owner.scale_120) {
                        owner.scale_120 = next_s;
                        owner.onScaleChanged();
                    }
                }
            }
        }
    }

    const surface_listener = c.struct_wl_surface_listener{
        .enter = surfaceEnter,
        .leave = surfaceLeave,
        .preferred_buffer_scale = surfacePreferredBufferScale,
        .preferred_buffer_transform = surfacePreferredBufferTransform,
    };

    fn surfaceEnter(
        data: ?*anyopaque,
        _: ?*c.struct_wl_surface,
        output: ?*c.struct_wl_output,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.entered_output = output;
        if (self.has_preferred_fractional_scale or self.has_preferred_buffer_scale) return;
        if (output) |out| {
            for (&self.outputs) |*slot| {
                if (slot.handle == out and slot.ready) {
                    const next_s: u32 = @as(u32, @intCast(@max(1, slot.scale))) * 120;
                    if (next_s != self.scale_120) {
                        self.scale_120 = next_s;
                        self.onScaleChanged();
                    }
                    break;
                }
            }
        }
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        _: ?*c.struct_wl_surface,
        output: ?*c.struct_wl_output,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.entered_output == output) {
            self.entered_output = null;
        }
    }

    fn surfacePreferredBufferScale(
        data: ?*anyopaque,
        _: ?*c.struct_wl_surface,
        factor: i32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (factor <= 0) return;
        self.has_preferred_buffer_scale = true;
        if (self.has_preferred_fractional_scale) return;
        const next_s: u32 = @as(u32, @intCast(factor)) * 120;
        if (next_s != self.scale_120) {
            self.scale_120 = next_s;
            self.onScaleChanged();
        }
    }

    fn surfacePreferredBufferTransform(
        _: ?*anyopaque,
        _: ?*c.struct_wl_surface,
        _: u32,
    ) callconv(.c) void {}

    const fractional_scale_listener = c.struct_wp_fractional_scale_v1_listener{
        .preferred_scale = fractionalScalePreferred,
    };

    fn fractionalScalePreferred(
        data: ?*anyopaque,
        _: ?*c.struct_wp_fractional_scale_v1,
        scale: u32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (scale == 0) return;
        self.has_preferred_fractional_scale = true;
        if (scale != self.scale_120) {
            self.scale_120 = scale;
            self.onScaleChanged();
        }
    }

    fn outputScale(data: ?*anyopaque, _: ?*c.struct_wl_output, factor: i32) callconv(.c) void {
        const slot: *OutputSlot = @ptrCast(@alignCast(data.?));
        slot.scale = @max(1, factor);
    }

    fn outputName(data: ?*anyopaque, _: ?*c.struct_wl_output, name_ptr: [*c]const u8) callconv(.c) void {
        const slot: *OutputSlot = @ptrCast(@alignCast(data.?));
        if (name_ptr == null) return;
        const raw = std.mem.span(name_ptr);
        const n: u8 = @intCast(@min(raw.len, slot.name.len));
        @memcpy(slot.name[0..n], raw[0..n]);
        slot.name_len = n;
    }

    fn outputDescription(_: ?*anyopaque, _: ?*c.struct_wl_output, _: [*c]const u8) callconv(.c) void {}

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
            self.syncEglWindow();
            if (width_changed and self.applied_input_height == 1) {
                self.stageInputRegion(1);
            }
            if (self.configured) {
                self.resized = true;
            }
        }
        self.needs_configure_commit = true;
        self.configured = true;
        self.exposed = true;
    }

    const shm_buffer_listener = c.struct_wl_buffer_listener{
        .release = shmBufferRelease,
    };

    fn shmBufferRelease(data: ?*anyopaque, _: ?*c.struct_wl_buffer) callconv(.c) void {
        const slot: *ShmBufferSlot = @ptrCast(@alignCast(data.?));
        slot.busy = false;
    }

    const frame_listener = c.struct_wl_callback_listener{
        .done = frameDone,
    };

    fn frameDone(data: ?*anyopaque, cb: ?*c.struct_wl_callback, _: u32) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (cb != null) c.wl_callback_destroy(cb);
        if (self.frame_cb == cb) {
            self.frame_cb = null;
        }
    }

    fn layerSurfaceClosed(data: ?*anyopaque, ls: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.layer_surface == null or ls != self.layer_surface) return;
        self.teardownLayerSurface();
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
        serial: u32,
        _: u32,
        button: u32,
        state: u32,
    ) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.last_button_serial = serial;

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

    // --- Native In-Process Wayland Clipboard ---

    const clipboard_mimes = [_][*:0]const u8{
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "STRING",
        "TEXT",
    };

    pub fn setClipboard(self: *WaylandBackend, text: []const u8) void {
        if (text.len == 0) return;
        const copy_len = @min(text.len, self.clipboard_buf.len);
        @memcpy(self.clipboard_buf[0..copy_len], text[0..copy_len]);
        self.clipboard_len = copy_len;

        self.applyWaylandSelection();
    }

    fn applyWaylandSelection(self: *WaylandBackend) void {
        const dpy = self.wl_display orelse return;
        const seat = self.wl_seat orelse return;

        // Tier 1: `ext_data_control_manager_v1` (KWin 6+, Sway, Hyprland — works without stealing keyboard focus)
        if (!self.ext_data_denied) {
            if (self.ext_data_manager) |mgr| {
                if (self.ext_data_source) |old| {
                    c.ext_data_control_source_v1_destroy(old);
                    self.ext_data_source = null;
                }
                if (self.ext_data_device == null) {
                    self.ext_data_device = c.ext_data_control_manager_v1_get_data_device(mgr, seat);
                    if (self.ext_data_device) |dev| {
                        _ = c.ext_data_control_device_v1_add_listener(dev, &ext_device_listener, self);
                    }
                }
                if (self.ext_data_device) |dev| {
                    if (c.ext_data_control_manager_v1_create_data_source(mgr)) |src| {
                        self.ext_data_source = src;
                        _ = c.ext_data_control_source_v1_add_listener(src, &ext_source_listener, self);
                        for (clipboard_mimes) |mime| {
                            c.ext_data_control_source_v1_offer(src, mime);
                        }
                        c.ext_data_control_device_v1_set_selection(dev, src);
                        _ = c.wl_display_flush(dpy);
                        return;
                    }
                }
            }
        }

        // Tier 2: `zwlr_data_control_manager_v1` (wlroots compositors without ext-data-control)
        if (!self.wlr_data_denied) {
            if (self.wlr_data_manager) |mgr| {
                if (self.wlr_data_source) |old| {
                    c.zwlr_data_control_source_v1_destroy(old);
                    self.wlr_data_source = null;
                }
                if (self.wlr_data_device == null) {
                    self.wlr_data_device = c.zwlr_data_control_manager_v1_get_data_device(mgr, seat);
                    if (self.wlr_data_device) |dev| {
                        _ = c.zwlr_data_control_device_v1_add_listener(dev, &wlr_device_listener, self);
                    }
                }
                if (self.wlr_data_device) |dev| {
                    if (c.zwlr_data_control_manager_v1_create_data_source(mgr)) |src| {
                        self.wlr_data_source = src;
                        _ = c.zwlr_data_control_source_v1_add_listener(src, &wlr_source_listener, self);
                        for (clipboard_mimes) |mime| {
                            c.zwlr_data_control_source_v1_offer(src, mime);
                        }
                        c.zwlr_data_control_device_v1_set_selection(dev, src);
                        _ = c.wl_display_flush(dpy);
                        return;
                    }
                }
            }
        }

        // Tier 3: Core `wl_data_device_manager` fallback using the pointer click serial
        if (self.wl_data_manager) |mgr| {
            if (self.wl_data_source) |old| {
                c.wl_data_source_destroy(old);
                self.wl_data_source = null;
            }
            if (self.wl_data_device == null) {
                self.wl_data_device = c.wl_data_device_manager_get_data_device(mgr, seat);
                if (self.wl_data_device) |dev| {
                    _ = c.wl_data_device_add_listener(dev, &wl_device_listener, self);
                }
            }
            if (self.wl_data_device) |dev| {
                if (c.wl_data_device_manager_create_data_source(mgr)) |src| {
                    self.wl_data_source = src;
                    _ = c.wl_data_source_add_listener(src, &wl_source_listener, self);
                    for (clipboard_mimes) |mime| {
                        c.wl_data_source_offer(src, mime);
                    }
                    c.wl_data_device_set_selection(dev, src, self.last_button_serial);
                    _ = c.wl_display_flush(dpy);
                }
            }
        }
    }

    fn destroyExtDataDevice(self: *WaylandBackend) void {
        if (self.pending_ext_offer) |o| {
            c.ext_data_control_offer_v1_destroy(o);
            self.pending_ext_offer = null;
        }
        if (self.ext_data_source) |src| {
            c.ext_data_control_source_v1_destroy(src);
            self.ext_data_source = null;
        }
        if (self.ext_data_device) |dev| {
            c.ext_data_control_device_v1_destroy(dev);
            self.ext_data_device = null;
        }
    }

    fn destroyWlrDataDevice(self: *WaylandBackend) void {
        if (self.pending_wlr_offer) |o| {
            c.zwlr_data_control_offer_v1_destroy(o);
            self.pending_wlr_offer = null;
        }
        if (self.wlr_data_source) |src| {
            c.zwlr_data_control_source_v1_destroy(src);
            self.wlr_data_source = null;
        }
        if (self.wlr_data_device) |dev| {
            c.zwlr_data_control_device_v1_destroy(dev);
            self.wlr_data_device = null;
        }
    }

    fn destroyWlDataDevice(self: *WaylandBackend) void {
        if (self.pending_wl_offer) |o| {
            c.wl_data_offer_destroy(o);
            self.pending_wl_offer = null;
        }
        if (self.dnd_wl_offer) |o| {
            c.wl_data_offer_destroy(o);
            self.dnd_wl_offer = null;
        }
        if (self.wl_data_source) |src| {
            c.wl_data_source_destroy(src);
            self.wl_data_source = null;
        }
        if (self.wl_data_device) |dev| {
            c.wl_data_device_destroy(dev);
            self.wl_data_device = null;
        }
    }

    fn deinitClipboard(self: *WaylandBackend) void {
        self.destroyExtDataDevice();
        self.destroyWlrDataDevice();
        self.destroyWlDataDevice();
        if (self.ext_data_manager) |mgr| {
            c.ext_data_control_manager_v1_destroy(mgr);
            self.ext_data_manager = null;
        }
        if (self.wlr_data_manager) |mgr| {
            c.zwlr_data_control_manager_v1_destroy(mgr);
            self.wlr_data_manager = null;
        }
        if (self.wl_data_manager) |mgr| {
            c.wl_data_device_manager_destroy(mgr);
            self.wl_data_manager = null;
        }
    }

    fn writeClipboardFd(fd: i32, bytes: []const u8) void {
        if (fd < 0) return;
        defer _ = c.close(fd);
        if (bytes.len == 0) return;

        const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        if (flags >= 0) {
            _ = c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
        }
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = c.write(fd, bytes[written..].ptr, bytes.len - written);
            if (rc <= 0) break;
            written += @intCast(rc);
        }
    }

    const ext_offer_listener = c.struct_ext_data_control_offer_v1_listener{
        .offer = extOfferMime,
    };
    fn extOfferMime(_: ?*anyopaque, _: ?*c.struct_ext_data_control_offer_v1, _: [*c]const u8) callconv(.c) void {}

    const ext_device_listener = c.struct_ext_data_control_device_v1_listener{
        .data_offer = extDeviceDataOffer,
        .selection = extDeviceSelection,
        .finished = extDeviceFinished,
        .primary_selection = extDevicePrimarySelection,
    };

    fn extDeviceDataOffer(
        data: ?*anyopaque,
        _: ?*c.struct_ext_data_control_device_v1,
        offer: ?*c.struct_ext_data_control_offer_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_ext_offer) |prev| c.ext_data_control_offer_v1_destroy(prev);
        self.pending_ext_offer = offer;
        if (offer) |o| {
            _ = c.ext_data_control_offer_v1_add_listener(o, &ext_offer_listener, self);
        }
    }

    fn extDeviceSelection(
        data: ?*anyopaque,
        _: ?*c.struct_ext_data_control_device_v1,
        offer: ?*c.struct_ext_data_control_offer_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_ext_offer == offer) self.pending_ext_offer = null;
        if (offer) |o| c.ext_data_control_offer_v1_destroy(o);
    }

    fn extDevicePrimarySelection(
        data: ?*anyopaque,
        _: ?*c.struct_ext_data_control_device_v1,
        offer: ?*c.struct_ext_data_control_offer_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_ext_offer == offer) self.pending_ext_offer = null;
        if (offer) |o| c.ext_data_control_offer_v1_destroy(o);
    }

    fn extDeviceFinished(data: ?*anyopaque, _: ?*c.struct_ext_data_control_device_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.destroyExtDataDevice();
        self.ext_data_denied = true;
        if (self.clipboard_len > 0) self.applyWaylandSelection();
    }

    const ext_source_listener = c.struct_ext_data_control_source_v1_listener{
        .send = extSourceSend,
        .cancelled = extSourceCancelled,
    };

    fn extSourceSend(
        data: ?*anyopaque,
        _: ?*c.struct_ext_data_control_source_v1,
        _: [*c]const u8,
        fd: i32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        writeClipboardFd(fd, self.clipboard_buf[0..self.clipboard_len]);
    }

    fn extSourceCancelled(data: ?*anyopaque, src: ?*c.struct_ext_data_control_source_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.ext_data_source == src) {
            self.destroyExtDataDevice(); // Unsubscribes from future desktop Ctrl+C events immediately
        } else if (src != null) {
            c.ext_data_control_source_v1_destroy(src);
        }
    }

    const wlr_offer_listener = c.struct_zwlr_data_control_offer_v1_listener{
        .offer = wlrOfferMime,
    };
    fn wlrOfferMime(_: ?*anyopaque, _: ?*c.struct_zwlr_data_control_offer_v1, _: [*c]const u8) callconv(.c) void {}

    const wlr_device_listener = c.struct_zwlr_data_control_device_v1_listener{
        .data_offer = wlrDeviceDataOffer,
        .selection = wlrDeviceSelection,
        .finished = wlrDeviceFinished,
    };

    fn wlrDeviceDataOffer(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_data_control_device_v1,
        offer: ?*c.struct_zwlr_data_control_offer_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_wlr_offer) |prev| c.zwlr_data_control_offer_v1_destroy(prev);
        self.pending_wlr_offer = offer;
        if (offer) |o| {
            _ = c.zwlr_data_control_offer_v1_add_listener(o, &wlr_offer_listener, self);
        }
    }

    fn wlrDeviceSelection(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_data_control_device_v1,
        offer: ?*c.struct_zwlr_data_control_offer_v1,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_wlr_offer == offer) self.pending_wlr_offer = null;
        if (offer) |o| c.zwlr_data_control_offer_v1_destroy(o);
    }

    fn wlrDeviceFinished(data: ?*anyopaque, _: ?*c.struct_zwlr_data_control_device_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        self.destroyWlrDataDevice();
        self.wlr_data_denied = true;
        if (self.clipboard_len > 0) self.applyWaylandSelection();
    }

    const wlr_source_listener = c.struct_zwlr_data_control_source_v1_listener{
        .send = wlrSourceSend,
        .cancelled = wlrSourceCancelled,
    };

    fn wlrSourceSend(
        data: ?*anyopaque,
        _: ?*c.struct_zwlr_data_control_source_v1,
        _: [*c]const u8,
        fd: i32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        writeClipboardFd(fd, self.clipboard_buf[0..self.clipboard_len]);
    }

    fn wlrSourceCancelled(data: ?*anyopaque, src: ?*c.struct_zwlr_data_control_source_v1) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.wlr_data_source == src) {
            self.destroyWlrDataDevice();
        } else if (src != null) {
            c.zwlr_data_control_source_v1_destroy(src);
        }
    }

    const wl_offer_listener = c.struct_wl_data_offer_listener{
        .offer = wlOfferMime,
    };
    fn wlOfferMime(_: ?*anyopaque, _: ?*c.struct_wl_data_offer, _: [*c]const u8) callconv(.c) void {}

    const wl_device_listener = c.struct_wl_data_device_listener{
        .data_offer = wlDeviceDataOffer,
        .enter = wlDeviceEnter,
        .leave = wlDeviceLeave,
        .motion = wlDeviceMotion,
        .drop = wlDeviceDrop,
        .selection = wlDeviceSelection,
    };

    fn wlDeviceDataOffer(
        data: ?*anyopaque,
        _: ?*c.struct_wl_data_device,
        offer: ?*c.struct_wl_data_offer,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_wl_offer) |prev| c.wl_data_offer_destroy(prev);
        self.pending_wl_offer = offer;
        if (offer) |o| {
            _ = c.wl_data_offer_add_listener(o, &wl_offer_listener, self);
        }
    }

    fn wlDeviceEnter(
        data: ?*anyopaque,
        _: ?*c.struct_wl_data_device,
        _: u32,
        _: ?*c.struct_wl_surface,
        _: c.wl_fixed_t,
        _: c.wl_fixed_t,
        offer: ?*c.struct_wl_data_offer,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_wl_offer == offer) self.pending_wl_offer = null;
        if (self.dnd_wl_offer != null and self.dnd_wl_offer != offer) {
            c.wl_data_offer_destroy(self.dnd_wl_offer);
        }
        self.dnd_wl_offer = offer;
    }

    fn wlDeviceLeave(data: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.dnd_wl_offer) |o| {
            c.wl_data_offer_destroy(o);
            self.dnd_wl_offer = null;
        }
    }

    fn wlDeviceMotion(_: ?*anyopaque, _: ?*c.struct_wl_data_device, _: u32, _: c.wl_fixed_t, _: c.wl_fixed_t) callconv(.c) void {}
    fn wlDeviceDrop(_: ?*anyopaque, _: ?*c.struct_wl_data_device) callconv(.c) void {}

    fn wlDeviceSelection(
        data: ?*anyopaque,
        _: ?*c.struct_wl_data_device,
        offer: ?*c.struct_wl_data_offer,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.pending_wl_offer == offer) self.pending_wl_offer = null;
        if (offer) |o| c.wl_data_offer_destroy(o);
    }

    const wl_source_listener = c.struct_wl_data_source_listener{
        .target = wlSourceTarget,
        .send = wlSourceSend,
        .cancelled = wlSourceCancelled,
    };

    fn wlSourceTarget(_: ?*anyopaque, _: ?*c.struct_wl_data_source, _: [*c]const u8) callconv(.c) void {}

    fn wlSourceSend(
        data: ?*anyopaque,
        _: ?*c.struct_wl_data_source,
        _: [*c]const u8,
        fd: i32,
    ) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        writeClipboardFd(fd, self.clipboard_buf[0..self.clipboard_len]);
    }

    fn wlSourceCancelled(data: ?*anyopaque, src: ?*c.struct_wl_data_source) callconv(.c) void {
        const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
        if (self.wl_data_source == src) {
            self.destroyWlDataDevice();
        } else if (src != null) {
            c.wl_data_source_destroy(src);
        }
    }
};

test "WaylandBackend.findOutputSlot matches default, exact, and case-insensitive connectors" {
    const dummy_a: *c.struct_wl_output = @ptrFromInt(0x1000);
    const dummy_b: *c.struct_wl_output = @ptrFromInt(0x2000);
    const dummy_c: *c.struct_wl_output = @ptrFromInt(0x3000);

    var slots: [4]WaylandBackend.OutputSlot = @splat(.{});
    // Slot 0: bound but not yet `done` (`ready == false`)
    slots[0].handle = dummy_a;
    slots[0].ready = false;
    @memcpy(slots[0].name[0..4], "DP-1");
    slots[0].name_len = 4;

    // Slot 1: ready `eDP-1`
    slots[1].handle = dummy_b;
    slots[1].ready = true;
    @memcpy(slots[1].name[0..5], "eDP-1");
    slots[1].name_len = 5;

    // Slot 2: ready `HDMI-A-1`
    slots[2].handle = dummy_c;
    slots[2].ready = true;
    @memcpy(slots[2].name[0..8], "HDMI-A-1");
    slots[2].name_len = 8;

    // Empty target picks first ready output (skips unready slot 0 -> picks slot 1)
    try std.testing.expectEqual(@as(?usize, 1), WaylandBackend.findOutputSlot(&slots, ""));
    // Exact match
    try std.testing.expectEqual(@as(?usize, 2), WaylandBackend.findOutputSlot(&slots, "HDMI-A-1"));
    // Case-insensitive match
    try std.testing.expectEqual(@as(?usize, 1), WaylandBackend.findOutputSlot(&slots, "edp-1"));
    // Unready output is ignored until `wl_output.done`
    try std.testing.expectEqual(@as(?usize, null), WaylandBackend.findOutputSlot(&slots, "DP-1"));
    // Disconnected connector returns null
    try std.testing.expectEqual(@as(?usize, null), WaylandBackend.findOutputSlot(&slots, "DP-9"));
}

test "WaylandBackend.scaledDim computes exact integer and fractional HiDPI buffer dimensions" {
    // 1.00x (`120 / 120`)
    try std.testing.expectEqual(@as(i32, 1920), WaylandBackend.scaledDim(1920, 120));
    try std.testing.expectEqual(@as(i32, 17), WaylandBackend.scaledDim(17, 120));

    // 1.25x (`150 / 120`): 1920 * 1.25 = 2400; 17 * 1.25 = 21.25 -> 21
    try std.testing.expectEqual(@as(i32, 2400), WaylandBackend.scaledDim(1920, 150));
    try std.testing.expectEqual(@as(i32, 21), WaylandBackend.scaledDim(17, 150));

    // 1.50x (`180 / 120`): 1280 * 1.5 = 1920; 17 * 1.5 = 25.5 -> 26 (halfway away from zero)
    try std.testing.expectEqual(@as(i32, 1920), WaylandBackend.scaledDim(1280, 180));
    try std.testing.expectEqual(@as(i32, 26), WaylandBackend.scaledDim(17, 180));

    // 1.75x (`210 / 120`): 1920 * 1.75 = 3360; 17 * 1.75 = 29.75 -> 30
    try std.testing.expectEqual(@as(i32, 3360), WaylandBackend.scaledDim(1920, 210));
    try std.testing.expectEqual(@as(i32, 30), WaylandBackend.scaledDim(17, 210));

    // 2.00x (`240 / 120`) and 3.00x (`360 / 120`)
    try std.testing.expectEqual(@as(i32, 3840), WaylandBackend.scaledDim(1920, 240));
    try std.testing.expectEqual(@as(i32, 34), WaylandBackend.scaledDim(17, 240));
    try std.testing.expectEqual(@as(i32, 51), WaylandBackend.scaledDim(17, 360));
}
