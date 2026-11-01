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
        /// `BEGIN [mode] [TRANSACTION [name]]`. `lhs` is the mode token and `rhs` the
        /// name token, each 0 when absent (no token that follows `BEGIN` has index 0).
        /// A bare `TRANSACTION` is not recorded; it means nothing.
        begin,
        /// `COMMIT` or `END`, which SQLite treats alike. `lhs` is the name token or 0.
        commit,
        /// `ROLLBACK [TRANSACTION [name]] [TO [SAVEPOINT] name]`. `lhs` is the
        /// transaction name token and `rhs` the savepoint name token, each 0 when absent.
        rollback,
        /// `SAVEPOINT name`. `lhs` is the name token.
        savepoint,
        /// `RELEASE [SAVEPOINT] name`. `lhs` is the name token.
        release,
        /// `SELECT [ALL] columns`. `lhs..rhs` is the range of `extra_data` holding the
        /// `result_star` and `result_expr` nodes. `main_token` is `SELECT`.
        select,
        /// `SELECT DISTINCT columns`, laid out like `select`.
        select_distinct,
        /// `*` as a result column. `main_token` is the star.
        result_star,
        /// `expr [[AS] alias]` as a result column. `lhs` is the expression and `rhs` the
        /// alias token or 0 when there is none (the first token is never an alias).
        result_expr,
        /// A number, string, blob, `NULL` or `CURRENT_*` term. `main_token` is the token.
        literal,
        /// A bound parameter such as `?1` or `:a`. `main_token` is the token.
        variable,
        /// `a`, `a.b` or `a.b.c`. `main_token` is the first name and `lhs` the number of
        /// names; they are every other token, from `main_token` on.
        name,
        /// `(lhs)`. `main_token` is the left parenthesis.
        paren,
        /// `(a, b, ...)`. `lhs..rhs` is the range of `extra_data` holding the expression
        /// nodes. `main_token` is the left parenthesis.
        row_value,
        /// A prefix operator, one of `- + ~ NOT`, applied to `lhs`. `main_token` is the operator.
        unary,
        /// `lhs OP rhs` for the infix operators that take two plain operands.
        /// `main_token` is the operator.
        binary,
        /// `lhs IS NOT rhs`. `main_token` is `IS`.
        is_not,
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
    Parse.resolveContextKeywords(tokens.items(.tag));

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
        .begin => {
            try writer.writeAll("BEGIN");
            if (n.data.lhs != 0) try self.renderKeyword(n.data.lhs, writer);
            try self.renderTransactionName(n.data.rhs, writer);
        },
        .commit => {
            try writer.writeAll("COMMIT");
            try self.renderTransactionName(n.data.lhs, writer);
        },
        .rollback => {
            try writer.writeAll("ROLLBACK");
            try self.renderTransactionName(n.data.lhs, writer);
            if (n.data.rhs != 0) {
                try writer.writeAll(" TO ");
                try self.renderName(n.data.rhs, writer);
            }
        },
        .savepoint, .release => {
            try writer.writeAll(if (n.tag == .savepoint) "SAVEPOINT " else "RELEASE ");
            try self.renderName(n.data.lhs, writer);
        },
        .select, .select_distinct => {
            try writer.writeAll(if (n.tag == .select) "SELECT " else "SELECT DISTINCT ");
            for (self.extra_data[n.data.lhs..n.data.rhs], 0..) |column, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.renderResultColumn(@fromBackingInt(@intCast(column)), writer);
            }
        },
        .result_star,
        .result_expr,
        .literal,
        .variable,
        .name,
        .paren,
        .row_value,
        .unary,
        .binary,
        .is_not,
        => unreachable,
    }
}

fn renderResultColumn(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    if (n.tag == .result_star) return writer.writeByte('*');
    try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
    if (n.data.rhs == 0) return;
    try writer.writeAll(" AS ");
    try self.renderName(n.data.rhs, writer);
}

