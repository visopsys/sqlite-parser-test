//! The statement-list driver, following `sqlite3RunParser` and the `ecmd` rule of
//! parse.y. Syntax errors are recorded in `errors`; the first one stops the parse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Token = Ast.Token;

gpa: Allocator,
token_tags: []const Token.Tag,
tok_i: u32,
nodes: Ast.NodeList,
extra_data: std.ArrayList(u32),
errors: std.ArrayList(Ast.Error),

const Parse = @This();

const Error = error{ OutOfMemory, ParseError };

/// Parses the whole token list into `nodes`, or records the first error.
pub fn parseRoot(p: *Parse) Allocator.Error!void {
    p.parseStatements() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {},
    };
}

fn parseStatements(p: *Parse) Error!void {
    try p.nodes.append(p.gpa, .{
        .tag = .root,
        .main_token = @fromBackingInt(@intCast(0)),
        .data = .{ .lhs = 0, .rhs = 0 },
    });
    var statements: std.ArrayList(u32) = .empty;
    defer statements.deinit(p.gpa);

    while (true) {
        while (p.eat(.semicolon)) {}
        if (p.peek() == .eof) break;
        try statements.append(p.gpa, @backingInt(try p.parseExplainable()));
        // At the end of input SQLite feeds a synthetic `;`, so the last one is optional.
        if (!p.eat(.semicolon) and p.peek() != .eof) return p.failHere();
    }

    const start: u32 = @intCast(p.extra_data.items.len);
    try p.extra_data.appendSlice(p.gpa, statements.items);
    const root = &p.nodes.items(.data)[@backingInt(Node.Index.root)];
    root.* = .{ .lhs = start, .rhs = @intCast(p.extra_data.items.len) };
}

/// `ecmd ::= explain cmdx SEMI | cmdx SEMI`, without the semicolon.
fn parseExplainable(p: *Parse) Error!Node.Index {
    if (p.peek() != .keyword_explain) return p.parseStatement();
    const explain = p.nextToken();
    const tag: Node.Tag = if (p.eat(.keyword_query)) tag: {
        if (!p.eat(.keyword_plan)) return p.failHere();
        break :tag .explain_query_plan;
    } else .explain;
    const inner = try p.parseStatement();
    return p.addNode(.{
        .tag = tag,
        .main_token = explain,
        .data = .{ .lhs = @backingInt(inner), .rhs = 0 },
    });
}

fn parseStatement(p: *Parse) Error!Node.Index {
    return p.failHere();
}

fn peek(p: Parse) Token.Tag {
    return p.token_tags[p.tok_i];
}

fn nextToken(p: *Parse) TokenIndex {
    const result: TokenIndex = @fromBackingInt(@intCast(p.tok_i));
    p.tok_i += 1;
    return result;
}

/// Consumes the next token if it has `tag`. Never consumes `eof`.
fn eat(p: *Parse, tag: Token.Tag) bool {
    if (p.peek() != tag) return false;
    _ = p.nextToken();
    return true;
}

fn addNode(p: *Parse, node: Node) Allocator.Error!Node.Index {
    const index: Node.Index = @fromBackingInt(@intCast(p.nodes.len));
    try p.nodes.append(p.gpa, node);
    return index;
}

/// The parser cannot go on at the current token.
fn failHere(p: *Parse) Error {
    return p.fail(if (p.peek() == .eof) .incomplete_input else .syntax_error, p.tok_i);
}

/// Records `tag` at `token`. SQLite tokenizes as it parses, so an `invalid` token at or
/// before the error point is reported instead.
fn fail(p: *Parse, tag: Ast.Error.Tag, token: u32) Error {
    const first_invalid = std.mem.indexOfScalar(Token.Tag, p.token_tags[0 .. token + 1], .invalid);
    try p.errors.append(p.gpa, if (first_invalid) |i|
        .{ .tag = .unrecognized_token, .token = @fromBackingInt(@intCast(i)) }
    else
        .{ .tag = tag, .token = @fromBackingInt(@intCast(token)) });
    return error.ParseError;
}
