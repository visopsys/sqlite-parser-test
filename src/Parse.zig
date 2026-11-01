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
        .keyword_select => return p.parseSelect(),
        // Only the prefix up to the token that follows CREATE [TEMP | UNIQUE] is
        // recognized so far; every statement CREATE can start is still rejected there.
        .keyword_create => {
            _ = p.nextToken();
            if (!p.eat(.keyword_temp)) _ = p.eat(.keyword_unique);
            return p.failHere();
        },
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

/// `select ::= SELECT distinct selcollist`; nothing may follow the result columns yet.
fn parseSelect(p: *Parse) Error!Node.Index {
    const select = p.nextToken();
    const distinct = p.eat(.keyword_distinct);
    if (!distinct) _ = p.eat(.keyword_all);
    var columns: std.ArrayList(u32) = .empty;
    defer columns.deinit(p.gpa);
    while (true) {
        try columns.append(p.gpa, @backingInt(try p.parseResultColumn()));
        if (!p.eat(.comma)) break;
    }
    return p.addNode(.{
        .tag = if (distinct) .select_distinct else .select,
        .main_token = select,
        .data = try p.addExtraRange(columns.items),
    });
}

/// `selcollist ::= expr as | STAR`, where `as ::= AS nm | ids | `.
fn parseResultColumn(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    if (p.eat(.star)) return p.addNode(.{
        .tag = .result_star,
        .main_token = @fromBackingInt(first),
        .data = .{ .lhs = 0, .rhs = 0 },
    });
    const expr = try p.parseExpr(0);
    const alias: u32 = if (p.eat(.keyword_as))
        try p.parseName(.nm)
    else if (p.acceptName(.ids)) |name|
        @backingInt(name)
    else
        0;
    return p.addNode(.{
        .tag = .result_expr,
        .main_token = @fromBackingInt(first),
        .data = .{ .lhs = @backingInt(expr), .rhs = alias },
    });
}

/// The precedence levels of the `%left`, `%right` and `%nonassoc` block of parse.y,
/// loosest first. Every infix operator is left associative, as in parse.y except for
/// ESCAPE, which a later rule handles.
const Level = enum(u8) {
    logical_or = 1,
    logical_and,
    not,
    equality,
    comparison,
    escape,
    bitwise,
    additive,
    multiplicative,
    concat,
    collate,
    bitnot,

    /// The binding power with which the operator takes the expression on its left.
    fn left(level: Level) u8 {
        return 2 * @backingInt(level);
    }

    /// The least binding power an operator needs to join the operand on its right.
    fn right(level: Level) u8 {
        return left(level) + 1;
    }
};

fn infixLevel(tag: Token.Tag) ?Level {
    return switch (tag) {
        .keyword_or => .logical_or,
        .keyword_and => .logical_and,
        .keyword_is,
        .keyword_not,
        .keyword_like_kw,
        .keyword_match,
        .keyword_between,
        .keyword_in,
        .keyword_isnull,
        .keyword_notnull,
        .equal,
        .equal_equal,
        .not_equal,
        => .equality,
        .l_angle_bracket, .angle_bracket_left_equal, .r_angle_bracket, .angle_bracket_right_equal => .comparison,
        .ampersand, .pipe, .angle_bracket_left_angle_bracket_left, .angle_bracket_right_angle_bracket_right => .bitwise,
        .plus, .minus => .additive,
        .star, .slash, .percent => .multiplicative,
        .pipe_pipe, .arrow, .arrow2 => .concat,
        .keyword_collate => .collate,
        else => null,
    };
}

/// Parses an expression whose infix operators all bind at least as tightly as `min_bp`.
/// A chain of operators of one level loops here instead of recursing.
fn parseExpr(p: *Parse, min_bp: u8) Error!Node.Index {
    return p.parseOperators(min_bp, false);
}

