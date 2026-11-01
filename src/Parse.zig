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
source: [:0]const u8,
token_tags: []const Token.Tag,
token_locs: []const Token.Loc,
tok_i: u32,
nodes: Ast.NodeList,
extra_data: std.ArrayList(u32),
errors: std.ArrayList(Ast.Error),
depth: u32 = 0,
/// The first `#N` register variable, which parse.y rejects; see `fail`.
register_variable: ?u32 = null,
/// A grammar-action error that SQLite raises when it reduces a rule, which takes the
/// next token as lookahead; see `deferError`.
deferred: ?Deferred = null,

const Deferred = struct { err: Ast.Error, lookahead: u32 };

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
        if (p.deferred) |d| return p.recordError(d.err.tag, @backingInt(d.err.token), d.lookahead);
    }
    if (p.register_variable) |token| return p.fail(.syntax_error, token);

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
        .keyword_select, .keyword_values => return p.parseSelectStatement(),
        .keyword_with => return p.parseWith(true),
        .keyword_insert, .keyword_replace => return p.parseInsert(),
        .keyword_update => return p.parseUpdate(),
        .keyword_delete => return p.parseDelete(),
        .keyword_create => return p.parseCreate(),
        .keyword_pragma => return p.parsePragma(),
        .keyword_attach => return p.parseAttach(),
        .keyword_detach => return p.parseDetach(),
        .keyword_vacuum => return p.parseVacuum(),
        .keyword_reindex, .keyword_analyze => return p.parseReindexOrAnalyze(),
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

/// `select ::= WITH [RECURSIVE] wqlist selectnowith | selectnowith`.
fn parseSelectStatement(p: *Parse) Error!Node.Index {
    if (p.peek() != .keyword_with) return p.parseSelectNoWith();
    return p.parseWith(false);
}

/// `with` followed by a query, or by an INSERT, UPDATE or DELETE when `is_statement` (only
/// a statement can be one: `cmd ::= with insert_cmd ..`).
fn parseWith(p: *Parse, is_statement: bool) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const with = p.nextToken();
    const recursive = p.eat(.keyword_recursive);
    var ctes: std.ArrayList(u32) = .empty;
    defer ctes.deinit(p.gpa);
    try ctes.appendSlice(p.gpa, &.{ @intFromBool(recursive), 0 });
    while (true) {
        try ctes.append(p.gpa, @backingInt(try p.parseCte()));
        if (!p.eat(.comma)) break;
    }
    ctes.items[1] = @intCast(ctes.items.len - 2);
    const query = if (!is_statement) try p.parseSelectNoWith() else switch (p.peek()) {
        .keyword_insert, .keyword_replace => try p.parseInsert(),
        .keyword_update => try p.parseUpdate(),
        .keyword_delete => try p.parseDelete(),
        else => try p.parseSelectNoWith(),
    };
    return p.addBinary(.with_clause, with, @fromBackingInt(try p.addExtra(ctes.items)), @backingInt(query));
}

/// `insert_cmd INTO xfullname idlist_opt select upsert` or `.. DEFAULT VALUES returning`.
fn parseInsert(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const first = p.nextToken();
    var record: Node.Insert = std.mem.zeroes(Node.Insert);
    if (p.token_tags[@backingInt(first)] == .keyword_insert and p.eat(.keyword_or)) {
        switch (p.peek()) {
            .keyword_rollback, .keyword_abort, .keyword_fail, .keyword_ignore, .keyword_replace => {},
            else => return p.failHere(),
        }
        record.conflict = @backingInt(p.nextToken());
    }
    if (!p.eat(.keyword_into)) return p.failHere();
    record.table = try p.parseName(.nm);
    if (p.eat(.dot)) {
        record.schema = record.table;
        record.table = try p.parseName(.nm);
    }
    if (p.eat(.keyword_as)) record.alias = try p.parseName(.nm);
    if (p.eat(.l_paren)) {
        var columns: std.ArrayList(u32) = .empty;
        defer columns.deinit(p.gpa);
        while (true) {
            try columns.append(p.gpa, try p.parseName(.nm));
            if (!p.eat(.comma)) break;
        }
        if (!p.eat(.r_paren)) return p.failHere();
        const range = try p.addExtraRange(columns.items);
        record.columns_start = range.lhs;
        record.columns_end = range.rhs;
    }
    var source: u32 = 0;
    if (p.eat(.keyword_default)) {
        if (!p.eat(.keyword_values)) return p.failHere();
    } else {
        source = @backingInt(try p.parseSelectStatement());
        record.upsert = try p.parseUpsert(&record);
        return p.addInsert(first, record, source);
    }
    const returning = try p.parseReturning();
    record.returning_start = returning.lhs;
    record.returning_end = returning.rhs;
    return p.addInsert(first, record, source);
}

fn addInsert(p: *Parse, first: TokenIndex, record: Node.Insert, source: u32) Error!Node.Index {
    return p.addNode(.{
        .tag = .insert,
        .main_token = first,
        .data = .{ .lhs = try p.addExtra(@ptrCast(&record)), .rhs = source },
    });
}

/// `returning ::= RETURNING selcollist | `, as a range of `extra_data` (empty when absent).
fn parseReturning(p: *Parse) Error!Node.Data {
    if (!p.eat(.keyword_returning)) return .{ .lhs = 0, .rhs = 0 };
    return p.parseCommaList(parseResultColumn);
}

/// `cmd ::= UPDATE orconf xfullname indexed_opt SET setlist from where_opt_ret orderby_opt
/// limit_opt`, in the `SQLITE_ENABLE_UPDATE_DELETE_LIMIT` form.
fn parseUpdate(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const first = p.nextToken();
    var record: Node.Update = std.mem.zeroes(Node.Update);
    if (p.eat(.keyword_or)) {
        switch (p.peek()) {
            .keyword_rollback, .keyword_abort, .keyword_fail, .keyword_ignore, .keyword_replace => {},
            else => return p.failHere(),
        }
        record.conflict = @backingInt(p.nextToken());
    }
    try p.parseTarget(&record);
    if (!p.eat(.keyword_set)) return p.failHere();
    const set = try p.parseCommaList(parseSetItem);
    record.set_start = set.lhs;
    record.set_end = set.rhs;
    if (p.eat(.keyword_from)) record.from = @backingInt(try p.parseFrom());
    try p.parseModifiers(&record);
    return p.addNode(.{
        .tag = .update,
        .main_token = first,
        .data = .{ .lhs = try p.addExtra(@ptrCast(&record)), .rhs = 0 },
    });
}

