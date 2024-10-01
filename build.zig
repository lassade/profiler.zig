const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const use_profiler = b.option(bool, "enable_profiling", "Enable Profiler") orelse true;

    const source_path = if (use_profiler) b.path("src/profiler.zig") else b.path("src/profiler_mock.zig");

    const profiler = b.addModule("profiler", .{
        .root_source_file = source_path,
        .target = target,
        .optimize = optimize,
    });

    const example = b.addExecutable(.{
        .name = "example",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("examples/main.zig"),
    });
    example.root_module.addImport("profiler", profiler);

    var run_example = b.addRunArtifact(example);
    const run_example_step = b.step("example", "Run example step");
    run_example_step.dependOn(&run_example.step);
}
