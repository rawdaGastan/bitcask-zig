const std = @import("std");

pub fn build(b: *std.Build) void {
    // This defines target platform (architecture. OS, ..)
    const target = b.standardTargetOptions(.{});
    // This defines optimization level (debug, release, ..)
    const optimize = b.standardOptimizeOption(.{});

    // Creating a static library (given below info)
    const lib = b.addStaticLibrary(.{
        .name = "bitcask-zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Ensure library is installed during build
    b.installArtifact(lib);

    // Main library tests
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Separate tests file
    const separate_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create test step that runs both test suites
    const run_main_tests = b.addRunArtifact(main_tests);
    const run_separate_tests = b.addRunArtifact(separate_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_separate_tests.step);
}
