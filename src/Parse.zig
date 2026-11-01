//! The statement-list driver, following `sqlite3RunParser` and the `ecmd` rule of
//! parse.y. Syntax errors are recorded in `errors`; the first one stops the parse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Token = Ast.Token;
const tokenizer = @import("tokenizer.zig");

gpa: Allocator,
token_tags: []const Token.Tag,
tok_i: u32,
nodes: Ast.NodeList,
extra_data: std.ArrayList(u32),
errors: std.ArrayList(Ast.Error),
depth: u32 = 0,

const Parse = @This();

/// How deeply rules may nest; the same figure as SQLITE_MAX_EXPR_DEPTH.
pub const max_depth = 1000;

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
    try p.enter();
    defer p.leave();
    const first = p.peek();
    switch (first) {
        .keyword_begin, .keyword_commit, .keyword_end, .keyword_rollback, .keyword_savepoint, .keyword_release => {},
        else => return p.failHere(),
    }
    const main_token = p.nextToken();
    const tag: Node.Tag, const data: Node.Data = switch (first) {
        .keyword_begin => .{ .begin, .{ .lhs = p.eatTransactionMode(), .rhs = try p.parseTransactionOpt() } },
        .keyword_commit, .keyword_end => .{ .commit, .{ .lhs = try p.parseTransactionOpt(), .rhs = 0 } },
        .keyword_rollback => rollback: {
            const transaction = try p.parseTransactionOpt();
            const savepoint = if (p.eat(.keyword_to)) to: {
                _ = p.eat(.keyword_savepoint);
                break :to try p.parseName(.nm);
            } else 0;
            break :rollback .{ .rollback, .{ .lhs = transaction, .rhs = savepoint } };
        },
        .keyword_savepoint => .{ .savepoint, .{ .lhs = try p.parseName(.nm), .rhs = 0 } },
        .keyword_release => release: {
            _ = p.eat(.keyword_savepoint);
            break :release .{ .release, .{ .lhs = try p.parseName(.nm), .rhs = 0 } };
        },
        else => unreachable,
    };
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = data });
}

/// Called on entry to every rule that can recurse; fails once nesting passes `max_depth`.
fn enter(p: *Parse) Error!void {
    if (p.depth >= max_depth) return p.fail(.depth_exceeded, p.tok_i);
    p.depth += 1;
}

fn leave(p: *Parse) void {
    p.depth -= 1;
}

/// `transtype`: the mode token, or 0 when there is none.
fn eatTransactionMode(p: *Parse) u32 {
    return switch (p.peek()) {
        .keyword_deferred, .keyword_immediate, .keyword_exclusive => @backingInt(p.nextToken()),
        else => 0,
    };
}

/// `trans_opt`: the name token after `TRANSACTION`, or 0 when there is none.
fn parseTransactionOpt(p: *Parse) Error!u32 {
    if (!p.eat(.keyword_transaction)) return 0;
    return if (p.acceptName(.nm)) |name| @backingInt(name) else 0;
}

fn parseName(p: *Parse, class: NameClass) Error!u32 {
    const name = p.acceptName(class) orelse return p.failHere();
    return @backingInt(name);
}

/// The token classes of parse.y that name things.
const NameClass = enum {
    /// `id ::= ID | INDEXED`
    id,
    /// `ids ::= ID | STRING`
    ids,
    /// `idj ::= ID | INDEXED | JOIN_KW`
    idj,
    /// `nm ::= idj | STRING`
    nm,
};

/// The keywords of `%fallback ID` in parse.y: they are identifiers wherever the grammar
/// gives them no meaning of their own.
const fallback_keywords = [_]Token.Tag{
    .keyword_abort,     .keyword_action,    .keyword_after,     .keyword_analyze,      .keyword_asc,
    .keyword_attach,    .keyword_before,    .keyword_begin,     .keyword_by,           .keyword_cascade,
    .keyword_cast,      .keyword_columnkw,  .keyword_conflict,  .keyword_database,     .keyword_deferred,
    .keyword_desc,      .keyword_detach,    .keyword_do,        .keyword_each,         .keyword_end,
    .keyword_exclusive, .keyword_explain,   .keyword_fail,      .keyword_for,          .keyword_ignore,
    .keyword_immediate, .keyword_initially, .keyword_instead,   .keyword_like_kw,      .keyword_match,
    .keyword_no,        .keyword_plan,      .keyword_query,     .keyword_key,          .keyword_of,
    .keyword_offset,    .keyword_pragma,    .keyword_raise,     .keyword_recursive,    .keyword_release,
    .keyword_replace,   .keyword_restrict,  .keyword_row,       .keyword_rows,         .keyword_rollback,
    .keyword_savepoint, .keyword_temp,      .keyword_trigger,   .keyword_vacuum,       .keyword_view,
    .keyword_virtual,   .keyword_with,      .keyword_without,   .keyword_nulls,        .keyword_first,
    .keyword_last,      .keyword_current,   .keyword_following, .keyword_partition,    .keyword_preceding,
    .keyword_range,     .keyword_unbounded, .keyword_exclude,   .keyword_groups,       .keyword_others,
    .keyword_ties,      .keyword_generated, .keyword_always,    .keyword_materialized, .keyword_reindex,
    .keyword_rename,    .keyword_ctime_kw,  .keyword_if,
};

