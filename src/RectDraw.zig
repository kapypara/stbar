const std = @import("std");

const c = @import("c");

pub const RectDraw = struct {
    // OpenGL Handles
    program: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbos: [2]c.GLuint = .{ 0, 0 }, // 0: points, 1: texcoords

    // Uniform Locations
    u_rect_size: c.GLint = -1,
    u_tex_size: c.GLint = -1,
    u_bg: c.GLint = -1,

    // State
    texture_id: c.GLuint = 0,
    ready: bool = false,

    const vs_source =
        \\#version 150 core
        \\in vec2 point;
        \\in vec2 texcoord;
        \\out VS_OUT {
        \\    vec2 point;
        \\    vec2 texcoord;
        \\} vs_out;
        \\void main() {
        \\    vs_out.point = point;
        \\    vs_out.texcoord = texcoord;
        \\}
    ;

    const gs_source =
        \\#version 150 core
        \\layout(points) in;
        \\layout(triangle_strip, max_vertices = 4) out;
        \\in VS_OUT {
        \\    vec2 point;
        \\    vec2 texcoord;
        \\} vs_in[];
        \\uniform vec2 rect_size;
        \\uniform vec2 tex_size;
        \\out vec2 texcoord_frag;
        \\void main() {
        \\    // Top Left
        \\    gl_Position = vec4(vs_in[0].point, 0.0, 1.0);
        \\    texcoord_frag = vs_in[0].texcoord;
        \\    EmitVertex();
        \\    // Bottom Left
        \\    gl_Position = vec4(vs_in[0].point.x, vs_in[0].point.y - rect_size.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(vs_in[0].texcoord.x, vs_in[0].texcoord.y + tex_size.y);
        \\    EmitVertex();
        \\    // Top Right
        \\    gl_Position = vec4(vs_in[0].point.x + rect_size.x, vs_in[0].point.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(vs_in[0].texcoord.x + tex_size.x, vs_in[0].texcoord.y);
        \\    EmitVertex();
        \\    // Bottom Right
        \\    gl_Position = vec4(vs_in[0].point.x + rect_size.x, vs_in[0].point.y - rect_size.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(vs_in[0].texcoord.x + tex_size.x, vs_in[0].texcoord.y + tex_size.y);
        \\    EmitVertex();
        \\    EndPrimitive();
        \\}
    ;

    const fs_source =
        \\#version 150 core
        \\in vec2 texcoord_frag;
        \\uniform vec4 bg;
        \\uniform sampler2D tex;
        \\void main() {
        \\    vec4 fg = texture(tex, texcoord_frag);
        \\    gl_FragColor = mix(bg, fg, fg.a);
        \\}
    ;

    pub fn init() !RectDraw {
        var r: RectDraw = .{};
        try r.build();

        return r;
    }

    pub fn build(self: *RectDraw) !void {
        const vs = try compileshader(c.GL_VERTEX_SHADER, vs_source);
        defer glew(c.glDeleteShader, .{vs}) catch {};
        const gs = try compileshader(c.GL_GEOMETRY_SHADER, gs_source);
        defer glew(c.glDeleteShader, .{gs}) catch {};
        const fs = try compileshader(c.GL_FRAGMENT_SHADER, fs_source);
        defer glew(c.glDeleteShader, .{fs}) catch {};

        self.program = try glew(c.glCreateProgram, .{});
        try glew(c.glAttachShader, .{self.program, vs});
        try glew(c.glAttachShader, .{self.program, gs});
        try glew(c.glAttachShader, .{self.program, fs});
        try glew(c.glLinkProgram, .{self.program});

        var status: c.GLint = 0;
        try glew(c.glGetProgramiv, .{self.program, c.GL_LINK_STATUS, &status});
        if (status == c.GL_FALSE) return error.programlinkfailed;

        // uniforms
        self.u_rect_size = try glew(c.glGetUniformLocation, .{self.program, "rect_size"});
        self.u_tex_size = try glew(c.glGetUniformLocation, .{self.program, "tex_size"});
        self.u_bg = try glew(c.glGetUniformLocation, .{self.program, "bg"});

        // vertex setup
        try glew(c.glGenVertexArrays, .{1, &self.vao});
        try glew(c.glGenBuffers, .{2, &self.vbos});

        self.ready = true;
    }


    pub fn deinit(self: *RectDraw) void {
        if (self.texture_id != 0) {
            c.glDeleteTextures(1, &self.texture_id);
            self.texture_id = 0;
        }
        glew(c.glDeleteProgram, .{self.program}) catch {};
        glew(c.glDeleteBuffers, .{2, &self.vbos}) catch {};
        glew(c.glDeleteVertexArrays, .{1, &self.vao}) catch {};
        self.ready = false;
    }

    pub fn use(self: RectDraw) !void {
        try glew(c.glBindVertexArray, .{self.vao});
        try glew(c.glUseProgram, .{self.program});
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture_id);
    }

    pub fn loadTexture(self: *RectDraw, width: u16, height: u16, rgba_pixels: []const u8) !void {
        var tex: c.GLuint = 0;
        // Generate a texture handle
        c.glGenTextures(1, &tex);
        if (tex == 0) return error.TextureGenerationFailed;

        // Temporarily bind it to configure its properties
        c.glBindTexture(c.GL_TEXTURE_2D, tex);

        // Set texture wrapping parameters (Clamp to edge avoids artifacts on thin borders)
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        // Set texture filtering parameters (GL_LINEAR for smooth scaling, or GL_NEAREST for pixel art)
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

        // Upload the raw pixel data byte array without copying it in Zig memory
        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,                      // Mipmap level
            c.GL_RGBA,              // Internal GPU color format
            width,
            height,
            0,                      // Legacy border attribute (must be 0)
            c.GL_RGBA,              // Format of your source data slice
            c.GL_UNSIGNED_BYTE,     // Data type per color channel
            rgba_pixels.ptr,
        );

        self.texture_id = tex;
    }

    pub fn setRectPoints(self: RectDraw, points: []const i16) !void {
        const size = @as(c.GLsizeiptr, @intCast(points.len * @sizeOf(i16)));

        try glew(c.glBindBuffer, .{c.GL_ARRAY_BUFFER, self.vbos[0]});
        try glew(c.glBufferData, .{c.GL_ARRAY_BUFFER, size, points.ptr, c.GL_DYNAMIC_DRAW});

        const loc = @as(c.GLuint, @intCast(try glew(c.glGetAttribLocation, .{self.program, "point"})));

        try glew(c.glEnableVertexAttribArray, .{loc});
        try glew(c.glVertexAttribPointer, .{loc, 2, c.GL_SHORT, c.GL_TRUE, 0, null});
    }

    pub fn setTextureCoordinates(self: RectDraw, coords: []const u16) !void {
        const size = @as(c.GLsizeiptr, @intCast(coords.len * @sizeOf(u16)));

        try glew(c.glBindBuffer, .{c.GL_ARRAY_BUFFER, self.vbos[1]});
        try glew(c.glBufferData, .{c.GL_ARRAY_BUFFER, size, coords.ptr, c.GL_DYNAMIC_DRAW});

        const loc = @as(c.GLuint, @intCast(try glew(c.glGetAttribLocation, .{self.program, "texcoord"})));

        try glew(c.glEnableVertexAttribArray, .{loc});
        try glew(c.glVertexAttribPointer, .{loc, 2, c.GL_UNSIGNED_SHORT, c.GL_TRUE, 0, null});
    }

    pub fn setRectSize(self: RectDraw, w: f32, h: f32) !void {
        try glew(c.glUniform2f, .{self.u_rect_size, w, h});
    }

    pub fn setTextureSize(self: RectDraw, w: f32, h: f32) !void {
        try glew(c.glUniform2f, .{self.u_tex_size, w, h});
    }

    pub fn setBackgroundColor(self: RectDraw, r: f32, g: f32, b: f32, a: f32) !void {
        try glew(c.glUniform4f, .{self.u_bg, r, g, b, a});
    }

    pub fn setBackgroundColorU32(self: RectDraw, rgba: u32) !void {
        const r = @as(f32, @floatFromInt(@as(u8, @truncate(rgba >> 24)))) / 255.0;
        const g = @as(f32, @floatFromInt(@as(u8, @truncate(rgba >> 16)))) / 255.0;
        const b = @as(f32, @floatFromInt(@as(u8, @truncate(rgba >> 8)))) / 255.0;
        const a = @as(f32, @floatFromInt(@as(u8, @truncate(rgba)))) / 255.0;

        try glew(c.glUniform4f, .{self.u_bg, r, g, b, a});
    }

    pub fn draw(_: RectDraw, count: u16) !void {
        c.glDrawArrays(c.GL_POINTS, 0, count);
    }

    pub fn flush(_: RectDraw) !void {
        c.glFlush();
    }
};

fn compileshader(kind: c.GLenum, source: []const u8) !c.GLuint {
    const id = try glew(c.glCreateShader, .{kind});

    const source_ptr: ?[*]const u8 = source.ptr;
    const source_len = @as(c.GLint, @intCast(source.len));

    try glew(c.glShaderSource, .{id, 1, &source_ptr, &source_len});
    try glew(c.glCompileShader, .{id});

    var status: c.GLint = 0;
    try glew(c.glGetShaderiv, .{id, c.GL_COMPILE_STATUS, &status});
    if (status == c.GL_FALSE) {
        var log_len: c.GLint = 0;
        try glew(c.glGetShaderiv,.{id, c.GL_INFO_LOG_LENGTH, &log_len});
        // in a real app, you'd allocate a buffer and print the log here

        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            try glew(c.glGetShaderInfoLog, .{ id, buf.len, null, &buf });

            // Safely clamp the slice size so we don't read garbage beyond what OpenGL wrote
            const print_len = @as(usize, @intCast(log_len));
            std.debug.print("Shader Compile Error:\n{s}\n", .{buf[0..print_len]});
        }

        return error.ShaderCompileError;
    }
    return id;
}

/// calls a glew-style function pointer getter and executes it with one argument
fn glew(getter: anytype, args: anytype) !glReturnType(getter) {
    if (getter()) |func| {
        return @call(.auto, func, args);
    }
    return error.OpenGlFunctionNotFound;
}

// helper to extract the return type cleanly
fn glReturnType(comptime getter: anytype) type {
    const getter_fn = @TypeOf(getter);
    const optional_func_ptr = @typeInfo(getter_fn).@"fn".return_type.?;
    const func_ptr = @typeInfo(optional_func_ptr).optional.child; // this is a pointer type
    
    // 1. get the type the pointer points to (.pointer.child)
    const raw_fn = @typeInfo(func_ptr).pointer.child; 
    
    // 2. now we can safely access the function's return type
    const actual_return_type = @typeInfo(raw_fn).@"fn".return_type.?;
    return actual_return_type;
}
