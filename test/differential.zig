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

/// A WITH-led statement without a top-level SELECT, VALUES or DML keyword is a broken
/// one of the WITH families, not an `other`: SQLite's verdict depends on the CTE grammar.
fn withFamily(t: *Tokenizer) Family {
    var depth: usize = 0;
    while (true) {
        switch (t.next().tag) {
            .eof => return .select_advanced,
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

const Mismatch = enum {
    verdict,
    message,
    offset,
    /// SQLite rejects our rendering of a statement we accepted.
    render_rejected,
    /// Our rendering does not parse back to the same rendering.
    render_unstable,
};

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
    try expectFamily(.select_advanced, "WITH ;");
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
    /// For a round-trip failure: our rendering of the statement.
    rendering: ?[]const u8 = null,

    pub fn format(failure: Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}#{d}: {t} differs\n  statement: \"{f}\"\n", .{
            failure.case_id,
            failure.index,
            failure.mismatch,
            std.zig.fmtString(failure.statement),
        });
        if (failure.original) |original| try w.print("  original:  \"{f}\"\n", .{std.zig.fmtString(original)});
        if (failure.mutation) |mutation| try w.print("  mutation:  {s}\n", .{mutation});
        if (failure.rendering) |rendering| try w.print("  rendering: \"{f}\"\n", .{std.zig.fmtString(rendering)});
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
    /// Mutants that SQLite reads as several statements.
    skipped_split: usize = 0,

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
        if (failure.rendering) |s| copy.rendering = try arena.dupe(u8, s);
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
        std.debug.print(" split mutants={d}\n", .{report.skipped_split});
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

/// Where a checked statement came from, for the failure report.
const Origin = struct {
    case_id: []const u8,
    index: usize,
    original: ?[]const u8 = null,
    mutation: ?[]const u8 = null,
};

fn failureOf(origin: Origin, statement: []const u8, mismatch: Mismatch, result: oracle.Result, ours: Outcome) Failure {
    return .{
        .case_id = origin.case_id,
        .index = origin.index,
        .statement = statement,
        .mismatch = mismatch,
        .sqlite_verdict = result.verdict,
        .sqlite_message = result.messageText(),
        .sqlite_offset = result.error_offset,
        .ours = ours,
        .original = origin.original,
        .mutation = origin.mutation,
    };
}

/// Checks that SQLite accepts our rendering of `statement`, which we accepted, and
/// that parsing the rendering renders the same text.
fn checkRoundTrip(report: *Report, scratch: std.mem.Allocator, origin: Origin, statement: []const u8, result: oracle.Result, ours: Outcome) !void {
    const rendered = try renderStatement(scratch, statement);
    const mismatch: ?Mismatch = if ((try oracle.check(rendered)).verdict == .reject)
        .render_rejected
    else if (!std.mem.eql(u8, rendered, try renderStatement(scratch, rendered)))
        .render_unstable
    else
        null;
    if (mismatch) |m| {
        var failure = failureOf(origin, statement, m, result, ours);
        failure.rendering = rendered;
        try report.addFailure(failure);
    }
}

/// Our canonical rendering of `statement`; empty when it does not parse.
fn renderStatement(arena: std.mem.Allocator, statement: []const u8) ![]const u8 {
    const ast = try Ast.parse(arena, try arena.dupeSentinel(u8, statement, 0));
    if (ast.errors.len != 0) return "";
    var out: std.Io.Writer.Allocating = .init(arena);
    try ast.render(&out.writer);
    return out.written();
}

/// Compares one statement with SQLite's `result`, and round-trips it when we accept
/// it. A `state` marks a statement of known_divergences.txt. Returns whether the
/// statement was compared, rather than skipped for its family or an unknown verdict.
fn checkStatement(
    report: *Report,
    scratch: std.mem.Allocator,
    origin: Origin,
    statement: []const u8,
    result: oracle.Result,
    state: ?*DivergenceState,
) !bool {
    const family = familyOf(try scratch.dupeSentinel(u8, statement, 0));
    if (!isImplemented(family)) return false;
    const ours = try judge(scratch, statement);
    if (ours.accepted) try checkRoundTrip(report, scratch, origin, statement, result, ours);
    if (result.verdict == .unknown) {
        report.skipped_unknown.getPtr(family).* += 1;
        return false;
    }
    report.checked.getPtr(family).* += 1;
    if (compare(result, ours)) |mismatch| {
        if (state) |s| {
            s.* = .disagreed;
        } else {
            try report.addFailure(failureOf(origin, statement, mismatch, result, ours));
        }
    } else if (state) |s| {
        s.* = .agreed;
    }
    return true;
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
            _ = try checkStatement(report, scratch, .{ .case_id = case.id, .index = index }, statement, result, state);
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

const operators = [_][]const u8{
    "+",  "-",  "*", "/", "%",  "=", "==", "!=", "<>", "<", "<=", ">", ">=",
    "<<", ">>", "&", "|", "||", "~", ",",  ".",  "(",  ")", ";",
};
const literals = [_][]const u8{ "1", "1.5", "'s'", "x'00'", "?", "abc", "\"q\"" };

/// A random keyword, operator or literal.
fn vocabularyToken(random: std.Random) []const u8 {
    const keyword_keys = sqlite_parser.tokenizer.keywords.keys();
    var i = random.uintLessThan(usize, keyword_keys.len + operators.len + literals.len);
    if (i < keyword_keys.len) return keyword_keys[i];
    i -= keyword_keys.len;
    if (i < operators.len) return operators[i];
    return literals[i - operators.len];
}

const Mutation = enum { delete, duplicate, swap, replace, insert, truncate };

/// The lexemes of `source` as slices of it, `invalid` ones included.
fn tokenTexts(arena: std.mem.Allocator, source: [:0]const u8) ![]const []const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    var t: Tokenizer = .init(source);
    while (true) {
        const token = t.next();
        if (token.tag == .eof) return texts.items;
        try texts.append(arena, source[token.loc.start..token.loc.end]);
    }
}

/// Applies one random mutation to the tokens of `original` and joins them with single
/// spaces so that they do not fuse. `description` receives what was done.
fn mutate(arena: std.mem.Allocator, random: std.Random, original: []const u8, description: *[]const u8) ![]const u8 {
    const texts = try tokenTexts(arena, try arena.dupeSentinel(u8, original, 0));
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(arena, texts);
    var kind = random.enumValue(Mutation);
    if (kind == .swap and list.items.len < 2) kind = .insert;
    const i = switch (kind) {
        .insert => random.uintAtMost(usize, list.items.len),
        .swap => random.uintLessThan(usize, list.items.len - 1),
        else => random.uintLessThan(usize, list.items.len),
    };
    const vocabulary = vocabularyToken(random);
    var detail: []const u8 = "";
    switch (kind) {
        .delete => _ = list.orderedRemove(i),
        .duplicate => try list.insert(arena, i, list.items[i]),
        .swap => std.mem.swap([]const u8, &list.items[i], &list.items[i + 1]),
        .replace => {
            detail = vocabulary;
            list.items[i] = vocabulary;
        },
        .insert => {
            detail = vocabulary;
            try list.insert(arena, i, vocabulary);
        },
        .truncate => list.shrinkRetainingCapacity(i + 1),
    }
    description.* = try std.fmt.allocPrint(arena, "{t} at token {d} {s}", .{ kind, i, detail });
    return std.mem.join(arena, " ", list.items);
}

/// The corpus statements of implemented families that have at least one token.
fn implementedStatements(arena: std.mem.Allocator) ![]const []const u8 {
    var statements: std.ArrayList([]const u8) = .empty;
    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        var pos: usize = 0;
        while (pos < case.sql.len) {
            const length = (try oracle.check(case.sql[pos..])).length;
            const statement = case.sql[pos..][0..length];
            pos += length;
            const source = try arena.dupeSentinel(u8, statement, 0);
            if (!isImplemented(familyOf(source))) continue;
            if ((try tokenTexts(arena, source)).len == 0) continue;
            try statements.append(arena, statement);
        }
    }
    return statements.items;
}

