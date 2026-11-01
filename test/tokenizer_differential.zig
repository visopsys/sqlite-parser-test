//! Compares our tokenizer with SQLite's. SQLite does not expose its tokenizer, but it
//! reports every bad token as `unrecognized token: "X"` at a byte offset, which is
//! enough to check where our `invalid` tokens may and may not appear.

const std = @import("std");
const sqlite_parser = @import("sqlite_parser");
const corpus = @import("corpus.zig");
const oracle = @import("oracle.zig");

const Token = sqlite_parser.tokenizer.Token;
const Tokenizer = sqlite_parser.tokenizer.Tokenizer;

const unrecognized_prefix = "unrecognized token: \"";

fn tokenize(gpa: std.mem.Allocator, source: [:0]const u8) !std.ArrayList(Token) {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    var tokenizer: Tokenizer = .init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) return tokens;
    }
}

/// Whether `tokens` agree with what SQLite said about `statement`.
fn agrees(statement: []const u8, result: oracle.Result, tokens: []const Token) bool {
    const first_invalid = for (tokens) |token| {
        if (token.tag == .invalid) break token;
    } else null;
    const invalid = first_invalid orelse return result.verdict != .reject or
        !std.mem.startsWith(u8, result.messageText(), unrecognized_prefix);
    switch (result.verdict) {
        .unknown => return true,
        .accept => return false,
        .reject => {},
    }
    const offset = result.error_offset orelse return false;
    const message = result.messageText();
    if (!std.mem.startsWith(u8, message, unrecognized_prefix)) return invalid.loc.start >= offset;
    const text = statement[invalid.loc.start..invalid.loc.end];
    const quoted = message[unrecognized_prefix.len..];
    // The oracle cuts messages at its buffer size, which loses the closing quote.
    const truncated = result.message_buffer.len - 1 == message.len;
    const matches = if (truncated)
        std.mem.startsWith(u8, text, quoted)
    else
        std.mem.eql(u8, text, quoted[0 .. quoted.len - 1]);
    return invalid.loc.start == offset and matches;
}

fn printFailure(statement: []const u8, result: oracle.Result, tokens: []const Token) void {
    std.debug.print("input: \"{f}\"\nSQLite: {s} message \"{s}\" at offset {?d}\ntokens:", .{
        std.zig.fmtString(statement),
        @tagName(result.verdict),
        result.messageText(),
        result.error_offset,
    });
    for (tokens) |token| {
        std.debug.print(" {s} {d}..{d};", .{ @tagName(token.tag), token.loc.start, token.loc.end });
    }
    std.debug.print("\n", .{});
}

/// Walks `input` statement by statement, as the oracle splits it, and checks the
/// tokens of each against SQLite's verdict.
fn checkInput(gpa: std.mem.Allocator, input: []const u8) !void {
    var pos: usize = 0;
    while (pos < input.len) {
        const result = try oracle.check(input[pos..]);
        try std.testing.expect(result.length > 0);
        const statement = try gpa.dupeSentinel(u8, input[pos..][0..result.length], 0);
        defer gpa.free(statement);
        var tokens = try tokenize(gpa, statement);
        defer tokens.deinit(gpa);
        if (!agrees(statement, result, tokens.items)) {
            printFailure(statement, result, tokens.items);
            return error.TestUnexpectedResult;
        }
        pos += result.length;
    }
}

test "tokenizer agrees with SQLite on every corpus script" {
    const gpa = std.testing.allocator;
    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        checkInput(gpa, case.sql) catch |err| {
            std.debug.print("corpus case: {s}\n", .{case.id});
            return err;
        };
    }
}

const mutation_bytes = "'\"`[]()xX$:#?019.eE-/* " ++ "\x80\xef\xbb\xbf\x00";
const min_mutations = 20_000;
const max_statement_len = 2000;

test "tokenizer agrees with SQLite on mutated corpus statements" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    var statements: std.ArrayList([]const u8) = .empty;
    defer statements.deinit(gpa);
    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        var pos: usize = 0;
        while (pos < case.sql.len) {
            const length = (try oracle.check(case.sql[pos..])).length;
            if (length <= max_statement_len) try statements.append(gpa, case.sql[pos..][0..length]);
            pos += length;
        }
    }

    var prng: std.Random.DefaultPrng = .init(0x5eed_70c5);
    const random = prng.random();
    var buffer: [max_statement_len + 1]u8 = undefined;
    var count: usize = 0;
    while (count < 2 * min_mutations) : (count += 1) {
        const original = statements.items[random.uintLessThan(usize, statements.items.len)];
        const at = random.uintAtMost(usize, original.len);
        const byte = mutation_bytes[random.uintLessThan(usize, mutation_bytes.len)];
        const mutated: []const u8 = switch (random.uintLessThan(u8, 4)) {
            0 => blk: {
                @memcpy(buffer[0..at], original[0..at]);
                buffer[at] = byte;
                @memcpy(buffer[at + 1 ..][0 .. original.len - at], original[at..]);
                break :blk buffer[0 .. original.len + 1];
            },
            1 => if (original.len == 0) original else blk: {
                const gone = @min(at, original.len - 1);
                @memcpy(buffer[0..gone], original[0..gone]);
                @memcpy(buffer[gone .. original.len - 1], original[gone + 1 ..]);
                break :blk buffer[0 .. original.len - 1];
            },
            2 => if (original.len == 0) original else blk: {
                @memcpy(buffer[0..original.len], original);
                buffer[@min(at, original.len - 1)] = byte;
                break :blk buffer[0..original.len];
            },
            else => original[0..at],
        };
        checkInput(gpa, mutated) catch |err| {
            std.debug.print("mutation number {d}\n", .{count});
            return err;
        };
    }
    try std.testing.expect(count >= min_mutations);
}

fn checkStructure(_: void, smith: *std.testing.Smith) !void {
    var raw: [257]u8 = undefined;
    const len = smith.slice(raw[0..256]);
    raw[len] = 0;
    const source: [:0]const u8 = raw[0..len :0];
    var tokenizer: Tokenizer = .init(source);
    var end: usize = 0;
    // Every token but eof is at least one byte, so len + 1 calls reach eof.
    for (0..len + 1) |_| {
        const token = tokenizer.next();
        try std.testing.expect(token.loc.start >= end);
        try std.testing.expect(token.loc.start <= token.loc.end);
        try std.testing.expect(token.loc.end <= len);
        end = token.loc.end;
        if (token.tag == .eof) return;
    }
    return error.TestUnexpectedResult;
}

test "fuzz: tokens are ordered, inside the input, and end with eof" {
    try std.testing.fuzz({}, checkStructure, .{});
}
