//! Compares our parser with SQLite's on the corpus and on mutants of it. This file
//! holds the pieces that decide whether the two agree: the statement families, which
//! say what is checked yet, and `compare`, which says what agreeing means.

const std = @import("std");
const sqlite_parser = @import("sqlite_parser");
const corpus = @import("corpus.zig");
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

/// One disagreement between SQLite and our parser, with everything needed to read it.
const Failure = struct {
    case_id: []const u8,
    index: usize,
    statement: []const u8,
    mismatch: Mismatch,
    sqlite_verdict: oracle.Verdict,
    sqlite_message: []const u8,
    sqlite_offset: ?u32,
    ours: Outcome,
    /// For a mutant: the corpus statement it came from and what was changed.
    original: ?[]const u8 = null,
    mutation: ?[]const u8 = null,

    pub fn format(failure: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}#{d}: {t} differs\n  statement: \"{f}\"\n", .{
            failure.case_id,
            failure.index,
            failure.mismatch,
            std.zig.fmtString(failure.statement),
        });
        if (failure.original) |original| try w.print("  original:  \"{f}\"\n", .{std.zig.fmtString(original)});
        if (failure.mutation) |mutation| try w.print("  mutation:  {s}\n", .{mutation});
        try w.print("  sqlite: {t} \"{f}\" offset {?d}\n", .{
            failure.sqlite_verdict,
            std.zig.fmtString(failure.sqlite_message),
            failure.sqlite_offset,
        });
        try w.print("  ours:   {s} \"{f}\" offset {?d}\n", .{
            if (failure.ours.accepted) "accept" else "reject",
            std.zig.fmtString(failure.ours.message),
            failure.ours.offset,
        });
    }
};

/// Collects failures and per-family counts over a run, then reports them all at once.
const Report = struct {
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayList(Failure) = .empty,
    /// Stale or dangling lines of known_divergences.txt.
    stale: std.ArrayList([]const u8) = .empty,
    checked: std.EnumArray(Family, usize) = .initFill(0),
    skipped_unknown: std.EnumArray(Family, usize) = .initFill(0),

    const max_printed = 20;

    fn init(gpa: std.mem.Allocator) Report {
        return .{ .arena = .init(gpa) };
    }

    fn deinit(report: *Report) void {
        report.arena.deinit();
    }

    fn totalChecked(report: *const Report) usize {
        var total: usize = 0;
        for (report.checked.values) |n| total += n;
        return total;
    }

    /// Records a failure, copying the strings that the caller reuses.
    fn addFailure(report: *Report, failure: Failure) !void {
        const arena = report.arena.allocator();
        var copy = failure;
        copy.statement = try arena.dupe(u8, failure.statement);
        copy.sqlite_message = try arena.dupe(u8, failure.sqlite_message);
        copy.ours.message = try arena.dupe(u8, failure.ours.message);
        if (failure.original) |s| copy.original = try arena.dupe(u8, s);
        if (failure.mutation) |s| copy.mutation = try arena.dupe(u8, s);
        try report.failures.append(arena, copy);
    }

    fn addStale(report: *Report, comptime fmt: []const u8, args: anytype) !void {
        const arena = report.arena.allocator();
        try report.stale.append(arena, try std.fmt.allocPrint(arena, fmt, args));
    }

    /// Prints the first failures, the counts and a per-family summary, and fails if
    /// anything disagreed.
    fn finish(report: *const Report) !void {
        const total = report.failures.items.len + report.stale.items.len;
        if (total == 0) return;
        for (report.failures.items[0..@min(report.failures.items.len, max_printed)]) |failure| {
            std.debug.print("{f}", .{failure});
        }
        for (report.stale.items) |line| std.debug.print("known_divergences.txt: {s}\n", .{line});
        std.debug.print("{d} disagreements (at most {d} listed above)\n", .{ total, max_printed });
        std.debug.print("checked/unknown per family:", .{});
        for (std.enums.values(Family)) |family| {
            std.debug.print(" {t}={d}/{d}", .{
                family, report.checked.get(family), report.skipped_unknown.get(family),
            });
        }
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    }
};

/// What the walk learned about a line of known_divergences.txt.
const DivergenceState = enum { unvisited, skipped, agreed, disagreed };

/// The `<case id>#<index>` keys of known_divergences.txt.
fn loadDivergences(arena: std.mem.Allocator, text: []const u8) !std.StringHashMapUnmanaged(DivergenceState) {
    var map: std.StringHashMapUnmanaged(DivergenceState) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const key = line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len];
        try map.put(arena, key, .unvisited);
    }
    return map;
}

fn checkCorpus(gpa: std.mem.Allocator, report: *Report) !void {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var divergences = try loadDivergences(report.arena.allocator(), @embedFile("known_divergences.txt"));

    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        var pos: usize = 0;
        var index: usize = 0;
        while (pos < case.sql.len) : (index += 1) {
            _ = scratch_state.reset(.retain_capacity);
            const result = try oracle.check(case.sql[pos..]);
            const statement = case.sql[pos..][0..result.length];
            pos += result.length;

            const key = try std.fmt.allocPrint(scratch, "{s}#{d}", .{ case.id, index });
            const state = divergences.getPtr(key);
            if (state) |s| s.* = .skipped;

            const source = try scratch.dupeSentinel(u8, statement, 0);
            const family = familyOf(source);
            if (!isImplemented(family)) continue;
            if (result.verdict == .unknown) {
                report.skipped_unknown.getPtr(family).* += 1;
                continue;
            }
            report.checked.getPtr(family).* += 1;

            const ours = try judge(scratch, statement);
            if (compare(result, ours)) |mismatch| {
                if (state) |s| {
                    s.* = .disagreed;
                    continue;
                }
                try report.addFailure(.{
                    .case_id = case.id,
                    .index = index,
                    .statement = statement,
                    .mismatch = mismatch,
                    .sqlite_verdict = result.verdict,
                    .sqlite_message = result.messageText(),
                    .sqlite_offset = result.error_offset,
                    .ours = ours,
                });
            } else if (state) |s| {
                s.* = .agreed;
            }
        }
    }

    var entries = divergences.iterator();
    while (entries.next()) |entry| switch (entry.value_ptr.*) {
        .unvisited => try report.addStale("{s} names no statement", .{entry.key_ptr.*}),
        .agreed => try report.addStale("{s} now agrees; remove it", .{entry.key_ptr.*}),
        .skipped, .disagreed => {},
    };
}

test "the parser agrees with SQLite on the corpus" {
    var report: Report = .init(std.testing.allocator);
    defer report.deinit();
    try checkCorpus(std.testing.allocator, &report);
    try report.finish();
    try std.testing.expect(report.totalChecked() > 1000);
}
