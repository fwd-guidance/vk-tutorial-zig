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
