//! Compares our parser with SQLite's on the corpus and on mutants of it. This file
//! holds the pieces that decide whether the two agree: the statement families, which
//! say what is checked yet, and `compare`, which says what agreeing means.

const std = @import("std");
const sqlite_parser = @import("sqlite_parser");
const oracle = @import("oracle.zig");

const Ast = sqlite_parser.Ast;
const Tag = sqlite_parser.tokenizer.Token.Tag;
const Tokenizer = sqlite_parser.tokenizer.Tokenizer;

/// The kind of a statement, by its leading keywords. Families are enabled for
/// checking one at a time, as the parser learns them.
pub const Family = enum {
    empty,
    transaction,
    pragma,
    attach,
    maintenance,
    select_expressions,
    select,
    select_advanced,
    insert,
    update,
    delete,
    create_table,
    alter_table,
    create_index,
    create_view,
    create_virtual_table,
    drop,
    create_trigger,
    other,
};

/// The families whose statements the differential tests check.
const implemented = [_]Family{ .empty, .transaction, .other };

fn isImplemented(family: Family) bool {
    return std.mem.indexOfScalar(Family, &implemented, family) != null;
}

/// Classifies one statement by its first token after an optional `EXPLAIN [QUERY PLAN]`.
fn familyOf(statement: [:0]const u8) Family {
    var t: Tokenizer = .init(statement);
    var first = t.next();
    if (first.tag == .keyword_explain) {
        first = t.next();
        if (first.tag == .keyword_query) {
            const plan = t.next();
            if (plan.tag != .keyword_plan) return .other;
            first = t.next();
        }
    }
    return switch (first.tag) {
        .eof, .semicolon => .empty,
        .keyword_begin,
        .keyword_commit,
        .keyword_end,
        .keyword_rollback,
        .keyword_savepoint,
        .keyword_release,
        => .transaction,
        .keyword_pragma => .pragma,
        .keyword_attach, .keyword_detach => .attach,
        .keyword_vacuum, .keyword_reindex, .keyword_analyze => .maintenance,
        .keyword_select, .keyword_values => selectFamily(&t, first.tag),
        .keyword_with => withFamily(&t),
        .keyword_insert, .keyword_replace => .insert,
        .keyword_update => .update,
        .keyword_delete => .delete,
        .keyword_create => createFamily(&t),
        .keyword_alter => .alter_table,
        .keyword_drop => .drop,
        else => .other,
    };
}

fn selectFamily(t: *Tokenizer, first: Tag) Family {
    var expressions = first == .keyword_select;
    var advanced = false;
    while (true) {
        switch (t.next().tag) {
            .eof => break,
            .keyword_with, .keyword_over, .keyword_filter, .keyword_window => advanced = true,
            .keyword_from,
            .keyword_where,
            .keyword_group,
            .keyword_having,
            .keyword_order,
            .keyword_limit,
            .keyword_union,
            .keyword_intersect,
            .keyword_except,
            .keyword_values,
            .keyword_select,
            .keyword_exists,
            .keyword_in,
            => expressions = false,
            else => {},
        }
        if (advanced) return .select_advanced;
    }
    return if (expressions) .select_expressions else .select;
}

fn withFamily(t: *Tokenizer) Family {
    var depth: usize = 0;
    while (true) {
        switch (t.next().tag) {
            .eof => return .other,
            .l_paren => depth += 1,
            .r_paren => depth -|= 1,
            .keyword_select, .keyword_values => if (depth == 0) return .select_advanced,
            .keyword_insert, .keyword_replace => if (depth == 0) return .insert,
            .keyword_update => if (depth == 0) return .update,
            .keyword_delete => if (depth == 0) return .delete,
            else => {},
        }
    }
}

fn createFamily(t: *Tokenizer) Family {
    var tag = t.next().tag;
    if (tag == .keyword_temp) tag = t.next().tag;
    if (tag == .keyword_unique) tag = t.next().tag;
    return switch (tag) {
        .keyword_table => .create_table,
        .keyword_index => .create_index,
        .keyword_view => .create_view,
        .keyword_virtual => .create_virtual_table,
        .keyword_trigger => .create_trigger,
        else => .other,
    };
}

/// What our parser said about a statement.
const Outcome = struct {
    accepted: bool,
    /// Our rendering of the first error; empty when accepted.
    message: []const u8,
    /// Byte offset of the token we blame; null when accepted.
    offset: ?usize,
};

const Mismatch = enum { verdict, message, offset };

/// Whether our `ours` agrees with SQLite's `result`: the same verdict and, for a
/// rejection, the same message and, when SQLite names one, the same offset. Null
/// means agreement, or that SQLite's verdict is `unknown` and nothing can be compared.
fn compare(result: oracle.Result, ours: Outcome) ?Mismatch {
    const accepted = switch (result.verdict) {
        .unknown => return null,
        .accept => true,
        .reject => false,
    };
    if (accepted != ours.accepted) return .verdict;
    if (accepted) return null;
    if (!std.mem.eql(u8, result.messageText(), ours.message)) return .message;
    if (result.error_offset) |offset| {
        if (offset != ours.offset) return .offset;
    }
    return null;
}

