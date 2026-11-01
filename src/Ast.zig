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

    /// The values of `Tag.call`'s quantifier.
    pub const call_distinct = 1;
    pub const call_all = 2;

    /// `Tag.order_item`'s sort options, packed into `Data.rhs`.
    pub const SortFlags = packed struct(u32) {
        direction: enum(u2) { default, asc, desc },
        nulls: enum(u2) { default, first, last },
        _: u28 = 0,
    };

    /// The record `Tag.select` points to in `extra_data`. The ranges index `extra_data`;
    /// nodes and ranges that are absent are 0 (no expression is node 0, the root).
    pub const Select = extern struct {
        distinct: u32,
        columns_start: u32,
        columns_end: u32,
        from: u32,
        where: u32,
        group_start: u32,
        group_end: u32,
        having: u32,
        order_start: u32,
        order_end: u32,
        limit: u32,
        offset: u32,
        window_start: u32,
        window_end: u32,
    };

    /// The record `Tag.window_def` points to in `extra_data`. Tokens and nodes that are
    /// absent are 0 (the base name and the frame unit follow `(`, so neither is token 0).
    pub const Window = extern struct {
        base: u32,
        partition_start: u32,
        partition_end: u32,
        order_start: u32,
        order_end: u32,
        /// The `RANGE`, `ROWS` or `GROUPS` token, or 0 when there is no frame.
        frame_unit: u32,
        start: FrameBound,
        start_expr: u32,
        /// `none` unless the frame has the `BETWEEN start AND end` form.
        end: FrameBound,
        end_expr: u32,
        exclude: FrameExclude,
    };

    /// One end of a window frame; `start_expr` and `end_expr` of `Window` are the offset
    /// expression of `preceding` and `following`.
    pub const FrameBound = enum(u32) { none, unbounded_preceding, unbounded_following, current_row, preceding, following };

    /// The `EXCLUDE` option of a window frame.
    pub const FrameExclude = enum(u32) { none, no_others, current_row, group, ties };

    /// The record `Tag.insert` points to in `extra_data`. Tokens absent are 0 (no token
    /// that follows `INSERT` or `REPLACE` has index 0); the ranges index `extra_data`.
    pub const Insert = extern struct {
        /// The conflict resolution keyword after `OR`.
        conflict: u32,
        /// The schema name when the table is written `schema.table`.
        schema: u32,
        table: u32,
        alias: u32,
        columns_start: u32,
        columns_end: u32,
        /// The first `upsert` node of the chain, or 0.
        upsert: u32,
        returning_start: u32,
        returning_end: u32,
    };

    /// The record `Tag.upsert` points to in `extra_data`. Nodes absent are 0.
    pub const Upsert = extern struct {
        target_start: u32,
        target_end: u32,
        target_where: u32,
        /// Empty for `DO NOTHING`.
        set_start: u32,
        set_end: u32,
        set_where: u32,
    };

    /// Whether a CTE says `MATERIALIZED`, `NOT MATERIALIZED` or neither.
    pub const Materialized = enum(u32) { any, yes, no };

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
        /// `PRAGMA first[.second] [= value | (value)]`. `lhs` is the first name token and
        /// `rhs` the index in `extra_data` of four tokens: the second name, the `=` or `(`,
        /// the `+` or `-` sign, and the value (a number, `ON`, `DELETE`, `DEFAULT` or a
        /// name), each 0 when absent (no token that follows `PRAGMA` has index 0).
        pragma,
        /// `ATTACH [DATABASE] lhs AS expr [KEY expr]`. `rhs` is the index in `extra_data`
        /// of the name expression and the key expression, which is 0 when absent.
        attach,
        /// `DETACH [DATABASE] lhs`.
        detach,
        /// `VACUUM [schema] [INTO expr]`. `lhs` is the schema name token and `rhs` the
        /// expression, each 0 when absent.
        vacuum,
        /// `REINDEX [first [. second]]`. `lhs` and `rhs` are the name tokens, 0 when absent.
        reindex,
        /// `ANALYZE [first [. second]]`, laid out like `reindex`.
        analyze,
        /// `SELECT [DISTINCT | ALL] columns [FROM ..] [WHERE ..] [GROUP BY ..] [HAVING ..]
        /// [ORDER BY ..] [LIMIT ..]`. `lhs` is the `extra_data` index of a `Node.Select`.
        select,
        /// `WITH [RECURSIVE] cte, .. query`. `main_token` is `WITH`. `lhs` is the `extra_data`
        /// index of the `RECURSIVE` flag (0 or 1), the number of CTEs and the `cte` nodes.
        /// `rhs` is the query node (`select`, `compound` or `values`).
        with_clause,
        /// `name [(columns)] AS [[NOT] MATERIALIZED] (query)`. `main_token` is the name.
        /// `lhs` is the query node. `rhs` is the `extra_data` index of a `Materialized`,
        /// the column count and the column name tokens.
        cte,
        /// A window definition, `base PARTITION BY .. ORDER BY .. frame`. `lhs` is the
        /// `extra_data` index of a `Node.Window`. `main_token` is the window's name in a
        /// `WINDOW` clause and the `(` in `OVER (..)`.
        window_def,
        /// `OVER name`. `main_token` is the name.
        window_ref,
        /// `FILTER (WHERE lhs) OVER rhs` after a function call; `lhs` is the filter
        /// expression and `rhs` the `window_def` or `window_ref` node, each 0 when absent.
        /// `main_token` is the first of the two keywords.
        filter_over,
        /// `lhs UNION [ALL] | INTERSECT | EXCEPT rhs` of `select`, `values` or `compound`
        /// nodes. `main_token` is the operator; for `UNION ALL` the next token is `ALL`.
        compound,
        /// `VALUES (..), (..)`. `lhs..rhs` is the range of `extra_data` holding the
        /// `row_value` nodes.
        values,
        /// `name[.name] [[AS] alias] [INDEXED BY name | NOT INDEXED]` in a `FROM` clause.
        /// `main_token` is the first name. `lhs` is the `extra_data` index of the second
        /// name, the alias and the `INDEXED` or `NOT` token, each 0 when absent.
        table_ref,
        /// `name[.name](args) [[AS] alias]` in a `FROM` clause. `main_token` is the first
        /// name. `lhs` is the `extra_data` index of the second name, the alias (each 0 when
        /// absent), the argument count and the argument nodes.
        table_func,
        /// `(select) [[AS] alias]` or `(tables) [[AS] alias]` in a `FROM` clause.
        /// `main_token` is the left parenthesis. `lhs` is the query or `FROM` item node
        /// inside and `rhs` the alias token or 0.
        subquery_table,
        /// `lhs op item [ON expr | USING (names)]` in a `FROM` clause. `main_token` is the
        /// first token of the operator: `,`, `JOIN` or a join keyword; a keyword operator
        /// ends at the next `JOIN`. `rhs` is the `extra_data` index of the right item node
        /// and the `ON` or `USING` token (0 when absent), then the `ON` expression node or
        /// the `USING` name count and tokens.
        join,
        /// A result column: `*` or `name.*`.
        /// `main_token` is the star and `lhs` the
        /// table name token or 0 when there is none.
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
        /// `lhs IS DISTINCT FROM rhs`, laid out like `is_not`.
        is_distinct,
        /// `lhs IS NOT DISTINCT FROM rhs`, laid out like `is_not`.
        is_not_distinct,
        /// `lhs COLLATE name`. `rhs` is the name token. `main_token` is `COLLATE`.
        collate,
        /// `lhs ISNULL`. `main_token` is `ISNULL`.
        is_null,
        /// `lhs NOTNULL` or `lhs NOT NULL`. `main_token` is `NOTNULL` or `NULL`.
        not_null,
        /// `lhs [NOT] LIKE|GLOB|REGEXP|MATCH pattern [ESCAPE escape]`. `main_token` is the
        /// operator keyword; the token before it is `NOT` when the operator is negated.
        /// `rhs` is the `extra_data` index of the pattern node and the escape node, which
        /// is 0 when there is no `ESCAPE` (no expression is node 0, the root).
        like,
        /// `lhs [NOT] BETWEEN low AND high`. `main_token` is `BETWEEN`, negated as for
        /// `like`. `rhs` is the `extra_data` index of the `low` and `high` nodes.
        between,
        /// `lhs [NOT] IN (items)`. `main_token` is `IN`, negated as for `like`. `rhs` is
        /// the `extra_data` index of the item count followed by the item nodes.
        in_list,
        /// `lhs [NOT] IN name` or `IN schema.name`. `main_token` is `IN`. `rhs` is the
        /// `extra_data` index of the name token and the token after the dot, or 0.
        in_table,
        /// `lhs [NOT] IN name(args)` or `IN schema.name(args)`. `main_token` is `IN`.
        /// `rhs` is the `extra_data` index of the same two tokens, then the argument count
        /// and the argument nodes.
        in_func,
        /// `CAST(lhs AS type)`. `main_token` is `CAST`. `rhs` is the `extra_data` index of
        /// the first and the end token of the type; the end is the closing parenthesis.
        /// The type is the tokens between them, as `typetoken` gives them.
        cast,
        /// `CASE [operand] WHEN .. THEN .. [ELSE ..] END`. `main_token` is `CASE`. `lhs` is
        /// the operand node or 0. `rhs` is the `extra_data` index of the `ELSE` node (0 when
        /// absent), the number of `WHEN` pairs and the pairs' nodes, condition first.
        case,
        /// `RAISE(IGNORE)` or `RAISE(kind, message)`. `main_token` is `RAISE`. `lhs` is the
        /// kind token and `rhs` the message name token, 0 for `IGNORE`.
        raise,
        /// `name([DISTINCT | ALL] args [ORDER BY items]) [filter_over]`. `main_token` is the
        /// name. `lhs` is the `extra_data` index of the quantifier (`call_distinct` or
        /// `call_all`, else 0), the argument count, the arguments, the item count and the
        /// `order_item` nodes. `rhs` is the `filter_over` node or 0.
        call,
        /// `name(*) [filter_over]`. `main_token` is the name; `rhs` is as for `call`.
        call_star,
        /// `(select)` as an expression; `lhs` is the query node. `main_token` is the `(`.
        subquery,
        /// `EXISTS (select)`; `lhs` is the query node. `main_token` is `EXISTS`.
        exists,
        /// `lhs [NOT] IN (select)`. `main_token` is `IN`, negated as for `like`. `rhs` is the
        /// query node.
        in_select,
        /// `expr [ASC | DESC] [NULLS FIRST | LAST]` in an `ORDER BY`. `lhs` is the
        /// expression. `rhs` is the `SortFlags` as an integer.
        order_item,
        /// `INSERT [OR conflict] INTO ..` or `REPLACE INTO ..`. `main_token` is `INSERT` or
        /// `REPLACE`. `lhs` is the `extra_data` index of a `Node.Insert`. `rhs` is the query
        /// node (`select`, `compound`, `values` or `with_clause`), or 0 for `DEFAULT VALUES`.
        insert,
        /// One `ON CONFLICT [(target) [WHERE ..]] DO NOTHING | DO UPDATE SET ..` clause.
        /// `main_token` is `ON`. `lhs` is the `extra_data` index of a `Node.Upsert`, whose
        /// target is a range of `order_item` nodes and the settings a range of `set_item`
        /// nodes. `rhs` is the next clause, or 0.
        upsert,
        /// `name = rhs` or `(names) = rhs` in a `SET` list. `main_token` is the first name,
        /// or the left parenthesis for the second form. `lhs` is the `extra_data` index of
        /// the name count and the name tokens.
        set_item,
    };
};

