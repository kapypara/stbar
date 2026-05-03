const std = @import("std");
const Window = @import("Window.zig");
const c = Window.c;

/// Dummy Rednerer to tset if window is working
pub const Renderer = struct {
    window: Window.Window,
    initialized: bool = false,
    texture_id: u32 = 0,

    pub fn init(self: *Renderer, x: i32, y: i32, width: i32, height: i32) !void {
        self.window.x = x;
        self.window.y = y;
        self.window.width = width;
        self.window.height = height;

        try self.window.createTheWindow();
        try self.window.createTheRenderContext();
        
        self.initialized = true;
    }

    pub fn handleEvents(self: *Renderer) void {
        self.window.updateTheMessageQueue();
    }

    pub fn update(self: *Renderer) void {
        c.glViewport(0, 0, self.window.width, self.window.height);
    }

    pub fn render(self: *Renderer) void {
        const w = @as(f32, @floatFromInt(self.window.width));
        const h = @as(f32, @floatFromInt(self.window.height));

        c.glMatrixMode(c.GL_PROJECTION);
        c.glLoadIdentity();
        c.glOrtho(0, @floatCast(w - 1), @floatCast(h - 1), 0, 0, 1);

        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        // Example: Drawing the Quads from your C++ code
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        c.glColor4f(1.0, 0.0, 0.0, 0.7); // Red
        c.glBegin(c.GL_QUADS);
        c.glVertex2i(100, 100);
        c.glVertex2i(100, self.window.height - 100);
        c.glVertex2i(self.window.width - 100, self.window.height - 100);
        c.glVertex2i(self.window.width - 100, 100);
        c.glEnd();

        c.glFlush();
    }

    pub fn swap(self: *Renderer) void {
        c.glXSwapBuffers(self.window.display, self.window.glx_handle);
    }
};