/// Parses `statement` and summarizes the result. The message is allocated in `arena`.
fn judge(arena: std.mem.Allocator, statement: []const u8) !Outcome {
    const source = try arena.dupeSentinel(u8, statement, 0);
    const ast = try Ast.parse(arena, source);
    if (ast.errors.len == 0) return .{ .accepted = true, .message = "", .offset = null };
    var message: std.Io.Writer.Allocating = .init(arena);
    try ast.renderError(ast.errors[0], &message.writer);
    return .{
        .accepted = false,
        .message = message.written(),
        .offset = ast.errorLocation(ast.errors[0]).byte_offset,
    };
}

fn expectFamily(expected: Family, statement: [:0]const u8) !void {
    try std.testing.expectEqual(expected, familyOf(statement));
}

test "familyOf classifies each family" {
    try expectFamily(.empty, ";");
    try expectFamily(.empty, "  -- comment\n");
    try expectFamily(.transaction, "BEGIN");
    try expectFamily(.transaction, "EXPLAIN QUERY PLAN BEGIN");
    try expectFamily(.transaction, "explain rollback to s");
    try expectFamily(.transaction, "SAVEPOINT s");
    try expectFamily(.pragma, "PRAGMA foreign_keys");
    try expectFamily(.attach, "ATTACH 'a' AS b");
    try expectFamily(.attach, "DETACH b");
    try expectFamily(.maintenance, "VACUUM");
    try expectFamily(.maintenance, "REINDEX t");
    try expectFamily(.maintenance, "ANALYZE");
    try expectFamily(.select_expressions, "SELECT 1+1");
    try expectFamily(.select_expressions, "SELECT x'abc'");
    try expectFamily(.select, "SELECT 1 FROM t");
    try expectFamily(.select, "VALUES (1)");
    try expectFamily(.select, "SELECT 1 UNION SELECT 2");
    try expectFamily(.select_advanced, "SELECT count(*) OVER () FROM t");
    try expectFamily(.select_advanced, "SELECT 1 FROM t WINDOW w AS ()");
    try expectFamily(.select_advanced, "WITH x AS (SELECT 1) SELECT * FROM x");
    try expectFamily(.insert, "INSERT INTO t VALUES (1)");
    try expectFamily(.insert, "REPLACE INTO t VALUES (1)");
    try expectFamily(.insert, "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x");
    try expectFamily(.update, "UPDATE t SET a = 1");
    try expectFamily(.delete, "DELETE FROM t");
    try expectFamily(.delete, "WITH x AS (SELECT 1) DELETE FROM t");
    try expectFamily(.create_table, "CREATE TABLE t(a)");
    try expectFamily(.create_table, "CREATE TEMP TABLE t(a)");
    try expectFamily(.alter_table, "ALTER TABLE t RENAME TO u");
    try expectFamily(.create_index, "CREATE UNIQUE INDEX i ON t(a)");
    try expectFamily(.create_view, "CREATE VIEW v AS SELECT 1");
    try expectFamily(.create_virtual_table, "CREATE VIRTUAL TABLE t USING m");
    try expectFamily(.drop, "DROP TABLE t");
    try expectFamily(.create_trigger, "CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END");
    try expectFamily(.other, "@");
    try expectFamily(.other, "FOO");
    try expectFamily(.other, "CREATE FOO");
}

fn check(statement: []const u8) !oracle.Result {
    return oracle.check(statement);
}

test "compare accepts agreement" {
    try std.testing.expectEqual(null, compare(try check("COMMIT"), .{ .accepted = true, .message = "", .offset = null }));
    try std.testing.expectEqual(null, compare(try check("BEGIN FOO"), .{
        .accepted = false,
        .message = "near \"FOO\": syntax error",
        .offset = 6,
    }));
}

test "compare skips unknown verdicts" {
    const result = try check("CREATE TABLE t(a, a, b garbage(");
    try std.testing.expectEqual(null, compare(result, .{ .accepted = true, .message = "", .offset = null }));
}

test "compare ignores our offset when SQLite names none" {
    const result = try check("SAVEPOINT");
    try std.testing.expectEqual(null, compare(result, .{ .accepted = false, .message = "incomplete input", .offset = 9 }));
}

test "compare reports a deliberately wrong verdict" {
    const wrong: Outcome = .{ .accepted = false, .message = "near \"BEGIN\": syntax error", .offset = 0 };
    try std.testing.expectEqual(Mismatch.verdict, compare(try check("BEGIN"), wrong));
}

test "compare reports a wrong message and a wrong offset" {
    const result = try check("BEGIN FOO");
    try std.testing.expectEqual(Mismatch.message, compare(result, .{
        .accepted = false,
        .message = "near \"BEGIN\": syntax error",
        .offset = 6,
    }));
    try std.testing.expectEqual(Mismatch.offset, compare(result, .{
        .accepted = false,
        .message = "near \"FOO\": syntax error",
        .offset = 5,
    }));
}

test "judge summarizes our parse" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ok = try judge(arena, "COMMIT");
    try std.testing.expect(ok.accepted);
    const bad = try judge(arena, "BEGIN FOO");
    try std.testing.expect(!bad.accepted);
    try std.testing.expectEqualStrings("near \"FOO\": syntax error", bad.message);
    try std.testing.expectEqual(@as(?usize, 6), bad.offset);
}
