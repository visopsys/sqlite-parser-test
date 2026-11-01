const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_parser = b.addModule("sqlite_parser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit, oracle and differential tests");

    const lib_tests = b.addTest(.{ .root_module = sqlite_parser });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // Tests that compare against the real SQLite. They link the system SQLite
    // 3.45.1 library through the C oracle in test/oracle/; the library above
    // never does.
    // Fuzz mode needs the LLVM backend, and SQLite's C must not be built with the
    // coverage instrumentation that only Zig's fuzzer runtime provides.
    const oracle_tests = b.addTest(.{ .use_llvm = true, .root_module = b.createModule(.{
        .root_source_file = b.path("test/all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "sqlite_parser", .module = sqlite_parser }},
    }) });
    oracle_tests.root_module.addCSourceFile(.{
        .file = b.path("test/oracle/oracle.c"),
        .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror", "-fno-sanitize-coverage=trace-cmp,trace-pc-guard,inline-8bit-counters,pc-table,indirect-calls" },
    });
    oracle_tests.root_module.addIncludePath(b.path("test/oracle"));
    oracle_tests.root_module.linkSystemLibrary("sqlite3", .{});
    test_step.dependOn(&b.addRunArtifact(oracle_tests).step);
}