/// With `and_ends_expr` the expression stops at an `AND` between its own operands, which
/// is how the first `AND` after `BETWEEN expr` is left to `BETWEEN`. An `AND` inside the
/// right operand of a looser operator (`OR`) still belongs to that operand.
fn parseOperators(p: *Parse, min_bp: u8, and_ends_expr: bool) Error!Node.Index {
    try p.enter();
    defer p.leave();
    var lhs = try p.parsePrimary();
    while (infixLevel(p.peek())) |level| {
        if (level.left() < min_bp) break;
        if (and_ends_expr and p.peek() == .keyword_and) break;
        lhs = try p.parseOperator(lhs, level);
    }
    return lhs;
}

/// Parses the operator at the current token, which is an infix operator of `level`, and
/// the operands that follow `lhs`.
fn parseOperator(p: *Parse, lhs: Node.Index, level: Level) Error!Node.Index {
    switch (p.peek()) {
        .keyword_collate => {
            const op = p.nextToken();
            const name = try p.parseName(.ids);
            return p.addBinary(.collate, op, lhs, name);
        },
        .keyword_isnull, .keyword_notnull => |tag| {
            const op = p.nextToken();
            return p.addBinary(if (tag == .keyword_isnull) .is_null else .not_null, op, lhs, 0);
        },
        .keyword_is => return p.parseIs(lhs),
        .keyword_not, .keyword_like_kw, .keyword_match, .keyword_between, .keyword_in => return p.parseNegatable(lhs),
        else => {
            const op = p.nextToken();
            const rhs = try p.parseExpr(level.right());
            return p.addBinary(.binary, op, lhs, @backingInt(rhs));
        },
    }
}

/// `IS [NOT] [DISTINCT FROM] expr`. `IS NOT` always takes the `NOT` as part of the
/// operator, never as a prefix operator of the right operand.
fn parseIs(p: *Parse, lhs: Node.Index) Error!Node.Index {
    const op = p.nextToken();
    const negated = p.eat(.keyword_not);
    const distinct = p.eat(.keyword_distinct);
    if (distinct and !p.eat(.keyword_from)) return p.failHere();
    const rhs = try p.parseExpr(Level.equality.right());
    const tag: Node.Tag = if (distinct)
        (if (negated) .is_not_distinct else .is_distinct)
    else if (negated) .is_not else .binary;
    return p.addBinary(tag, op, lhs, @backingInt(rhs));
}

/// The operators that `NOT` may precede: `[NOT] LIKE|GLOB|REGEXP|MATCH`, `[NOT] BETWEEN`,
/// `[NOT] IN` and `NOT NULL`.
fn parseNegatable(p: *Parse, lhs: Node.Index) Error!Node.Index {
    _ = p.eat(.keyword_not);
    const op: TokenIndex = @fromBackingInt(p.tok_i);
    switch (p.peek()) {
        .keyword_null => {
            _ = p.nextToken();
            return p.addBinary(.not_null, op, lhs, 0);
        },
        .keyword_like_kw, .keyword_match => {
            _ = p.nextToken();
            const operand_bp = Level.equality.right();
            const pattern = try p.parseExpr(operand_bp);
            const escape: u32 = if (p.eat(.keyword_escape)) @backingInt(try p.parseExpr(operand_bp)) else 0;
            const operands = try p.addExtra(&.{ @backingInt(pattern), escape });
            return p.addBinary(.like, op, lhs, operands);
        },
        .keyword_between => {
            _ = p.nextToken();
            const low = try p.parseOperators(0, true);
            if (!p.eat(.keyword_and)) return p.failHere();
            const high = try p.parseExpr(Level.equality.right());
            const operands = try p.addExtra(&.{ @backingInt(low), @backingInt(high) });
            return p.addBinary(.between, op, lhs, operands);
        },
        .keyword_in => {
            _ = p.nextToken();
            return p.parseInOperand(op, lhs);
        },
        else => return p.failHere(),
    }
}