/// Writes an expression with every operator application in parentheses, so that the
/// text means the same to SQLite whatever precedence it assigns.
fn renderExpr(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    const main_token: u32 = @backingInt(n.main_token);
    switch (n.tag) {
        .literal => switch (self.tokens.items(.tag)[main_token]) {
            .keyword_null, .keyword_ctime_kw => try writeUpper(self.tokenText(n.main_token), writer),
            else => try writer.writeAll(self.tokenText(n.main_token)),
        },
        .variable => try writer.writeAll(self.tokenText(n.main_token)),
        .name => for (0..n.data.lhs) |i| {
            if (i > 0) try writer.writeByte('.');
            try self.renderName(main_token + 2 * @as(u32, @intCast(i)), writer);
        },
        .paren => try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer),
        .row_value => {
            try writer.writeByte('(');
            for (self.extra_data[n.data.lhs..n.data.rhs], 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.renderExpr(@fromBackingInt(@intCast(item)), writer);
            }
            try writer.writeByte(')');
        },
        .unary => {
            try writer.writeByte('(');
            try writeUpper(self.tokens.items(.tag)[main_token].symbol(), writer);
            if (self.tokens.items(.tag)[main_token] == .keyword_not) try writer.writeByte(' ');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeByte(')');
        },
        .binary, .is_not => {
            try writer.writeByte('(');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeByte(' ');
            try writeUpper(self.tokens.items(.tag)[main_token].symbol(), writer);
            if (n.tag == .is_not) try writer.writeAll(" NOT");
            try writer.writeByte(' ');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.rhs)), writer);
            try writer.writeByte(')');
        },
        else => unreachable,
    }
}

fn writeUpper(text: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (text) |c| try writer.writeByte(std.ascii.toUpper(c));
}

fn renderKeyword(self: Ast, token: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte(' ');
    try writeUpper(self.tokens.items(.tag)[token].lexeme().?, writer);
}

fn renderTransactionName(self: Ast, name: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (name == 0) return;
    try writer.writeAll(" TRANSACTION ");
    try self.renderName(name, writer);
}

/// Writes the name at `token` without its quotes, double-quoted again only when it
/// would not parse as a plain identifier.
fn renderName(self: Ast, token: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = self.tokenText(@fromBackingInt(token));
    const quote: u8 = switch (text[0]) {
        '"', '`', '\'' => text[0],
        '[' => ']',
        else => 0,
    };
    const inner = if (quote == 0) text else text[1 .. text.len - 1];
    if (isPlainIdentifier(inner)) return writer.writeAll(inner);
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (text[0] != '[' and c == quote) i += 1;
        try writer.writeByte(c);
        if (c == '"') try writer.writeByte('"');
    }
    try writer.writeByte('"');
}

fn isPlainIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0]) or tokenizer.getKeyword(name) != null) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c < 0x80) return false;
    }
    return true;
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

