//! Checks precedence against the real engine: SQLite must evaluate our canonical
//! rendering of an expression to the same rows as the original text.

const std = @import("std");
const sqlite_parser = @import("sqlite_parser");
const corpus = @import("corpus.zig");
const differential = @import("differential.zig");
const oracle = @import("oracle.zig");

const buffer_size = 64 * 1024;

const Comparison = enum { compared, skipped, mismatch };

fn sameEvaluation(a: oracle.Evaluation, b: oracle.Evaluation) bool {
    return switch (a) {
        .rows => |rows| b == .rows and std.mem.eql(u8, rows, b.rows),
        .failed => |message| b == .failed and std.mem.eql(u8, message, b.failed),
        .refused => b == .refused,
    };
}

/// Evaluates `sql` and our rendering of it. Statements SQLite refuses to run, that
/// we do not parse, or whose result changes between two runs are skipped.
fn sameRows(arena: std.mem.Allocator, sql: []const u8) !Comparison {
    const first = oracle.eval(sql, try arena.alloc(u8, buffer_size));
    if (first == .refused) return .skipped;
    if (!sameEvaluation(first, oracle.eval(sql, try arena.alloc(u8, buffer_size)))) return .skipped;
    const rendered = try differential.renderStatement(arena, sql);
    if (rendered.len == 0) return .skipped;
    if (sameEvaluation(first, oracle.eval(rendered, try arena.alloc(u8, buffer_size)))) return .compared;
    std.debug.print("evaluation differs\n  original:  \"{f}\"\n  rendering: \"{f}\"\n", .{
        std.zig.fmtString(sql), std.zig.fmtString(rendered),
    });
    return .mismatch;
}

test "evaluation of corpus expressions is unchanged by rendering" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var accepted: usize = 0;
    var compared: usize = 0;
    var mismatches: usize = 0;
    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        var pos: usize = 0;
        while (pos < case.sql.len) {
            _ = arena_state.reset(.retain_capacity);
            const result = try oracle.check(case.sql[pos..]);
            const statement = case.sql[pos..][0..result.length];
            pos += result.length;
            if (result.verdict != .accept) continue;
            if (differential.familyOf(try arena.dupeSentinel(u8, statement, 0)) != .select_expressions) continue;
            accepted += 1;
            switch (try sameRows(arena, statement)) {
                .compared => compared += 1,
                .skipped => {},
                .mismatch => mismatches += 1,
            }
        }
    }
    try std.testing.expectEqual(0, mismatches);
    std.testing.expect(compared > 0 and compared * 4 >= accepted * 3) catch |err| {
        std.debug.print("compared {d} of {d} accepted statements\n", .{ compared, accepted });
        return err;
    };
}

const binary_operators = [_][]const u8{
    "OR", "AND",    "=",                "==",                   "!=", "<>", "<", "<=", ">", ">=",
    "&",  "|",      "<<",               ">>",                   "+",  "-",  "*", "/",  "%", "||",
    "IS", "IS NOT", "IS DISTINCT FROM", "IS NOT DISTINCT FROM",
};
const prefix_operators = [_][]const u8{ "-", "+", "~", "NOT" };
const integers = [_][]const u8{
    "0",                    "1",                   "2",          "3",   "7",                   "-1",
    "255",                  "-256",                "2147483648", "-65", "9223372036854775807", "9223372036854775808",
    "-9223372036854775808", "4611686018427387904",
};
const reals = [_][]const u8{ "0.5", "1.5", "-2.25", "0.1", "1e10", "2.5e-3", "1e308", ".75" };
const strings = [_][]const u8{ "'abc'", "'ABC'", "'a%'", "'_b'", "''", "'12'", "' 3'", "'x y'", "'1.5e1'", "'abc  '" };
const json_templates = [_][]const u8{
    "'{\"a\":5,\"b\":[1,2]}' -> '$.b'",
    "'{\"a\":5,\"b\":[1,2]}' ->> '$.a'",
    "'{\"a\":\"x\"}' ->> 'a'",
    "'[1,[2,3]]' -> 1 ->> 0",
    "'{\"a\":null}' -> '$.a'",
};
const cast_types = [_][]const u8{ "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", "UNSIGNED BIG INT", "DOUBLE PRECISION", "VARCHAR(10)", "DECIMAL(10, 5)" };
const collations = [_][]const u8{ "NOCASE", "BINARY", "RTRIM" };
const like_operators = [_][]const u8{ "LIKE", "GLOB", "NOT LIKE", "NOT GLOB" };
const postfix_tests = [_][]const u8{ "ISNULL", "NOTNULL", "NOT NULL", "IS NULL", "IS NOT NULL" };