/// A syntax error. `token` is the token SQLite blames.
pub const Error = struct {
    tag: Tag,
    token: TokenIndex,

    /// One tag per message SQLite produces. The ones after `depth_exceeded` are raised by
    /// grammar actions in SQLite (docs/research.md, section 3, item 8).
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
        /// Blamed on the first token of the join operator.
        unknown_join_type,
        /// Blamed on the compound operator that follows the term with an `ORDER BY`.
        order_by_after_union,
        /// Like `order_by_after_union`, for a `LIMIT`.
        limit_after_union,
        /// Blamed on the `ON` or `USING` of a `FROM` item that has no join before it.
        join_clause_required,
        /// Blamed on the token after a `COLLATE`, `ASC` or `DESC` in a CTE column list;
        /// the message names the column.
        syntax_error_after_column_name,
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
        .source = source,
        .token_tags = tokens.items(.tag),
        .token_locs = tokens.items(.loc),
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
        .unknown_join_type => {
            const tags = self.tokens.items(.tag);
            try writer.writeAll("unknown join type:");
            var i: u32 = @backingInt(err.token);
            while (tags[i] != .keyword_join) : (i += 1) {
                try writer.print(" {s}", .{self.tokenText(@fromBackingInt(i))});
            }
        },
        .order_by_after_union, .limit_after_union => {
            try writer.writeAll(if (err.tag == .order_by_after_union) "ORDER BY" else "LIMIT");
            try writer.writeAll(" clause should come after ");
            try writeUpper(text, writer);
            if (self.tokens.items(.tag)[@backingInt(err.token) + 1] == .keyword_all) try writer.writeAll(" ALL");
            try writer.writeAll(" not before");
        },
        .join_clause_required => {
            try writer.writeAll("a JOIN clause is required before ");
            try writeUpper(text, writer);
        },
        .syntax_error_after_column_name => {
            const tags = self.tokens.items(.tag);
            var column: u32 = @backingInt(err.token);
            while (tags[column - 1] != .comma and tags[column - 1] != .l_paren) column -= 1;
            try writer.print("syntax error after column name \"{s}\"", .{self.tokenText(@fromBackingInt(column))});
        },
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
        .pragma => {
            const pragma = self.extra_data[n.data.rhs..][0..4];
            try writer.writeAll("PRAGMA ");
            try self.renderName(n.data.lhs, writer);
            if (pragma[0] != 0) {
                try writer.writeByte('.');
                try self.renderName(pragma[0], writer);
            }
            if (pragma[1] == 0) return;
            const tags = self.tokens.items(.tag);
            try writer.writeAll(if (tags[pragma[1]] == .l_paren) "(" else " = ");
            if (pragma[2] != 0) try writer.writeAll(self.tokenText(@fromBackingInt(pragma[2])));
            switch (tags[pragma[3]]) {
                .integer_literal, .float_literal => try writer.writeAll(self.tokenText(@fromBackingInt(pragma[3]))),
                .keyword_on, .keyword_delete, .keyword_default => try writeUpper(self.tokenText(@fromBackingInt(pragma[3])), writer),
                else => try self.renderName(pragma[3], writer),
            }
            if (tags[pragma[1]] == .l_paren) try writer.writeByte(')');
        },
        .attach => {
            const name, const key = self.extra_data[n.data.rhs..][0..2].*;
            try writer.writeAll("ATTACH DATABASE ");
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeAll(" AS ");
            try self.renderExpr(@fromBackingInt(@intCast(name)), writer);
            if (key != 0) {
                try writer.writeAll(" KEY ");
                try self.renderExpr(@fromBackingInt(@intCast(key)), writer);
            }
        },
        .detach => {
            try writer.writeAll("DETACH DATABASE ");
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
        },
        .vacuum => {
            try writer.writeAll("VACUUM");
            if (n.data.lhs != 0) {
                try writer.writeByte(' ');
                try self.renderName(n.data.lhs, writer);
            }
            if (n.data.rhs != 0) {
                try writer.writeAll(" INTO ");
                try self.renderExpr(@fromBackingInt(@intCast(n.data.rhs)), writer);
            }
        },
        .reindex, .analyze => {
            try writer.writeAll(if (n.tag == .reindex) "REINDEX" else "ANALYZE");
            if (n.data.lhs != 0) {
                try writer.writeByte(' ');
                try self.renderName(n.data.lhs, writer);
            }
            if (n.data.rhs != 0) {
                try writer.writeByte('.');
                try self.renderName(n.data.rhs, writer);
            }
        },
        .select => try self.renderSelect(n, writer),
        .with_clause => {
            const ctes = self.extra_data[n.data.lhs + 2 ..][0..self.extra_data[n.data.lhs + 1]];
            try writer.writeAll(if (self.extra_data[n.data.lhs] != 0) "WITH RECURSIVE " else "WITH ");
            for (ctes, 0..) |cte, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.renderCte(@fromBackingInt(@intCast(cte)), writer);
            }
            try writer.writeByte(' ');
            try self.renderStatement(@fromBackingInt(@intCast(n.data.rhs)), writer);
        },
        .insert => try self.renderInsert(n, writer),
        .compound => {
            try self.renderStatement(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeByte(' ');
            try writeUpper(self.tokenText(n.main_token), writer);
            if (self.tokens.items(.tag)[@backingInt(n.main_token) + 1] == .keyword_all) try writer.writeAll(" ALL");
            try writer.writeByte(' ');
            try self.renderStatement(@fromBackingInt(@intCast(n.data.rhs)), writer);
        },
        .values => {
            try writer.writeAll("VALUES ");
            try self.renderExprRange(n.data.lhs, n.data.rhs, writer);
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
        .is_distinct,
        .is_not_distinct,
        .collate,
        .is_null,
        .not_null,
        .like,
        .between,
        .in_list,
        .in_table,
        .in_func,
        .cast,
        .case,
        .raise,
        .call,
        .call_star,
        .order_item,
        .table_ref,
        .table_func,
        .subquery_table,
        .join,
        .subquery,
        .exists,
        .in_select,
        .cte,
        .window_def,
        .window_ref,
        .filter_over,
        .upsert,
        .set_item,
        => unreachable,
    }
}

fn renderInsert(self: Ast, n: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const record: *const Node.Insert = @ptrCast(self.extra_data[n.data.lhs..][0 .. @sizeOf(Node.Insert) / 4]);
    if (self.tokens.items(.tag)[@backingInt(n.main_token)] == .keyword_replace) {
        try writer.writeAll("REPLACE");
    } else {
        try writer.writeAll("INSERT");
        if (record.conflict != 0) {
            try writer.writeAll(" OR");
            try self.renderKeyword(record.conflict, writer);
        }
    }
    try writer.writeAll(" INTO ");
    if (record.schema != 0) {
        try self.renderName(record.schema, writer);
        try writer.writeByte('.');
    }
    try self.renderName(record.table, writer);
    try self.renderAlias(record.alias, writer);
    for (self.extra_data[record.columns_start..record.columns_end], 0..) |column, i| {
        try writer.writeAll(if (i == 0) " (" else ", ");
        try self.renderName(column, writer);
    }
    if (record.columns_start != record.columns_end) try writer.writeByte(')');
    if (n.data.rhs == 0) {
        try writer.writeAll(" DEFAULT VALUES");
    } else {
        try writer.writeByte(' ');
        try self.renderStatement(@fromBackingInt(@intCast(n.data.rhs)), writer);
    }
    var clause = record.upsert;
    while (clause != 0) {
        const upsert = self.nodes.get(clause);
        try self.renderUpsert(upsert, writer);
        clause = upsert.data.rhs;
    }
    for (self.extra_data[record.returning_start..record.returning_end], 0..) |column, i| {
        try writer.writeAll(if (i == 0) " RETURNING " else ", ");
        try self.renderResultColumn(@fromBackingInt(@intCast(column)), writer);
    }
}