/// `cmd ::= DELETE FROM xfullname indexed_opt where_opt_ret orderby_opt limit_opt`, in the
/// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT` form.
fn parseDelete(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const first = p.nextToken();
    var record: Node.Delete = std.mem.zeroes(Node.Delete);
    if (!p.eat(.keyword_from)) return p.failHere();
    try p.parseTarget(&record);
    try p.parseModifiers(&record);
    return p.addNode(.{
        .tag = .delete,
        .main_token = first,
        .data = .{ .lhs = try p.addExtra(@ptrCast(&record)), .rhs = 0 },
    });
}

/// `xfullname indexed_opt` into the `schema`, `table`, `alias` and `indexed` fields of
/// `record`. `xfullname` is `nm [DOT nm] [AS nm]`.
fn parseTarget(p: *Parse, record: anytype) Error!void {
    record.table = try p.parseName(.nm);
    if (p.eat(.dot)) {
        record.schema = record.table;
        record.table = try p.parseName(.nm);
    }
    if (p.eat(.keyword_as)) record.alias = try p.parseName(.nm);
    switch (p.peek()) {
        .keyword_indexed => {
            record.indexed = p.tok_i;
            _ = p.nextToken();
            if (!p.eat(.keyword_by)) return p.failHere();
            _ = try p.parseName(.nm);
        },
        .keyword_not => {
            record.indexed = p.tok_i;
            _ = p.nextToken();
            if (!p.eat(.keyword_indexed)) return p.failHere();
        },
        else => {},
    }
}

/// `where_opt_ret orderby_opt limit_opt` into the matching fields of `record`:
/// `WHERE expr`, `RETURNING ..`, `ORDER BY ..`, then `LIMIT expr [OFFSET expr | COMMA expr]`.
/// The comma form puts the offset first.
fn parseModifiers(p: *Parse, record: anytype) Error!void {
    if (p.eat(.keyword_where)) record.where = @backingInt(try p.parseExpr(0));
    const returning = try p.parseReturning();
    record.returning_start = returning.lhs;
    record.returning_end = returning.rhs;
    if (p.eat(.keyword_order)) {
        if (!p.eat(.keyword_by)) return p.failHere();
        const order = try p.parseCommaList(parseOrderItem);
        record.order_start = order.lhs;
        record.order_end = order.rhs;
    }
    if (!p.eat(.keyword_limit)) return;
    record.limit = @backingInt(try p.parseExpr(0));
    if (p.eat(.keyword_offset)) {
        record.offset = @backingInt(try p.parseExpr(0));
    } else if (p.eat(.comma)) {
        record.offset = record.limit;
        record.limit = @backingInt(try p.parseExpr(0));
    }
}

/// `upsert`: the first clause's node, or 0. Only a clause with a conflict target can be
/// followed by another one; the others end the chain, and so does RETURNING.
fn parseUpsert(p: *Parse, record: *Node.Insert) Error!u32 {
    var first: u32 = 0;
    var previous: u32 = 0;
    while (p.peek() == .keyword_on) {
        const on = p.nextToken();
        if (!p.eat(.keyword_conflict)) return p.failHere();
        var u: Node.Upsert = std.mem.zeroes(Node.Upsert);
        const targeted = p.eat(.l_paren);
        if (targeted) {
            const target = try p.parseCommaList(parseOrderItem);
            u.target_start = target.lhs;
            u.target_end = target.rhs;
            if (!p.eat(.r_paren)) return p.failHere();
            if (p.eat(.keyword_where)) u.target_where = @backingInt(try p.parseExpr(0));
        }
        if (!p.eat(.keyword_do)) return p.failHere();
        if (p.eat(.keyword_update)) {
            if (!p.eat(.keyword_set)) return p.failHere();
            const settings = try p.parseCommaList(parseSetItem);
            u.set_start = settings.lhs;
            u.set_end = settings.rhs;
            if (p.eat(.keyword_where)) u.set_where = @backingInt(try p.parseExpr(0));
        } else if (!p.eat(.keyword_nothing)) return p.failHere();
        const node = @backingInt(try p.addNode(.{
            .tag = .upsert,
            .main_token = on,
            .data = .{ .lhs = try p.addExtra(@ptrCast(&u)), .rhs = 0 },
        }));
        if (previous == 0) first = node else p.nodes.items(.data)[previous].rhs = node;
        previous = node;
        if (!targeted) break;
    }
    const returning = try p.parseReturning();
    record.returning_start = returning.lhs;
    record.returning_end = returning.rhs;
    return first;
}

/// `setlist` item: `nm EQ expr` or `LP idlist RP EQ expr`.
fn parseSetItem(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    var names: std.ArrayList(u32) = .empty;
    defer names.deinit(p.gpa);
    try names.append(p.gpa, 0);
    const parenthesized = p.eat(.l_paren);
    while (true) {
        try names.append(p.gpa, try p.parseName(.nm));
        if (!parenthesized or !p.eat(.comma)) break;
    }
    if (parenthesized and !p.eat(.r_paren)) return p.failHere();
    if (!p.eat(.equal) and !p.eat(.equal_equal)) return p.failHere();
    names.items[0] = @intCast(names.items.len - 1);
    const expr = try p.parseExpr(0);
    return p.addNode(.{
        .tag = .set_item,
        .main_token = @fromBackingInt(first),
        .data = .{ .lhs = try p.addExtra(names.items), .rhs = @backingInt(expr) },
    });
}

/// `nm collate sortorder` of an `eidlist`. The grammar takes the decoration and the action
/// rejects it, when the parser reduces.
fn parseEidlistName(p: *Parse) Error!u32 {
    const name = try p.parseName(.nm);
    const decorated = p.eat(.keyword_collate);
    if (decorated) _ = try p.parseName(.ids);
    if (p.eat(.keyword_asc) or p.eat(.keyword_desc) or decorated) {
        p.deferError(.{ .tag = .syntax_error_after_column_name, .token = @fromBackingInt(p.tok_i) });
    }
    return name;
}

/// `wqitem ::= nm eidlist_opt wqas LP select RP`.
fn parseCte(p: *Parse) Error!Node.Index {
    const name: TokenIndex = @fromBackingInt(try p.parseName(.nm));
    var record: std.ArrayList(u32) = .empty;
    defer record.deinit(p.gpa);
    try record.appendSlice(p.gpa, &.{ @backingInt(Node.Materialized.any), 0 });
    if (p.eat(.l_paren)) {
        while (true) {
            try record.append(p.gpa, try p.parseEidlistName());
            if (!p.eat(.comma)) break;
        }
        if (!p.eat(.r_paren)) return p.failHere();
        record.items[1] = @intCast(record.items.len - 2);
    }
    if (!p.eat(.keyword_as)) return p.failHere();
    if (p.eat(.keyword_materialized)) {
        record.items[0] = @backingInt(Node.Materialized.yes);
    } else if (p.eat(.keyword_not)) {
        if (!p.eat(.keyword_materialized)) return p.failHere();
        record.items[0] = @backingInt(Node.Materialized.no);
    }
    if (!p.eat(.l_paren)) return p.failHere();
    const query = try p.parseSelectStatement();
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addBinary(.cte, name, query, try p.addExtra(record.items));
}

