const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_parser = b.addModule("sqlite_parser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "sqlcheck", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "sqlite_parser", .module = sqlite_parser }},
    }) });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit, oracle and differential tests");

    const lib_tests = b.addTest(.{ .root_module = sqlite_parser });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    const cli_cases = [_]CliCase{
        .{ .arg = "test/cli/valid.sql", .exit_code = 0, .stderr = "" },
        .{
            .arg = "test/cli/invalid_multiline.sql",
            .exit_code = 1,
            .stderr = "test/cli/invalid_multiline.sql:3:17: error: near \"FROM\": syntax error\n" ++
                "  SELECT a FROM FROM t;\n" ++
                "                ^~~~\n",
        },
        .{
            .arg = "test/cli/invalid_tab.sql",
            .exit_code = 1,
            .stderr = "test/cli/invalid_tab.sql:1:11: error: near \"FORM\": syntax error\n" ++
                "\tSELECT\t* FORM t;\n" ++
                "\t      \t  ^~~~\n",
        },
        .{ .stdin = "SELECT 1;\n", .exit_code = 0, .stderr = "" },
        .{
            .stdin = "SELECT 1 FROM;",
            .exit_code = 1,
            .stderr = "<stdin>:1:14: error: near \";\": syntax error\n" ++
                "SELECT 1 FROM;\n" ++
                "             ^\n",
        },
        .{
            .arg = "test/cli/does-not-exist.sql",
            .exit_code = 2,
            .stderr = "sqlcheck: test/cli/does-not-exist.sql: FileNotFound\n",
        },
        .{
            .stdin = "SELECT",
            .exit_code = 1,
            .stderr = "<stdin>:1:7: error: incomplete input\n" ++
                "SELECT\n" ++
                "      ^\n",
        },
    };
    for (cli_cases) |case| test_step.dependOn(&addCliRun(b, exe, case).step);

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

/// One run of `sqlcheck`: a file argument or standard input, and the expected result.
const CliCase = struct {
    arg: ?[]const u8 = null,
    stdin: ?[]const u8 = null,
    exit_code: u8,
    stderr: []const u8,
};

fn addCliRun(b: *std.Build, exe: *std.Build.Step.Compile, case: CliCase) *std.Build.Step.Run {
    const run = b.addRunArtifact(exe);
    // The file name appears in the messages, so run from the repository root.
    run.setCwd(b.path("."));
    if (case.arg) |arg| run.addArg(arg);
    if (case.stdin) |bytes| run.setStdIn(.{ .bytes = bytes });
    run.expectExitCode(case.exit_code);
    run.expectStdErrEqual(case.stderr);
    return run;
}