/// What follows `IN`: `(exprlist)`, `name`, `schema.name` or either name with a
/// parenthesized argument list.
fn parseInOperand(p: *Parse, op: TokenIndex, lhs: Node.Index) Error!Node.Index {
    var operands: std.ArrayList(u32) = .empty;
    defer operands.deinit(p.gpa);
    if (p.eat(.l_paren)) {
        try p.parseCountedExprList(&operands);
        return p.addBinary(.in_list, op, lhs, try p.addExtra(operands.items));
    }
    try operands.append(p.gpa, try p.parseName(.nm));
    try operands.append(p.gpa, if (p.eat(.dot)) try p.parseName(.nm) else 0);
    if (!p.eat(.l_paren)) return p.addBinary(.in_table, op, lhs, try p.addExtra(operands.items));
    try p.parseCountedExprList(&operands);
    return p.addBinary(.in_func, op, lhs, try p.addExtra(operands.items));
}

/// `exprlist RP`, after the left parenthesis: appends the number of expressions to `list`
/// and then the expressions.
fn parseCountedExprList(p: *Parse, list: *std.ArrayList(u32)) Error!void {
    try p.parseExprListBody(list);
    if (!p.eat(.r_paren)) return p.failHere();
}

/// `exprlist`, which may be empty: appends the number of expressions to `list` and then
/// the expressions. The list ends before `)` or `ORDER`.
fn parseExprListBody(p: *Parse, list: *std.ArrayList(u32)) Error!void {
    const count_at = list.items.len;
    try list.append(p.gpa, 0);
    if (p.peek() != .r_paren and p.peek() != .keyword_order) {
        while (true) {
            try list.append(p.gpa, @backingInt(try p.parseExpr(0)));
            if (!p.eat(.comma)) break;
        }
    }
    list.items[count_at] = @intCast(list.items.len - count_at - 1);
}

fn addBinary(p: *Parse, tag: Node.Tag, op: TokenIndex, lhs: Node.Index, rhs: u32) Allocator.Error!Node.Index {
    return p.addNode(.{
        .tag = tag,
        .main_token = op,
        .data = .{ .lhs = @backingInt(lhs), .rhs = rhs },
    });
}

/// A term, a name, a parenthesized expression or row value, or a prefix operator and its
/// operand.
fn parsePrimary(p: *Parse) Error!Node.Index {
    const first = p.peek();
    const main_token: TokenIndex = @fromBackingInt(p.tok_i);
    switch (first) {
        .integer_literal, .float_literal, .blob_literal, .keyword_null, .keyword_ctime_kw => {
            _ = p.nextToken();
            return p.addNode(.{ .tag = .literal, .main_token = main_token, .data = .{ .lhs = 0, .rhs = 0 } });
        },
        .string_literal => if (p.token_tags[p.tok_i + 1] != .dot) {
            _ = p.nextToken();
            return p.addNode(.{ .tag = .literal, .main_token = main_token, .data = .{ .lhs = 0, .rhs = 0 } });
        },
        .variable => {
            _ = p.nextToken();
            return p.addNode(.{ .tag = .variable, .main_token = main_token, .data = .{ .lhs = 0, .rhs = 0 } });
        },
        .minus, .plus, .tilde, .keyword_not => {
            _ = p.nextToken();
            const level: Level = if (first == .keyword_not) .not else .bitnot;
            const operand = try p.parseExpr(level.right());
            return p.addNode(.{
                .tag = .unary,
                .main_token = main_token,
                .data = .{ .lhs = @backingInt(operand), .rhs = 0 },
            });
        },
        .l_paren => return p.parseParenthesized(),
        else => {},
    }
    // CAST, RAISE and CASE open expressions of their own, so they are not names here.
    switch (first) {
        .keyword_cast => return p.parseCast(),
        .keyword_raise => return p.parseRaise(),
        .keyword_case => return p.parseCase(),
        else => {},
    }
    if (!name_tags.get(.nm).contains(first)) return p.failHere();
    if (name_tags.get(.idj).contains(first) and p.token_tags[p.tok_i + 1] == .l_paren) return p.parseCall();
    _ = p.nextToken();
    var parts: u32 = 1;
    while (parts < 3 and p.eat(.dot)) : (parts += 1) _ = try p.parseName(.nm);
    return p.addNode(.{ .tag = .name, .main_token = main_token, .data = .{ .lhs = parts, .rhs = 0 } });
}

