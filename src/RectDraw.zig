const std = @import("std");

const c = @import("c");

pub const RectDraw = struct {
    pub const uv_solid: [2]u16 = .{ 65535, 65535 };
    pub const uv_empty: [2]u16 = .{ 0, 65535 };

    pub const QuadVertex = extern struct {
        size: [2]f32,
        pos: [2]i16,
        uv: [2]u16,
        color: [4]u8,
    };

    // OpenGL Handles
    program: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
    vbo_capacity: usize = 0,

    // Cached Uniform Locations
    u_tex_size: c.GLint = -1,
    u_opacity: c.GLint = -1,
    last_opacity: f32 = -1.0,

    // State
    texture_id: c.GLuint = 0,
    ready: bool = false,

    const vs_source =
        \\#version 150 core
        \\in vec2 rect_size;
        \\in vec2 point;
        \\in vec2 texcoord;
        \\in vec4 bg_color;
        \\out VS_OUT {
        \\    vec2 rect_size;
        \\    vec2 point;
        \\    vec2 texcoord;
        \\    vec4 bg_color;
        \\} vs_out;
        \\void main() {
        \\    vs_out.rect_size = rect_size;
        \\    vs_out.point = point;
        \\    vs_out.texcoord = texcoord;
        \\    vs_out.bg_color = bg_color;
        \\}
    ;

    const gs_source =
        \\#version 150 core
        \\layout(points) in;
        \\layout(triangle_strip, max_vertices = 4) out;
        \\in VS_OUT {
        \\    vec2 rect_size;
        \\    vec2 point;
        \\    vec2 texcoord;
        \\    vec4 bg_color;
        \\} vs_in[];
        \\uniform vec2 tex_size;
        \\out vec2 texcoord_frag;
        \\flat out vec4 bg_frag;
        \\flat out int solid_frag;
        \\void main() {
        \\    vec2 uv = vs_in[0].texcoord;
        \\    if (uv.y > 0.99 && uv.x < 0.5) {
        \\        return;
        \\    }
        \\    solid_frag = (uv.y > 0.99) ? 1 : 0;
        \\    bg_frag = vs_in[0].bg_color;
        \\    vec2 p = vs_in[0].point;
        \\    vec2 s = vs_in[0].rect_size;
        \\
        \\    gl_Position = vec4(p, 0.0, 1.0);
        \\    texcoord_frag = uv;
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x, p.y - s.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(uv.x, uv.y + tex_size.y);
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x + s.x, p.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(uv.x + tex_size.x, uv.y);
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x + s.x, p.y - s.y, 0.0, 1.0);
        \\    texcoord_frag = vec2(uv.x + tex_size.x, uv.y + tex_size.y);
        \\    EmitVertex();
        \\
        \\    EndPrimitive();
        \\}
    ;

    const fs_source =
        \\#version 150 core
        \\in vec2 texcoord_frag;
        \\flat in vec4 bg_frag;
        \\flat in int solid_frag;
        \\uniform sampler2D tex;
        \\uniform float u_opacity;
        \\out vec4 frag_color;
        \\void main() {
        \\    vec4 base = bg_frag;
        \\    if (solid_frag == 0) {
        \\        vec4 fg = texture(tex, texcoord_frag);
        \\        base = mix(bg_frag, fg, fg.a);
        \\    }
        \\    frag_color = base * u_opacity;
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
        try glew(c.glAttachShader, .{ self.program, vs });
        try glew(c.glAttachShader, .{ self.program, gs });
        try glew(c.glAttachShader, .{ self.program, fs });
        try glew(c.glLinkProgram, .{self.program});

        var status: c.GLint = 0;
        try glew(c.glGetProgramiv, .{ self.program, c.GL_LINK_STATUS, &status });
        if (status == c.GL_FALSE) return error.programlinkfailed;

        self.u_tex_size = try glew(c.glGetUniformLocation, .{ self.program, "tex_size" });
        self.u_opacity = try glew(c.glGetUniformLocation, .{ self.program, "u_opacity" });

        try glew(c.glGenVertexArrays, .{ 1, &self.vao });
        try glew(c.glGenBuffers, .{ 1, &self.vbo });

        try glew(c.glBindVertexArray, .{self.vao});
        try glew(c.glBindBuffer, .{ c.GL_ARRAY_BUFFER, self.vbo });

        const stride: c.GLsizei = @sizeOf(QuadVertex);
        const loc_size: c.GLuint = @intCast(try glew(c.glGetAttribLocation, .{ self.program, "rect_size" }));
        const loc_point: c.GLuint = @intCast(try glew(c.glGetAttribLocation, .{ self.program, "point" }));
        const loc_tex: c.GLuint = @intCast(try glew(c.glGetAttribLocation, .{ self.program, "texcoord" }));
        const loc_bg: c.GLuint = @intCast(try glew(c.glGetAttribLocation, .{ self.program, "bg_color" }));

        try glew(c.glEnableVertexAttribArray, .{loc_size});
        try glew(c.glVertexAttribPointer, .{ loc_size, 2, c.GL_FLOAT, c.GL_FALSE, stride, @as(?*const anyopaque, null) });

        try glew(c.glEnableVertexAttribArray, .{loc_point});
        try glew(c.glVertexAttribPointer, .{ loc_point, 2, c.GL_SHORT, c.GL_TRUE, stride, @as(?*const anyopaque, @ptrFromInt(@offsetOf(QuadVertex, "pos"))) });

        try glew(c.glEnableVertexAttribArray, .{loc_tex});
        try glew(c.glVertexAttribPointer, .{ loc_tex, 2, c.GL_UNSIGNED_SHORT, c.GL_TRUE, stride, @as(?*const anyopaque, @ptrFromInt(@offsetOf(QuadVertex, "uv"))) });

        try glew(c.glEnableVertexAttribArray, .{loc_bg});
        try glew(c.glVertexAttribPointer, .{ loc_bg, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, @as(?*const anyopaque, @ptrFromInt(@offsetOf(QuadVertex, "color"))) });

        self.ready = true;
    }

    pub fn deinit(self: *RectDraw) void {
        if (self.texture_id != 0) {
            c.glDeleteTextures(1, &self.texture_id);
            self.texture_id = 0;
        }
        glew(c.glDeleteProgram, .{self.program}) catch {};
        glew(c.glDeleteBuffers, .{ 1, &self.vbo }) catch {};
        glew(c.glDeleteVertexArrays, .{ 1, &self.vao }) catch {};
        self.ready = false;
    }

    pub fn use(self: *RectDraw) !void {
        try glew(c.glBindVertexArray, .{self.vao});
        try glew(c.glBindBuffer, .{ c.GL_ARRAY_BUFFER, self.vbo });
        try glew(c.glUseProgram, .{self.program});
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture_id);
        try self.setOpacity(1.0);
    }

    pub fn loadTexture(self: *RectDraw, width: u16, height: u16, rgba_pixels: []const u8) !void {
        var tex: c.GLuint = 0;
        c.glGenTextures(1, &tex);
        if (tex == 0) return error.TextureGenerationFailed;

        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            width,
            height,
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            rgba_pixels.ptr,
        );

        self.texture_id = tex;
    }

    pub fn setTextureSize(self: RectDraw, w: f32, h: f32) !void {
        try glew(c.glUniform2f, .{ self.u_tex_size, w, h });
    }

    pub fn setOpacity(self: *RectDraw, opacity: f32) !void {
        if (opacity == self.last_opacity) return;
        self.last_opacity = opacity;
        try glew(c.glUniform1f, .{ self.u_opacity, opacity });
    }

    pub fn ensureCapacity(self: *RectDraw, quad_count: usize) !void {
        if (quad_count <= self.vbo_capacity) return;
        const byte_size: c.GLsizeiptr = @intCast(quad_count * @sizeOf(QuadVertex));
        try glew(c.glBufferData, .{ c.GL_ARRAY_BUFFER, byte_size, null, c.GL_STREAM_DRAW });
        self.vbo_capacity = quad_count;
    }

    pub fn drawBatch(self: *RectDraw, quads: []const QuadVertex, opacity: f32) !void {
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        if (quads.len == 0 or opacity <= 0.0) return;

        try self.ensureCapacity(quads.len);
        try self.setOpacity(opacity);

        const byte_size: c.GLsizeiptr = @intCast(quads.len * @sizeOf(QuadVertex));
        try glew(c.glBufferSubData, .{ c.GL_ARRAY_BUFFER, 0, byte_size, quads.ptr });
        c.glDrawArrays(c.GL_POINTS, 0, @intCast(quads.len));
    }
};

