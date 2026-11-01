//! Reads test/corpus/*.sql files: SQL scripts, each introduced by a header line
//! `#### <id>`. See tools/extract_corpus.py for how they are made.

const std = @import("std");

/// The scripts extracted from SQLite's own test suite at tag version-3.45.1.
pub const sqlite_tests = @embedFile("corpus/sqlite-tests.sql");

pub const Case = struct {
    /// Where the script came from, as `<test file>:<line>`.
    id: []const u8,
    /// The SQL text, ending in a newline.
    sql: []const u8,
};

pub const Iterator = struct {
    rest: []const u8,

    const header = "#### ";

    pub fn init(bytes: []const u8) Iterator {
        std.debug.assert(bytes.len == 0 or std.mem.startsWith(u8, bytes, header));
        return .{ .rest = bytes };
    }

    pub fn next(it: *Iterator) ?Case {
        if (it.rest.len == 0) return null;
        const id_end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
        const id = it.rest[header.len..id_end];
        const body = it.rest[@min(id_end + 1, it.rest.len)..];
        const body_end = if (std.mem.indexOf(u8, body, "\n" ++ header)) |i| i + 1 else body.len;
        it.rest = body[body_end..];
        return .{ .id = id, .sql = body[0..body_end] };
    }
};

test "iterates cases in order" {
    var it: Iterator = .init("#### a.test:1\nSELECT 1;\n#### b.test:2\nSELECT\n  2\n");
    const a = it.next().?;
    try std.testing.expectEqualStrings("a.test:1", a.id);
    try std.testing.expectEqualStrings("SELECT 1;\n", a.sql);
    const b = it.next().?;
    try std.testing.expectEqualStrings("b.test:2", b.id);
    try std.testing.expectEqualStrings("SELECT\n  2\n", b.sql);
    try std.testing.expectEqual(null, it.next());
}
