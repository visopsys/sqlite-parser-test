//! Zig interface to the reference oracle in oracle/oracle.c, which asks the real
//! SQLite library whether SQL parses. Test-only. See docs/research.md, section 6.

const std = @import("std");

/// The SQLite release every verdict comes from. A different system SQLite would
/// silently move the target, so the tests refuse to run against one.
pub const expected_sqlite_version = "3.45.1";

pub const Verdict = enum(c_int) {
    /// SQLite's parser accepted the statement.
    accept = 0,
    /// SQLite's parser rejected the statement with a syntax-class error.
    reject = 1,
    /// A semantic error stopped SQLite before its parser saw the whole statement.
    unknown = 2,
};

/// SQLite's judgement of the first statement of some input.
pub const Result = struct {
    verdict: Verdict,
    /// Byte length of the statement, through its terminating `;` as
    /// `sqlite3_complete` finds it, or to the end of the input.
    length: u32,
    /// For `.reject`: the byte offset of the token SQLite blames, or null when it
    /// names none (`incomplete input`).
    error_offset: ?u32,
    message_buffer: [256]u8,

    /// SQLite's error message; empty when there was none.
    pub fn messageText(r: *const Result) []const u8 {
        return std.mem.sliceTo(&r.message_buffer, 0);
    }
};

const CResult = extern struct {
    verdict: c_int,
    length: c_int,
    error_offset: c_int,
    message: [256]u8,
};

extern fn oracle_sqlite_version() [*:0]const u8;
extern fn oracle_check(sql: [*]const u8, len: c_int, out: *CResult) c_int;
extern fn oracle_eval(sql: [*]const u8, len: c_int, buf: [*]u8, cap: c_int) c_int;

pub fn sqliteVersion() []const u8 {
    return std.mem.span(oracle_sqlite_version());
}

/// Checks the first statement of `sql`. The caller advances by `result.length`
/// to check the next one.
pub fn check(sql: []const u8) error{OutOfMemory}!Result {
    var c: CResult = undefined;
    if (oracle_check(sql.ptr, @intCast(sql.len), &c) != 0) return error.OutOfMemory;
    return .{
        .verdict = @fromBackingInt(@intCast(c.verdict)),
        .length = @intCast(c.length),
        .error_offset = if (c.error_offset >= 0) @intCast(c.error_offset) else null,
        .message_buffer = c.message,
    };
}

pub const Evaluation = union(enum) {
    /// Result rows: values as `<type>:<value>` joined by `|`, one row per line.
    rows: []const u8,
    /// SQLite's error message.
    failed: []const u8,
    /// The statement was not run: it is not one read-only statement.
    refused,
};

/// Runs the single read-only statement `sql` on an empty in-memory database.
/// The returned slices point into `buffer`.
pub fn eval(sql: []const u8, buffer: []u8) Evaluation {
    const status = oracle_eval(sql.ptr, @intCast(sql.len), buffer.ptr, @intCast(buffer.len));
    const text = std.mem.sliceTo(buffer, 0);
    return switch (status) {
        0 => .{ .rows = text },
        1 => .{ .failed = text },
        else => .refused,
    };
}

test "links the expected SQLite" {
    try std.testing.expectEqualStrings(expected_sqlite_version, sqliteVersion());
}

fn expectVerdict(sql: []const u8, verdict: Verdict) !void {
    const r = try check(sql);
    std.testing.expectEqual(verdict, r.verdict) catch |err| {
        std.debug.print("statement: {s}\nmessage: {s}\n", .{ sql, r.messageText() });
        return err;
    };
}

test "accepts valid statements, including ones with semantic errors" {
    try expectVerdict("SELECT 1", .accept);
    try expectVerdict("SELECT * FROM no_such_table", .accept);
    try expectVerdict("UPDATE t SET a = 1 ORDER BY a LIMIT 1", .accept);
    try expectVerdict(";", .accept);
    try expectVerdict("-- only a comment", .accept);
    try expectVerdict("SELECT 1 /* unterminated comment", .accept);
    try expectVerdict("ATTACH 'never-created.db' AS x", .accept);
    // Name resolution runs after the parse, so the oracle creates no stand-ins for it.
    // SQLite 3.45.1 crashes resolving this one against them.
    try expectVerdict("SELECT * FROM t5 JOIN ((t4 JOIN (t5 JOIN t6)) t7)", .accept);
    try expectVerdict("ALTER TABLE t ADD", .reject);
    try expectVerdict("CREATE TRIGGER tr AFTER INSERT ON t BEGIN", .reject);
    try expectVerdict("CREATE TABLE t(a COLLATE c", .reject);
    try expectVerdict("CREATE TABLE t(a COLLATE c)", .accept);
}

