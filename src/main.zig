//! `sqlcheck [FILE...]`: checks SQL files, or stdin when none is given, against
//! SQLite's syntax. Exit status: 0 all valid, 1 a syntax error, 2 an unreadable file.

const std = @import("std");
const Ast = @import("sqlite_parser").Ast;

const max_source_bytes = 1 << 30;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var status: u8 = 0;
    if (args.len <= 1) {
        const source = readStdin(gpa, io) catch |err| {
            try stderr.print("sqlcheck: <stdin>: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(2);
        };
        defer gpa.free(source);
        if (try check(gpa, "<stdin>", source, stderr)) status = 1;
    }
    for (args[1..]) |path| {
        const source = std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| {
            try stderr.print("sqlcheck: {s}: {s}\n", .{ path, @errorName(err) });
            status = 2;
            continue;
        };
        defer gpa.free(source);
        if (try check(gpa, path, source, stderr)) status = @max(status, 1);
    }
    try stderr.flush();
    if (status != 0) std.process.exit(status);
}

fn readStdin(gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    var reader = std.Io.File.stdin().readerStreaming(io, &.{});
    return reader.interface.allocRemainingAlignedSentinel(gpa, .limited(max_source_bytes), .of(u8), 0) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// Reports the first syntax error in `source` to `out`. Returns whether there was one.
fn check(gpa: std.mem.Allocator, name: []const u8, source: [:0]const u8, out: *std.Io.Writer) !bool {
    var ast = try Ast.parse(gpa, source);
    defer ast.deinit(gpa);
    if (ast.errors.len == 0) return false;

    const err = ast.errors[0];
    const loc = ast.errorLocation(err);
    const token = ast.tokens.items(.loc)[@backingInt(err.token)];
    try out.print("{s}:{d}:{d}: error: ", .{ name, loc.line, loc.column });
    try ast.renderError(err, out);
    try out.writeByte('\n');
    try writeCaretLines(out, source, loc.byte_offset, token.end - token.start);
    return true;
}

/// Writes the source line containing `offset`, then a line with `^` under `offset` and `~`
/// under the rest of the `len`-byte token, cut off at the end of the line. Tabs before the
/// token are kept so the caret lines up.
fn writeCaretLines(out: *std.Io.Writer, source: []const u8, offset: usize, len: usize) !void {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfAnyPos(u8, source, offset, "\r\n") orelse source.len;
    try out.print("{s}\n", .{source[line_start..line_end]});
    for (source[line_start..offset]) |c| try out.writeByte(if (c == '\t') '\t' else ' ');
    try out.writeByte('^');
    const width = @min(@max(len, 1), line_end -| offset);
    try out.splatByteAll('~', width -| 1);
    try out.writeByte('\n');
}

test "caret spans the token" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCaretLines(&w, "SELECT 1;\nSELECT FROM t;\n", 17, 4);
    try std.testing.expectEqualStrings("SELECT FROM t;\n       ^~~~\n", w.buffered());
}

test "caret keeps tabs and is cut off at the end of the line" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCaretLines(&w, "\tx /* a\nb */", 3, 9);
    try std.testing.expectEqualStrings("\tx /* a\n\t  ^~~~\n", w.buffered());
}