const TagSet = std.EnumSet(Token.Tag);

fn nameTags(extra: []const Token.Tag) TagSet {
    @setEvalBranchQuota(10_000);
    var set: TagSet = .initMany(&fallback_keywords);
    set.insert(.identifier);
    for (extra) |tag| set.insert(tag);
    return set;
}

const name_tags: std.EnumArray(NameClass, TagSet) = .init(.{
    .id = nameTags(&.{.keyword_indexed}),
    .ids = nameTags(&.{.string_literal}),
    .idj = nameTags(&.{ .keyword_indexed, .keyword_join_kw }),
    .nm = nameTags(&.{ .keyword_indexed, .keyword_join_kw, .string_literal }),
});

/// Consumes the next token if it is a name of `class`.
fn acceptName(p: *Parse, class: NameClass) ?TokenIndex {
    if (!name_tags.get(class).contains(p.peek())) return null;
    return p.nextToken();
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

fn expectNameClass(class: NameClass, source: [:0]const u8, accepted: bool) !void {
    var t: tokenizer.Tokenizer = .init(source);
    const tags = [_]Token.Tag{ t.next().tag, .eof };
    var p: Parse = .{
        .gpa = std.testing.allocator,
        .token_tags = &tags,
        .tok_i = 0,
        .nodes = .empty,
        .extra_data = .empty,
        .errors = .empty,
    };
    try std.testing.expectEqual(accepted, p.acceptName(class) != null);
    try std.testing.expectEqual(@as(u32, @intFromBool(accepted)), p.tok_i);
}

test "name classes" {
    const Case = struct { []const u8, [4]bool };
    // Columns: id, ids, idj, nm.
    const cases = [_]Case{
        .{ "abc", .{ true, true, true, true } },
        .{ "\"abc\"", .{ true, true, true, true } },
        .{ "indexed", .{ true, false, true, true } },
        .{ "left", .{ false, false, true, true } },
        .{ "cross", .{ false, false, true, true } },
        .{ "'abc'", .{ false, true, false, true } },
        .{ "begin", .{ true, true, true, true } },
        .{ "if", .{ true, true, true, true } },
        .{ "current_date", .{ true, true, true, true } },
        .{ "glob", .{ true, true, true, true } },
        .{ "select", .{ false, false, false, false } },
        .{ "union", .{ false, false, false, false } },
        .{ "null", .{ false, false, false, false } },
        .{ "1", .{ false, false, false, false } },
        .{ ";", .{ false, false, false, false } },
    };
    for (cases) |case| {
        const source = try std.testing.allocator.dupeSentinel(u8, case[0], 0);
        defer std.testing.allocator.free(source);
        for (std.enums.values(NameClass), case[1]) |class, accepted| {
            try expectNameClass(class, source, accepted);
        }
    }
}

test "nesting past max_depth is an error at the current token" {
    const gpa = std.testing.allocator;
    var ast = try Ast.parse(gpa, "BEGIN;\n  COMMIT");
    defer ast.deinit(gpa);
    var p: Parse = .{
        .gpa = gpa,
        .token_tags = ast.tokens.items(.tag),
        .tok_i = 2,
        .nodes = .empty,
        .extra_data = .empty,
        .errors = .empty,
    };
    defer p.errors.deinit(gpa);
    for (0..max_depth) |_| try p.enter();
    try std.testing.expectError(error.ParseError, p.enter());
    try std.testing.expectEqual(max_depth, p.depth);

    try std.testing.expectEqual(1, p.errors.items.len);
    const err = p.errors.items[0];
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try ast.renderError(err, &buf.writer);
    try std.testing.expectEqualStrings("Expression tree is too large (maximum depth 1000)", buf.written());
    try std.testing.expectEqualDeep(
        Ast.Location{ .byte_offset = 9, .line = 2, .column = 3 },
        ast.errorLocation(err),
    );

    p.leave();
    try p.enter();
}

test "long inputs parse without deep recursion" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    try source.appendNTimes(gpa, ';', 100_000);
    try source.append(gpa, 0);
    var semicolons = try Ast.parse(gpa, source.items[0 .. source.items.len - 1 :0]);
    semicolons.deinit(gpa);

    source.clearRetainingCapacity();
    for (0..10_000) |_| try source.appendSlice(gpa, "BEGIN;");
    try source.append(gpa, 0);
    var begins = try Ast.parse(gpa, source.items[0 .. source.items.len - 1 :0]);
    defer begins.deinit(gpa);
    try std.testing.expectEqual(0, begins.errors.len);
    try std.testing.expectEqual(10_001, begins.nodes.len);
}