test "creates stand-ins for missing schema objects" {
    try expectVerdict("CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END", .accept);
    try expectVerdict("CREATE TRIGGER tr INSTEAD OF INSERT ON v BEGIN SELECT 1; END", .accept);
    try expectVerdict("ALTER TABLE t ADD COLUMN c INTEGER NOT NULL DEFAULT 0", .accept);
    try expectVerdict("CREATE TABLE aux.t(a)", .accept);
    try expectVerdict("SELECT 1 COLLATE no_such_collation", .accept);
    try expectVerdict("CREATE TRIGGER tr AFTER INSERT ON t BEGIN garbage; END", .reject);
    // "unknown database aux" is raised on the last token, before the parser sees
    // that the statement ends too early.
    const r = try check("CREATE TABLE aux.t (");
    try std.testing.expectEqual(Verdict.reject, r.verdict);
    try std.testing.expectEqualStrings("incomplete input", r.messageText());
}

test "rejects syntax errors with SQLite's message and offset" {
    var r = try check("SELECT 1 FROM WHERE");
    try std.testing.expectEqual(Verdict.reject, r.verdict);
    try std.testing.expectEqualStrings("near \"WHERE\": syntax error", r.messageText());
    try std.testing.expectEqual(@as(?u32, 14), r.error_offset);

    r = try check("SELECT (1");
    try std.testing.expectEqual(Verdict.reject, r.verdict);
    try std.testing.expectEqualStrings("incomplete input", r.messageText());
    try std.testing.expectEqual(@as(?u32, null), r.error_offset);

    r = try check("SELECT x'abc'");
    try std.testing.expectEqualStrings("unrecognized token: \"x'abc'\"", r.messageText());
    try std.testing.expectEqual(@as(?u32, 7), r.error_offset);

    try expectVerdict("SELECT * FROM a NATURAL FOO JOIN b", .reject);
    try expectVerdict("CREATE TABLE t(a) WITHOUT foo", .reject);
    try expectVerdict("SELECT 1 UNION SELECT 2 ORDER BY 1 UNION SELECT 3", .reject);
}

test "reports unknown when a semantic error hides the rest of the statement" {
    try expectVerdict("CREATE TABLE t(a, a, b garbage(", .unknown);
}

test "splits statements the way sqlite3_complete does" {
    const script = "SELECT 1; CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END; SELECT";
    var r = try check(script);
    try std.testing.expectEqual(@as(u32, 9), r.length);
    r = try check(script[9..]);
    try std.testing.expectEqualStrings(" CREATE TRIGGER tr AFTER INSERT ON t BEGIN SELECT 1; END;", script[9..][0..r.length]);
    r = try check(script[9 + r.length ..]);
    try std.testing.expectEqual(Verdict.reject, r.verdict);
    try std.testing.expectEqualStrings("incomplete input", r.messageText());
}

test "evaluates read-only statements only" {
    var buffer: [256]u8 = undefined;
    switch (eval("SELECT 1 + 2 * 3, 'a' || 'b', NULL, 1.5, x'ff'", &buffer)) {
        .rows => |rows| try std.testing.expectEqualStrings("integer:7|text:ab|null:|real:1.5|blob:ff\n", rows),
        else => return error.TestUnexpectedResult,
    }
    switch (eval("SELECT * FROM missing", &buffer)) {
        .failed => |msg| try std.testing.expectEqualStrings("no such table: missing", msg),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Evaluation.refused, eval("CREATE TABLE t(a)", &buffer));
    try std.testing.expectEqual(Evaluation.refused, eval("SELECT 1; SELECT 2", &buffer));
}