/// `selectnowith ::= oneselect | selectnowith multiselect_op oneselect`. Terms combine
/// from the left.
fn parseSelectNoWith(p: *Parse) Error!Node.Index {
    var term = try p.parseOneSelect();
    var lhs = term.node;
    var misplaced: ?Ast.Error = null;
    while (switch (p.peek()) {
        .keyword_union, .keyword_except, .keyword_intersect => true,
        else => false,
    }) {
        const op = p.nextToken();
        if (p.token_tags[@backingInt(op)] == .keyword_union) _ = p.eat(.keyword_all);
        // parserDoubleLinkSelect walks from the right, so the last such term is the one named.
        if (term.clause) |tag| misplaced = .{ .tag = tag, .token = op };
        term = try p.parseOneSelect();
        lhs = try p.addBinary(.compound, op, lhs, @backingInt(term.node));
    }
    if (misplaced) |err| p.deferError(err);
    return lhs;
}

/// `oneselect` and the clause that a following compound
/// operator would misplace.
const OneSelect = struct { node: Node.Index, clause: ?Ast.Error.Tag };

fn parseOneSelect(p: *Parse) Error!OneSelect {
    if (p.peek() == .keyword_values) return .{ .node = try p.parseValues(), .clause = null };
    if (p.peek() != .keyword_select) return p.failHere();
    const select = p.nextToken();
    const distinct = p.eat(.keyword_distinct);
    if (!distinct) _ = p.eat(.keyword_all);
    const columns = try p.parseCommaList(parseResultColumn);
    const from = if (p.eat(.keyword_from)) try p.parseFrom() else null;
    const where = if (p.eat(.keyword_where)) try p.parseExpr(0) else null;
    const group = if (p.eat(.keyword_group)) group: {
        if (!p.eat(.keyword_by)) return p.failHere();
        break :group try p.parseCommaList(parseWholeExpr);
    } else Node.Data{ .lhs = 0, .rhs = 0 };
    const having = if (p.eat(.keyword_having)) try p.parseExpr(0) else null;
    const windows = if (p.eat(.keyword_window)) try p.parseCommaList(parseWindowDefn) else Node.Data{ .lhs = 0, .rhs = 0 };
    const order = if (p.eat(.keyword_order)) order: {
        if (!p.eat(.keyword_by)) return p.failHere();
        break :order try p.parseCommaList(parseOrderItem);
    } else Node.Data{ .lhs = 0, .rhs = 0 };
    var limit: ?Node.Index = null;
    var offset: ?Node.Index = null;
    if (p.eat(.keyword_limit)) {
        limit = try p.parseExpr(0);
        // `LIMIT a, b` takes b as the limit and a as the offset.
        if (p.eat(.keyword_offset)) {
            offset = try p.parseExpr(0);
        } else if (p.eat(.comma)) {
            offset = limit;
            limit = try p.parseExpr(0);
        }
    }
    const record: Node.Select = .{
        .distinct = @intFromBool(distinct),
        .columns_start = columns.lhs,
        .columns_end = columns.rhs,
        .from = optionalIndex(from),
        .where = optionalIndex(where),
        .group_start = group.lhs,
        .group_end = group.rhs,
        .having = optionalIndex(having),
        .order_start = order.lhs,
        .order_end = order.rhs,
        .limit = optionalIndex(limit),
        .offset = optionalIndex(offset),
        .window_start = windows.lhs,
        .window_end = windows.rhs,
    };
    const node = try p.addNode(.{
        .tag = .select,
        .main_token = select,
        .data = .{ .lhs = try p.addExtra(@ptrCast(&record)), .rhs = 0 },
    });
    const clause: ?Ast.Error.Tag = if (order.lhs != order.rhs)
        .order_by_after_union
    else if (limit != null)
        .limit_after_union
    else
        null;
    return .{ .node = node, .clause = clause };
}

fn optionalIndex(node: ?Node.Index) u32 {
    return if (node) |n| @backingInt(n) else 0;
}

fn parseWholeExpr(p: *Parse) Error!Node.Index {
    return p.parseExpr(0);
}

/// `cmd ::= create_table create_table_args`; only the TABLE form is recognized so far, and
/// the other statements CREATE can start are rejected at the token after
/// `CREATE [TEMP | UNIQUE]`.
fn parseCreate(p: *Parse) Error!Node.Index {
    const create = p.nextToken();
    const temp = p.eat(.keyword_temp);
    if (!p.eat(.keyword_table)) {
        if (!temp) _ = p.eat(.keyword_unique);
        return p.failHere();
    }
    var record: Node.CreateTable = std.mem.zeroes(Node.CreateTable);
    record.flags.temp = temp;
    if (p.eat(.keyword_if)) {
        if (!p.eat(.keyword_not) or !p.eat(.keyword_exists)) return p.failHere();
        record.flags.if_not_exists = true;
    }
    record.name = try p.parseName(.nm);
    if (p.eat(.dot)) {
        record.schema = record.name;
        record.name = try p.parseName(.nm);
    }
    var query: u32 = 0;
    if (p.eat(.keyword_as)) {
        query = @backingInt(try p.parseSelectStatement());
    } else {
        const items = try p.parseTableBody();
        record.items_start = items.lhs;
        record.items_end = items.rhs;
        try p.parseTableOptions(&record.flags);
    }
    return p.addNode(.{
        .tag = .create_table,
        .main_token = create,
        .data = .{ .lhs = try p.addExtra(@ptrCast(&record)), .rhs = query },
    });
}

/// `LP columnlist conslist_opt RP`, as a range of `extra_data`. The comma between
/// constraints is optional, but once the constraints start no column may follow.
fn parseTableBody(p: *Parse) Error!Node.Data {
    if (!p.eat(.l_paren)) return p.failHere();
    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(p.gpa);
    try items.append(p.gpa, @backingInt(try p.parseColumnDef()));
    while (p.eat(.comma)) {
        if (!isTableConstraintStart(p.peek())) {
            try items.append(p.gpa, @backingInt(try p.parseColumnDef()));
            continue;
        }
        try p.parseTableConstraints(&items);
        break;
    }
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addExtraRange(items.items);
}

/// `conslist`, appended to `items`.
fn parseTableConstraints(p: *Parse, items: *std.ArrayList(u32)) Error!void {
    while (true) {
        try items.append(p.gpa, @backingInt(try p.parseTableConstraint()));
        if (!p.eat(.comma) and !isTableConstraintStart(p.peek())) return;
    }
}