const mutant_seed = 0x5eed_5917;
const min_mutants = 20_000;

/// Mutates corpus statements until `min_mutants` of them were compared with SQLite.
/// Returns the number compared.
fn checkMutants(gpa: std.mem.Allocator, report: *Report) !usize {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const statements = try implementedStatements(report.arena.allocator());

    var prng: std.Random.DefaultPrng = .init(mutant_seed);
    const random = prng.random();
    var compared: usize = 0;
    var attempts: usize = 0;
    while (compared < min_mutants and attempts < min_mutants * 10) : (attempts += 1) {
        _ = scratch_state.reset(.retain_capacity);
        const original = statements[random.uintLessThan(usize, statements.len)];
        var description: []const u8 = undefined;
        const mutant = try mutate(scratch, random, original, &description);
        const result = try oracle.check(mutant);
        if (result.length < mutant.len) {
            report.skipped_split += 1;
            continue;
        }
        const origin: Origin = .{ .case_id = "mutant", .index = attempts, .original = original, .mutation = description };
        if (try checkStatement(report, scratch, origin, mutant, result, null)) compared += 1;
    }
    return compared;
}

test "the parser agrees with SQLite on mutants of the corpus" {
    var report: Report = .init(std.testing.allocator);
    defer report.deinit();
    const compared = try checkMutants(std.testing.allocator, &report);
    try report.finish();
    try std.testing.expect(compared >= min_mutants);
}

fn fuzzStatement(_: void, smith: *std.testing.Smith) !void {
    var raw: [256]u8 = undefined;
    const len = smith.slice(&raw);
    const input = raw[0 .. std.mem.indexOfScalar(u8, raw[0..len], 0) orelse len];
    var report: Report = .init(std.testing.allocator);
    defer report.deinit();
    var scratch_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch_state.deinit();
    const result = try oracle.check(input);
    if (result.length >= input.len) {
        _ = try checkStatement(&report, scratch_state.allocator(), .{ .case_id = "fuzz", .index = 0 }, input, result, null);
    }
    try report.finish();
}

test "fuzz: the parser agrees with SQLite on arbitrary input" {
    try std.testing.fuzz({}, fuzzStatement, .{});
}
