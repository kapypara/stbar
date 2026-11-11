const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zigbar",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
        }),
        .use_llvm = true,
    });

    // Bake `assets/font/tamzen.json` + `assets/font/tamzen.png` into `.rodata` at build time (zero runtime asset files)
    const bake_font_exe = b.addExecutable(.{
        .name = "bake_font",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bake_font.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
        .use_llvm = true,
    });
    const run_bake = b.addRunArtifact(bake_font_exe);
    run_bake.addFileArg(b.path("assets/font/tamzen.json"));
    run_bake.addFileArg(b.path("assets/font/tamzen.png"));
    const baked_font_file = run_bake.addOutputFileArg("tamzen_embedded.zig");
    exe.root_module.addImport("tamzen_embedded", b.createModule(.{
        .root_source_file = baked_font_file,
        .target = target,
        .optimize = optimize,
    }));

    // --- ADDED SYSTEM DEPENDENCIES HERE ---
    // Link libc (required for C headers and system libraries)
    exe.root_module.link_libc = true;

    // Link the required system libraries (Wayland + EGL + OpenGL + sd-bus + X11 fallback)
    const c_lib = [_][]const u8{
        "wayland-client",
        "wayland-egl",
        "EGL",
        "GL",
        "libsystemd",
        "X11",
        "Xrender",
        "Xext",
    };

    for (c_lib) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }

    const wf = b.addWriteFiles();

    const protocols = [_]struct { xml: []const u8, stem: []const u8 }{
        .{ .xml = "protocols/xdg-shell.xml", .stem = "xdg-shell" },
        .{ .xml = "protocols/wlr-layer-shell-unstable-v1.xml", .stem = "wlr-layer-shell-unstable-v1" },
        .{ .xml = "protocols/wlr-foreign-toplevel-management-unstable-v1.xml", .stem = "wlr-foreign-toplevel-management-unstable-v1" },
    };

    for (protocols) |proto| {
        const header_name = b.fmt("{s}-client-protocol.h", .{proto.stem});
        const code_name = b.fmt("{s}-protocol.c", .{proto.stem});

        const gen_h = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        gen_h.addFileArg(b.path(proto.xml));
        const h_file = gen_h.addOutputFileArg(header_name);
        _ = wf.addCopyFile(h_file, header_name);

        const gen_c = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        gen_c.addFileArg(b.path(proto.xml));
        const c_file = gen_c.addOutputFileArg(code_name);
        exe.root_module.addCSourceFile(.{ .file = c_file });
    }

    exe.root_module.addIncludePath(wf.getDirectory());

    const c_header = wf.add("c.h",
        \\#include <wayland-client.h>
        \\#include <wayland-egl.h>
        \\#include <EGL/egl.h>
        \\#include "xdg-shell-client-protocol.h"
        \\#include "wlr-layer-shell-unstable-v1-client-protocol.h"
        \\#include "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
        \\#include <GL/gl.h>
        \\#include <GL/glext.h>
        \\#include <GL/glx.h>
        \\#include <GL/glxext.h>
        \\#include <X11/Xatom.h>
        \\#include <X11/extensions/Xrender.h>
        \\#include <X11/extensions/shape.h>
        \\#include <X11/Xutil.h>
        \\#include <sys/statvfs.h>
        \\#include <poll.h>
        \\#include <unistd.h>
        \\#include <fcntl.h>
        \\#include <signal.h>
        \\#include <time.h>
        \\#include <systemd/sd-bus.h>
        \\
    );
    const translate_c = b.addTranslateC(.{
        .root_source_file = c_header,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(wf.getDirectory());
    for (c_lib) |lib| {
        translate_c.linkSystemLibrary(lib, .{});
    }
    exe.root_module.addImport("c", translate_c.createModule());
    // --------------------------------------

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = true,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
