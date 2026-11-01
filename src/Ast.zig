//! The result of parsing SQLite SQL: the tokens, the syntax tree and the first syntax
//! error, if any. Modeled on `std.zig.Ast`: everything is stored in flat arrays and
//! referred to by `u32` indices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer = @import("tokenizer.zig");
const Parse = @import("Parse.zig");

/// The text that was parsed. The Ast does not own it.
source: [:0]const u8,
/// Every token of `source`, ending with `eof`.
tokens: TokenList.Slice,
/// The syntax tree. Node 0 is always the root.
nodes: NodeList.Slice,
extra_data: []u32,
/// Empty when the source is valid SQL; otherwise the single first error, because
/// SQLite stops parsing at the first one.
errors: []const Error,

const Ast = @This();

pub const Token = tokenizer.Token;
pub const TokenList = std.MultiArrayList(Token);
pub const NodeList = std.MultiArrayList(Node);

/// An index into `tokens`.
pub const TokenIndex = enum(u32) { _ };

/// 1-based line and column of a byte offset; the column counts bytes.
pub const Location = struct {
    byte_offset: usize,
    line: usize,
    column: usize,
};

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Data = struct {
        lhs: u32,
        rhs: u32,
    };

    /// An index into `nodes`.
    pub const Index = enum(u32) {
        root = 0,
        _,
    };

    pub const Tag = enum {
        /// The statement list. `lhs..rhs` is the range of `extra_data` holding the
        /// statement nodes. `main_token` is the first token.
        root,
        /// `EXPLAIN lhs`. `main_token` is `EXPLAIN`.
        explain,
        /// `EXPLAIN QUERY PLAN lhs`. `main_token` is `EXPLAIN`.
        explain_query_plan,
    };
};

/// A syntax error. `token` is the token SQLite blames.
pub const Error = struct {
    tag: Tag,
    token: TokenIndex,

    /// One tag per message SQLite produces. The last three are raised by grammar
    /// actions in SQLite (docs/research.md, section 3, item 8) and are not produced yet.
    pub const Tag = enum {
        /// `near "X": syntax error`
        syntax_error,
        /// The input ended in the middle of a statement; blamed on `eof`.
        incomplete_input,
        /// The tokenizer rejected the token.
        unrecognized_token,
        /// Nesting deeper than the parser allows.
        depth_exceeded,
        unknown_table_option,
        unknown_join_type,
        order_by_after_union,
    };
};

