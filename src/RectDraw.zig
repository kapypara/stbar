const std = @import("std");

const c = @import("c");
const gl_procs_zig = @import("GlProcs.zig");
const GlProcs = gl_procs_zig.GlProcs;
const ProcLoader = gl_procs_zig.ProcLoader;

pub const RectDraw = struct {
    pub const uv_solid: [2]u16 = .{ 65535, 65535 };
    pub const uv_empty: [2]u16 = .{ 0, 65535 };

    pub const QuadVertex = extern struct {
        size: [2]f32,
        pos: [2]i16,
        uv: [2]u16,
        color: [4]u8,
    };

    gl: GlProcs = undefined,

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
        \\uniform sampler2D tex;
        \\out vec2 local_uv;
        \\flat out ivec2 cell_origin;
        \\flat out ivec2 cell_extent;
        \\flat out vec4 bg_frag;
        \\flat out int solid_frag;
        \\void main() {
        \\    vec2 uv = vs_in[0].texcoord;
        \\    if (uv.y > 0.99 && uv.x < 0.5) {
        \\        return;
        \\    }
        \\    solid_frag = (uv.y > 0.99) ? 1 : 0;
        \\    bg_frag = vs_in[0].bg_color;
        \\    vec2 atlas_f = vec2(textureSize(tex, 0));
        \\    ivec2 c_sz = max(ivec2(round(tex_size * atlas_f)), ivec2(1));
        \\    cell_extent = c_sz;
        \\    cell_origin = ivec2(round(uv * atlas_f));
        \\    vec2 ext_f = vec2(c_sz);
        \\    vec2 p = vs_in[0].point;
        \\    vec2 s = vs_in[0].rect_size;
        \\
        \\    gl_Position = vec4(p, 0.0, 1.0);
        \\    local_uv = vec2(0.0, 0.0);
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x, p.y - s.y, 0.0, 1.0);
        \\    local_uv = vec2(0.0, ext_f.y);
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x + s.x, p.y, 0.0, 1.0);
        \\    local_uv = vec2(ext_f.x, 0.0);
        \\    EmitVertex();
        \\
        \\    gl_Position = vec4(p.x + s.x, p.y - s.y, 0.0, 1.0);
        \\    local_uv = ext_f;
        \\    EmitVertex();
        \\
        \\    EndPrimitive();
        \\}
    ;

    const fs_source =
        \\#version 150 core
        \\in vec2 local_uv;
        \\flat in ivec2 cell_origin;
        \\flat in ivec2 cell_extent;
        \\flat in vec4 bg_frag;
        \\flat in int solid_frag;
        \\uniform sampler2D tex;
        \\uniform float u_opacity;
        \\out vec4 frag_color;
        \\void main() {
        \\    vec4 base = bg_frag;
        \\    if (solid_frag == 0) {
        \\        vec2 fw = max(fwidth(local_uv), vec2(1e-4));
        \\        vec2 u0 = local_uv - 0.5 * fw;
        \\        vec2 u1 = local_uv + 0.5 * fw;
        \\        ivec2 max_c = cell_extent - ivec2(1);
        \\        ivec2 t0 = clamp(ivec2(floor(u0)), ivec2(0), max_c);
        \\        ivec2 t1 = clamp(ivec2(floor(u1 - 1e-4)), ivec2(0), max_c);
        \\        vec2 w = clamp((u1 - vec2(t1)) / fw, 0.0, 1.0) * vec2(notEqual(t0, t1));
        \\        vec4 c00 = texelFetch(tex, cell_origin + t0, 0);
        \\        vec4 c10 = texelFetch(tex, cell_origin + ivec2(t1.x, t0.y), 0);
        \\        vec4 c01 = texelFetch(tex, cell_origin + ivec2(t0.x, t1.y), 0);
        \\        vec4 c11 = texelFetch(tex, cell_origin + t1, 0);
        \\        vec4 fg = mix(mix(c00, c10, w.x), mix(c01, c11, w.x), w.y);
        \\        base = mix(bg_frag, fg, fg.a);
        \\    }
        \\    frag_color = base * u_opacity;
        \\}
    ;

    pub fn init(loader: ProcLoader) !RectDraw {
        var r: RectDraw = .{
            .gl = try GlProcs.load(loader),
        };
        try r.build();
        return r;
    }

    pub fn build(self: *RectDraw) !void {
        const vs = try self.compileShader(c.GL_VERTEX_SHADER, vs_source);
        defer self.gl.DeleteShader(vs);
        const gs = try self.compileShader(c.GL_GEOMETRY_SHADER, gs_source);
        defer self.gl.DeleteShader(gs);
        const fs = try self.compileShader(c.GL_FRAGMENT_SHADER, fs_source);
        defer self.gl.DeleteShader(fs);

        self.program = self.gl.CreateProgram();
        self.gl.AttachShader(self.program, vs);
        self.gl.AttachShader(self.program, gs);
        self.gl.AttachShader(self.program, fs);
        self.gl.LinkProgram(self.program);

        var status: c.GLint = 0;
        self.gl.GetProgramiv(self.program, c.GL_LINK_STATUS, &status);
        if (status == c.GL_FALSE) return error.ProgramLinkFailed;

        self.u_tex_size = self.gl.GetUniformLocation(self.program, "tex_size");
        self.u_opacity = self.gl.GetUniformLocation(self.program, "u_opacity");

        self.gl.GenVertexArrays(1, &self.vao);
        self.gl.GenBuffers(1, &self.vbo);

        self.gl.BindVertexArray(self.vao);
        self.gl.BindBuffer(c.GL_ARRAY_BUFFER, self.vbo);

        const stride: c.GLsizei = @sizeOf(QuadVertex);
        const loc_size: c.GLuint = @intCast(self.gl.GetAttribLocation(self.program, "rect_size"));
        const loc_point: c.GLuint = @intCast(self.gl.GetAttribLocation(self.program, "point"));
        const loc_tex: c.GLuint = @intCast(self.gl.GetAttribLocation(self.program, "texcoord"));
        const loc_bg: c.GLuint = @intCast(self.gl.GetAttribLocation(self.program, "bg_color"));

        self.gl.EnableVertexAttribArray(loc_size);
        self.gl.VertexAttribPointer(loc_size, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);

        self.gl.EnableVertexAttribArray(loc_point);
        self.gl.VertexAttribPointer(loc_point, 2, c.GL_SHORT, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(QuadVertex, "pos")));

        self.gl.EnableVertexAttribArray(loc_tex);
        self.gl.VertexAttribPointer(loc_tex, 2, c.GL_UNSIGNED_SHORT, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(QuadVertex, "uv")));

        self.gl.EnableVertexAttribArray(loc_bg);
        self.gl.VertexAttribPointer(loc_bg, 4, c.GL_UNSIGNED_BYTE, c.GL_TRUE, stride, @ptrFromInt(@offsetOf(QuadVertex, "color")));

        self.ready = true;
    }

    pub fn deinit(self: *RectDraw) void {
        if (!self.ready) return;
        if (self.texture_id != 0) {
            c.glDeleteTextures(1, &self.texture_id);
            self.texture_id = 0;
        }
        self.gl.DeleteProgram(self.program);
        self.gl.DeleteBuffers(1, &self.vbo);
        self.gl.DeleteVertexArrays(1, &self.vao);
        self.ready = false;
    }

    pub fn use(self: *RectDraw) void {
        self.gl.BindVertexArray(self.vao);
        self.gl.BindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        self.gl.UseProgram(self.program);
        c.glBindTexture(c.GL_TEXTURE_2D, self.texture_id);
        self.setOpacity(1.0);
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

    pub fn setTextureSize(self: RectDraw, w: f32, h: f32) void {
        self.gl.Uniform2f(self.u_tex_size, w, h);
    }

    pub fn setOpacity(self: *RectDraw, opacity: f32) void {
        if (opacity == self.last_opacity) return;
        self.last_opacity = opacity;
        self.gl.Uniform1f(self.u_opacity, opacity);
    }

    pub fn ensureCapacity(self: *RectDraw, quad_count: usize) void {
        if (quad_count <= self.vbo_capacity) return;
        const byte_size: c.GLsizeiptr = @intCast(quad_count * @sizeOf(QuadVertex));
        self.gl.BufferData(c.GL_ARRAY_BUFFER, byte_size, null, c.GL_STREAM_DRAW);
        self.vbo_capacity = quad_count;
    }

    pub fn drawBatch(self: *RectDraw, quads: []const QuadVertex, opacity: f32) void {
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        if (quads.len == 0 or opacity <= 0.0) return;

        self.ensureCapacity(quads.len);
        self.setOpacity(opacity);

        const byte_size: c.GLsizeiptr = @intCast(quads.len * @sizeOf(QuadVertex));
        self.gl.BufferSubData(c.GL_ARRAY_BUFFER, 0, byte_size, quads.ptr);
        c.glDrawArrays(c.GL_POINTS, 0, @intCast(quads.len));
    }

    fn compileShader(self: *const RectDraw, kind: c.GLenum, source: []const u8) !c.GLuint {
        const id = self.gl.CreateShader(kind);

        const source_ptr: ?[*]const u8 = source.ptr;
        const source_len = @as(c.GLint, @intCast(source.len));

        self.gl.ShaderSource(id, 1, &source_ptr, &source_len);
        self.gl.CompileShader(id);

        var status: c.GLint = 0;
        self.gl.GetShaderiv(id, c.GL_COMPILE_STATUS, &status);
        if (status == c.GL_FALSE) {
            var log_len: c.GLint = 0;
            self.gl.GetShaderiv(id, c.GL_INFO_LOG_LENGTH, &log_len);

            if (log_len > 0) {
                var buf: [1024]u8 = undefined;
                self.gl.GetShaderInfoLog(id, buf.len, null, &buf);

                const print_len = @min(buf.len, @as(usize, @intCast(log_len)));
                std.debug.print("Shader Compile Error:\n{s}\n", .{buf[0..print_len]});
            }

            return error.ShaderCompileError;
        }
        return id;
    }
};
