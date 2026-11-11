const c = @import("c");

pub const ProcLoader = *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque;

fn GlFn(comptime OptPtr: type) type {
    return @typeInfo(OptPtr).optional.child;
}

pub const GlProcs = struct {
    CreateShader: GlFn(c.PFNGLCREATESHADERPROC),
    ShaderSource: GlFn(c.PFNGLSHADERSOURCEPROC),
    CompileShader: GlFn(c.PFNGLCOMPILESHADERPROC),
    GetShaderiv: GlFn(c.PFNGLGETSHADERIVPROC),
    GetShaderInfoLog: GlFn(c.PFNGLGETSHADERINFOLOGPROC),
    DeleteShader: GlFn(c.PFNGLDELETESHADERPROC),
    CreateProgram: GlFn(c.PFNGLCREATEPROGRAMPROC),
    AttachShader: GlFn(c.PFNGLATTACHSHADERPROC),
    LinkProgram: GlFn(c.PFNGLLINKPROGRAMPROC),
    GetProgramiv: GlFn(c.PFNGLGETPROGRAMIVPROC),
    DeleteProgram: GlFn(c.PFNGLDELETEPROGRAMPROC),
    UseProgram: GlFn(c.PFNGLUSEPROGRAMPROC),
    GetUniformLocation: GlFn(c.PFNGLGETUNIFORMLOCATIONPROC),
    Uniform1f: GlFn(c.PFNGLUNIFORM1FPROC),
    Uniform2f: GlFn(c.PFNGLUNIFORM2FPROC),
    GenVertexArrays: GlFn(c.PFNGLGENVERTEXARRAYSPROC),
    BindVertexArray: GlFn(c.PFNGLBINDVERTEXARRAYPROC),
    DeleteVertexArrays: GlFn(c.PFNGLDELETEVERTEXARRAYSPROC),
    GenBuffers: GlFn(c.PFNGLGENBUFFERSPROC),
    BindBuffer: GlFn(c.PFNGLBINDBUFFERPROC),
    BufferData: GlFn(c.PFNGLBUFFERDATAPROC),
    BufferSubData: GlFn(c.PFNGLBUFFERSUBDATAPROC),
    DeleteBuffers: GlFn(c.PFNGLDELETEBUFFERSPROC),
    GetAttribLocation: GlFn(c.PFNGLGETATTRIBLOCATIONPROC),
    EnableVertexAttribArray: GlFn(c.PFNGLENABLEVERTEXATTRIBARRAYPROC),
    VertexAttribPointer: GlFn(c.PFNGLVERTEXATTRIBPOINTERPROC),

    pub fn load(loader: ProcLoader) !GlProcs {
        var procs: GlProcs = undefined;
        inline for (@typeInfo(GlProcs).@"struct".field_names) |field_name| {
            const sym_name = "gl" ++ field_name;
            const raw = loader(sym_name) orelse return error.OpenGlFunctionNotFound;
            @field(procs, field_name) = @ptrCast(raw);
        }
        return procs;
    }
};
