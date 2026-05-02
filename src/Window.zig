const std = @import("std");

// Import C headers
pub const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glxext.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/extensions/Xrender.h");
    @cInclude("X11/Xutil.h");
});

pub const Window = struct {
    x_screen: i32 = 0,
    del_atom: c.Atom = 0,
    cmap: c.Colormap = 0,
    display: ?*c.Display = null,
    visual: ?*c.XVisualInfo = null,
    pict_format: ?*c.XRenderPictFormat = null,
    fbconfigs: ?[*c]c.GLXFBConfig = null,
    fbconfig: c.GLXFBConfig = null,
    num_fbconfigs: i32 = 0,
    render_context: c.GLXContext = null,
    root: c.Window = 0,
    handle: c.Window = 0,
    glx_handle: c.GLXWindow = 0,

    width: i32 = 100,
    height: i32 = 100,
    x: i32 = 100,
    y: i32 = 100,

    running: bool = true,
    docked: bool = false,
    clicked: bool = false,
    last_click: Click = .{ .x = 0, .y = 0, .button = 0 },

    const Click = struct {
        x: i32,
        y: i32,
        button: u32,
    };

    pub fn deinit(self: *Window) void {
        if (self.display) |dpy| {
            _ = c.glXMakeCurrent(dpy, 0, null);
            if (self.render_context != null) c.glXDestroyContext(dpy, self.render_context);
            if (self.handle != 0) _ = c.XDestroyWindow(dpy, self.handle);
            _ = c.XCloseDisplay(dpy);
        }
    }

    pub fn createTheWindow(self: *Window) !void {
        self.display = c.XOpenDisplay(null) orelse return error.XOpenDisplayFailed;
        const dpy = self.display.?;

        self.x_screen = c.DefaultScreen(dpy);
        self.root = c.RootWindow(dpy, self.x_screen);

        const vis_data = [_]i32{
            c.GLX_RENDER_TYPE,   c.GLX_RGBA_BIT,
            c.GLX_DRAWABLE_TYPE, c.GLX_WINDOW_BIT,
            c.GLX_DOUBLEBUFFER,  c.False,
            c.GLX_RED_SIZE,      8,
            c.GLX_GREEN_SIZE,    8,
            c.GLX_BLUE_SIZE,     8,
            c.GLX_ALPHA_SIZE,    8,
            c.GLX_DEPTH_SIZE,    16,
            c.None,
        };

        self.fbconfigs = c.glXChooseFBConfig(dpy, self.x_screen, &vis_data, &self.num_fbconfigs);
        if (self.fbconfigs == null) return error.NoFBConfigs;

        // Find Alpha format
        var i: usize = 0;
        while (i < @as(usize, @intCast(self.num_fbconfigs))) : (i += 1) {
            const vis = c.glXGetVisualFromFBConfig(dpy, self.fbconfigs.?[i]);
            if (vis == null) continue;
            defer _ = c.XFree(vis);

            const pf = c.XRenderFindVisualFormat(dpy, vis.*.visual);
            if (pf == null) continue;

            if (pf.*.direct.alphaMask > 0) {
                self.fbconfig = self.fbconfigs.?[i];
                self.visual = vis; // Warning: manual management needed if not copied
                self.pict_format = pf;
                break;
            }
        }

        if (self.fbconfig == null) return error.NoMatchingFBConfig;

        self.cmap = c.XCreateColormap(dpy, self.root, self.visual.?.visual, c.AllocNone);

        var attr: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
        attr.colormap = self.cmap;
        attr.event_mask = c.StructureNotifyMask | c.EnterWindowMask | c.LeaveWindowMask |
            c.ExposureMask | c.ButtonPressMask | c.ButtonReleaseMask |
            c.OwnerGrabButtonMask | c.KeyPressMask | c.KeyReleaseMask;

        const attr_mask = c.CWColormap | c.CWBorderPixel | c.CWEventMask;

        self.handle = c.XCreateWindow(
            dpy,
            self.root,
            self.x, self.y, @intCast(self.width), @intCast(self.height),
            0,
            self.visual.?.depth,
            @intCast(c.InputOutput),
            self.visual.?.visual,
            @intCast(attr_mask),
            &attr,
        );

        if (self.handle == 0) return error.CreateWindowFailed;
        self.glx_handle = self.handle; // Simplify: assuming glX_window_handle = window_handle

        // NetWM DOCK Logic
        if (self.docked) {
            const dock_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", 1);
            const window_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", 1);
            _ = c.XChangeProperty(dpy, self.handle, window_type, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&dock_type), 1);
            // ... (Repeat for Sticky/Above/Strut using XChangeProperty)
        }

        _ = c.XMapWindow(dpy, self.handle);
        
        // Wait for map notify
        var event: c.XEvent = undefined;
        _ = c.XIfEvent(dpy, &event, waitForMapNotify, @ptrCast(&self.handle));

        self.del_atom = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(dpy, self.handle, &self.del_atom, 1);
    }

    pub fn updateTheMessageQueue(self: *Window) void {
        var event: c.XEvent = undefined;
        while (c.XPending(self.display) > 0) {
            _ = c.XNextEvent(self.display, &event);
            switch (event.type) {
                c.ClientMessage => {
                    if (event.xclient.data.l[0] == @as(i64, @intCast(self.del_atom))) {
                        self.running = false;
                    }
                },
                c.ConfigureNotify => {
                    self.width = event.xconfigure.width;
                    self.height = event.xconfigure.height;
                },
                c.ButtonPress => {
                    self.last_click = .{
                        .x = event.xbutton.x,
                        .y = event.xbutton.y,
                        .button = event.xbutton.button,
                    };
                    self.clicked = true;
                },
                else => {},
            }
        }
    }

    // Helper for XIfEvent
    fn waitForMapNotify(dpy: ?*c.Display, ev: [*c]c.XEvent, arg: [*c]u8) callconv(.C) i32 {
        _ = dpy;
        const handle_ptr: *c.Window = @ptrCast(@alignCast(arg));
        return if (ev.*.type == c.MapNotify and ev.*.xmap.window == handle_ptr.*) 1 else 0;
    }
};
