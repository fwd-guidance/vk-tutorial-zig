const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "vulkan-tutorial",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 1. Setup Shader Compilation Commands
    const compile_vert = b.addSystemCommand(&.{ "glslc", "-o" });
    const vert_spv = compile_vert.addOutputFileArg("vert.spv");
    compile_vert.addFileArg(b.path("shaders/shader.vert"));

    const compile_frag = b.addSystemCommand(&.{ "glslc", "-o" });
    const frag_spv = compile_frag.addOutputFileArg("frag.spv");
    compile_frag.addFileArg(b.path("shaders/shader.frag"));

    // 2. Create a WriteFiles step to bundle the compiled shaders with a Zig wrapper
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(vert_spv, "vert.spv");
    _ = wf.addCopyFile(frag_spv, "frag.spv");

    // 3. Generate a Zig file that embeds those freshly compiled binaries.
    // CRITICAL: We use align(4) because Vulkan requires SPIR-V bytecode to be strictly 32-bit aligned!
    const shaders_zig = wf.add("shaders.zig",
        \\pub const vert align(4) = @embedFile("vert.spv").*;
        \\pub const frag align(4) = @embedFile("frag.spv").*;
    );

    // 4. Add this generated file as an importable module to your executable
    exe.root_module.addImport("shaders", b.createModule(.{
        .root_source_file = shaders_zig,
    }));

    const artifacts = [_]*std.Build.Step.Compile{exe};

    for (artifacts) |art| {
        art.addIncludePath(b.path("src"));
        art.addCSourceFile(.{
            .file = b.path("src/include.c"),
            .flags = &[_][]const u8{"-std=c99"},
        });
        art.linkLibC();

        switch (target.result.os.tag) {
            .macos => {
                art.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
                art.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
                art.linkFramework("Cocoa");
                art.linkFramework("IOKit");
                art.linkFramework("CoreFoundation");
                art.linkSystemLibrary("vulkan");
                art.linkSystemLibrary("cglm");
            },
            .linux => {
                art.linkSystemLibrary("X11");
                art.linkSystemLibrary("Xrandr");
                art.linkSystemLibrary("m");
                art.linkSystemLibrary("GL");
                art.linkSystemLibrary("cglm");
                art.linkSystemLibrary("vulkan");
            },
            .windows => {
                art.linkSystemLibrary("gdi32");
                art.linkSystemLibrary("winmm");
            },
            else => {},
        }
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the main app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