fn renderUpsert(self: Ast, n: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const u: *const Node.Upsert = @ptrCast(self.extra_data[n.data.lhs..][0 .. @sizeOf(Node.Upsert) / 4]);
    try writer.writeAll(" ON CONFLICT");
    if (u.target_start != u.target_end) {
        try writer.writeAll(" (");
        try self.renderExprRange(u.target_start, u.target_end, writer);
        try writer.writeByte(')');
        try self.renderClause(" WHERE ", u.target_where, writer);
    }
    if (u.set_start == u.set_end) return writer.writeAll(" DO NOTHING");
    for (self.extra_data[u.set_start..u.set_end], 0..) |item, i| {
        try writer.writeAll(if (i == 0) " DO UPDATE SET " else ", ");
        const set = self.nodes.get(item);
        const names = self.extra_data[set.data.lhs + 1 ..][0..self.extra_data[set.data.lhs]];
        const parenthesized = self.tokens.items(.tag)[@backingInt(set.main_token)] == .l_paren;
        if (parenthesized) try writer.writeByte('(');
        for (names, 0..) |name, j| {
            if (j > 0) try writer.writeAll(", ");
            try self.renderName(name, writer);
        }
        if (parenthesized) try writer.writeByte(')');
        try writer.writeAll(" = ");
        try self.renderExpr(@fromBackingInt(@intCast(set.data.rhs)), writer);
    }
    try self.renderClause(" WHERE ", u.set_where, writer);
}

fn renderCte(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    const materialized: Node.Materialized = @fromBackingInt(@intCast(self.extra_data[n.data.rhs]));
    const columns = self.extra_data[n.data.rhs + 2 ..][0..self.extra_data[n.data.rhs + 1]];
    try self.renderName(@backingInt(n.main_token), writer);
    if (columns.len > 0) {
        try writer.writeByte('(');
        for (columns, 0..) |column, i| {
            if (i > 0) try writer.writeAll(", ");
            try self.renderName(column, writer);
        }
        try writer.writeByte(')');
    }
    try writer.writeAll(switch (materialized) {
        .any => " AS (",
        .yes => " AS MATERIALIZED (",
        .no => " AS NOT MATERIALIZED (",
    });
    try self.renderStatement(@fromBackingInt(@intCast(n.data.lhs)), writer);
    try writer.writeByte(')');
}

fn renderWindowDef(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    const w: *const Node.Window = @ptrCast(self.extra_data[n.data.lhs..][0 .. @sizeOf(Node.Window) / 4]);
    var separator: []const u8 = "";
    try writer.writeByte('(');
    if (w.base != 0) {
        try self.renderName(w.base, writer);
        separator = " ";
    }
    if (w.partition_start != w.partition_end) {
        try writer.print("{s}PARTITION BY ", .{separator});
        try self.renderExprRange(w.partition_start, w.partition_end, writer);
        separator = " ";
    }
    if (w.order_start != w.order_end) {
        try writer.print("{s}ORDER BY ", .{separator});
        try self.renderExprRange(w.order_start, w.order_end, writer);
        separator = " ";
    }
    if (w.frame_unit != 0) {
        try writer.writeAll(separator);
        try writeUpper(self.tokenText(@fromBackingInt(w.frame_unit)), writer);
        if (w.end == .none) {
            try writer.writeByte(' ');
            try self.renderFrameBound(w.start, w.start_expr, writer);
        } else {
            try writer.writeAll(" BETWEEN ");
            try self.renderFrameBound(w.start, w.start_expr, writer);
            try writer.writeAll(" AND ");
            try self.renderFrameBound(w.end, w.end_expr, writer);
        }
        try writer.writeAll(switch (w.exclude) {
            .none => "",
            .no_others => " EXCLUDE NO OTHERS",
            .current_row => " EXCLUDE CURRENT ROW",
            .group => " EXCLUDE GROUP",
            .ties => " EXCLUDE TIES",
        });
    }
    try writer.writeByte(')');
}

fn renderFrameBound(self: Ast, bound: Node.FrameBound, expr: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (bound) {
        .none => unreachable,
        .unbounded_preceding => try writer.writeAll("UNBOUNDED PRECEDING"),
        .unbounded_following => try writer.writeAll("UNBOUNDED FOLLOWING"),
        .current_row => try writer.writeAll("CURRENT ROW"),
        .preceding, .following => {
            try self.renderExpr(@fromBackingInt(@intCast(expr)), writer);
            try writer.writeAll(if (bound == .preceding) " PRECEDING" else " FOLLOWING");
        },
    }
}

fn renderFilterOver(self: Ast, node: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (node == 0) return;
    const n = self.nodes.get(node);
    if (n.data.lhs != 0) {
        try writer.writeAll(" FILTER (WHERE ");
        try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
        try writer.writeByte(')');
    }
    if (n.data.rhs == 0) return;
    try writer.writeAll(" OVER ");
    if (self.nodes.items(.tag)[n.data.rhs] == .window_ref) {
        try self.renderName(@backingInt(self.nodes.items(.main_token)[n.data.rhs]), writer);
    } else {
        try self.renderWindowDef(@fromBackingInt(@intCast(n.data.rhs)), writer);
    }
}

fn renderSelect(self: Ast, n: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const s: *const Node.Select = @ptrCast(self.extra_data[n.data.lhs..][0 .. @sizeOf(Node.Select) / 4]);
    try writer.writeAll(if (s.distinct != 0) "SELECT DISTINCT " else "SELECT ");
    for (self.extra_data[s.columns_start..s.columns_end], 0..) |column, i| {
        if (i > 0) try writer.writeAll(", ");
        try self.renderResultColumn(@fromBackingInt(@intCast(column)), writer);
    }
    if (s.from != 0) {
        try writer.writeAll(" FROM ");
        try self.renderFrom(@fromBackingInt(@intCast(s.from)), writer);
    }
    try self.renderClause(" WHERE ", s.where, writer);
    if (s.group_start != s.group_end) {
        try writer.writeAll(" GROUP BY ");
        try self.renderExprRange(s.group_start, s.group_end, writer);
    }
    try self.renderClause(" HAVING ", s.having, writer);
    for (self.extra_data[s.window_start..s.window_end], 0..) |window, i| {
        try writer.writeAll(if (i == 0) " WINDOW " else ", ");
        const node: Node.Index = @fromBackingInt(@intCast(window));
        try self.renderName(@backingInt(self.nodes.items(.main_token)[@backingInt(node)]), writer);
        try writer.writeAll(" AS ");
        try self.renderWindowDef(node, writer);
    }
    if (s.order_start != s.order_end) {
        try writer.writeAll(" ORDER BY ");
        try self.renderExprRange(s.order_start, s.order_end, writer);
    }
    try self.renderClause(" LIMIT ", s.limit, writer);
    try self.renderClause(" OFFSET ", s.offset, writer);
}

fn renderClause(self: Ast, keyword: []const u8, expr: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (expr == 0) return;
    try writer.writeAll(keyword);
    try self.renderExpr(@fromBackingInt(@intCast(expr)), writer);
}

/// Writes the expression nodes in `extra_data[start..end]`, separated by commas.
fn renderExprRange(self: Ast, start: u32, end: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (self.extra_data[start..end], 0..) |item, i| {
        if (i > 0) try writer.writeAll(", ");
        try self.renderExpr(@fromBackingInt(@intCast(item)), writer);
    }
}

/// Writes a `FROM` item or a join of them.
fn renderFrom(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    const tags = self.tokens.items(.tag);
    switch (n.tag) {
        .table_ref, .table_func => {
            const second, const alias = self.extra_data[n.data.lhs..][0..2].*;
            try self.renderName(@backingInt(n.main_token), writer);
            if (second != 0) {
                try writer.writeByte('.');
                try self.renderName(second, writer);
            }
            if (n.tag == .table_func) {
                try self.renderExprList(self.extra_data[n.data.lhs + 2 ..], writer);
            }
            try self.renderAlias(alias, writer);
            if (n.tag == .table_ref) {
                const indexed = self.extra_data[n.data.lhs + 2];
                if (indexed == 0) return;
                try writer.writeAll(if (tags[indexed] == .keyword_not) " NOT INDEXED" else " INDEXED BY ");
                if (tags[indexed] == .keyword_indexed) try self.renderName(indexed + 2, writer);
            }
        },
        .subquery_table => {
            const inner: Node.Index = @fromBackingInt(@intCast(n.data.lhs));
            try writer.writeByte('(');
            switch (self.nodes.items(.tag)[@backingInt(inner)]) {
                .select, .compound, .values, .with_clause => try self.renderStatement(inner, writer),
                else => try self.renderFrom(inner, writer),
            }
            try writer.writeByte(')');
            try self.renderAlias(n.data.rhs, writer);
        },
        .join => {
            const item, const constraint = self.extra_data[n.data.rhs..][0..2].*;
            try self.renderFrom(@fromBackingInt(@intCast(n.data.lhs)), writer);
            if (tags[@backingInt(n.main_token)] == .comma) {
                try writer.writeAll(", ");
            } else {
                var i: u32 = @backingInt(n.main_token);
                while (true) : (i += 1) {
                    try writer.writeByte(' ');
                    try writeUpper(self.tokenText(@fromBackingInt(i)), writer);
                    if (tags[i] == .keyword_join) break;
                }
                try writer.writeByte(' ');
            }
            try self.renderFrom(@fromBackingInt(@intCast(item)), writer);
            if (constraint == 0) return;
            const payload = self.extra_data[n.data.rhs + 2 ..];
            if (tags[constraint] == .keyword_on) {
                try writer.writeAll(" ON ");
                try self.renderExpr(@fromBackingInt(@intCast(payload[0])), writer);
            } else {
                try writer.writeAll(" USING (");
                for (payload[1..][0..payload[0]], 0..) |name, j| {
                    if (j > 0) try writer.writeAll(", ");
                    try self.renderName(name, writer);
                }
                try writer.writeByte(')');
            }
        },
        else => unreachable,
    }
}

fn renderAlias(self: Ast, alias: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (alias == 0) return;
    try writer.writeAll(" AS ");
    try self.renderName(alias, writer);
}