fn isTableConstraintStart(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_constraint, .keyword_primary, .keyword_unique, .keyword_check, .keyword_foreign => true,
        else => false,
    };
}

/// `table_option_set`: `WITHOUT ROWID` and `STRICT`, separated by commas, where the first
/// may be missing before a comma.
fn parseTableOptions(p: *Parse, flags: *Node.CreateTable.Flags) Error!void {
    if (p.peek() == .keyword_without or name_tags.get(.nm).contains(p.peek())) try p.parseTableOption(flags);
    while (p.eat(.comma)) try p.parseTableOption(flags);
}

/// `table_option`. SQLite rejects any name but `ROWID` after `WITHOUT` and `STRICT` when
/// the rule reduces.
fn parseTableOption(p: *Parse, flags: *Node.CreateTable.Flags) Error!void {
    const without = p.eat(.keyword_without);
    const name = try p.parseName(.nm);
    const loc = p.token_locs[name];
    if (!std.ascii.eqlIgnoreCase(p.source[loc.start..loc.end], if (without) "rowid" else "strict")) {
        p.deferError(.{ .tag = .unknown_table_option, .token = @fromBackingInt(name) });
    } else if (without) {
        flags.without_rowid = true;
    } else {
        flags.strict = true;
    }
}

/// `columnname carglist`.
fn parseColumnDef(p: *Parse) Error!Node.Index {
    const name: TokenIndex = @fromBackingInt(try p.parseName(.nm));
    const type_start = p.tok_i;
    try p.parseTypeToken();
    var record: std.ArrayList(u32) = .empty;
    defer record.deinit(p.gpa);
    try record.appendSlice(p.gpa, &.{ type_start, p.tok_i, 0 });
    while (try p.parseColumnConstraint()) |constraint| {
        try record.append(p.gpa, @backingInt(constraint));
        record.items[2] += 1;
    }
    return p.addNode(.{
        .tag = .column_def,
        .main_token = name,
        .data = .{ .lhs = try p.addExtra(record.items), .rhs = 0 },
    });
}

/// `ccons`, or null when the next token starts none.
fn parseColumnConstraint(p: *Parse) Error!?Node.Index {
    const first = p.tok_i;
    switch (p.peek()) {
        .keyword_constraint, .keyword_collate => return try p.parseKeywordName(),
        .keyword_default => return try p.parseDefault(),
        .keyword_check => return try p.parseCheck(false),
        .keyword_generated, .keyword_as => {
            if (p.eat(.keyword_generated) and !p.eat(.keyword_always)) return p.failHere();
            const as = p.tok_i;
            if (!p.eat(.keyword_as)) return p.failHere();
            const expr = try p.parseParenExpr();
            // The terminal ID, which `id` would also match with INDEXED.
            const storage = if (p.peek() == .keyword_indexed) null else p.acceptName(.id);
            return try p.addConstraint(.constraint_expr, as, expr, if (storage) |token| @backingInt(token) else 0);
        },
        .keyword_null, .keyword_not, .keyword_primary, .keyword_unique, .keyword_deferrable, .keyword_references => {
            try p.parseKeywordConstraint();
            return try p.addConstraint(.constraint_keywords, first, p.tok_i, 0);
        },
        else => return null,
    }
}

/// The constraints that are only keywords and names: `NULL onconf`, `NOT NULL onconf`,
/// `PRIMARY KEY sortorder onconf autoinc`, `UNIQUE onconf`, `defer_subclause` and
/// `REFERENCES nm eidlist_opt refargs`.
fn parseKeywordConstraint(p: *Parse) Error!void {
    const first = p.peek();
    if (first == .keyword_references) return p.parseReferences(false);
    if (first == .keyword_deferrable or p.token_tags[p.tok_i + 1] == .keyword_deferrable) return p.parseDeferClause();
    _ = p.nextToken();
    if (first == .keyword_primary) {
        if (!p.eat(.keyword_key)) return p.failHere();
        _ = p.eat(.keyword_asc) or p.eat(.keyword_desc);
    } else if (first == .keyword_not and !p.eat(.keyword_null)) return p.failHere();
    _ = try p.parseOnConf();
    if (first == .keyword_primary) _ = p.eat(.keyword_autoincr);
}

/// `tcons`.
fn parseTableConstraint(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    switch (p.peek()) {
        .keyword_constraint => return p.parseKeywordName(),
        .keyword_check => return p.parseCheck(true),
        .keyword_primary, .keyword_unique => {
            const is_primary = p.peek() == .keyword_primary;
            _ = p.nextToken();
            if (is_primary and !p.eat(.keyword_key)) return p.failHere();
            if (!p.eat(.l_paren)) return p.failHere();
            const list = try p.parseCommaList(parseOrderItem);
            const autoincrement: u32 = if (is_primary and p.peek() == .keyword_autoincr) @backingInt(p.nextToken()) else 0;
            if (!p.eat(.r_paren)) return p.failHere();
            const key: Node.Key = .{ .list_start = list.lhs, .list_end = list.rhs, .autoincrement = autoincrement, .conflict = try p.parseOnConf() };
            return p.addConstraint(.constraint_key, first, try p.addExtra(@ptrCast(&key)), 0);
        },
        .keyword_foreign => {
            _ = p.nextToken();
            if (!p.eat(.keyword_key)) return p.failHere();
            try p.parseNameList();
            if (p.peek() != .keyword_references) return p.failHere();
            try p.parseReferences(true);
            return p.addConstraint(.constraint_keywords, first, p.tok_i, 0);
        },
        else => return p.failHere(),
    }
}

/// `CONSTRAINT nm` and `COLLATE ids`.
fn parseKeywordName(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    _ = p.nextToken();
    const class: NameClass = if (p.token_tags[first] == .keyword_constraint) .nm else .ids;
    return p.addConstraint(.constraint_name, first, try p.parseName(class), 0);
}

fn addConstraint(p: *Parse, tag: Node.Tag, main_token: u32, lhs: u32, rhs: u32) Error!Node.Index {
    return p.addNode(.{ .tag = tag, .main_token = @fromBackingInt(main_token), .data = .{ .lhs = lhs, .rhs = rhs } });
}

/// `onconf`: the token after `ON CONFLICT`, or 0.
fn parseOnConf(p: *Parse) Error!u32 {
    if (!p.eat(.keyword_on)) return 0;
    if (!p.eat(.keyword_conflict)) return p.failHere();
    switch (p.peek()) {
        .keyword_rollback, .keyword_abort, .keyword_fail, .keyword_ignore, .keyword_replace => {},
        else => return p.failHere(),
    }
    return @backingInt(p.nextToken());
}