/// Builds random constant expressions with no redundant parentheses, so that the
/// grammar's precedence decides how they group.
const Generator = struct {
    gpa: std.mem.Allocator,
    random: std.Random,
    out: std.ArrayList(u8) = .empty,

    fn put(g: *Generator, text: []const u8) !void {
        try g.out.appendSlice(g.gpa, text);
    }

    fn pick(g: *Generator, choices: []const []const u8) !void {
        try g.put(choices[g.random.uintLessThan(usize, choices.len)]);
    }

    fn atom(g: *Generator) !void {
        switch (g.random.uintLessThan(u8, 10)) {
            0, 1, 2 => try g.pick(&integers),
            3 => try g.put(try std.fmt.allocPrint(g.gpa, "{d}", .{g.random.int(i64)})),
            4, 5 => try g.pick(&reals),
            6, 7 => try g.pick(&strings),
            8 => try g.put("NULL"),
            else => try g.pick(&json_templates),
        }
    }

    fn list(g: *Generator, depth: u8, min: usize, max: usize) !void {
        const n = min + g.random.uintAtMost(usize, max - min);
        for (0..n) |i| {
            if (i != 0) try g.put(", ");
            try g.expr(depth);
        }
    }

    fn expr(g: *Generator, depth: u8) std.mem.Allocator.Error!void {
        if (depth == 0) return g.atom();
        const d = depth - 1;
        switch (g.random.uintLessThan(u8, 20)) {
            0, 1 => try g.atom(),
            2, 3 => {
                try g.pick(&prefix_operators);
                try g.put(" ");
                try g.expr(d);
            },
            4, 5, 6, 7, 8, 9 => {
                try g.expr(d);
                try g.put(" ");
                try g.pick(&binary_operators);
                try g.put(" ");
                try g.expr(d);
            },
            10 => {
                try g.expr(d);
                try g.put(" ");
                try g.pick(&postfix_tests);
            },
            11 => {
                try g.expr(d);
                try g.put(if (g.random.boolean()) " BETWEEN (" else " NOT BETWEEN (");
                // A BETWEEN in the lower bound would take this one's AND.
                try g.expr(d);
                try g.put(") AND ");
                try g.expr(d);
            },
            12 => {
                try g.expr(d);
                try g.put(if (g.random.boolean()) " IN (" else " NOT IN (");
                try g.list(d, 0, 3);
                try g.put(")");
            },
            13 => {
                try g.expr(d);
                try g.put(" ");
                try g.pick(&like_operators);
                try g.put(" ");
                if (g.random.boolean()) {
                    // ESCAPE only follows a pattern that no weaker operator has absorbed.
                    try g.put("(");
                    try g.expr(d);
                    try g.put(") ESCAPE ");
                    try g.put(if (g.random.boolean()) "'!'" else "'\\'");
                } else {
                    try g.expr(d);
                }
            },
            14 => {
                try g.expr(d);
                try g.put(" COLLATE ");
                try g.pick(&collations);
            },
            15 => {
                try g.put("CASE ");
                if (g.random.boolean()) try g.expr(d);
                for (0..1 + g.random.uintAtMost(usize, 2)) |_| {
                    try g.put(" WHEN ");
                    try g.expr(d);
                    try g.put(" THEN ");
                    try g.expr(d);
                }
                if (g.random.boolean()) {
                    try g.put(" ELSE ");
                    try g.expr(d);
                }
                try g.put(" END");
            },
            16 => {
                try g.put("CAST(");
                try g.expr(d);
                try g.put(" AS ");
                try g.pick(&cast_types);
                try g.put(")");
            },
            17 => {
                const functions = [_]struct { name: []const u8, min: usize, max: usize }{
                    .{ .name = "abs", .min = 1, .max = 1 },
                    .{ .name = "length", .min = 1, .max = 1 },
                    .{ .name = "typeof", .min = 1, .max = 1 },
                    .{ .name = "nullif", .min = 2, .max = 2 },
                    .{ .name = "coalesce", .min = 2, .max = 4 },
                    .{ .name = "min", .min = 2, .max = 3 },
                    .{ .name = "max", .min = 2, .max = 3 },
                };
                const f = functions[g.random.uintLessThan(usize, functions.len)];
                try g.put(f.name);
                try g.put("(");
                try g.list(d, f.min, f.max);
                try g.put(")");
            },
            18 => {
                try g.put("(");
                try g.list(d, 2, 2);
                try g.put(") ");
                try g.pick(&.{ "=", "<", "IS", "!=" });
                try g.put(" (");
                try g.list(d, 2, 2);
                try g.put(")");
            },
            else => {
                try g.put("(");
                try g.expr(d);
                try g.put(")");
            },
        }
    }
};

const generated_seed = 0x6e47_0001;
const min_generated = 5_000;
const max_depth = 5;

test "evaluation of generated expressions is unchanged by rendering" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(generated_seed);
    var compared: usize = 0;
    var attempts: usize = 0;
    while (compared < min_generated and attempts < min_generated * 2) : (attempts += 1) {
        _ = arena_state.reset(.retain_capacity);
        var g: Generator = .{ .gpa = arena, .random = prng.random() };
        try g.put("SELECT ");
        try g.expr(1 + prng.random().uintLessThan(u8, max_depth));
        const sql = g.out.items;
        const source = try arena.dupeSentinel(u8, sql, 0);
        const ast = try sqlite_parser.Ast.parse(arena, source);
        if (ast.errors.len != 0) {
            const theirs = try oracle.check(sql);
            std.debug.print("does not parse: \"{f}\"\n  sqlite: {t} \"{s}\" offset {?d}\n  ours at {d}\n", .{
                std.zig.fmtString(sql), theirs.verdict, theirs.messageText(), theirs.error_offset, ast.errorLocation(ast.errors[0]).byte_offset,
            });
            return error.TestUnexpectedResult;
        }
        switch (try sameRows(arena, sql)) {
            .compared => compared += 1,
            .skipped => {},
            .mismatch => return error.TestUnexpectedResult,
        }
    }
    std.testing.expect(compared >= min_generated) catch |err| {
        std.debug.print("compared {d} of {d} generated expressions\n", .{ compared, attempts });
        return err;
    };
}