fn renderResultColumn(self: Ast, node: Node.Index, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = self.nodes.get(@backingInt(node));
    if (n.tag == .result_star) {
        if (n.data.lhs != 0) {
            try self.renderName(n.data.lhs, writer);
            try writer.writeByte('.');
        }
        return writer.writeByte('*');
    }
    try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
    try self.renderAlias(n.data.rhs, writer);
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
        .name => {
            const text = self.tokenText(n.main_token);
            // A lone "x" falls back to the string 'x' when no column has that name,
            // which a bare x does not.
            if (n.data.lhs == 1 and text[0] == '"') return renderQuoted(text, '"', writer);
            for (0..n.data.lhs) |i| {
                if (i > 0) try writer.writeByte('.');
                try self.renderName(main_token + 2 * @as(u32, @intCast(i)), writer);
            }
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
        .binary, .is_not, .is_distinct, .is_not_distinct => {
            try writer.writeByte('(');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeByte(' ');
            try writeUpper(self.tokens.items(.tag)[main_token].symbol(), writer);
            try writer.writeAll(switch (n.tag) {
                .is_not => " NOT",
                .is_distinct => " DISTINCT FROM",
                .is_not_distinct => " NOT DISTINCT FROM",
                else => "",
            });
            try writer.writeByte(' ');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.rhs)), writer);
            try writer.writeByte(')');
        },
        .collate => {
            try writer.writeByte('(');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeAll(" COLLATE ");
            try self.renderName(n.data.rhs, writer);
            try writer.writeByte(')');
        },
        .is_null, .not_null => {
            try writer.writeByte('(');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeAll(if (n.tag == .is_null) " ISNULL)" else " NOTNULL)");
        },
        .subquery, .exists => {
            if (n.tag == .exists) try writer.writeAll("EXISTS ");
            try self.renderSubquery(n.data.lhs, writer);
        },
        .like, .between, .in_list, .in_table, .in_func, .in_select => {
            try writer.writeByte('(');
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeByte(' ');
            if (self.tokens.items(.tag)[main_token - 1] == .keyword_not) try writer.writeAll("NOT ");
            try writeUpper(self.tokenText(n.main_token), writer);
            try writer.writeByte(' ');
            if (n.tag == .in_select) try self.renderSubquery(n.data.rhs, writer) else try self.renderOperands(n, writer);
            try writer.writeByte(')');
        },
        .cast => {
            const type_tokens = self.extra_data[n.data.rhs..][0..2];
            try writer.writeAll("CAST(");
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeAll(" AS");
            try self.renderType(type_tokens[0], type_tokens[1], writer);
            try writer.writeByte(')');
        },
        .case => {
            const clauses = self.extra_data[n.data.rhs..];
            try writer.writeAll("CASE");
            if (n.data.lhs != 0) {
                try writer.writeByte(' ');
                try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            }
            for (0..clauses[1]) |i| {
                try writer.writeAll(" WHEN ");
                try self.renderExpr(@fromBackingInt(@intCast(clauses[2 + 2 * i])), writer);
                try writer.writeAll(" THEN ");
                try self.renderExpr(@fromBackingInt(@intCast(clauses[3 + 2 * i])), writer);
            }
            if (clauses[0] != 0) {
                try writer.writeAll(" ELSE ");
                try self.renderExpr(@fromBackingInt(@intCast(clauses[0])), writer);
            }
            try writer.writeAll(" END");
        },
        .raise => {
            try writer.writeAll("RAISE(");
            try writeUpper(self.tokenText(@fromBackingInt(n.data.lhs)), writer);
            if (n.data.rhs != 0) {
                try writer.writeAll(", ");
                try self.renderName(n.data.rhs, writer);
            }
            try writer.writeByte(')');
        },
        .call_star => {
            try self.renderName(main_token, writer);
            try writer.writeAll("(*)");
            try self.renderFilterOver(n.data.rhs, writer);
        },
        .call => {
            const parts = self.extra_data[n.data.lhs..];
            const args = parts[2..][0..parts[1]];
            const order = parts[2 + args.len ..];
            try self.renderName(main_token, writer);
            try writer.writeByte('(');
            switch (parts[0]) {
                Node.call_distinct => try writer.writeAll("DISTINCT "),
                Node.call_all => try writer.writeAll("ALL "),
                else => {},
            }
            for (args, 0..) |arg, i| {
                if (i > 0) try writer.writeAll(", ");
                try self.renderExpr(@fromBackingInt(@intCast(arg)), writer);
            }
            for (order[1..][0..order[0]], 0..) |item, i| {
                try writer.writeAll(if (i == 0) " ORDER BY " else ", ");
                try self.renderExpr(@fromBackingInt(@intCast(item)), writer);
            }
            try writer.writeByte(')');
            try self.renderFilterOver(n.data.rhs, writer);
        },
        .order_item => {
            const flags: Node.SortFlags = @bitCast(n.data.rhs);
            try self.renderExpr(@fromBackingInt(@intCast(n.data.lhs)), writer);
            try writer.writeAll(switch (flags.direction) {
                .default => "",
                .asc => " ASC",
                .desc => " DESC",
            });
            try writer.writeAll(switch (flags.nulls) {
                .default => "",
                .first => " NULLS FIRST",
                .last => " NULLS LAST",
            });
        },
        else => unreachable,
    }
}

/// Writes the type of a `cast` node: each name after a space, then the optional
/// parenthesized sizes. The tokens run from `first` up to, not including, `end`.
fn renderType(self: Ast, first: u32, end: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const tags = self.tokens.items(.tag);
    for (first..end) |i| {
        const token: TokenIndex = @fromBackingInt(@intCast(i));
        switch (tags[i]) {
            .l_paren, .r_paren, .plus, .minus, .integer_literal, .float_literal => try writer.writeAll(self.tokenText(token)),
            .comma => try writer.writeAll(", "),
            else => {
                try writer.writeByte(' ');
                try self.renderName(@intCast(i), writer);
            },
        }
    }
}

/// Writes what follows the operator keyword of a `like`, `between`, `in_list`,
/// `in_table` or `in_func` node.
fn renderOperands(self: Ast, n: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const operands = self.extra_data[n.data.rhs..];
    switch (n.tag) {
        .like => {
            try self.renderExpr(@fromBackingInt(@intCast(operands[0])), writer);
            if (operands[1] == 0) return;
            try writer.writeAll(" ESCAPE ");
            try self.renderExpr(@fromBackingInt(@intCast(operands[1])), writer);
        },
        .between => {
            try self.renderExpr(@fromBackingInt(@intCast(operands[0])), writer);
            try writer.writeAll(" AND ");
            try self.renderExpr(@fromBackingInt(@intCast(operands[1])), writer);
        },
        .in_list => try self.renderExprList(operands, writer),
        .in_table, .in_func => {
            try self.renderName(operands[0], writer);
            if (operands[1] != 0) {
                try writer.writeByte('.');
                try self.renderName(operands[1], writer);
            }
            if (n.tag == .in_func) try self.renderExprList(operands[2..], writer);
        },
        else => unreachable,
    }
}

fn renderSubquery(self: Ast, query: u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('(');
    try self.renderStatement(@fromBackingInt(@intCast(query)), writer);
    try writer.writeByte(')');
}

/// Writes `(a, b, ...)` for a count followed by that many expression nodes.
fn renderExprList(self: Ast, counted: []const u32, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeByte('(');
    for (counted[1..][0..counted[0]], 0..) |item, i| {
        if (i > 0) try writer.writeAll(", ");
        try self.renderExpr(@fromBackingInt(@intCast(item)), writer);
    }
    try writer.writeByte(')');
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
    try renderQuoted(text, quote, writer);
}

