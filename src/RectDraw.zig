const std = @import("std");

/// Assuming you are linking against OpenGL via C import
const c = @cImport({
    @cInclude("GL/glew.h"); // Or your preferred GL loader
});

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

    pub fn init() RectDraw {
        return .{};
    }

    pub fn build(self: *RectDraw) !void {
        const vs = try compileShader(c.GL_VERTEX_SHADER, vs_source);
        defer c.glDeleteShader(vs);
        const gs = try compileShader(c.GL_GEOMETRY_SHADER, gs_source);
        defer c.glDeleteShader(gs);
        const fs = try compileShader(c.GL_FRAGMENT_SHADER, fs_source);
        defer c.glDeleteShader(fs);

        self.program = c.glCreateProgram();
        c.glAttachShader(self.program, vs);
        c.glAttachShader(self.program, gs);
        c.glAttachShader(self.program, fs);
        c.glLinkProgram(self.program);

        var status: c.GLint = 0;
        c.glGetProgramiv(self.program, c.GL_LINK_STATUS, &status);
        if (status == c.GL_FALSE) return error.ProgramLinkFailed;

        // Uniforms
        self.u_rect_size = c.glGetUniformLocation(self.program, "rect_size");
        self.u_tex_size = c.glGetUniformLocation(self.program, "tex_size");
        self.u_bg = c.glGetUniformLocation(self.program, "bg");

        // Vertex Setup
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(2, &self.vbos);

        self.ready = true;
    }

    pub fn deinit(self: *RectDraw) void {
        c.glDeleteProgram(self.program);
        c.glDeleteBuffers(2, &self.vbos);
        c.glDeleteVertexArrays(1, &self.vao);
        self.ready = false;
    }

    pub fn use(self: RectDraw) void {
        c.glBindVertexArray(self.vao);
        c.glUseProgram(self.program);
    }

    pub fn setTexture(self: *RectDraw, tex_id: c.GLuint) void {
        self.texture_id = tex_id;
    }

    pub fn bindTexture(self: RectDraw) void {
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture_id);
    }

    pub fn unbindTexture(_: RectDraw) void {
        c.glBindTexture(c.GL_TEXTURE_2D, 0);
    }

    pub fn setRectPoints(self: RectDraw, points: []const f32) void {
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[0]);
        const size = @as(c.GLsizeiptr, @intCast(points.len * @sizeOf(f32)));
        c.glBufferData(c.GL_ARRAY_BUFFER, size, points.ptr, c.GL_DYNAMIC_DRAW);

        const loc = @as(c.GLuint, @intCast(c.glGetAttribLocation(self.program, "point")));
        c.glEnableVertexAttribArray(loc);
        c.glVertexAttribPointer(loc, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
    }

    pub fn setTextureCoordinates(self: RectDraw, coords: []const f32) void {
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[1]);
        const size = @as(c.GLsizeiptr, @intCast(coords.len * @sizeOf(f32)));
        c.glBufferData(c.GL_ARRAY_BUFFER, size, coords.ptr, c.GL_DYNAMIC_DRAW);

        const loc = @as(c.GLuint, @intCast(c.glGetAttribLocation(self.program, "texcoord")));
        c.glEnableVertexAttribArray(loc);
        c.glVertexAttribPointer(loc, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);
    }

    pub fn setRectSize(self: RectDraw, w: f32, h: f32) void {
        c.glUniform2f(self.u_rect_size, w, h);
    }

    pub fn setTextureSize(self: RectDraw, w: f32, h: f32) void {
        c.glUniform2f(self.u_tex_size, w, h);
    }

    pub fn setBackgroundColor(self: RectDraw, r: f32, g: f32, b: f32, a: f32) void {
        c.glUniform4f(self.u_bg, r, g, b, a);
    }

    pub fn draw(_: RectDraw, count: u16) void {
        c.glDrawArrays(c.GL_POINTS, 0, count);
    }

    pub fn flush(_: RectDraw) void {
        c.glFlush();
    }
};

fn compileShader(kind: c.GLenum, source: []const u8) !c.GLuint {
    const id = c.glCreateShader(kind);
    const source_ptr: ?[*]const u8 = source.ptr;
    const source_len = @as(c.GLint, @intCast(source.len));

    c.glShaderSource(id, 1, &source_ptr, &source_len);
    c.glCompileShader(id);

    var status: c.GLint = 0;
    c.glGetShaderiv(id, c.GL_COMPILE_STATUS, &status);
    if (status == c.GL_FALSE) {
        var log_len: c.GLint = 0;
        c.glGetShaderiv(id, c.GL_INFO_LOG_LENGTH, &log_len);
        // In a real app, you'd allocate a buffer and print the log here
        return error.ShaderCompileError;
    }
    return id;
}