fn compileshader(kind: c.GLenum, source: []const u8) !c.GLuint {
    const id = try glew(c.glCreateShader, .{kind});

    const source_ptr: ?[*]const u8 = source.ptr;
    const source_len = @as(c.GLint, @intCast(source.len));

    try glew(c.glShaderSource, .{ id, 1, &source_ptr, &source_len });
    try glew(c.glCompileShader, .{id});

    var status: c.GLint = 0;
    try glew(c.glGetShaderiv, .{ id, c.GL_COMPILE_STATUS, &status });
    if (status == c.GL_FALSE) {
        var log_len: c.GLint = 0;
        try glew(c.glGetShaderiv, .{ id, c.GL_INFO_LOG_LENGTH, &log_len });

        if (log_len > 0) {
            var buf: [1024]u8 = undefined;
            try glew(c.glGetShaderInfoLog, .{ id, buf.len, null, &buf });

            const print_len = @min(buf.len, @as(usize, @intCast(log_len)));
            std.debug.print("Shader Compile Error:\n{s}\n", .{buf[0..print_len]});
        }

        return error.ShaderCompileError;
    }
    return id;
}

/// calls a glew-style function pointer getter and executes it
fn glew(getter: anytype, args: anytype) !glReturnType(getter) {
    if (getter()) |func| {
        return @call(.auto, func, args);
    }
    return error.OpenGlFunctionNotFound;
}

fn glReturnType(comptime getter: anytype) type {
    const getter_fn = @TypeOf(getter);
    const optional_func_ptr = @typeInfo(getter_fn).@"fn".return_type.?;
    const func_ptr = @typeInfo(optional_func_ptr).optional.child;
    const raw_fn = @typeInfo(func_ptr).pointer.child;
    return @typeInfo(raw_fn).@"fn".return_type.?;
}