/// `LP expr RP`.
fn parseParenExpr(p: *Parse) Error!u32 {
    if (!p.eat(.l_paren)) return p.failHere();
    const expr = try p.parseExpr(0);
    if (!p.eat(.r_paren)) return p.failHere();
    return @backingInt(expr);
}

/// `CHECK LP expr RP`, followed by `onconf` in a table constraint.
fn parseCheck(p: *Parse, is_table: bool) Error!Node.Index {
    const first = p.nextToken();
    const expr = try p.parseParenExpr();
    return p.addConstraint(.constraint_expr, @backingInt(first), expr, if (is_table) try p.parseOnConf() else 0);
}

/// `DEFAULT term`, `DEFAULT [PLUS | MINUS] term`, `DEFAULT LP expr RP` or `DEFAULT id`.
fn parseDefault(p: *Parse) Error!Node.Index {
    const first = p.nextToken();
    const operand: u32 = switch (p.peek()) {
        .l_paren => try p.parseParenExpr(),
        .plus, .minus => plus: {
            _ = p.nextToken();
            break :plus @backingInt(try p.parseTerm() orelse return p.failHere());
        },
        else => if (try p.parseTerm()) |term| @backingInt(term) else name: {
            _ = try p.parseName(.id);
            break :name 0;
        },
    };
    return p.addConstraint(.constraint_default, @backingInt(first), operand, 0);
}

/// `term` in the forms a column default can take, or null at any other token.
fn parseTerm(p: *Parse) Error!?Node.Index {
    switch (p.peek()) {
        .integer_literal, .float_literal, .blob_literal, .string_literal, .keyword_null, .keyword_ctime_kw => {},
        else => return null,
    }
    return try p.addNode(.{ .tag = .literal, .main_token = p.nextToken(), .data = .{ .lhs = 0, .rhs = 0 } });
}

/// `defer_subclause`, at its `NOT` or `DEFERRABLE`.
fn parseDeferClause(p: *Parse) Error!void {
    _ = p.eat(.keyword_not);
    if (!p.eat(.keyword_deferrable)) return p.failHere();
    if (p.eat(.keyword_initially) and !p.eat(.keyword_deferred) and !p.eat(.keyword_immediate)) return p.failHere();
}

/// `REFERENCES nm eidlist_opt refargs`, and `defer_subclause_opt` when `is_foreign`.
fn parseReferences(p: *Parse, is_foreign: bool) Error!void {
    _ = p.nextToken();
    _ = try p.parseName(.nm);
    if (p.peek() == .l_paren) try p.parseNameList();
    while (true) {
        if (p.eat(.keyword_match)) {
            _ = try p.parseName(.nm);
        } else if (p.eat(.keyword_on)) {
            if (!p.eat(.keyword_insert) and !p.eat(.keyword_delete) and !p.eat(.keyword_update)) return p.failHere();
            const ok = if (p.eat(.keyword_set))
                p.eat(.keyword_null) or p.eat(.keyword_default)
            else if (p.eat(.keyword_no))
                p.eat(.keyword_action)
            else
                p.eat(.keyword_cascade) or p.eat(.keyword_restrict);
            if (!ok) return p.failHere();
        } else break;
    }
    if (is_foreign and (p.peek() == .keyword_not or p.peek() == .keyword_deferrable)) try p.parseDeferClause();
}

/// `LP eidlist RP`.
fn parseNameList(p: *Parse) Error!void {
    if (!p.eat(.l_paren)) return p.failHere();
    while (true) {
        _ = try p.parseEidlistName();
        if (!p.eat(.comma)) break;
    }
    if (!p.eat(.r_paren)) return p.failHere();
}

/// `item (COMMA item)*`, stored as a range of `extra_data`.
fn parseCommaList(p: *Parse, comptime parseItem: fn (*Parse) Error!Node.Index) Error!Node.Data {
    var items: std.ArrayList(u32) = .empty;
    defer items.deinit(p.gpa);
    while (true) {
        try items.append(p.gpa, @backingInt(try parseItem(p)));
        if (!p.eat(.comma)) break;
    }
    return p.addExtraRange(items.items);
}

/// `values ::= VALUES LP nexprlist RP | values COMMA LP nexprlist RP`.
fn parseValues(p: *Parse) Error!Node.Index {
    const values = p.nextToken();
    var rows: std.ArrayList(u32) = .empty;
    defer rows.deinit(p.gpa);
    while (true) {
        if (p.peek() != .l_paren) return p.failHere();
        const open = p.nextToken();
        const items = try p.parseCommaList(parseWholeExpr);
        if (!p.eat(.r_paren)) return p.failHere();
        try rows.append(p.gpa, @backingInt(try p.addNode(.{ .tag = .row_value, .main_token = open, .data = items })));
        if (!p.eat(.comma)) break;
    }
    return p.addNode(.{ .tag = .values, .main_token = values, .data = try p.addExtraRange(rows.items) });
}

/// `seltablist`: items joined by join operators, each optionally with `ON` or `USING`.
fn parseFrom(p: *Parse) Error!Node.Index {
    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(p.gpa);
    var list: ?Node.Index = null;
    var op: u32 = 0;
    while (true) {
        const item = try p.parseFromItem();
        parts.clearRetainingCapacity();
        try parts.append(p.gpa, @backingInt(item));
        try p.parseOnUsing(&parts);
        if (list == null and parts.items[1] != 0) {
            p.deferError(.{ .tag = .join_clause_required, .token = @fromBackingInt(parts.items[1]) });
        }
        list = if (list) |left|
            try p.addBinary(.join, @fromBackingInt(op), left, try p.addExtra(parts.items))
        else
            item;
        op = try p.parseJoinOp() orelse return list.?;
    }
}

/// A table, a table-valued function, a subquery or a parenthesized `seltablist`, with its
/// alias and, for a table, `INDEXED BY` or `NOT INDEXED`.
fn parseFromItem(p: *Parse) Error!Node.Index {
    if (p.peek() == .l_paren) return p.parseParenthesizedFrom();
    const name = p.tok_i;
    _ = try p.parseName(.nm);
    const second = if (p.eat(.dot)) try p.parseName(.nm) else 0;
    if (p.eat(.l_paren)) {
        var parts: std.ArrayList(u32) = .empty;
        defer parts.deinit(p.gpa);
        try parts.appendSlice(p.gpa, &.{ second, 0 });
        try p.parseCountedExprList(&parts);
        parts.items[1] = try p.parseAlias();
        return p.addNode(.{
            .tag = .table_func,
            .main_token = @fromBackingInt(name),
            .data = .{ .lhs = try p.addExtra(parts.items), .rhs = 0 },
        });
    }
    const alias = try p.parseAlias();
    const indexed = p.tok_i;
    switch (p.peek()) {
        .keyword_indexed => {
            _ = p.nextToken();
            if (!p.eat(.keyword_by)) return p.failHere();
            _ = try p.parseName(.nm);
        },
        .keyword_not => {
            _ = p.nextToken();
            if (!p.eat(.keyword_indexed)) return p.failHere();
        },
        else => {},
    }
    return p.addNode(.{
        .tag = .table_ref,
        .main_token = @fromBackingInt(name),
        .data = .{
            .lhs = try p.addExtra(&.{ second, alias, if (p.tok_i == indexed) 0 else indexed }),
            .rhs = 0,
        },
    });
}