/// `CAST LP expr AS typetoken RP`, where `typetoken` is any number of `ids` and then
/// `(signed)` or `(signed, signed)`, the last two only after a name.
fn parseCast(p: *Parse) Error!Node.Index {
    const cast = p.nextToken();
    if (!p.eat(.l_paren)) return p.failHere();
    const operand = try p.parseExpr(0);
    if (!p.eat(.keyword_as)) return p.failHere();
    const type_start = p.tok_i;
    if (p.acceptName(.ids) != null) {
        while (p.acceptName(.ids) != null) {}
        if (p.eat(.l_paren)) {
            try p.parseSigned();
            if (p.eat(.comma)) try p.parseSigned();
            if (!p.eat(.r_paren)) return p.failHere();
        }
    }
    const type_end = p.tok_i;
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{
        .tag = .cast,
        .main_token = cast,
        .data = .{ .lhs = @backingInt(operand), .rhs = try p.addExtra(&.{ type_start, type_end }) },
    });
}

/// `signed ::= [PLUS | MINUS] number`.
fn parseSigned(p: *Parse) Error!void {
    _ = p.eat(.plus) or p.eat(.minus);
    if (!p.eat(.integer_literal) and !p.eat(.float_literal)) return p.failHere();
}

/// `CASE case_operand case_exprlist case_else END`.
fn parseCase(p: *Parse) Error!Node.Index {
    const case = p.nextToken();
    const operand: u32 = if (p.peek() == .keyword_when) 0 else @backingInt(try p.parseExpr(0));
    var clauses: std.ArrayList(u32) = .empty;
    defer clauses.deinit(p.gpa);
    try clauses.appendSlice(p.gpa, &.{ 0, 0 });
    while (p.eat(.keyword_when)) {
        try clauses.append(p.gpa, @backingInt(try p.parseExpr(0)));
        if (!p.eat(.keyword_then)) return p.failHere();
        try clauses.append(p.gpa, @backingInt(try p.parseExpr(0)));
        clauses.items[1] += 1;
    }
    if (clauses.items[1] == 0) return p.failHere();
    if (p.eat(.keyword_else)) clauses.items[0] = @backingInt(try p.parseExpr(0));
    if (!p.eat(.keyword_end)) return p.failHere();
    return p.addNode(.{
        .tag = .case,
        .main_token = case,
        .data = .{ .lhs = operand, .rhs = try p.addExtra(clauses.items) },
    });
}

/// `RAISE LP IGNORE RP` or `RAISE LP raisetype COMMA nm RP`.
fn parseRaise(p: *Parse) Error!Node.Index {
    const raise = p.nextToken();
    if (!p.eat(.l_paren)) return p.failHere();
    const kind = p.peek();
    const kind_token = p.tok_i;
    switch (kind) {
        .keyword_ignore, .keyword_rollback, .keyword_abort, .keyword_fail => _ = p.nextToken(),
        else => return p.failHere(),
    }
    var message: u32 = 0;
    if (kind != .keyword_ignore) {
        if (!p.eat(.comma)) return p.failHere();
        message = try p.parseName(.nm);
    }
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{
        .tag = .raise,
        .main_token = raise,
        .data = .{ .lhs = kind_token, .rhs = message },
    });
}

/// `idj LP distinct exprlist [ORDER BY sortlist] RP` or `idj LP STAR RP`, at the name.
fn parseCall(p: *Parse) Error!Node.Index {
    const name = p.nextToken();
    _ = p.nextToken();
    if (p.eat(.star)) {
        if (!p.eat(.r_paren)) return p.failHere();
        return p.addNode(.{ .tag = .call_star, .main_token = name, .data = .{ .lhs = 0, .rhs = 0 } });
    }
    const quantifier: u32 = if (p.eat(.keyword_distinct))
        Node.call_distinct
    else if (p.eat(.keyword_all))
        Node.call_all
    else
        0;
    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(p.gpa);
    try parts.append(p.gpa, quantifier);
    try p.parseExprListBody(&parts);
    const order_at = parts.items.len;
    try parts.append(p.gpa, 0);
    if (p.eat(.keyword_order)) {
        if (!p.eat(.keyword_by)) return p.failHere();
        while (true) {
            try parts.append(p.gpa, @backingInt(try p.parseOrderItem()));
            if (!p.eat(.comma)) break;
        }
        parts.items[order_at] = @intCast(parts.items.len - order_at - 1);
    }
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{
        .tag = .call,
        .main_token = name,
        .data = .{ .lhs = try p.addExtra(parts.items), .rhs = 0 },
    });
}

