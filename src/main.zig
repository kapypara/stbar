const std = @import("std");
const Window = @import("Window.zig").Window;
const Ticker = @import("Ticker.zig").Ticker;
const StatusMonitor = @import("StatusMonitor.zig").StatusMonitor;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // 1. Initialize Renderer
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer {
        const check = debug_allocator.deinit();
        if (check == .leak) {
            std.debug.print("⚠️ MEMORY LEAK DETECTED! ⚠️\n", .{});
        }
    }

    // var evented: std.Io.Evented = undefined;
    // try evented.init(gpa, .{
    //     .argv0 = .init(init.args),
    //     .environ = init.environ,
    //     .backing_allocator_needs_mutex = false,
    // });
    // defer evented.deinit();
    const io = init.io; //evented.io();

    // 1. Initialize the struct
    var window = Window{
        .docked = true,
    };

    // 3. Call Init
    try window.init(0, 0, 1920, 30);
    defer window.deinit(); // Clean up X11/GL resources

    const tr = 10;
    const rr = 60;

    var ticker = Ticker.init(io, rr, tr);

    var monitor: StatusMonitor = .{ .window = window };

    try monitor.init(io, gpa, tr, rr);
    defer monitor.deinit();

    // 4. Main Loop
    while (window.running and false) {
        window.updateTheMessageQueue();
        
        window.updateViewport();
        monitor.update();

        // TODO add this
        try monitor.render();

        // optional swap code
        // window.swapBuffers();
        ticker.tick();
    }
    
    // 2. Setup Static Rect
    // var dp: c.static_rect = undefined;
    // c.static_rect_build(&dp);
    
    // if (!c.static_rect_is_ready(&dp)) {
    //     return error.StaticRectNotReady;
    // }

    // background: vec4 is likely a struct {x, y, z, w}
    // c.static_rect_setBackgroundColor(&dp, .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.4666 });

    // 3. Texture and Font
    // var font_texture: c.GL_texture = undefined;
    // c.texture_create(&font_texture);
    // c.texture_load(&font_texture, "assets/font/tamzen.png");

    // c.static_rect_setTexture(&dp, &font_texture);
    // c.static_rect_bindTexture(&dp);

    // c.static_rect_setTextureSize(&dp, tex_char_size);

    // 4. Output
    // var bar: c.output_line = undefined;
    // c.output_line_init(&bar, &ren, &dp, &font_glyphs, 8, 60);
    // c.output_line_output(&bar);

    std.debug.print("Bar initialized successfully.\n", .{});
}