/// `LP select RP as` or `LP seltablist RP as`.
fn parseParenthesizedFrom(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const open = p.nextToken();
    const inner = switch (p.peek()) {
        .keyword_select, .keyword_values, .keyword_with => try p.parseSelectStatement(),
        else => try p.parseFrom(),
    };
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{
        .tag = .subquery_table,
        .main_token = open,
        .data = .{ .lhs = @backingInt(inner), .rhs = try p.parseAlias() },
    });
}

/// `as ::= AS nm | ids | `: the alias token, or 0.
fn parseAlias(p: *Parse) Error!u32 {
    if (p.eat(.keyword_as)) return p.parseName(.nm);
    return if (p.acceptName(.ids)) |name| @backingInt(name) else 0;
}

/// `on_using`: appends the `ON` or `USING` token, or 0, then the expression for `ON` or the
/// count and the names for `USING`.
fn parseOnUsing(p: *Parse, parts: *std.ArrayList(u32)) Error!void {
    switch (p.peek()) {
        .keyword_on => {
            try parts.append(p.gpa, @backingInt(p.nextToken()));
            try parts.append(p.gpa, @backingInt(try p.parseExpr(0)));
        },
        .keyword_using => {
            try parts.append(p.gpa, @backingInt(p.nextToken()));
            if (!p.eat(.l_paren)) return p.failHere();
            const count_at = parts.items.len;
            try parts.append(p.gpa, 0);
            while (true) {
                try parts.append(p.gpa, try p.parseName(.nm));
                if (!p.eat(.comma)) break;
            }
            if (!p.eat(.r_paren)) return p.failHere();
            parts.items[count_at] = @intCast(parts.items.len - count_at - 1);
        },
        else => try parts.append(p.gpa, 0),
    }
}

/// The bits of tokenize.c's join keywords, as `sqlite3JoinType` combines them.
const JoinBits = struct {
    const natural = 1;
    const inner = 2;
    const cross = 4;
    const left = 8;
    const right = 16;
    const outer = 32;
};

const join_keywords = std.StaticStringMap(u8).initComptime(.{
    .{ "natural", JoinBits.natural },
    .{ "left", JoinBits.left | JoinBits.outer },
    .{ "outer", JoinBits.outer },
    .{ "right", JoinBits.right | JoinBits.outer },
    .{ "full", JoinBits.left | JoinBits.right | JoinBits.outer },
    .{ "inner", JoinBits.inner },
    .{ "cross", JoinBits.inner | JoinBits.cross },
});

/// `joinop`: the first token of the operator, or null when none follows. A join keyword
/// operator is checked as `sqlite3JoinType` does.
fn parseJoinOp(p: *Parse) Error!?u32 {
    const first = p.tok_i;
    switch (p.peek()) {
        .comma, .keyword_join => _ = p.nextToken(),
        .keyword_join_kw => {
            _ = p.nextToken();
            while (p.tok_i - first < 3 and p.acceptName(.nm) != null) {}
            if (!p.eat(.keyword_join)) return p.failHere();
            if (!p.isValidJoinType(first, p.tok_i - 1)) p.deferError(.{ .tag = .unknown_join_type, .token = @fromBackingInt(first) });
        },
        else => return null,
    }
    return first;
}

/// Whether the tokens `first..end` are join keywords that `sqlite3JoinType` accepts.
fn isValidJoinType(p: Parse, first: u32, end: u32) bool {
    var bits: u8 = 0;
    for (p.token_locs[first..end]) |loc| {
        var buf: [8]u8 = undefined;
        const text = p.source[loc.start..loc.end];
        if (text.len > buf.len) return false;
        bits |= join_keywords.get(std.ascii.lowerString(&buf, text)) orelse return false;
    }
    const inner_outer = JoinBits.inner | JoinBits.outer;
    return bits & inner_outer != inner_outer and bits & (JoinBits.outer | JoinBits.left | JoinBits.right) != JoinBits.outer;
}

/// `PRAGMA nm dbnm`, optionally followed by `EQ` or `LP` and a value, then `RP`.
fn parsePragma(p: *Parse) Error!Node.Index {
    const pragma = p.nextToken();
    const first = try p.parseName(.nm);
    const second = if (p.eat(.dot)) try p.parseName(.nm) else 0;
    const form: u32 = switch (p.peek()) {
        .equal, .equal_equal, .l_paren => @backingInt(p.nextToken()),
        else => 0,
    };
    var sign: u32 = 0;
    var value: u32 = 0;
    if (form != 0) {
        if (p.peek() == .plus or p.peek() == .minus) sign = @backingInt(p.nextToken());
        value = switch (p.peek()) {
            .integer_literal, .float_literal => @backingInt(p.nextToken()),
            .keyword_on, .keyword_delete, .keyword_default => if (sign == 0) @backingInt(p.nextToken()) else return p.failHere(),
            else => if (sign == 0) try p.parseName(.nm) else return p.failHere(),
        };
        if (p.token_tags[form] == .l_paren and !p.eat(.r_paren)) return p.failHere();
    }
    return p.addNode(.{
        .tag = .pragma,
        .main_token = pragma,
        .data = .{ .lhs = first, .rhs = try p.addExtra(&.{ second, form, sign, value }) },
    });
}

/// `ATTACH database_kw_opt expr AS expr key_opt`.
fn parseAttach(p: *Parse) Error!Node.Index {
    const attach = p.nextToken();
    _ = p.eat(.keyword_database);
    const file = try p.parseExpr(0);
    if (!p.eat(.keyword_as)) return p.failHere();
    const name = try p.parseExpr(0);
    const key = if (p.eat(.keyword_key)) try p.parseExpr(0) else null;
    return p.addNode(.{
        .tag = .attach,
        .main_token = attach,
        .data = .{
            .lhs = @backingInt(file),
            .rhs = try p.addExtra(&.{ @backingInt(name), if (key) |k| @backingInt(k) else 0 }),
        },
    });
}