/// `expr sortorder nulls`.
fn parseOrderItem(p: *Parse) Error!Node.Index {
    const first: TokenIndex = @fromBackingInt(p.tok_i);
    const expr = try p.parseExpr(0);
    var flags: Node.SortFlags = .{ .direction = .default, .nulls = .default };
    if (p.eat(.keyword_asc)) {
        flags.direction = .asc;
    } else if (p.eat(.keyword_desc)) {
        flags.direction = .desc;
    }
    if (p.eat(.keyword_nulls)) {
        if (p.eat(.keyword_first)) {
            flags.nulls = .first;
        } else if (p.eat(.keyword_last)) {
            flags.nulls = .last;
        } else return p.failHere();
    }
    return p.addNode(.{
        .tag = .order_item,
        .main_token = first,
        .data = .{ .lhs = @backingInt(expr), .rhs = @bitCast(flags) },
    });
}

/// `LP expr RP` or `LP nexprlist COMMA expr RP`.
fn parseParenthesized(p: *Parse) Error!Node.Index {
    const open = p.nextToken();
    const first = try p.parseExpr(0);
    if (p.peek() != .comma) {
        if (!p.eat(.r_paren)) return p.failHere();
        return p.addNode(.{ .tag = .paren, .main_token = open, .data = .{ .lhs = @backingInt(first), .rhs = 0 } });
    }
    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(p.gpa);
    try items.append(p.gpa, @backingInt(first));
    while (p.eat(.comma)) try items.append(p.gpa, @backingInt(try p.parseExpr(0)));
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{ .tag = .row_value, .main_token = open, .data = try p.addExtraRange(items.items) });
}

/// Appends `items` to `extra_data` and returns the index of the first.
fn addExtra(p: *Parse, items: []const u32) Allocator.Error!u32 {
    const start: u32 = @intCast(p.extra_data.items.len);
    try p.extra_data.appendSlice(p.gpa, items);
    return start;
}

/// Appends `items` to `extra_data` and returns the range they occupy.
fn addExtraRange(p: *Parse, items: []const u32) Allocator.Error!Node.Data {
    const start = try p.addExtra(items);
    return .{ .lhs = start, .rhs = start + @as(u32, @intCast(items.len)) };
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

/// Whether tokenize.c's `getToken` reports the tag as `TK_ID` when it looks ahead: an
/// identifier, a string, a join keyword, or a keyword that falls back to `ID`.
fn isLookaheadId(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_join_kw, .keyword_window, .keyword_over => true,
        else => name_tags.get(.ids).contains(tag),
    };
}

/// Turns WINDOW, OVER and FILTER into identifiers wherever `analyzeWindowKeyword`,
/// `analyzeOverKeyword` and `analyzeFilterKeyword` of tokenize.c do. `tags` ends with `eof`.
pub fn resolveContextKeywords(tags: []Token.Tag) void {
    for (tags, 0..) |*tag, i| {
        const previous: Token.Tag = if (i > 0) tags[i - 1] else .eof;
        const next = tags[@min(i + 1, tags.len - 1)];
        const after_next = tags[@min(i + 2, tags.len - 1)];
        const is_keyword = switch (tag.*) {
            .keyword_window => isLookaheadId(next) and after_next == .keyword_as,
            .keyword_over => previous == .r_paren and (next == .l_paren or isLookaheadId(next)),
            .keyword_filter => previous == .r_paren and next == .l_paren,
            else => continue,
        };
        if (!is_keyword) tag.* = .identifier;
    }
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