/// Tokenizes and parses `source`. Syntax errors are reported in `errors`, not as a
/// Zig error.
pub fn parse(gpa: Allocator, source: [:0]const u8) error{OutOfMemory}!Ast {
    var tokens: TokenList = .empty;
    defer tokens.deinit(gpa);

    var t: tokenizer.Tokenizer = .init(source);
    while (true) {
        const token = t.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    var p: Parse = .{
        .gpa = gpa,
        .token_tags = tokens.items(.tag),
        .tok_i = 0,
        .nodes = .empty,
        .extra_data = .empty,
        .errors = .empty,
    };
    defer p.nodes.deinit(gpa);
    defer p.extra_data.deinit(gpa);
    defer p.errors.deinit(gpa);

    try p.parseRoot();

    return .{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = p.nodes.toOwnedSlice(),
        .extra_data = try p.extra_data.toOwnedSlice(gpa),
        .errors = try p.errors.toOwnedSlice(gpa),
    };
}

pub fn deinit(self: *Ast, gpa: Allocator) void {
    self.tokens.deinit(gpa);
    self.nodes.deinit(gpa);
    gpa.free(self.extra_data);
    gpa.free(self.errors);
    self.* = undefined;
}

fn tokenText(self: Ast, token: TokenIndex) []const u8 {
    const loc = self.tokens.items(.loc)[@backingInt(token)];
    return self.source[loc.start..loc.end];
}

/// Writes the message SQLite gives for `err`.
pub fn renderError(self: Ast, err: Error, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = self.tokenText(err.token);
    switch (err.tag) {
        .syntax_error => try writer.print("near \"{s}\": syntax error", .{text}),
        .incomplete_input => try writer.writeAll("incomplete input"),
        .unrecognized_token => try writer.print("unrecognized token: \"{s}\"", .{text}),
        .depth_exceeded => try writer.writeAll("Expression tree is too large (maximum depth 1000)"),
        .unknown_table_option => try writer.print("unknown table option: {s}", .{text}),
        .unknown_join_type => try writer.print("unknown join type: {s}", .{text}),
        .order_by_after_union => try writer.print(
            "ORDER BY clause should come after {s} not before",
            .{text},
        ),
    }
}

/// Where the token blamed by `err` starts.
pub fn errorLocation(self: Ast, err: Error) Location {
    const offset = self.tokens.items(.loc)[@backingInt(err.token)].start;
    var line: usize = 1;
    var line_start: usize = 0;
    for (self.source[0..offset], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .byte_offset = offset, .line = line, .column = offset - line_start + 1 };
}

/// Writes the canonical SQL form of the statements: keywords in upper case, single
/// spaces, each statement followed by `;` and a newline.
pub fn render(self: Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const root = self.nodes.get(@backingInt(Node.Index.root));
    for (self.extra_data[root.data.lhs..root.data.rhs]) |statement| {
        try self.renderStatement(@fromBackingInt(@intCast(statement)), writer);
        try writer.writeAll(";\n");
    }
}

fn renderStatement(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    switch (n.tag) {
        .root => unreachable,
        .explain, .explain_query_plan => {
            try writer.writeAll(if (n.tag == .explain) "EXPLAIN " else "EXPLAIN QUERY PLAN ");
            try self.renderStatement(@fromBackingInt(@intCast(n.data.lhs)), writer);
        },
    }
}

fn expectError(source: [:0]const u8, message: []const u8, loc: Location) !void {
    const gpa = std.testing.allocator;
    var ast = try parse(gpa, source);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(1, ast.errors.len);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try ast.renderError(ast.errors[0], &buf.writer);
    try std.testing.expectEqualStrings(message, buf.written());
    try std.testing.expectEqualDeep(loc, ast.errorLocation(ast.errors[0]));
}

fn expectEmpty(source: [:0]const u8) !void {
    const gpa = std.testing.allocator;
    var ast = try parse(gpa, source);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(0, ast.errors.len);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try ast.render(&buf.writer);
    try std.testing.expectEqualStrings("", buf.written());
}

test "inputs without statements are valid" {
    try expectEmpty("");
    try expectEmpty("   \t\n ");
    try expectEmpty("-- comment");
    try expectEmpty("/* a */ -- b\n");
    try expectEmpty(";");
    try expectEmpty(";;");
    try expectEmpty(" ; ;\n; ");
}

test "syntax error blames the first token" {
    try expectError("FOO", "near \"FOO\": syntax error", .{ .byte_offset = 0, .line = 1, .column = 1 });
    try expectError("SELECT", "near \"SELECT\": syntax error", .{ .byte_offset = 0, .line = 1, .column = 1 });
}

test "syntax error after leading empty statements" {
    try expectError(";; FOO", "near \"FOO\": syntax error", .{ .byte_offset = 3, .line = 1, .column = 4 });
}

test "line and column count lines and bytes" {
    try expectError("\n\n  FOO", "near \"FOO\": syntax error", .{ .byte_offset = 4, .line = 3, .column = 3 });
    try expectError("-- c\n;\n  \tBAR baz", "near \"BAR\": syntax error", .{ .byte_offset = 10, .line = 3, .column = 4 });
}

test "EXPLAIN without a statement is incomplete input at eof" {
    try expectError("EXPLAIN", "incomplete input", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("EXPLAIN QUERY PLAN", "incomplete input", .{ .byte_offset = 18, .line = 1, .column = 19 });
    try expectError("explain\n", "incomplete input", .{ .byte_offset = 8, .line = 2, .column = 1 });
}

test "EXPLAIN followed by a token that starts nothing is a syntax error" {
    try expectError("EXPLAIN ;", "near \";\": syntax error", .{ .byte_offset = 8, .line = 1, .column = 9 });
    try expectError("EXPLAIN QUERY FOO", "near \"FOO\": syntax error", .{ .byte_offset = 14, .line = 1, .column = 15 });
}

test "invalid tokens are unrecognized" {
    try expectError("\x01", "unrecognized token: \"\x01\"", .{ .byte_offset = 0, .line = 1, .column = 1 });
    try expectError(";\x01", "unrecognized token: \"\x01\"", .{ .byte_offset = 1, .line = 1, .column = 2 });
    try expectError("\n;\n@@@", "unrecognized token: \"@\"", .{ .byte_offset = 3, .line = 3, .column = 1 });
    try expectError("'abc", "unrecognized token: \"'abc\"", .{ .byte_offset = 0, .line = 1, .column = 1 });
}

test "a parser error before an invalid token wins" {
    try expectError("FOO \x01", "near \"FOO\": syntax error", .{ .byte_offset = 0, .line = 1, .column = 1 });
}

test "a NUL byte ends the input" {
    try expectEmpty("; \x00 FOO");
}

test "renderError writes every tag" {
    const gpa = std.testing.allocator;
    var ast = try parse(gpa, "FOO");
    defer ast.deinit(gpa);
    const cases = [_]struct { Error.Tag, []const u8 }{
        .{ .syntax_error, "near \"FOO\": syntax error" },
        .{ .incomplete_input, "incomplete input" },
        .{ .unrecognized_token, "unrecognized token: \"FOO\"" },
        .{ .depth_exceeded, "Expression tree is too large (maximum depth 1000)" },
        .{ .unknown_table_option, "unknown table option: FOO" },
        .{ .unknown_join_type, "unknown join type: FOO" },
        .{ .order_by_after_union, "ORDER BY clause should come after FOO not before" },
    };
    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        defer buf.deinit();
        try ast.renderError(.{ .tag = case[0], .token = @fromBackingInt(@intCast(0)) }, &buf.writer);
        try std.testing.expectEqualStrings(case[1], buf.written());
    }
}