/// `DETACH database_kw_opt expr`.
fn parseDetach(p: *Parse) Error!Node.Index {
    const detach = p.nextToken();
    _ = p.eat(.keyword_database);
    const database = try p.parseExpr(0);
    return p.addNode(.{
        .tag = .detach,
        .main_token = detach,
        .data = .{ .lhs = @backingInt(database), .rhs = 0 },
    });
}

/// `VACUUM [nm] vinto`, where `vinto ::= INTO expr | `.
fn parseVacuum(p: *Parse) Error!Node.Index {
    const vacuum = p.nextToken();
    const schema = if (p.acceptName(.nm)) |name| @backingInt(name) else 0;
    const into = if (p.eat(.keyword_into)) @backingInt(try p.parseExpr(0)) else 0;
    return p.addNode(.{ .tag = .vacuum, .main_token = vacuum, .data = .{ .lhs = schema, .rhs = into } });
}

/// `REINDEX` or `ANALYZE`, each optionally followed by `nm dbnm`.
fn parseReindexOrAnalyze(p: *Parse) Error!Node.Index {
    const tag: Node.Tag = if (p.peek() == .keyword_reindex) .reindex else .analyze;
    const keyword = p.nextToken();
    var first: u32 = 0;
    var second: u32 = 0;
    if (p.acceptName(.nm)) |name| {
        first = @backingInt(name);
        if (p.eat(.dot)) second = try p.parseName(.nm);
    }
    return p.addNode(.{ .tag = tag, .main_token = keyword, .data = .{ .lhs = first, .rhs = second } });
}

/// `selcollist ::= expr as | STAR`, where `as ::= AS nm | ids | `.
fn parseResultColumn(p: *Parse) Error!Node.Index {
    const first = p.tok_i;
    if (p.eat(.star)) return p.addNode(.{
        .tag = .result_star,
        .main_token = @fromBackingInt(first),
        .data = .{ .lhs = 0, .rhs = 0 },
    });
    if (name_tags.get(.nm).contains(p.peek()) and p.token_tags[first + 1] == .dot and p.token_tags[first + 2] == .star) {
        p.tok_i += 3;
        return p.addNode(.{
            .tag = .result_star,
            .main_token = @fromBackingInt(first + 2),
            .data = .{ .lhs = first, .rhs = 0 },
        });
    }
    const expr = try p.parseExpr(0);
    return p.addNode(.{
        .tag = .result_expr,
        .main_token = @fromBackingInt(first),
        .data = .{ .lhs = @backingInt(expr), .rhs = try p.parseAlias() },
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

fn isQueryStart(tag: Token.Tag) bool {
    return tag == .keyword_select or tag == .keyword_values or tag == .keyword_with;
}

/// What follows `IN`: `(exprlist)`, `name`, `schema.name` or either name with a
/// parenthesized argument list.
fn parseInOperand(p: *Parse, op: TokenIndex, lhs: Node.Index) Error!Node.Index {
    var operands: std.ArrayList(u32) = .empty;
    defer operands.deinit(p.gpa);
    if (p.peek() == .l_paren and isQueryStart(p.token_tags[p.tok_i + 1])) {
        _ = p.nextToken();
        const query = try p.parseSelectStatement();
        if (!p.eat(.r_paren)) return p.failHere();
        return p.addBinary(.in_select, op, lhs, @backingInt(query));
    }
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
            const start = p.token_locs[p.tok_i].start;
            if (p.register_variable == null and p.source[start] == '#' and std.ascii.isDigit(p.source[start + 1]))
                p.register_variable = p.tok_i;
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
        .keyword_exists => {
            _ = p.nextToken();
            if (!p.eat(.l_paren) or !isQueryStart(p.peek())) return p.failHere();
            const query = try p.parseSelectStatement();
            if (!p.eat(.r_paren)) return p.failHere();
            return p.addNode(.{ .tag = .exists, .main_token = main_token, .data = .{ .lhs = @backingInt(query), .rhs = 0 } });
        },
        else => {},
    }
    if (!name_tags.get(.nm).contains(first)) return p.failHere();
    if (name_tags.get(.idj).contains(first) and p.token_tags[p.tok_i + 1] == .l_paren) return p.parseCall();
    _ = p.nextToken();
    var parts: u32 = 1;
    while (parts < 3 and p.eat(.dot)) : (parts += 1) _ = try p.parseName(.nm);
    return p.addNode(.{ .tag = .name, .main_token = main_token, .data = .{ .lhs = parts, .rhs = 0 } });
}

/// `CAST LP expr AS typetoken RP`.
fn parseCast(p: *Parse) Error!Node.Index {
    const cast = p.nextToken();
    if (!p.eat(.l_paren)) return p.failHere();
    const operand = try p.parseExpr(0);
    if (!p.eat(.keyword_as)) return p.failHere();
    const type_start = p.tok_i;
    try p.parseTypeToken();
    const type_end = p.tok_i;
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{
        .tag = .cast,
        .main_token = cast,
        .data = .{ .lhs = @backingInt(operand), .rhs = try p.addExtra(&.{ type_start, type_end }) },
    });
}

/// `typetoken`: any number of `ids` and then `(signed)` or `(signed, signed)`, the last
/// two only after a name.
fn parseTypeToken(p: *Parse) Error!void {
    if (p.acceptName(.ids) == null) return;
    while (p.acceptName(.ids) != null) {}
    if (p.eat(.l_paren)) {
        try p.parseSigned();
        if (p.eat(.comma)) try p.parseSigned();
        if (!p.eat(.r_paren)) return p.failHere();
    }
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
        return p.addNode(.{ .tag = .call_star, .main_token = name, .data = .{ .lhs = 0, .rhs = try p.parseFilterOver() } });
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
        .data = .{ .lhs = try p.addExtra(parts.items), .rhs = try p.parseFilterOver() },
    });
}

/// `filter_over`, which may be empty: the `filter_over` node, or 0.
fn parseFilterOver(p: *Parse) Error!u32 {
    const first: TokenIndex = @fromBackingInt(p.tok_i);
    var filter: u32 = 0;
    if (p.eat(.keyword_filter)) {
        if (!p.eat(.l_paren) or !p.eat(.keyword_where)) return p.failHere();
        filter = @backingInt(try p.parseExpr(0));
        if (!p.eat(.r_paren)) return p.failHere();
    }
    var over: u32 = 0;
    if (p.eat(.keyword_over)) {
        if (p.peek() == .l_paren) {
            over = @backingInt(try p.parseWindow());
        } else {
            const name = try p.parseName(.nm);
            over = @backingInt(try p.addNode(.{ .tag = .window_ref, .main_token = @fromBackingInt(name), .data = .{ .lhs = 0, .rhs = 0 } }));
        }
    }
    if (filter == 0 and over == 0) return 0;
    return @backingInt(try p.addNode(.{ .tag = .filter_over, .main_token = first, .data = .{ .lhs = filter, .rhs = over } }));
}