test "CREATE followed by a token that starts nothing blames that token" {
    try expectError("create bogus", "near \"bogus\": syntax error", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("CREATE TEMP FOO", "near \"FOO\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("CREATE UNIQUE", "incomplete input", .{ .byte_offset = 13, .line = 1, .column = 14 });
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

fn expectRender(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var ast = try parse(gpa, source);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(0, ast.errors.len);
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try ast.render(&buf.writer);
    try std.testing.expectEqualStrings(expected, buf.written());

    const again = try gpa.dupeSentinel(u8, buf.written(), 0);
    defer gpa.free(again);
    var ast2 = try parse(gpa, again);
    defer ast2.deinit(gpa);
    try std.testing.expectEqual(0, ast2.errors.len);
    var buf2: std.Io.Writer.Allocating = .init(gpa);
    defer buf2.deinit();
    try ast2.render(&buf2.writer);
    try std.testing.expectEqualStrings(expected, buf2.written());
}

test "BEGIN" {
    try expectRender("begin", "BEGIN;\n");
    try expectRender("BEGIN;", "BEGIN;\n");
    try expectRender("begin transaction", "BEGIN;\n");
    try expectRender("begin deferred", "BEGIN DEFERRED;\n");
    try expectRender("begin exclusive;", "BEGIN EXCLUSIVE;\n");
    try expectRender("begin immediate transaction t1", "BEGIN IMMEDIATE TRANSACTION t1;\n");
    try expectRender("BEGIN TRANSACTION begin", "BEGIN TRANSACTION \"begin\";\n");
}

test "COMMIT and END" {
    try expectRender("commit", "COMMIT;\n");
    try expectRender("END", "COMMIT;\n");
    try expectRender("end transaction", "COMMIT;\n");
    try expectRender("commit transaction t", "COMMIT TRANSACTION t;\n");
    try expectRender("end transaction left", "COMMIT TRANSACTION \"left\";\n");
}

test "ROLLBACK" {
    try expectRender("rollback", "ROLLBACK;\n");
    try expectRender("rollback transaction", "ROLLBACK;\n");
    try expectRender("rollback transaction t", "ROLLBACK TRANSACTION t;\n");
    try expectRender("rollback to s", "ROLLBACK TO s;\n");
    try expectRender("rollback to savepoint s", "ROLLBACK TO s;\n");
    try expectRender("rollback transaction to s", "ROLLBACK TO s;\n");
    try expectRender("rollback transaction t to savepoint s", "ROLLBACK TRANSACTION t TO s;\n");
    try expectRender("rollback to savepoint savepoint", "ROLLBACK TO \"savepoint\";\n");
}

test "SAVEPOINT and RELEASE" {
    try expectRender("savepoint s;release s;release savepoint s", "SAVEPOINT s;\nRELEASE s;\nRELEASE s;\n");
    try expectRender("release savepoint savepoint", "RELEASE \"savepoint\";\n");
}

test "statements are separated by semicolons" {
    try expectRender("begin;;commit; rollback", "BEGIN;\nCOMMIT;\nROLLBACK;\n");
    try expectRender("explain begin; explain query plan end", "EXPLAIN BEGIN;\nEXPLAIN QUERY PLAN COMMIT;\n");
}

test "fallback keywords and strings are names" {
    try expectRender("savepoint begin", "SAVEPOINT \"begin\";\n");
    try expectRender("release abort", "RELEASE \"abort\";\n");
    try expectRender("savepoint left", "SAVEPOINT \"left\";\n");
    try expectRender("savepoint indexed", "SAVEPOINT \"indexed\";\n");
    try expectRender("savepoint 'x'", "SAVEPOINT x;\n");
    try expectRender("begin transaction 'a b'", "BEGIN TRANSACTION \"a b\";\n");
    try expectRender("savepoint 'it''s'", "SAVEPOINT \"it's\";\n");
}

test "quoted names are unquoted and re-quoted only when needed" {
    try expectRender("savepoint \"a\"", "SAVEPOINT a;\n");
    try expectRender("savepoint `a`", "SAVEPOINT a;\n");
    try expectRender("savepoint [a]", "SAVEPOINT a;\n");
    try expectRender("savepoint [a b]", "SAVEPOINT \"a b\";\n");
    try expectRender("savepoint \"a\"\"b\"", "SAVEPOINT \"a\"\"b\";\n");
    try expectRender("savepoint `a``b`", "SAVEPOINT \"a`b\";\n");
    try expectRender("savepoint \"1a\"", "SAVEPOINT \"1a\";\n");
    try expectRender("savepoint ''", "SAVEPOINT \"\";\n");
    try expectRender("savepoint \"select\"", "SAVEPOINT \"select\";\n");
    try expectRender("savepoint é_1", "SAVEPOINT é_1;\n");
}

test "WINDOW, OVER and FILTER are names outside their contexts" {
    try expectRender("savepoint filter; release window; rollback to over", "SAVEPOINT \"filter\";\nRELEASE \"window\";\nROLLBACK TO \"over\";\n");
    try expectError("SAVEPOINT over one", "near \"one\": syntax error", .{ .byte_offset = 15, .line = 1, .column = 16 });
    try expectError("ROLLBACK TO window one", "near \"one\": syntax error", .{ .byte_offset = 19, .line = 1, .column = 20 });
}

test "a name that is not a name" {
    try expectError("savepoint select", "near \"select\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("release 1", "near \"1\": syntax error", .{ .byte_offset = 8, .line = 1, .column = 9 });
}

test "transaction statement errors" {
    try expectError("BEGIN BEGIN", "near \"BEGIN\": syntax error", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("BEGIN DEFERRED DEFERRED", "near \"DEFERRED\": syntax error", .{ .byte_offset = 15, .line = 1, .column = 16 });
    try expectError("COMMIT x", "near \"x\": syntax error", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("COMMIT TRANSACTION x y", "near \"y\": syntax error", .{ .byte_offset = 21, .line = 1, .column = 22 });
    try expectError("SAVEPOINT", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SAVEPOINT;", "near \";\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("RELEASE SAVEPOINT", "incomplete input", .{ .byte_offset = 17, .line = 1, .column = 18 });
    try expectError("RELEASE SAVEPOINT;", "near \";\": syntax error", .{ .byte_offset = 17, .line = 1, .column = 18 });
    try expectError("ROLLBACK TO", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("ROLLBACK TRANSACTION TO SAVEPOINT", "incomplete input", .{ .byte_offset = 33, .line = 1, .column = 34 });
}

test "an error on a later line" {
    try expectError("BEGIN;\nSAVEPOINT s\n  COMMIT x;", "near \"COMMIT\": syntax error", .{ .byte_offset = 21, .line = 3, .column = 3 });
    try expectError("BEGIN\n\n  TRANSACTION a b", "near \"b\": syntax error", .{ .byte_offset = 23, .line = 3, .column = 17 });
}

test "an invalid token inside a transaction statement" {
    try expectError("BEGIN \x01", "unrecognized token: \"\x01\"", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("SAVEPOINT 'abc", "unrecognized token: \"'abc\"", .{ .byte_offset = 10, .line = 1, .column = 11 });
}

test "result columns" {
    try expectRender("select 1", "SELECT 1;\n");
    try expectRender("SELECT ALL 1", "SELECT 1;\n");
    try expectRender("SELECT DISTINCT 1, 2", "SELECT DISTINCT 1, 2;\n");
    try expectRender("SELECT *", "SELECT *;\n");
    try expectRender("SELECT 1 x, 2 AS y, 3 AS 'z z', 4 \"w\", 5 desc, 6 AS left", "SELECT 1 AS x, 2 AS y, 3 AS \"z z\", 4 AS w, 5 AS \"desc\", 6 AS \"left\";\n");
    try expectRender("SELECT *, a, *", "SELECT *, a, *;\n");
    try expectRender("explain select 1; select 2", "EXPLAIN SELECT 1;\nSELECT 2;\n");
}

test "primary expressions" {
    try expectRender(
        "SELECT 1, 0x1F, 1.5e3, .5, 'it''s', x'ab', null, true, current_date, Current_Time, current_timestamp",
        "SELECT 1, 0x1F, 1.5e3, .5, 'it''s', x'ab', NULL, true, CURRENT_DATE, CURRENT_TIME, CURRENT_TIMESTAMP;\n",
    );
    try expectRender("SELECT ?, ?1, :a, @b, $c", "SELECT ?, ?1, :a, @b, $c;\n");
    try expectRender(
        "SELECT a, a.b, a.b.c, \"x y\".z, 'q'.r, [s].[t].`u`, abort, left, indexed, replace",
        "SELECT a, a.b, a.b.c, \"x y\".z, q.r, s.t.u, \"abort\", \"left\", \"indexed\", \"replace\";\n",
    );
    try expectRender("SELECT t.desc, t.left", "SELECT t.\"desc\", t.\"left\";\n");
    try expectRender("SELECT (1), ((a)), (1, 2, 3), ((1, 2), 3)", "SELECT 1, a, (1, 2, 3), ((1, 2), 3);\n");
}

test "unary operators" {
    try expectRender("SELECT -1, +a, ~b, NOT c", "SELECT (-1), (+a), (~b), (NOT c);\n");
    try expectRender("SELECT - - 1, NOT NOT a, -~+a", "SELECT (-(-1)), (NOT (NOT a)), (-(~(+a)));\n");
}

test "binary operators" {
    try expectRender(
        "SELECT a OR b, a AND b, a = b, a == b, a != b, a <> b, a < b, a <= b, a > b, a >= b",
        "SELECT (a OR b), (a AND b), (a = b), (a == b), (a != b), (a != b), (a < b), (a <= b), (a > b), (a >= b);\n",
    );
    try expectRender(
        "SELECT a & b, a | b, a << b, a >> b, a + b, a - b, a * b, a / b, a % b, a || b, a -> b, a ->> b, a IS b, a IS NOT b",
        "SELECT (a & b), (a | b), (a << b), (a >> b), (a + b), (a - b), (a * b), (a / b), (a % b), (a || b), (a -> b), (a ->> b), (a IS b), (a IS NOT b);\n",
    );
}

test "precedence between adjacent levels" {
    try expectRender("SELECT a OR b AND c", "SELECT (a OR (b AND c));\n");
    try expectRender("SELECT a AND b OR c", "SELECT ((a AND b) OR c);\n");
    try expectRender("SELECT a AND NOT b", "SELECT (a AND (NOT b));\n");
    try expectRender("SELECT NOT a AND b", "SELECT ((NOT a) AND b);\n");
    try expectRender("SELECT NOT a = b", "SELECT (NOT (a = b));\n");
    try expectRender("SELECT a = NOT b", "SELECT (a = (NOT b));\n");
    try expectRender("SELECT a = b < c", "SELECT (a = (b < c));\n");
    try expectRender("SELECT a < b = c", "SELECT ((a < b) = c);\n");
    try expectRender("SELECT a IS b < c", "SELECT (a IS (b < c));\n");
    try expectRender("SELECT a < b | c", "SELECT (a < (b | c));\n");
    try expectRender("SELECT a | b < c", "SELECT ((a | b) < c);\n");
    try expectRender("SELECT a | b + c", "SELECT (a | (b + c));\n");
    try expectRender("SELECT a + b | c", "SELECT ((a + b) | c);\n");
    try expectRender("SELECT a + b * c", "SELECT (a + (b * c));\n");
    try expectRender("SELECT a * b + c", "SELECT ((a * b) + c);\n");
    try expectRender("SELECT a * b || c", "SELECT (a * (b || c));\n");
    try expectRender("SELECT a || b * c", "SELECT ((a || b) * c);\n");
    try expectRender("SELECT a -> b * c", "SELECT ((a -> b) * c);\n");
    try expectRender("SELECT -a || b", "SELECT ((-a) || b);\n");
    try expectRender("SELECT a || -b", "SELECT (a || (-b));\n");
    try expectRender("SELECT ~a + b", "SELECT ((~a) + b);\n");
    try expectRender("SELECT a + ~b", "SELECT (a + (~b));\n");
    try expectRender("SELECT 1 + 2 * 3", "SELECT (1 + (2 * 3));\n");
}

test "operators of one level associate to the left" {
    try expectRender("SELECT a - b - c", "SELECT ((a - b) - c);\n");
    try expectRender("SELECT a = b == c <> d", "SELECT (((a = b) == c) != d);\n");
    try expectRender("SELECT a -> b ->> c || d", "SELECT (((a -> b) ->> c) || d);\n");
    try expectRender("SELECT a IS NOT b IS c", "SELECT ((a IS NOT b) IS c);\n");
    try expectRender("SELECT a IS NOT NOT b", "SELECT (a IS NOT (NOT b));\n");
    try expectRender("SELECT (a OR b) AND c", "SELECT ((a OR b) AND c);\n");
}

test "a long chain of operators does not recurse per operator" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "SELECT 1");
    for (0..10_000) |_| try source.appendSlice(gpa, "+1");
    try source.append(gpa, 0);
    var ast = try parse(gpa, source.items[0 .. source.items.len - 1 :0]);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(0, ast.errors.len);
}

test "deep nesting is an error, not a stack overflow" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendSlice(gpa, "SELECT ");
    for (0..100_000) |_| try source.appendSlice(gpa, "(");
    try source.append(gpa, 0);
    try expectError(source.items[0 .. source.items.len - 1 :0], "Expression tree is too large (maximum depth 1000)", .{ .byte_offset = 1006, .line = 1, .column = 1007 });

    source.clearRetainingCapacity();
    try source.appendSlice(gpa, "SELECT ");
    for (0..100_000) |_| try source.appendSlice(gpa, "- ");
    try source.append(gpa, 0);
    try expectError(source.items[0 .. source.items.len - 1 :0], "Expression tree is too large (maximum depth 1000)", .{ .byte_offset = 2005, .line = 1, .column = 2006 });
}

test "expression syntax errors" {
    try expectError("SELECT", "incomplete input", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("SELECT 1 +", "incomplete input", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("SELECT 1 +\n  *", "near \"*\": syntax error", .{ .byte_offset = 13, .line = 2, .column = 3 });
    try expectError("SELECT 1 2", "near \"2\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT (1", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT (1 2)", "near \"2\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("SELECT ()", "near \")\": syntax error", .{ .byte_offset = 8, .line = 1, .column = 9 });
    try expectError("SELECT 1 FROM", "near \"FROM\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT a.", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT a.b.c.d", "near \".\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT 1,", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT 1 AS", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("SELECT * x", "near \"x\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT select", "near \"select\": syntax error", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("SELECT 1 + \x01", "unrecognized token: \"\x01\"", .{ .byte_offset = 11, .line = 1, .column = 12 });
}