fn renderQuoted(text: []const u8, quote: u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const inner = if (quote == 0) text else text[1 .. text.len - 1];
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
    var ast = try parse(gpa, "FOO JOIN");
    defer ast.deinit(gpa);
    const cases = [_]struct { Error.Tag, []const u8 }{
        .{ .syntax_error, "near \"FOO\": syntax error" },
        .{ .incomplete_input, "incomplete input" },
        .{ .unrecognized_token, "unrecognized token: \"FOO\"" },
        .{ .depth_exceeded, "Expression tree is too large (maximum depth 1000)" },
        .{ .unknown_table_option, "unknown table option: FOO" },
        .{ .unknown_join_type, "unknown join type: FOO" },
        .{ .order_by_after_union, "ORDER BY clause should come after FOO not before" },
        .{ .limit_after_union, "LIMIT clause should come after FOO not before" },
        .{ .join_clause_required, "a JOIN clause is required before FOO" },
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

test "COLLATE, ISNULL and NOTNULL" {
    try expectRender("SELECT a COLLATE x, a collate 'y z', a COLLATE x COLLATE nocase", "SELECT (a COLLATE x), (a COLLATE \"y z\"), ((a COLLATE x) COLLATE nocase);\n");
    try expectRender("SELECT a ISNULL, a NOTNULL, a NOT NULL, a ISNULL ISNULL", "SELECT (a ISNULL), (a NOTNULL), (a NOTNULL), ((a ISNULL) ISNULL);\n");
}

test "LIKE family" {
    try expectRender(
        "SELECT a LIKE b, a glob b, a REGEXP b, a MATCH b, a NOT LIKE b, a not glob b, a NOT REGEXP b, a NOT MATCH b",
        "SELECT (a LIKE b), (a GLOB b), (a REGEXP b), (a MATCH b), (a NOT LIKE b), (a NOT GLOB b), (a NOT REGEXP b), (a NOT MATCH b);\n",
    );
    try expectRender("SELECT a LIKE b ESCAPE c, a NOT LIKE b ESCAPE c", "SELECT (a LIKE b ESCAPE c), (a NOT LIKE b ESCAPE c);\n");
}

test "IS forms" {
    try expectRender(
        "SELECT a IS b, a IS NOT b, a IS DISTINCT FROM b, a IS NOT DISTINCT FROM b, a is null, a is not null",
        "SELECT (a IS b), (a IS NOT b), (a IS DISTINCT FROM b), (a IS NOT DISTINCT FROM b), (a IS NULL), (a IS NOT NULL);\n",
    );
}

test "BETWEEN" {
    try expectRender("SELECT a BETWEEN b AND c, a NOT BETWEEN b AND c", "SELECT (a BETWEEN b AND c), (a NOT BETWEEN b AND c);\n");
}

test "IN" {
    try expectRender(
        "SELECT a IN (b, c), a NOT IN (b), a IN (), a NOT IN (), (a, b) IN ((1, 2), (3, 4))",
        "SELECT (a IN (b, c)), (a NOT IN (b)), (a IN ()), (a NOT IN ()), ((a, b) IN ((1, 2), (3, 4)));\n",
    );
    try expectRender(
        "SELECT a IN t, a NOT IN s.t, a IN f(), a IN f(1, 2), a NOT IN s.f(b), a IN 'q'.left, a IN left",
        "SELECT (a IN t), (a NOT IN s.t), (a IN f()), (a IN f(1, 2)), (a NOT IN s.f(b)), (a IN q.\"left\"), (a IN \"left\");\n",
    );
}

test "precedence of the special operators" {
    try expectRender("SELECT a = b ISNULL", "SELECT ((a = b) ISNULL);\n");
    try expectRender("SELECT a + b ISNULL", "SELECT ((a + b) ISNULL);\n");
    try expectRender("SELECT a AND b ISNULL", "SELECT (a AND (b ISNULL));\n");
    try expectRender("SELECT a NOT NULL = b", "SELECT ((a NOTNULL) = b);\n");
    try expectRender("SELECT NOT a NOT NULL", "SELECT (NOT (a NOTNULL));\n");
    try expectRender("SELECT a IS b = c", "SELECT ((a IS b) = c);\n");
    try expectRender("SELECT a = b IS c", "SELECT ((a = b) IS c);\n");
    try expectRender("SELECT a IS NOT b = c", "SELECT ((a IS NOT b) = c);\n");
    try expectRender("SELECT a IS NOT DISTINCT FROM b = c", "SELECT ((a IS NOT DISTINCT FROM b) = c);\n");
    try expectRender("SELECT a IS b < c", "SELECT (a IS (b < c));\n");
    try expectRender("SELECT a < b IS c", "SELECT ((a < b) IS c);\n");
    try expectRender("SELECT a LIKE b = c", "SELECT ((a LIKE b) = c);\n");
    try expectRender("SELECT a = b LIKE c", "SELECT ((a = b) LIKE c);\n");
    try expectRender("SELECT a LIKE b LIKE c", "SELECT ((a LIKE b) LIKE c);\n");
    try expectRender("SELECT a LIKE b < c", "SELECT (a LIKE (b < c));\n");
    try expectRender("SELECT a LIKE b ESCAPE c || d", "SELECT (a LIKE b ESCAPE (c || d));\n");
    try expectRender("SELECT a LIKE b ESCAPE c = d", "SELECT ((a LIKE b ESCAPE c) = d);\n");
    try expectRender("SELECT a LIKE b + c ESCAPE d", "SELECT (a LIKE (b + c) ESCAPE d);\n");
    try expectRender("SELECT a AND b LIKE c", "SELECT (a AND (b LIKE c));\n");
    try expectRender("SELECT a COLLATE x + 1", "SELECT ((a COLLATE x) + 1);\n");
    try expectRender("SELECT 1 + a COLLATE x", "SELECT (1 + (a COLLATE x));\n");
    try expectRender("SELECT a || b COLLATE x", "SELECT (a || (b COLLATE x));\n");
    try expectRender("SELECT - a COLLATE x", "SELECT ((-a) COLLATE x);\n");
    try expectRender("SELECT ~ a COLLATE x", "SELECT ((~a) COLLATE x);\n");
    try expectRender("SELECT a NOT IN b", "SELECT (a NOT IN b);\n");
    try expectRender("SELECT a IN (b) = c", "SELECT ((a IN (b)) = c);\n");
    try expectRender("SELECT a = b IN (c)", "SELECT ((a = b) IN (c));\n");
    try expectRender("SELECT a IN (b) IN (c)", "SELECT ((a IN (b)) IN (c));\n");
    try expectRender("SELECT a OR b IN (c)", "SELECT (a OR (b IN (c)));\n");
    try expectRender("SELECT a + b IN (c)", "SELECT ((a + b) IN (c));\n");
}

test "BETWEEN takes the first AND" {
    try expectRender("SELECT a BETWEEN b AND c AND d", "SELECT ((a BETWEEN b AND c) AND d);\n");
    try expectRender("SELECT a BETWEEN b + 1 AND c OR d", "SELECT ((a BETWEEN (b + 1) AND c) OR d);\n");
    try expectRender("SELECT a BETWEEN b AND c + 1", "SELECT (a BETWEEN b AND (c + 1));\n");
    try expectRender("SELECT a BETWEEN b AND c = d", "SELECT ((a BETWEEN b AND c) = d);\n");
    try expectRender("SELECT a = b BETWEEN c AND d", "SELECT ((a = b) BETWEEN c AND d);\n");
    try expectRender("SELECT a BETWEEN b = c AND d", "SELECT (a BETWEEN (b = c) AND d);\n");
    try expectRender("SELECT a BETWEEN NOT b AND c", "SELECT (a BETWEEN (NOT b) AND c);\n");
    try expectRender("SELECT a AND b BETWEEN c AND d", "SELECT (a AND (b BETWEEN c AND d));\n");
    try expectRender("SELECT NOT a BETWEEN b AND c", "SELECT (NOT (a BETWEEN b AND c));\n");
    try expectRender("SELECT a BETWEEN b BETWEEN c AND d AND e", "SELECT (a BETWEEN (b BETWEEN c AND d) AND e);\n");
}

test "special operator syntax errors" {
    try expectError("SELECT 1 NOT 2", "near \"2\": syntax error", .{ .byte_offset = 13, .line = 1, .column = 14 });
    try expectError("SELECT 1 NOT", "incomplete input", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT 1 BETWEEN 2", "incomplete input", .{ .byte_offset = 18, .line = 1, .column = 19 });
    try expectError("SELECT 1 BETWEEN 2 OR 3", "incomplete input", .{ .byte_offset = 23, .line = 1, .column = 24 });
    try expectError("SELECT 1 IN (", "incomplete input", .{ .byte_offset = 13, .line = 1, .column = 14 });
    try expectError("SELECT 1 IN (1,)", "near \")\": syntax error", .{ .byte_offset = 15, .line = 1, .column = 16 });
    try expectError("SELECT 1 IN 2", "near \"2\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT 1 IN a.b.c", "near \".\": syntax error", .{ .byte_offset = 15, .line = 1, .column = 16 });
    try expectError("SELECT 1 IS DISTINCT 2", "near \"2\": syntax error", .{ .byte_offset = 21, .line = 1, .column = 22 });
    try expectError("SELECT 1 IS NOT DISTINCT 2", "near \"2\": syntax error", .{ .byte_offset = 25, .line = 1, .column = 26 });
    try expectError("SELECT 1 IS DISTINCT FROM", "incomplete input", .{ .byte_offset = 25, .line = 1, .column = 26 });
    try expectError("SELECT 1 COLLATE x.y", "near \".\": syntax error", .{ .byte_offset = 18, .line = 1, .column = 19 });
    try expectError("SELECT 1 COLLATE", "incomplete input", .{ .byte_offset = 16, .line = 1, .column = 17 });
    try expectError("SELECT 1 NOT NULL NOT NOT", "near \"NOT\": syntax error", .{ .byte_offset = 22, .line = 1, .column = 23 });
    try expectError("SELECT 1 LIKE 2 ESCAPE 3 ESCAPE 4", "near \"ESCAPE\": syntax error", .{ .byte_offset = 25, .line = 1, .column = 26 });
    try expectError("SELECT 1 = 2 ESCAPE 3", "near \"ESCAPE\": syntax error", .{ .byte_offset = 13, .line = 1, .column = 14 });
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
    try expectError("SELECT a.", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT a.b.c.d", "near \".\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT 1,", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT 1 AS", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("SELECT * x", "near \"x\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("SELECT select", "near \"select\": syntax error", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("SELECT 1 + \x01", "unrecognized token: \"\x01\"", .{ .byte_offset = 11, .line = 1, .column = 12 });
}

test "CAST" {
    try expectRender("SELECT CAST(x AS INT)", "SELECT CAST(x AS INT);\n");
    try expectRender("select cast(1+2 as DECIMAL(10, 2))", "SELECT CAST((1 + 2) AS DECIMAL(10, 2));\n");
    try expectRender("SELECT CAST(x AS UNSIGNED BIG INT)", "SELECT CAST(x AS UNSIGNED BIG INT);\n");
    try expectRender("SELECT CAST(x AS VARCHAR(10))", "SELECT CAST(x AS VARCHAR(10));\n");
    try expectRender("SELECT CAST(x AS DECIMAL(10, -2))", "SELECT CAST(x AS DECIMAL(10, -2));\n");
    try expectRender("SELECT CAST(x AS T(+1.5, 2))", "SELECT CAST(x AS T(+1.5, 2));\n");
    try expectRender("SELECT CAST(x AS 'my type' int)", "SELECT CAST(x AS \"my type\" int);\n");
    try expectRender("SELECT CAST(x AS)", "SELECT CAST(x AS);\n");
    try expectRender("SELECT CAST(a + b AS INT) * 2", "SELECT (CAST((a + b) AS INT) * 2);\n");
}

test "CASE" {
    try expectRender("SELECT CASE WHEN a THEN b END", "SELECT CASE WHEN a THEN b END;\n");
    try expectRender("SELECT CASE x WHEN 1 THEN 2 WHEN 3 THEN 4 ELSE 5 END", "SELECT CASE x WHEN 1 THEN 2 WHEN 3 THEN 4 ELSE 5 END;\n");
    try expectRender("SELECT CASE WHEN a OR b THEN c + 1 ELSE d AND e END", "SELECT CASE WHEN (a OR b) THEN (c + 1) ELSE (d AND e) END;\n");
    try expectRender("SELECT CASE end WHEN 1 THEN 2 END", "SELECT CASE \"end\" WHEN 1 THEN 2 END;\n");
}

test "RAISE" {
    try expectRender("SELECT RAISE(IGNORE)", "SELECT RAISE(IGNORE);\n");
    try expectRender("SELECT raise(abort, 'no way')", "SELECT RAISE(ABORT, \"no way\");\n");
    try expectRender("SELECT RAISE(ROLLBACK, msg)", "SELECT RAISE(ROLLBACK, msg);\n");
    try expectRender("SELECT RAISE(FAIL, 'x')", "SELECT RAISE(FAIL, x);\n");
}

test "function calls" {
    try expectRender("SELECT f(), g(*), h(1, a + 2)", "SELECT f(), g(*), h(1, (a + 2));\n");
    try expectRender("SELECT count(DISTINCT a, b), count(ALL a)", "SELECT count(DISTINCT a, b), count(ALL a);\n");
    try expectRender("SELECT group_concat(a ORDER BY b DESC)", "SELECT group_concat(a ORDER BY b DESC);\n");
    try expectRender(
        "SELECT f(a, b ORDER BY c ASC NULLS FIRST, d NULLS LAST, e)",
        "SELECT f(a, b ORDER BY c ASC NULLS FIRST, d NULLS LAST, e);\n",
    );
    try expectRender("SELECT f(DISTINCT)", "SELECT f(DISTINCT );\n");
    try expectRender("SELECT left(a, 1), replace(a, b, c), \"x\"(1), cross(1), indexed(2)", "SELECT \"left\"(a, 1), \"replace\"(a, b, c), x(1), \"cross\"(1), \"indexed\"(2);\n");
    try expectRender("SELECT f(a) + g(b) * 2", "SELECT (f(a) + (g(b) * 2));\n");
}

test "CAST, CASE, RAISE and call syntax errors" {
    try expectError("SELECT CAST(1)", "near \")\": syntax error", .{ .byte_offset = 13, .line = 1, .column = 14 });
    try expectError("SELECT CAST(1 AS", "incomplete input", .{ .byte_offset = 16, .line = 1, .column = 17 });
    try expectError("SELECT CAST(1 AS (2))", "near \"(\": syntax error", .{ .byte_offset = 17, .line = 1, .column = 18 });
    try expectError("SELECT CAST(1 AS T(x))", "near \"x\": syntax error", .{ .byte_offset = 19, .line = 1, .column = 20 });
    try expectError("SELECT CAST(1 AS T(1, 2, 3))", "near \",\": syntax error", .{ .byte_offset = 23, .line = 1, .column = 24 });
    try expectError("SELECT CAST", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("SELECT CASE END", "incomplete input", .{ .byte_offset = 15, .line = 1, .column = 16 });
    try expectError("SELECT CASE WHEN a END", "near \"END\": syntax error", .{ .byte_offset = 19, .line = 1, .column = 20 });
    try expectError("SELECT CASE WHEN a THEN b", "incomplete input", .{ .byte_offset = 25, .line = 1, .column = 26 });
    try expectError("SELECT CASE\n  ELSE 1 END", "near \"ELSE\": syntax error", .{ .byte_offset = 14, .line = 2, .column = 3 });
    try expectError("SELECT RAISE(ABORT)", "near \")\": syntax error", .{ .byte_offset = 18, .line = 1, .column = 19 });
    try expectError("SELECT RAISE(IGNORE, 'x')", "near \",\": syntax error", .{ .byte_offset = 19, .line = 1, .column = 20 });
    try expectError("SELECT RAISE(ABORT, 1)", "near \"1\": syntax error", .{ .byte_offset = 20, .line = 1, .column = 21 });
    try expectError("SELECT RAISE(x)", "near \"x\": syntax error", .{ .byte_offset = 13, .line = 1, .column = 14 });
    try expectError("SELECT RAISE", "incomplete input", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT f(*, 1)", "near \",\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("SELECT f(a,)", "near \")\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("SELECT f(a ORDER b)", "near \"b\": syntax error", .{ .byte_offset = 17, .line = 1, .column = 18 });
    try expectError("SELECT f(a ORDER BY b NULLS)", "near \")\": syntax error", .{ .byte_offset = 27, .line = 1, .column = 28 });
    try expectError("SELECT 'f'(1)", "near \"(\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
}

test "qualified star result columns" {
    try expectRender("SELECT t.*", "SELECT t.*;\n");
    try expectRender("select 'a'.*, \"b c\".*, x", "SELECT a.*, \"b c\".*, x;\n");
    try expectError("SELECT a.b.*", "near \"*\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
}

test "register variables are rejected unless the next token is the error" {
    try expectError("SELECT 1 IS #1;", "near \"#1\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("SELECT #1 , 2 +", "near \"#1\": syntax error", .{ .byte_offset = 7, .line = 1, .column = 8 });
    try expectError("SELECT +#1 )", "near \")\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("SELECT #1 #2", "near \"#2\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectRender("SELECT #abc, #x1", "SELECT #abc, #x1;\n");
}

test "pragma" {
    try expectRender("pragma p", "PRAGMA p;\n");
    try expectRender("pragma s.p", "PRAGMA s.p;\n");
    try expectRender("pragma p=1", "PRAGMA p = 1;\n");
    try expectRender("pragma p=+1", "PRAGMA p = +1;\n");
    try expectRender("pragma p == delete", "PRAGMA p = DELETE;\n");
    try expectRender("pragma p=-1.5", "PRAGMA p = -1.5;\n");
    try expectRender("pragma p = - 1", "PRAGMA p = -1;\n");
    try expectRender("pragma p(x)", "PRAGMA p(x);\n");
    try expectRender("pragma p(-1)", "PRAGMA p(-1);\n");
    try expectRender("pragma p(+0x10)", "PRAGMA p(+0x10);\n");
    try expectRender("pragma p=on", "PRAGMA p = ON;\n");
    try expectRender("pragma p=delete", "PRAGMA p = DELETE;\n");
    try expectRender("pragma p(default)", "PRAGMA p(DEFAULT);\n");
    try expectRender("pragma p='str'", "PRAGMA p = str;\n");
    try expectRender("pragma s.p = 'a b'", "PRAGMA s.p = \"a b\";\n");
    try expectRender("pragma pragma = left", "PRAGMA \"pragma\" = \"left\";\n");
    try expectRender("explain pragma p; explain query plan pragma p=1", "EXPLAIN PRAGMA p;\nEXPLAIN QUERY PLAN PRAGMA p = 1;\n");
}

test "pragma errors" {
    try expectError("pragma", "incomplete input", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("pragma;", "near \";\": syntax error", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("pragma p=", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("pragma p=-x", "near \"x\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("pragma p=+x", "near \"x\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("pragma p=-on", "near \"on\": syntax error", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("pragma p=--1", "incomplete input", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("pragma p=- -1", "near \"-\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("pragma p(", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("pragma p(1", "incomplete input", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("pragma p(1)2", "near \"2\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("pragma p=1 2", "near \"2\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("pragma p ==", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("pragma p.", "incomplete input", .{ .byte_offset = 9, .line = 1, .column = 10 });
}

test "attach and detach" {
    try expectRender("attach 'f' as a", "ATTACH DATABASE 'f' AS a;\n");
    try expectRender("attach database 'f' as a key 'k'", "ATTACH DATABASE 'f' AS a KEY 'k';\n");
    try expectRender("attach x+1 as y", "ATTACH DATABASE (x + 1) AS y;\n");
    try expectRender("attach database database as x", "ATTACH DATABASE \"database\" AS x;\n");
    try expectRender("attach 'f' as a key key", "ATTACH DATABASE 'f' AS a KEY \"key\";\n");
    try expectRender("detach a", "DETACH DATABASE a;\n");
    try expectRender("detach database a", "DETACH DATABASE a;\n");
    try expectRender("detach database database", "DETACH DATABASE \"database\";\n");
    try expectRender("explain detach 'x'", "EXPLAIN DETACH DATABASE 'x';\n");
}

test "attach and detach errors" {
    try expectError("attach 'f'", "incomplete input", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("attach 'f' as", "incomplete input", .{ .byte_offset = 13, .line = 1, .column = 14 });
    try expectError("attach 'f' a", "near \"a\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("attach database as x", "near \"as\": syntax error", .{ .byte_offset = 16, .line = 1, .column = 17 });
    try expectError("detach", "incomplete input", .{ .byte_offset = 6, .line = 1, .column = 7 });
    try expectError("detach database", "incomplete input", .{ .byte_offset = 15, .line = 1, .column = 16 });
}

test "vacuum, reindex and analyze" {
    try expectRender("vacuum", "VACUUM;\n");
    try expectRender("vacuum m", "VACUUM m;\n");
    try expectRender("vacuum into 'f'", "VACUUM INTO 'f';\n");
    try expectRender("vacuum m into 'f'", "VACUUM m INTO 'f';\n");
    try expectRender("vacuum vacuum", "VACUUM \"vacuum\";\n");
    try expectRender("reindex", "REINDEX;\n");
    try expectRender("reindex t", "REINDEX t;\n");
    try expectRender("reindex s.t", "REINDEX s.t;\n");
    try expectRender("reindex left", "REINDEX \"left\";\n");
    try expectRender("analyze", "ANALYZE;\n");
    try expectRender("analyze t", "ANALYZE t;\n");
    try expectRender("analyze s.t", "ANALYZE s.t;\n");
    try expectRender("analyze analyze", "ANALYZE \"analyze\";\n");
    try expectRender("explain vacuum; explain query plan analyze t", "EXPLAIN VACUUM;\nEXPLAIN QUERY PLAN ANALYZE t;\n");
}

test "vacuum, reindex and analyze errors" {
    try expectError("vacuum into", "incomplete input", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("vacuum into into 1", "near \"into\": syntax error", .{ .byte_offset = 12, .line = 1, .column = 13 });
    try expectError("vacuum a b", "near \"b\": syntax error", .{ .byte_offset = 9, .line = 1, .column = 10 });
    try expectError("reindex a.", "incomplete input", .{ .byte_offset = 10, .line = 1, .column = 11 });
    try expectError("reindex a.b.c", "near \".\": syntax error", .{ .byte_offset = 11, .line = 1, .column = 12 });
    try expectError("analyze 1", "near \"1\": syntax error", .{ .byte_offset = 8, .line = 1, .column = 9 });
}

test "SELECT FROM, joins and clauses" {
    const cases = [_][2][:0]const u8{
        .{ "SELECT a, b AS c, t.*, * FROM t", "SELECT a, b AS c, t.*, * FROM t;\n" },
        .{ "SELECT DISTINCT a FROM s.t AS x INDEXED BY i", "SELECT DISTINCT a FROM s.t AS x INDEXED BY i;\n" },
        .{ "SELECT a FROM t x NOT INDEXED", "SELECT a FROM t AS x NOT INDEXED;\n" },
        .{ "SELECT a FROM f(1,2)", "SELECT a FROM f(1, 2);\n" },
        .{ "SELECT a FROM s.f(1) y", "SELECT a FROM s.f(1) AS y;\n" },
        .{ "SELECT a FROM (SELECT 1) q", "SELECT a FROM (SELECT 1) AS q;\n" },
        .{ "SELECT a FROM (t1 JOIN t2)", "SELECT a FROM (t1 JOIN t2);\n" },
        .{ "SELECT a FROM a, b JOIN c ON a.x=c.x", "SELECT a FROM a, b JOIN c ON (a.x = c.x);\n" },
        .{ "SELECT a FROM a left outer join b using (x,y)", "SELECT a FROM a LEFT OUTER JOIN b USING (x, y);\n" },
        .{ "SELECT a FROM a NATURAL JOIN b CROSS JOIN c", "SELECT a FROM a NATURAL JOIN b CROSS JOIN c;\n" },
        .{ "SELECT a FROM t WHERE a GROUP BY a,b HAVING c", "SELECT a FROM t WHERE a GROUP BY a, b HAVING c;\n" },
        .{ "SELECT a HAVING c", "SELECT a HAVING c;\n" },
        .{ "SELECT a FROM t ORDER BY a DESC NULLS LAST, b ASC NULLS FIRST", "SELECT a FROM t ORDER BY a DESC NULLS LAST, b ASC NULLS FIRST;\n" },
        .{ "SELECT 1 LIMIT 1", "SELECT 1 LIMIT 1;\n" },
        .{ "SELECT 1 LIMIT 1 OFFSET 2", "SELECT 1 LIMIT 1 OFFSET 2;\n" },
        .{ "SELECT 1 LIMIT 1, 2", "SELECT 1 LIMIT 2 OFFSET 1;\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "SELECT compounds, VALUES and subqueries" {
    const cases = [_][2][:0]const u8{
        .{ "SELECT 1 UNION SELECT 2 UNION ALL SELECT 3 INTERSECT SELECT 4 EXCEPT SELECT 5", "SELECT 1 UNION SELECT 2 UNION ALL SELECT 3 INTERSECT SELECT 4 EXCEPT SELECT 5;\n" },
        .{ "VALUES (1,2),(3,4)", "VALUES (1, 2), (3, 4);\n" },
        .{ "SELECT 1 UNION VALUES (2)", "SELECT 1 UNION VALUES (2);\n" },
        .{ "SELECT (SELECT 1)", "SELECT (SELECT 1);\n" },
        .{ "SELECT EXISTS (SELECT 1)", "SELECT EXISTS (SELECT 1);\n" },
        .{ "SELECT x IN (SELECT 1)", "SELECT (x IN (SELECT 1));\n" },
        .{ "SELECT x NOT IN (SELECT 1)", "SELECT (x NOT IN (SELECT 1));\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "SELECT errors" {
    const Case = struct { [:0]const u8, []const u8, usize };
    const cases = [_]Case{
        .{ "SELECT 1 FROM", "incomplete input", 13 },
        .{ "SELECT 1 FROM t WHERE", "incomplete input", 21 },
        .{ "SELECT * FROM t JOIN u ON", "incomplete input", 25 },
        .{ "SELECT 1 FROM t GROUP x", "near \"x\": syntax error", 22 },
        .{ "SELECT 1 FROM t LIMIT", "incomplete input", 21 },
        .{ "SELECT a FROM t ON x", "a JOIN clause is required before ON", 16 },
        .{ "SELECT * FROM a LEFT FOO JOIN b", "unknown join type: LEFT FOO", 16 },
        .{ "SELECT * FROM a INNER OUTER JOIN b", "unknown join type: INNER OUTER", 16 },
        .{ "SELECT 1 ORDER BY 1 UNION SELECT 2", "ORDER BY clause should come after UNION not before", 20 },
        .{ "SELECT 1 LIMIT 1 EXCEPT SELECT 2", "LIMIT clause should come after EXCEPT not before", 17 },
        .{ "VALUES", "incomplete input", 6 },
        .{ "SELECT (SELECT", "incomplete input", 14 },
    };
    for (cases) |case| {
        try expectError(case[0], case[1], .{ .byte_offset = case[2], .line = 1, .column = case[2] + 1 });
    }
}

test "WITH clauses" {
    const cases = [_][2][:0]const u8{
        .{ "WITH x AS (SELECT 1) SELECT * FROM x", "WITH x AS (SELECT 1) SELECT * FROM x;\n" },
        .{
            "WITH RECURSIVE x(a, b) AS MATERIALIZED (SELECT 1, 2), y AS NOT MATERIALIZED (VALUES (1)) SELECT * FROM x, y",
            "WITH RECURSIVE x(a, b) AS MATERIALIZED (SELECT 1, 2), y AS NOT MATERIALIZED (VALUES (1)) SELECT * FROM x, y;\n",
        },
        .{ "WITH x AS (SELECT 1) VALUES (2)", "WITH x AS (SELECT 1) VALUES (2);\n" },
        .{ "with x(a) as (select 1 union select 2) select a from x", "WITH x(a) AS (SELECT 1 UNION SELECT 2) SELECT a FROM x;\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "window functions" {
    const cases = [_][2][:0]const u8{
        .{ "SELECT sum(a) OVER () FROM t", "SELECT sum(a) OVER () FROM t;\n" },
        .{ "SELECT sum(a) OVER w FROM t", "SELECT sum(a) OVER w FROM t;\n" },
        .{
            "SELECT sum(a) OVER (w PARTITION BY a, b ORDER BY c DESC NULLS LAST) FROM t",
            "SELECT sum(a) OVER (w PARTITION BY a, b ORDER BY c DESC NULLS LAST) FROM t;\n",
        },
        .{ "SELECT f(a) FILTER (WHERE a > 1) OVER w FROM t", "SELECT f(a) FILTER (WHERE (a > 1)) OVER w FROM t;\n" },
        .{ "SELECT count(*) FILTER (WHERE x) FROM t", "SELECT count(*) FILTER (WHERE x) FROM t;\n" },
        .{
            "SELECT a FROM t WINDOW w AS (PARTITION BY a), v AS (w ORDER BY a)",
            "SELECT a FROM t WINDOW w AS (PARTITION BY a), v AS (w ORDER BY a);\n",
        },
        .{ "SELECT 1 FROM t WINDOW w AS ()", "SELECT 1 FROM t WINDOW w AS ();\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "window frames" {
    const cases = [_][2][:0]const u8{
        .{ "SELECT f(a) OVER (RANGE UNBOUNDED PRECEDING)", "SELECT f(a) OVER (RANGE UNBOUNDED PRECEDING);\n" },
        .{ "SELECT f(a) OVER (ROWS CURRENT ROW)", "SELECT f(a) OVER (ROWS CURRENT ROW);\n" },
        .{ "SELECT f(a) OVER (GROUPS 2 FOLLOWING)", "SELECT f(a) OVER (GROUPS 2 FOLLOWING);\n" },
        .{ "SELECT f(a) OVER (ROWS 3 PRECEDING)", "SELECT f(a) OVER (ROWS 3 PRECEDING);\n" },
        .{
            "SELECT f(a) OVER (ORDER BY b ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING)",
            "SELECT f(a) OVER (ORDER BY b ROWS BETWEEN 1 PRECEDING AND 2 FOLLOWING);\n",
        },
        .{
            "SELECT f(a) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
            "SELECT f(a) OVER (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);\n",
        },
        .{
            "SELECT f(a) OVER (GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)",
            "SELECT f(a) OVER (GROUPS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING);\n",
        },
        .{ "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE NO OTHERS)", "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE NO OTHERS);\n" },
        .{ "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE CURRENT ROW)", "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE CURRENT ROW);\n" },
        .{ "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE GROUP)", "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE GROUP);\n" },
        .{ "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE TIES)", "SELECT f(a) OVER (ROWS CURRENT ROW EXCLUDE TIES);\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "WINDOW, OVER and FILTER as identifiers in expressions and aliases" {
    const cases = [_][2][:0]const u8{
        .{ "SELECT over FROM t", "SELECT \"over\" FROM t;\n" },
        .{ "SELECT filter FROM t", "SELECT \"filter\" FROM t;\n" },
        .{ "SELECT window FROM t", "SELECT \"window\" FROM t;\n" },
        .{ "SELECT filter(x) FROM t", "SELECT \"filter\"(x) FROM t;\n" },
        .{ "SELECT 1 AS window", "SELECT 1 AS \"window\";\n" },
        .{ "SELECT f(x) over FROM t", "SELECT f(x) AS \"over\" FROM t;\n" },
        .{ "SELECT f(x) filter FROM t", "SELECT f(x) AS \"filter\" FROM t;\n" },
        .{ "SELECT 1 FROM t window", "SELECT 1 FROM t AS \"window\";\n" },
        .{ "SELECT 1 FROM t over", "SELECT 1 FROM t AS \"over\";\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "WITH and window syntax errors" {
    const Case = struct { [:0]const u8, []const u8, usize };
    const cases = [_]Case{
        .{ "WITH x(a COLLATE nocase) AS (SELECT 1) SELECT 1", "syntax error after column name \"a\"", 23 },
        .{ "WITH x(a ASC) AS (SELECT 1) SELECT 1", "syntax error after column name \"a\"", 12 },
        .{ "WITH x(a DESC) AS (SELECT 1) SELECT 1", "syntax error after column name \"a\"", 13 },
        .{ "WITH x AS SELECT 1", "near \"SELECT\": syntax error", 10 },
        .{ "WITH x AS (SELECT 1)", "incomplete input", 20 },
        .{ "SELECT sum(a) OVER (ROWS) FROM t", "near \")\": syntax error", 24 },
        .{ "SELECT 1 FROM t WINDOW w AS () x", "near \"x\": syntax error", 31 },
        .{ "SELECT sum(a) OVER (", "incomplete input", 20 },
    };
    for (cases) |case| {
        try expectError(case[0], case[1], .{ .byte_offset = case[2], .line = 1, .column = case[2] + 1 });
    }
}

test "INSERT" {
    const cases = [_][2][:0]const u8{
        .{ "insert into t values (1, 2)", "INSERT INTO t VALUES (1, 2);\n" },
        .{ "INSERT INTO t VALUES (1), (2)", "INSERT INTO t VALUES (1), (2);\n" },
        .{ "INSERT INTO t(a, b) SELECT 1, 2", "INSERT INTO t (a, b) SELECT 1, 2;\n" },
        .{ "replace into t(a) values(1)", "REPLACE INTO t (a) VALUES (1);\n" },
        .{ "INSERT OR REPLACE INTO main.t AS x (a, b) SELECT 1, 2", "INSERT OR REPLACE INTO main.t AS x (a, b) SELECT 1, 2;\n" },
        .{ "INSERT OR ROLLBACK INTO t VALUES (1)", "INSERT OR ROLLBACK INTO t VALUES (1);\n" },
        .{ "INSERT OR ABORT INTO t VALUES (1)", "INSERT OR ABORT INTO t VALUES (1);\n" },
        .{ "INSERT OR FAIL INTO t VALUES (1)", "INSERT OR FAIL INTO t VALUES (1);\n" },
        .{ "INSERT OR IGNORE INTO t VALUES (1)", "INSERT OR IGNORE INTO t VALUES (1);\n" },
        .{ "INSERT INTO t AS x VALUES (1)", "INSERT INTO t AS x VALUES (1);\n" },
        .{ "INSERT INTO 'my t' DEFAULT VALUES", "INSERT INTO \"my t\" DEFAULT VALUES;\n" },
        .{ "INSERT INTO t DEFAULT VALUES", "INSERT INTO t DEFAULT VALUES;\n" },
        .{ "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x;\n" },
        .{ "with x(a) as (select 1) replace into t(a) select a from x", "WITH x(a) AS (SELECT 1) REPLACE INTO t (a) SELECT a FROM x;\n" },
        .{ "INSERT INTO t SELECT 1 FROM a WHERE true ON CONFLICT DO NOTHING", "INSERT INTO t SELECT 1 FROM a WHERE true ON CONFLICT DO NOTHING;\n" },
        .{ "INSERT INTO t SELECT 1 FROM a WHERE true ON CONFLICT(x) DO NOTHING", "INSERT INTO t SELECT 1 FROM a WHERE true ON CONFLICT (x) DO NOTHING;\n" },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "INSERT upsert chains and RETURNING" {
    const cases = [_][2][:0]const u8{
        .{ "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING", "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING;\n" },
        .{ "INSERT INTO t VALUES (1) ON CONFLICT DO UPDATE SET a = 1", "INSERT INTO t VALUES (1) ON CONFLICT DO UPDATE SET a = 1;\n" },
        .{
            "INSERT INTO t VALUES (1) ON CONFLICT(a COLLATE nocase DESC, b+1) WHERE a>1 DO UPDATE SET a=1+1, (b,c)=(1,2) WHERE b<3",
            "INSERT INTO t VALUES (1) ON CONFLICT ((a COLLATE nocase) DESC, (b + 1)) WHERE (a > 1) DO UPDATE SET a = (1 + 1), (b, c) = (1, 2) WHERE (b < 3);\n",
        },
        .{
            "INSERT INTO t VALUES (1) ON CONFLICT(a) DO NOTHING ON CONFLICT(b) DO UPDATE SET x=1 ON CONFLICT DO NOTHING",
            "INSERT INTO t VALUES (1) ON CONFLICT (a) DO NOTHING ON CONFLICT (b) DO UPDATE SET x = 1 ON CONFLICT DO NOTHING;\n",
        },
        .{ "INSERT INTO t VALUES (1) ON CONFLICT(a) DO UPDATE SET (a) = 1", "INSERT INTO t VALUES (1) ON CONFLICT (a) DO UPDATE SET (a) = 1;\n" },
        .{ "INSERT INTO t VALUES (1) RETURNING *", "INSERT INTO t VALUES (1) RETURNING *;\n" },
        .{ "INSERT INTO t VALUES (1) RETURNING a, b+1 AS c", "INSERT INTO t VALUES (1) RETURNING a, (b + 1) AS c;\n" },
        .{ "INSERT INTO t DEFAULT VALUES RETURNING a", "INSERT INTO t DEFAULT VALUES RETURNING a;\n" },
        .{ "REPLACE INTO t VALUES (1) RETURNING *", "REPLACE INTO t VALUES (1) RETURNING *;\n" },
        .{ "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING RETURNING a", "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING RETURNING a;\n" },
        .{
            "INSERT INTO t VALUES (1) ON CONFLICT(a) DO UPDATE SET a=1 RETURNING *",
            "INSERT INTO t VALUES (1) ON CONFLICT (a) DO UPDATE SET a = 1 RETURNING *;\n",
        },
        .{
            "INSERT INTO t VALUES (1) ON CONFLICT(a) DO NOTHING RETURNING a, b AS c",
            "INSERT INTO t VALUES (1) ON CONFLICT (a) DO NOTHING RETURNING a, b AS c;\n",
        },
    };
    for (cases) |case| try expectRender(case[0], case[1]);
}

test "INSERT errors" {
    const Case = struct { [:0]const u8, []const u8, usize };
    const syntax = [_]Case{
        // A join's ON swallows ON CONFLICT, so DO is the first bad token.
        .{ "INSERT INTO t SELECT * FROM u ON CONFLICT DO NOTHING", "near \"DO\": syntax error", 42 },
        .{ "INSERT INTO t SELECT * FROM a JOIN b ON CONFLICT DO NOTHING", "near \"DO\": syntax error", 49 },
        .{ "INSERT INTO t SELECT * FROM a ON CONFLICT(x) DO NOTHING", "near \"DO\": syntax error", 45 },
        .{ "INSERT INTO t SELECT * FROM a JOIN b ON CONFLICT(x) DO NOTHING", "near \"DO\": syntax error", 52 },
        .{ "INSERT INTO t VALUES(1) ON CONFLICT DO NOTHING ON CONFLICT(b) DO NOTHING", "near \"ON\": syntax error", 47 },
        .{ "INSERT INTO t VALUES(1) ON CONFLICT DO UPDATE SET a=1 ON CONFLICT DO NOTHING", "near \"ON\": syntax error", 54 },
        .{ "INSERT INTO t VALUES(1) ON CONFLICT(a) DO NOTHING RETURNING a ON CONFLICT(b) DO NOTHING", "near \"ON\": syntax error", 62 },
        .{ "INSERT INTO t DEFAULT VALUES ON CONFLICT DO NOTHING", "near \"ON\": syntax error", 29 },
        .{ "INSERT INTO t VALUES(1) ON CONFLICT DO FOO", "near \"FOO\": syntax error", 39 },
        .{ "INSERT INTO t VALUES(1) ON CONFLICT(a) DO UPDATE SET (a,)=1", "near \")\": syntax error", 56 },
        .{ "INSERT OR RAISE INTO t VALUES(1)", "near \"RAISE\": syntax error", 10 },
        .{ "INSERT OR INTO t VALUES(1)", "near \"INTO\": syntax error", 10 },
        .{ "INSERT INTO t() VALUES(1)", "near \")\": syntax error", 14 },
        .{ "INSERT t VALUES(1)", "near \"t\": syntax error", 7 },
    };
    for (syntax) |case| {
        try expectError(case[0], case[1], .{ .byte_offset = case[2], .line = 1, .column = case[2] + 1 });
    }

    const incomplete = [_][:0]const u8{
        "INSERT",
        "INSERT INTO",
        "INSERT INTO t",
        "INSERT INTO t(",
        "INSERT INTO t(a,",
        "INSERT INTO t VALUES",
        "INSERT INTO t DEFAULT",
        "INSERT INTO t DEFAULT VALUES RETURNING",
        "INSERT INTO t VALUES(1) RETURNING",
        "INSERT INTO t VALUES(1) ON",
        "INSERT INTO t VALUES(1) ON CONFLICT",
        "INSERT INTO t VALUES(1) ON CONFLICT(a)",
        "INSERT INTO t VALUES(1) ON CONFLICT(a) DO",
        "INSERT INTO t VALUES(1) ON CONFLICT(a) DO UPDATE",
        "INSERT INTO t VALUES(1) ON CONFLICT(a) DO UPDATE SET",
        "INSERT INTO t VALUES(1) ON CONFLICT(a) DO UPDATE SET a",
        "INSERT INTO t VALUES(1) ON CONFLICT(a) DO UPDATE SET a=",
    };
    for (incomplete) |source| {
        try expectError(source, "incomplete input", .{ .byte_offset = source.len, .line = 1, .column = source.len + 1 });
    }
}