/// `windowdefn ::= nm AS LP window RP`.
fn parseWindowDefn(p: *Parse) Error!Node.Index {
    const name = p.tok_i;
    _ = try p.parseName(.nm);
    if (!p.eat(.keyword_as)) return p.failHere();
    if (p.peek() != .l_paren) return p.failHere();
    const window = try p.parseWindow();
    p.nodes.items(.main_token)[@backingInt(window)] = @fromBackingInt(name);
    return window;
}

/// `LP window RP`, at the left parenthesis.
fn parseWindow(p: *Parse) Error!Node.Index {
    try p.enter();
    defer p.leave();
    const open = p.nextToken();
    var w: Node.Window = std.mem.zeroes(Node.Window);
    // PARTITION, RANGE, ROWS and GROUPS begin the rules that follow, so they are not a base name.
    switch (p.peek()) {
        .keyword_partition, .keyword_range, .keyword_rows, .keyword_groups => {},
        else => if (p.acceptName(.nm)) |base| {
            w.base = @backingInt(base);
        },
    }
    if (p.eat(.keyword_partition)) {
        if (!p.eat(.keyword_by)) return p.failHere();
        const list = try p.parseCommaList(parseWholeExpr);
        w.partition_start = list.lhs;
        w.partition_end = list.rhs;
    }
    if (p.eat(.keyword_order)) {
        if (!p.eat(.keyword_by)) return p.failHere();
        const list = try p.parseCommaList(parseOrderItem);
        w.order_start = list.lhs;
        w.order_end = list.rhs;
    }
    switch (p.peek()) {
        .keyword_range, .keyword_rows, .keyword_groups => try p.parseFrame(&w),
        else => {},
    }
    if (!p.eat(.r_paren)) return p.failHere();
    return p.addNode(.{ .tag = .window_def, .main_token = open, .data = .{ .lhs = try p.addExtra(@ptrCast(&w)), .rhs = 0 } });
}

/// `frame_opt` after `range_or_rows`, at that keyword: fills in the frame fields of `w`.
fn parseFrame(p: *Parse, w: *Node.Window) Error!void {
    w.frame_unit = @backingInt(p.nextToken());
    if (p.eat(.keyword_between)) {
        w.start, w.start_expr = try p.parseFrameBound(.unbounded_preceding);
        if (!p.eat(.keyword_and)) return p.failHere();
        w.end, w.end_expr = try p.parseFrameBound(.unbounded_following);
    } else {
        w.start, w.start_expr = try p.parseFrameBound(.unbounded_preceding);
    }
    if (p.eat(.keyword_exclude)) {
        w.exclude = if (p.eat(.keyword_no))
            if (p.eat(.keyword_others)) .no_others else return p.failHere()
        else if (p.eat(.keyword_current))
            if (p.eat(.keyword_row)) .current_row else return p.failHere()
        else if (p.eat(.keyword_group))
            .group
        else if (p.eat(.keyword_ties))
            .ties
        else
            return p.failHere();
    }
}

/// `frame_bound_s` or `frame_bound_e`: `unbounded` is the only `UNBOUNDED` form the
/// caller's bound admits. Returns the bound and its expression, 0 when it has none.
fn parseFrameBound(p: *Parse, unbounded: Node.FrameBound) Error!struct { Node.FrameBound, u32 } {
    if (p.eat(.keyword_unbounded)) {
        const direction: Token.Tag = if (unbounded == .unbounded_preceding) .keyword_preceding else .keyword_following;
        if (!p.eat(direction)) return p.failHere();
        return .{ unbounded, 0 };
    }
    if (p.eat(.keyword_current)) {
        if (!p.eat(.keyword_row)) return p.failHere();
        return .{ .current_row, 0 };
    }
    const expr = try p.parseExpr(0);
    const bound: Node.FrameBound = if (p.eat(.keyword_preceding))
        .preceding
    else if (p.eat(.keyword_following))
        .following
    else
        return p.failHere();
    return .{ bound, @backingInt(expr) };
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
    if (isQueryStart(p.peek())) {
        const query = try p.parseSelectStatement();
        if (!p.eat(.r_paren)) return p.failHere();
        return p.addNode(.{ .tag = .subquery, .main_token = open, .data = .{ .lhs = @backingInt(query), .rhs = 0 } });
    }
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

/// A grammar action of parse.y raises its error when the rule reduces, which needs the
/// next token as lookahead. If that token is itself a syntax error, the parser never
/// reduces and reports the syntax error; see `fail`. Only the first such error counts.
fn deferError(p: *Parse, err: Ast.Error) void {
    if (p.deferred == null) p.deferred = .{ .err = err, .lookahead = p.tok_i };
}

/// Records `tag` at `token`. SQLite tokenizes as it parses, so an `invalid` token at or
/// before the error point is reported instead.
///
/// parse.y reports `#N` only when it reduces the variable, which takes the next token as
/// lookahead (`expr ::= VARIABLE`), and stops there. So a syntax error at the very next
/// token wins; any later error never happens and the variable is blamed.
fn fail(p: *Parse, error_tag: Ast.Error.Tag, error_token: u32) Error {
    if (p.deferred) |d| {
        if (error_token > d.lookahead) return p.recordError(d.err.tag, @backingInt(d.err.token), d.lookahead);
    }
    const blamed = p.register_variable orelse error_token;
    const redirected = blamed != error_token and error_token != blamed + 1;
    const tag: Ast.Error.Tag = if (redirected) .syntax_error else error_tag;
    const token = if (redirected) blamed else error_token;
    return p.recordError(tag, token, token);
}

/// Appends the error; `seen` is the last token SQLite had tokenized when it raised it.
fn recordError(p: *Parse, error_tag: Ast.Error.Tag, error_token: u32, seen: u32) Error {
    const first_invalid = std.mem.indexOfScalar(Token.Tag, p.token_tags[0 .. seen + 1], .invalid);
    try p.errors.append(p.gpa, if (first_invalid) |i|
        .{ .tag = .unrecognized_token, .token = @fromBackingInt(@intCast(i)) }
    else
        .{ .tag = error_tag, .token = @fromBackingInt(error_token) });
    return error.ParseError;
}

fn expectNameClass(class: NameClass, source: [:0]const u8, accepted: bool) !void {
    var t: tokenizer.Tokenizer = .init(source);
    const tags = [_]Token.Tag{ t.next().tag, .eof };
    var p: Parse = .{
        .gpa = std.testing.allocator,
        .source = source,
        .token_tags = &tags,
        .token_locs = &.{},
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
        .source = ast.source,
        .token_tags = ast.tokens.items(.tag),
        .token_locs = ast.tokens.items(.loc),
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
