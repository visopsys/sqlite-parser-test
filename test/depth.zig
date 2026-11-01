//! Checks that the parser's nesting limit is no lower than SQLite's: every deeply
//! nested statement SQLite parses, we parse too, and none overflows the stack.

const std = @import("std");
const sqlite_parser = @import("sqlite_parser");
const oracle = @import("oracle.zig");

const Ast = sqlite_parser.Ast;

/// A statement built by repeating `open` and `close` around `middle` `n` times.
const Nesting = struct {
    name: []const u8,
    prefix: []const u8,
    open: []const u8,
    middle: []const u8,
    close: []const u8,
    suffix: []const u8 = "",
};

const nestings = [_]Nesting{
    .{ .name = "parentheses", .prefix = "SELECT ", .open = "(", .middle = "1", .close = ")" },
    .{ .name = "unary minus", .prefix = "SELECT ", .open = "- ", .middle = "1", .close = "" },
    .{ .name = "NOT", .prefix = "SELECT ", .open = "NOT ", .middle = "1", .close = "" },
    .{ .name = "binary operators", .prefix = "SELECT ", .open = "1 + (", .middle = "1", .close = ")" },
    .{ .name = "scalar subqueries", .prefix = "SELECT ", .open = "(SELECT ", .middle = "1", .close = ")" },
    .{ .name = "FROM subqueries", .prefix = "SELECT * FROM ", .open = "(SELECT * FROM ", .middle = "(SELECT 1)", .close = ")" },
    .{ .name = "CASE", .prefix = "SELECT ", .open = "CASE WHEN 1 THEN ", .middle = "1", .close = " END" },
    .{ .name = "function calls", .prefix = "SELECT ", .open = "abs(", .middle = "1", .close = ")" },
    .{ .name = "IN lists", .prefix = "SELECT 1 IN (", .open = "1 IN (", .middle = "1", .close = ")", .suffix = ")" },
};

const depths = [_]usize{ 1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100, 200, 500, 999, 1000, 1001, 3000, 100_000 };

fn build(gpa: std.mem.Allocator, nesting: Nesting, n: usize) ![:0]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(gpa);
    try source.appendSlice(gpa, nesting.prefix);
    for (0..n) |_| try source.appendSlice(gpa, nesting.open);
    try source.appendSlice(gpa, nesting.middle);
    for (0..n) |_| try source.appendSlice(gpa, nesting.close);
    try source.appendSlice(gpa, nesting.suffix);
    return source.toOwnedSliceSentinel(gpa, 0);
}

test "the parser accepts every nesting depth SQLite accepts" {
    const gpa = std.testing.allocator;
    for (nestings) |nesting| {
        var deepest_accepted: usize = 0;
        for (depths) |n| {
            const source = try build(gpa, nesting, n);
            defer gpa.free(source);
            var ast = try Ast.parse(gpa, source);
            defer ast.deinit(gpa);
            const result = try oracle.check(source);
            const sqlite_accepts = result.verdict == .accept and result.messageText().len == 0;
            if (sqlite_accepts) deepest_accepted = n;
            if (sqlite_accepts and ast.errors.len != 0) {
                std.debug.print("{s} at depth {d}: SQLite accepts, we report ", .{ nesting.name, n });
                var buf: [256]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                try ast.renderError(ast.errors[0], &w);
                std.debug.print("{s}\n", .{w.buffered()});
                return error.TestUnexpectedResult;
            }
        }
        // The test means something only when SQLite accepts some nesting. Its parser
        // stack (YYSTACKDEPTH, 100 entries) is the binding limit, well below
        // SQLITE_MAX_EXPR_DEPTH: of the depths tried, 3.45.1 accepts at most 90
        // parentheses, 30 function calls and 10 FROM subqueries. Ours is 1000.
        std.testing.expect(deepest_accepted >= 10) catch |err| {
            std.debug.print("{s}: SQLite accepts only depth {d}\n", .{ nesting.name, deepest_accepted });
            return err;
        };
    }
}
