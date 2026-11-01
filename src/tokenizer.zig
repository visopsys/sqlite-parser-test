//! SQLite's tokenizer: `sqlite3GetToken` from tokenize.c, as a state machine over a
//! sentinel-terminated buffer in the shape of `std.zig.Tokenizer`. Spaces and
//! comments are skipped. The context rule that turns WINDOW, OVER and FILTER into
//! identifiers belongs to the parser; here they are plain keyword tags.

const std = @import("std");

/// A lexeme in the source: its tag and the byte range it covers.
pub const Token = struct {
    tag: Tag,
    loc: Loc,

    /// Byte offsets into the tokenized buffer; `end` is exclusive.
    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    /// One value per token kind the parser distinguishes. Keyword tags are named after
    /// the `TK_*` tokens of mkkeywordhash.c, so words that share a token share a tag.
    pub const Tag = enum {
        invalid,
        eof,
        identifier,
        string_literal,
        blob_literal,
        integer_literal,
        float_literal,
        variable,
        minus,
        l_paren,
        r_paren,
        semicolon,
        plus,
        star,
        slash,
        percent,
        equal,
        equal_equal,
        l_angle_bracket,
        angle_bracket_left_equal,
        angle_bracket_left_angle_bracket_left,
        not_equal,
        r_angle_bracket,
        angle_bracket_right_equal,
        angle_bracket_right_angle_bracket_right,
        comma,
        ampersand,
        tilde,
        pipe,
        pipe_pipe,
        dot,
        arrow,
        arrow2,
        keyword_abort,
        keyword_action,
        keyword_add,
        keyword_after,
        keyword_all,
        keyword_alter,
        keyword_always,
        keyword_analyze,
        keyword_and,
        keyword_as,
        keyword_asc,
        keyword_attach,
        keyword_autoincr,
        keyword_before,
        keyword_begin,
        keyword_between,
        keyword_by,
        keyword_cascade,
        keyword_case,
        keyword_cast,
        keyword_check,
        keyword_collate,
        keyword_columnkw,
        keyword_commit,
        keyword_conflict,
        keyword_constraint,
        keyword_create,
        keyword_join_kw,
        keyword_current,
        keyword_ctime_kw,
        keyword_database,
        keyword_default,
        keyword_deferred,
        keyword_deferrable,
        keyword_delete,
        keyword_desc,
        keyword_detach,
        keyword_distinct,
        keyword_do,
        keyword_drop,
        keyword_end,
        keyword_each,
        keyword_else,
        keyword_escape,
        keyword_except,
        keyword_exclusive,
        keyword_exclude,
        keyword_exists,
        keyword_explain,
        keyword_fail,
        keyword_filter,
        keyword_first,
        keyword_following,
        keyword_for,
        keyword_foreign,
        keyword_from,
        keyword_generated,
        keyword_like_kw,
        keyword_group,
        keyword_groups,
        keyword_having,
        keyword_if,
        keyword_ignore,
        keyword_immediate,
        keyword_in,
        keyword_index,
        keyword_indexed,
        keyword_initially,
        keyword_insert,
        keyword_instead,
        keyword_intersect,
        keyword_into,
        keyword_is,
        keyword_isnull,
        keyword_join,
        keyword_key,
        keyword_last,
        keyword_limit,
        keyword_match,
        keyword_materialized,
        keyword_no,
        keyword_not,
        keyword_nothing,
        keyword_notnull,
        keyword_null,
        keyword_nulls,
        keyword_of,
        keyword_offset,
        keyword_on,
        keyword_or,
        keyword_order,
        keyword_others,
        keyword_over,
        keyword_partition,
        keyword_plan,
        keyword_pragma,
        keyword_preceding,
        keyword_primary,
        keyword_query,
        keyword_raise,
        keyword_range,
        keyword_recursive,
        keyword_references,
        keyword_reindex,
        keyword_release,
        keyword_rename,
        keyword_replace,
        keyword_restrict,
        keyword_returning,
        keyword_rollback,
        keyword_row,
        keyword_rows,
        keyword_savepoint,
        keyword_select,
        keyword_set,
        keyword_table,
        keyword_temp,
        keyword_then,
        keyword_ties,
        keyword_to,
        keyword_transaction,
        keyword_trigger,
        keyword_unbounded,
        keyword_union,
        keyword_unique,
        keyword_update,
        keyword_using,
        keyword_vacuum,
        keyword_values,
        keyword_view,
        keyword_virtual,
        keyword_when,
        keyword_where,
        keyword_window,
        keyword_with,
        keyword_without,

        /// The source text of a tag that always has the same spelling, else null.
        /// Keywords are lower case.
        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .minus => "-",
                .l_paren => "(",
                .r_paren => ")",
                .semicolon => ";",
                .plus => "+",
                .star => "*",
                .slash => "/",
                .percent => "%",
                .equal => "=",
                .equal_equal => "==",
                .l_angle_bracket => "<",
                .angle_bracket_left_equal => "<=",
                .angle_bracket_left_angle_bracket_left => "<<",
                .r_angle_bracket => ">",
                .angle_bracket_right_equal => ">=",
                .angle_bracket_right_angle_bracket_right => ">>",
                .comma => ",",
                .ampersand => "&",
                .tilde => "~",
                .pipe => "|",
                .pipe_pipe => "||",
                .dot => ".",
                .arrow => "->",
                .arrow2 => "->>",
                else => keyword_lexemes[@backingInt(tag)],
            };
        }

        /// A description of the tag for messages: its spelling when fixed, else a name.
        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .eof => "EOF",
                .not_equal => "!=",
                else => @tagName(tag),
            };
        }
    };
};

const keyword_table = [_]struct { []const u8, Token.Tag }{
    .{ "abort", .keyword_abort },            .{ "action", .keyword_action },              .{ "add", .keyword_add },
    .{ "after", .keyword_after },            .{ "all", .keyword_all },                    .{ "alter", .keyword_alter },
    .{ "always", .keyword_always },          .{ "analyze", .keyword_analyze },            .{ "and", .keyword_and },
    .{ "as", .keyword_as },                  .{ "asc", .keyword_asc },                    .{ "attach", .keyword_attach },
    .{ "autoincrement", .keyword_autoincr }, .{ "before", .keyword_before },              .{ "begin", .keyword_begin },
    .{ "between", .keyword_between },        .{ "by", .keyword_by },                      .{ "cascade", .keyword_cascade },
    .{ "case", .keyword_case },              .{ "cast", .keyword_cast },                  .{ "check", .keyword_check },
    .{ "collate", .keyword_collate },        .{ "column", .keyword_columnkw },            .{ "commit", .keyword_commit },
    .{ "conflict", .keyword_conflict },      .{ "constraint", .keyword_constraint },      .{ "create", .keyword_create },
    .{ "cross", .keyword_join_kw },          .{ "current", .keyword_current },            .{ "current_date", .keyword_ctime_kw },
    .{ "current_time", .keyword_ctime_kw },  .{ "current_timestamp", .keyword_ctime_kw }, .{ "database", .keyword_database },
    .{ "default", .keyword_default },        .{ "deferred", .keyword_deferred },          .{ "deferrable", .keyword_deferrable },
    .{ "delete", .keyword_delete },          .{ "desc", .keyword_desc },                  .{ "detach", .keyword_detach },
    .{ "distinct", .keyword_distinct },      .{ "do", .keyword_do },                      .{ "drop", .keyword_drop },
    .{ "end", .keyword_end },                .{ "each", .keyword_each },                  .{ "else", .keyword_else },
    .{ "escape", .keyword_escape },          .{ "except", .keyword_except },              .{ "exclusive", .keyword_exclusive },
    .{ "exclude", .keyword_exclude },        .{ "exists", .keyword_exists },              .{ "explain", .keyword_explain },
    .{ "fail", .keyword_fail },              .{ "filter", .keyword_filter },              .{ "first", .keyword_first },
    .{ "following", .keyword_following },    .{ "for", .keyword_for },                    .{ "foreign", .keyword_foreign },
    .{ "from", .keyword_from },              .{ "full", .keyword_join_kw },               .{ "generated", .keyword_generated },
    .{ "glob", .keyword_like_kw },           .{ "group", .keyword_group },                .{ "groups", .keyword_groups },
    .{ "having", .keyword_having },          .{ "if", .keyword_if },                      .{ "ignore", .keyword_ignore },
    .{ "immediate", .keyword_immediate },    .{ "in", .keyword_in },                      .{ "index", .keyword_index },
    .{ "indexed", .keyword_indexed },        .{ "initially", .keyword_initially },        .{ "inner", .keyword_join_kw },
    .{ "insert", .keyword_insert },          .{ "instead", .keyword_instead },            .{ "intersect", .keyword_intersect },
    .{ "into", .keyword_into },              .{ "is", .keyword_is },                      .{ "isnull", .keyword_isnull },
    .{ "join", .keyword_join },              .{ "key", .keyword_key },                    .{ "last", .keyword_last },
    .{ "left", .keyword_join_kw },           .{ "like", .keyword_like_kw },               .{ "limit", .keyword_limit },
    .{ "match", .keyword_match },            .{ "materialized", .keyword_materialized },  .{ "natural", .keyword_join_kw },
    .{ "no", .keyword_no },                  .{ "not", .keyword_not },                    .{ "nothing", .keyword_nothing },
    .{ "notnull", .keyword_notnull },        .{ "null", .keyword_null },                  .{ "nulls", .keyword_nulls },
    .{ "of", .keyword_of },                  .{ "offset", .keyword_offset },              .{ "on", .keyword_on },
    .{ "or", .keyword_or },                  .{ "order", .keyword_order },                .{ "others", .keyword_others },
    .{ "outer", .keyword_join_kw },          .{ "over", .keyword_over },                  .{ "partition", .keyword_partition },
    .{ "plan", .keyword_plan },              .{ "pragma", .keyword_pragma },              .{ "preceding", .keyword_preceding },
    .{ "primary", .keyword_primary },        .{ "query", .keyword_query },                .{ "raise", .keyword_raise },
    .{ "range", .keyword_range },            .{ "recursive", .keyword_recursive },        .{ "references", .keyword_references },
    .{ "regexp", .keyword_like_kw },         .{ "reindex", .keyword_reindex },            .{ "release", .keyword_release },
    .{ "rename", .keyword_rename },          .{ "replace", .keyword_replace },            .{ "restrict", .keyword_restrict },
    .{ "returning", .keyword_returning },    .{ "right", .keyword_join_kw },              .{ "rollback", .keyword_rollback },
    .{ "row", .keyword_row },                .{ "rows", .keyword_rows },                  .{ "savepoint", .keyword_savepoint },
    .{ "select", .keyword_select },          .{ "set", .keyword_set },                    .{ "table", .keyword_table },
    .{ "temp", .keyword_temp },              .{ "temporary", .keyword_temp },             .{ "then", .keyword_then },
    .{ "ties", .keyword_ties },              .{ "to", .keyword_to },                      .{ "transaction", .keyword_transaction },
    .{ "trigger", .keyword_trigger },        .{ "unbounded", .keyword_unbounded },        .{ "union", .keyword_union },
    .{ "unique", .keyword_unique },          .{ "update", .keyword_update },              .{ "using", .keyword_using },
    .{ "vacuum", .keyword_vacuum },          .{ "values", .keyword_values },              .{ "view", .keyword_view },
    .{ "virtual", .keyword_virtual },        .{ "when", .keyword_when },                  .{ "where", .keyword_where },
    .{ "window", .keyword_window },          .{ "with", .keyword_with },                  .{ "without", .keyword_without },
};

/// The spelling of each keyword tag that has exactly one; null for shared tags
/// (LIKE_KW, JOIN_KW, CTIME_KW, TEMP) and non-keywords.
const keyword_lexemes = blk: {
    const tag_count = @typeInfo(Token.Tag).@"enum".field_names.len;
    var lexemes: [tag_count]?[]const u8 = @splat(null);
    var uses: [tag_count]usize = @splat(0);
    for (keyword_table) |entry| {
        const index = @backingInt(entry[1]);
        lexemes[index] = entry[0];
        uses[index] += 1;
    }
    for (&lexemes, uses) |*lexeme, count| {
        if (count != 1) lexeme.* = null;
    }
    break :blk lexemes;
};

/// SQLite's keywords, keyed by lower case spelling.
pub const keywords = std.StaticStringMap(Token.Tag).initComptime(keyword_table);

const longest_keyword = "current_timestamp".len;

/// Looks up `bytes` as a keyword, ignoring ASCII case.
pub fn getKeyword(bytes: []const u8) ?Token.Tag {
    if (bytes.len > longest_keyword) return null;
    var buffer: [longest_keyword]u8 = undefined;
    const lower = std.ascii.lowerString(&buffer, bytes);
    return keywords.get(lower);
}

/// Splits a buffer into tokens, one `next` call at a time.
pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    /// Starts at the first byte of `buffer`.
    pub fn init(buffer: [:0]const u8) Tokenizer {
        return .{ .buffer = buffer, .index = 0 };
    }
    const State = enum { start, line_comment, block_comment };

    /// Returns the next token. At the end of input, and at a NUL byte, it returns `eof`
    /// again and again.
    pub fn next(self: *Tokenizer) Token {
        const buffer = self.buffer;
        var start = self.index;
        state: switch (State.start) {
            .start => switch (buffer[self.index]) {
                0 => return .{ .tag = .eof, .loc = .{ .start = start, .end = start } },
                ' ', '\t', '\n', '\x0c', '\r' => {
                    // Once a run has started, a vertical tab continues it (sqlite3Isspace).
                    while (isSpace(buffer[self.index])) self.index += 1;
                    start = self.index;
                    continue :state .start;
                },
                0xef => {
                    if (buffer[self.index + 1] == 0xbb and buffer[self.index + 2] == 0xbf) {
                        self.index += 3;
                        start = self.index;
                        continue :state .start;
                    }
                    return self.identifier(start);
                },
                '-' => switch (buffer[self.index + 1]) {
                    '-' => continue :state .line_comment,
                    '>' => {
                        const long = buffer[self.index + 2] == '>';
                        return self.finish(start, if (long) 3 else 2, if (long) .arrow2 else .arrow);
                    },
                    else => return self.finish(start, 1, .minus),
                },
                '/' => if (buffer[self.index + 1] == '*' and buffer[self.index + 2] != 0) {
                    continue :state .block_comment;
                } else return self.finish(start, 1, .slash),
                '(' => return self.finish(start, 1, .l_paren),
                ')' => return self.finish(start, 1, .r_paren),
                ';' => return self.finish(start, 1, .semicolon),
                '+' => return self.finish(start, 1, .plus),
                '*' => return self.finish(start, 1, .star),
                '%' => return self.finish(start, 1, .percent),
                ',' => return self.finish(start, 1, .comma),
                '&' => return self.finish(start, 1, .ampersand),
                '~' => return self.finish(start, 1, .tilde),
                '=' => return self.pair(start, '=', .equal_equal, .equal),
                '<' => return switch (buffer[self.index + 1]) {
                    '=' => self.finish(start, 2, .angle_bracket_left_equal),
                    '>' => self.finish(start, 2, .not_equal),
                    '<' => self.finish(start, 2, .angle_bracket_left_angle_bracket_left),
                    else => self.finish(start, 1, .l_angle_bracket),
                },
                '>' => return switch (buffer[self.index + 1]) {
                    '=' => self.finish(start, 2, .angle_bracket_right_equal),
                    '>' => self.finish(start, 2, .angle_bracket_right_angle_bracket_right),
                    else => self.finish(start, 1, .r_angle_bracket),
                },
                '!' => return self.pair(start, '=', .not_equal, .invalid),
                '|' => return self.pair(start, '|', .pipe_pipe, .pipe),
                '.' => return if (std.ascii.isDigit(buffer[self.index + 1]))
                    self.number(start)
                else
                    self.finish(start, 1, .dot),
                '0'...'9' => return self.number(start),
                '"', '\'', '`' => return self.quoted(start),
                '[' => {
                    var i = self.index + 1;
                    while (buffer[i] != 0 and buffer[i] != ']') i += 1;
                    if (buffer[i] == ']') return self.finish(start, i + 1 - start, .identifier);
                    return self.finish(start, i - start, .invalid);
                },
                '?' => {
                    var i = self.index + 1;
                    while (std.ascii.isDigit(buffer[i])) i += 1;
                    return self.finish(start, i - start, .variable);
                },
                '$', '@', '#', ':' => return self.variable(start),
                'x', 'X' => return if (buffer[self.index + 1] == '\'')
                    self.blob(start)
                else
                    self.identifier(start),
                'a'...'w', 'y', 'z', 'A'...'W', 'Y', 'Z' => return self.wordOrIdentifier(start),
                '_', 0x80...0xee, 0xf0...0xff => return self.identifier(start),
                else => return self.finish(start, 1, .invalid),
            },
            .line_comment => {
                while (buffer[self.index] != 0 and buffer[self.index] != '\n') self.index += 1;
                start = self.index;
                continue :state .start;
            },
            .block_comment => {
                self.index += 2;
                while (buffer[self.index] != 0) : (self.index += 1) {
                    if (buffer[self.index] == '*' and buffer[self.index + 1] == '/') {
                        self.index += 2;
                        break;
                    }
                }
                start = self.index;
                continue :state .start;
            },
        }
    }

    fn finish(self: *Tokenizer, start: usize, len: usize, tag: Token.Tag) Token {
        self.index = start + len;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.index } };
    }

    /// A one-byte token, or a two-byte one when `second` follows.
    fn pair(self: *Tokenizer, start: usize, second: u8, long: Token.Tag, short: Token.Tag) Token {
        const is_long = self.buffer[start + 1] == second;
        return self.finish(start, if (is_long) 2 else 1, if (is_long) long else short);
    }

    /// An identifier that cannot be a keyword: consumes every IdChar.
    fn identifier(self: *Tokenizer, start: usize) Token {
        var i = self.index + 1;
        while (isIdChar(self.buffer[i])) i += 1;
        return self.finish(start, i - start, .identifier);
    }

    /// A run of letters and underscores is a keyword unless an IdChar follows it
    /// (tokenize.c, `CC_KYWD0`).
    fn wordOrIdentifier(self: *Tokenizer, start: usize) Token {
        var i = self.index + 1;
        while (isKeywordChar(self.buffer[i])) i += 1;
        if (isIdChar(self.buffer[i])) return self.identifier(start);
        const tag = getKeyword(self.buffer[start..i]) orelse .identifier;
        return self.finish(start, i - start, tag);
    }

    /// A string, or a `"` or `` ` `` quoted identifier. A quote doubled inside stands
    /// for itself; without a closing quote the rest of the input is invalid.
    fn quoted(self: *Tokenizer, start: usize) Token {
        const buffer = self.buffer;
        const delimiter = buffer[start];
        var i = start + 1;
        while (buffer[i] != 0) : (i += 1) {
            if (buffer[i] != delimiter) continue;
            if (buffer[i + 1] != delimiter) break;
            i += 1;
        }
        if (buffer[i] == 0) return self.finish(start, i - start, .invalid);
        return self.finish(start, i + 1 - start, if (delimiter == '\'') .string_literal else .identifier);
    }

    /// `x'..'` with an even number of hex digits. Anything else is invalid up to and
    /// including the next quote.
    fn blob(self: *Tokenizer, start: usize) Token {
        const buffer = self.buffer;
        var i = start + 2;
        while (std.ascii.isHex(buffer[i])) i += 1;
        var tag: Token.Tag = .blob_literal;
        if (buffer[i] != '\'' or (i - start) % 2 != 0) {
            tag = .invalid;
            while (buffer[i] != 0 and buffer[i] != '\'') i += 1;
        }
        if (buffer[i] != 0) i += 1;
        return self.finish(start, i - start, tag);
    }

    fn number(self: *Tokenizer, start: usize) Token {
        const buffer = self.buffer;
        if (buffer[start] == '0' and (buffer[start + 1] | 0x20) == 'x' and
            std.ascii.isHex(buffer[start + 2]))
        {
            var i = start + 3;
            while (std.ascii.isHex(buffer[i])) i += 1;
            return self.finish(start, i - start, .integer_literal);
        }
        var tag: Token.Tag = .integer_literal;
        var i = start;
        while (std.ascii.isDigit(buffer[i])) i += 1;
        if (buffer[i] == '.') {
            i += 1;
            while (std.ascii.isDigit(buffer[i])) i += 1;
            tag = .float_literal;
        }
        if ((buffer[i] | 0x20) == 'e' and (std.ascii.isDigit(buffer[i + 1]) or
            ((buffer[i + 1] == '+' or buffer[i + 1] == '-') and std.ascii.isDigit(buffer[i + 2]))))
        {
            i += 2;
            while (std.ascii.isDigit(buffer[i])) i += 1;
            tag = .float_literal;
        }
        while (isIdChar(buffer[i])) {
            tag = .invalid;
            i += 1;
        }
        return self.finish(start, i - start, tag);
    }

    /// `$name`, `@name`, `:name`, `#name`, including the Tcl forms `a::b` and `a(b)`.
    fn variable(self: *Tokenizer, start: usize) Token {
        const buffer = self.buffer;
        var tag: Token.Tag = .variable;
        var name_len: usize = 0;
        var i = start + 1;
        while (buffer[i] != 0) : (i += 1) {
            const c = buffer[i];
            if (isIdChar(c)) {
                name_len += 1;
            } else if (c == '(' and name_len > 0) {
                i += 1;
                while (buffer[i] != 0 and !isSpace(buffer[i]) and buffer[i] != ')') i += 1;
                if (buffer[i] == ')') i += 1 else tag = .invalid;
                break;
            } else if (c == ':' and buffer[i + 1] == ':') {
                i += 1;
            } else break;
        }
        if (name_len == 0) tag = .invalid;
        return self.finish(start, i - start, tag);
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn isKeywordChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Bytes that can continue an identifier: `IdChar` in tokenize.c.
fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// The words of mkkeywordhash.c, in its spelling.
const mkkeywordhash_words = [_][]const u8{
    "ABORT",     "ACTION",    "ADD",          "AFTER",         "ALL",               "ALTER",       "ALWAYS",   "ANALYZE",    "AND",
    "AS",        "ASC",       "ATTACH",       "AUTOINCREMENT", "BEFORE",            "BEGIN",       "BETWEEN",  "BY",         "CASCADE",
    "CASE",      "CAST",      "CHECK",        "COLLATE",       "COLUMN",            "COMMIT",      "CONFLICT", "CONSTRAINT", "CREATE",
    "CROSS",     "CURRENT",   "CURRENT_DATE", "CURRENT_TIME",  "CURRENT_TIMESTAMP", "DATABASE",    "DEFAULT",  "DEFERRED",   "DEFERRABLE",
    "DELETE",    "DESC",      "DETACH",       "DISTINCT",      "DO",                "DROP",        "END",      "EACH",       "ELSE",
    "ESCAPE",    "EXCEPT",    "EXCLUSIVE",    "EXCLUDE",       "EXISTS",            "EXPLAIN",     "FAIL",     "FILTER",     "FIRST",
    "FOLLOWING", "FOR",       "FOREIGN",      "FROM",          "FULL",              "GENERATED",   "GLOB",     "GROUP",      "GROUPS",
    "HAVING",    "IF",        "IGNORE",       "IMMEDIATE",     "IN",                "INDEX",       "INDEXED",  "INITIALLY",  "INNER",
    "INSERT",    "INSTEAD",   "INTERSECT",    "INTO",          "IS",                "ISNULL",      "JOIN",     "KEY",        "LAST",
    "LEFT",      "LIKE",      "LIMIT",        "MATCH",         "MATERIALIZED",      "NATURAL",     "NO",       "NOT",        "NOTHING",
    "NOTNULL",   "NULL",      "NULLS",        "OF",            "OFFSET",            "ON",          "OR",       "ORDER",      "OTHERS",
    "OUTER",     "OVER",      "PARTITION",    "PLAN",          "PRAGMA",            "PRECEDING",   "PRIMARY",  "QUERY",      "RAISE",
    "RANGE",     "RECURSIVE", "REFERENCES",   "REGEXP",        "REINDEX",           "RELEASE",     "RENAME",   "REPLACE",    "RESTRICT",
    "RETURNING", "RIGHT",     "ROLLBACK",     "ROW",           "ROWS",              "SAVEPOINT",   "SELECT",   "SET",        "TABLE",
    "TEMP",      "TEMPORARY", "THEN",         "TIES",          "TO",                "TRANSACTION", "TRIGGER",  "UNBOUNDED",  "UNION",
    "UNIQUE",    "UPDATE",    "USING",        "VACUUM",        "VALUES",            "VIEW",        "VIRTUAL",  "WHEN",       "WHERE",
    "WINDOW",    "WITH",      "WITHOUT",
};

const Expected = struct { Token.Tag, []const u8 };

/// Checks the tags and the source text under each `loc`, then `eof` at the end.
fn expectTokens(source: [:0]const u8, expected: []const Expected) !void {
    var tokenizer: Tokenizer = .init(source);
    var previous_end: usize = 0;
    for (expected) |entry| {
        const token = tokenizer.next();
        try std.testing.expectEqual(entry[0], token.tag);
        try std.testing.expectEqualStrings(entry[1], source[token.loc.start..token.loc.end]);
        try std.testing.expect(token.loc.start >= previous_end);
        previous_end = token.loc.end;
    }
    const last = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last.tag);
    try std.testing.expectEqual(source.len, last.loc.start);
    try std.testing.expectEqual(source.len, last.loc.end);
}

fn expectOne(source: [:0]const u8, tag: Token.Tag) !void {
    try expectTokens(source, &.{.{ tag, source }});
}

test "keyword map has exactly the words of mkkeywordhash.c" {
    try std.testing.expectEqual(@as(usize, 147), mkkeywordhash_words.len);
    try std.testing.expectEqual(mkkeywordhash_words.len, keywords.kvs.len);
    for (mkkeywordhash_words) |word| {
        var buffer: [longest_keyword]u8 = undefined;
        try std.testing.expect(keywords.has(std.ascii.lowerString(&buffer, word)));
    }
    for (keywords.keys()) |key| {
        var buffer: [longest_keyword]u8 = undefined;
        const upper = std.ascii.upperString(&buffer, key);
        for (mkkeywordhash_words) |word| {
            if (std.mem.eql(u8, word, upper)) break;
        } else return error.KeywordNotInMkkeywordhash;
    }
}

const CaseStyle = enum { upper, lower, upper_first, lower_first };

fn withCase(buffer: *[32:0]u8, word: []const u8, style: CaseStyle) [:0]const u8 {
    for (word, 0..) |c, i| {
        buffer[i] = switch (style) {
            .upper => std.ascii.toUpper(c),
            .lower => std.ascii.toLower(c),
            .upper_first => if (i % 2 == 0) std.ascii.toUpper(c) else std.ascii.toLower(c),
            .lower_first => if (i % 2 == 0) std.ascii.toLower(c) else std.ascii.toUpper(c),
        };
    }
    buffer[word.len] = 0;
    return buffer[0..word.len :0];
}

/// Words whose tag is not `keyword_` plus the word, written down by hand.
const renamed_keywords = [_]struct { []const u8, Token.Tag }{
    .{ "autoincrement", .keyword_autoincr },
    .{ "column", .keyword_columnkw },
    .{ "temporary", .keyword_temp },
    .{ "glob", .keyword_like_kw },
    .{ "like", .keyword_like_kw },
    .{ "regexp", .keyword_like_kw },
    .{ "current_date", .keyword_ctime_kw },
    .{ "current_time", .keyword_ctime_kw },
    .{ "current_timestamp", .keyword_ctime_kw },
    .{ "cross", .keyword_join_kw },
    .{ "full", .keyword_join_kw },
    .{ "inner", .keyword_join_kw },
    .{ "left", .keyword_join_kw },
    .{ "natural", .keyword_join_kw },
    .{ "outer", .keyword_join_kw },
    .{ "right", .keyword_join_kw },
};

fn expectedKeywordTag(lower: []const u8) !Token.Tag {
    for (renamed_keywords) |entry| {
        if (std.mem.eql(u8, entry[0], lower)) return entry[1];
    }
    var name_buffer: [48]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "keyword_{s}", .{lower});
    return std.meta.stringToEnum(Token.Tag, name) orelse error.NoTagForKeyword;
}

fn isSharedTag(tag: Token.Tag) bool {
    return switch (tag) {
        .keyword_temp, .keyword_like_kw, .keyword_ctime_kw, .keyword_join_kw => true,
        else => false,
    };
}

test "every keyword tokenizes to its tag in every letter case" {
    for (mkkeywordhash_words) |word| {
        var lower_buffer: [longest_keyword]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buffer, word);
        const tag = try expectedKeywordTag(lower);
        for (std.enums.values(CaseStyle)) |style| {
            var buffer: [32:0]u8 = @splat(0);
            const source = withCase(&buffer, word, style);
            try expectTokens(source, &.{.{ tag, source }});
        }
        if (isSharedTag(tag)) {
            try std.testing.expectEqual(@as(?[]const u8, null), tag.lexeme());
            try std.testing.expectEqualStrings(@tagName(tag), tag.symbol());
        } else {
            try std.testing.expectEqualStrings(lower, tag.lexeme().?);
            try std.testing.expectEqualStrings(lower, tag.symbol());
        }
    }
}

test "WINDOW, OVER and FILTER are keywords here" {
    try expectTokens("window over filter", &.{
        .{ .keyword_window, "window" },
        .{ .keyword_over, "over" },
        .{ .keyword_filter, "filter" },
    });
}

test "keyword and identifier boundary" {
    try expectOne("selectx", .identifier);
    try expectOne("select1", .identifier);
    try expectOne("select$", .identifier);
    try expectOne("select\u{e9}", .identifier);
    try expectOne("select_", .identifier);
    try expectOne("current_datex", .identifier);
    try expectOne("_select", .identifier);
    try expectOne("selec", .identifier);
    try expectOne("x", .identifier);
    try expectOne("xor", .identifier);
    try expectOne("x1", .identifier);
    try expectTokens("select.", &.{ .{ .keyword_select, "select" }, .{ .dot, "." } });
    try expectTokens("select(", &.{ .{ .keyword_select, "select" }, .{ .l_paren, "(" } });
}

test "whitespace" {
    try expectTokens("", &.{});
    try expectTokens(" \t\n\x0c\r ", &.{});
    try expectTokens("  \t\n\x0c\r a", &.{.{ .identifier, "a" }});
    try expectTokens("\xef\xbb\xbfa", &.{.{ .identifier, "a" }});
    try expectTokens("a \xef\xbb\xbf b", &.{ .{ .identifier, "a" }, .{ .identifier, "b" } });
    try expectTokens("a;\xef\xbb\xbfb", &.{ .{ .identifier, "a" }, .{ .semicolon, ";" }, .{ .identifier, "b" } });
    try expectTokens("\xef\xbb\xbf\xef\xbb\xbf", &.{});
}

test "vertical tab starts an invalid token but continues a space run" {
    try expectOne("\x0b", .invalid);
    try expectTokens(" \x0b a", &.{.{ .identifier, "a" }});
}

test "a partial BOM is an identifier" {
    try expectOne("\xef", .identifier);
    try expectOne("\xef\xbb", .identifier);
    try expectOne("\xef\xbbx", .identifier);
}

test "NUL ends the input" {
    var tokenizer: Tokenizer = .init("a\x00b");
    try std.testing.expectEqual(Token.Tag.identifier, tokenizer.next().tag);
    for (0..2) |_| {
        const token = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.eof, token.tag);
        try std.testing.expectEqual(@as(usize, 1), token.loc.start);
        try std.testing.expectEqual(@as(usize, 1), token.loc.end);
    }
    tokenizer = .init("\x00");
    try std.testing.expectEqual(@as(usize, 0), tokenizer.next().loc.start);
}

test "line comments" {
    try expectTokens("a--x\nb", &.{ .{ .identifier, "a" }, .{ .identifier, "b" } });
    try expectTokens("a--x", &.{.{ .identifier, "a" }});
    try expectTokens("--", &.{});
    try expectTokens("-- a\r\n-- b\n", &.{});
    try expectTokens("a-->b\nc", &.{ .{ .identifier, "a" }, .{ .identifier, "c" } });
}

test "block comments" {
    try expectTokens("a/*x*/b", &.{ .{ .identifier, "a" }, .{ .identifier, "b" } });
    try expectTokens("/**/b", &.{.{ .identifier, "b" }});
    try expectTokens("/***/b", &.{.{ .identifier, "b" }});
    try expectTokens("/* a * / b */c", &.{.{ .identifier, "c" }});
    try expectTokens("a/*x", &.{.{ .identifier, "a" }});
    try expectTokens("/*/", &.{});
    try expectTokens("/*x*", &.{});
    try expectTokens("/* \n\n", &.{});
}

test "slash and star when a block comment cannot start" {
    try expectTokens("/*", &.{ .{ .slash, "/" }, .{ .star, "*" } });
    try expectTokens("a/*", &.{ .{ .identifier, "a" }, .{ .slash, "/" }, .{ .star, "*" } });
    try expectTokens("/ *", &.{ .{ .slash, "/" }, .{ .star, "*" } });
    try expectTokens("/", &.{.{ .slash, "/" }});
    try expectTokens("*/", &.{ .{ .star, "*" }, .{ .slash, "/" } });
}

test "identifiers" {
    try expectOne("abc", .identifier);
    try expectOne("_a", .identifier);
    try expectOne("a_1", .identifier);
    try expectOne("a$b", .identifier);
    try expectOne("a$", .identifier);
    try expectOne("\xc3\xa9", .identifier);
    try expectOne("a\xc3\xa9b", .identifier);
    try expectOne("\x80", .identifier);
    try expectOne("\xff", .identifier);
    try expectTokens("a.b", &.{ .{ .identifier, "a" }, .{ .dot, "." }, .{ .identifier, "b" } });
}

test "quoted identifiers" {
    try expectOne("\"abc\"", .identifier);
    try expectOne("\"a\"\"b\"", .identifier);
    try expectOne("\"\"", .identifier);
    try expectOne("`abc`", .identifier);
    try expectOne("`a``b`", .identifier);
    try expectOne("[abc]", .identifier);
    try expectOne("[]", .identifier);
    try expectOne("[a\"'`b]", .identifier);
    try expectTokens("[a]b]", &.{ .{ .identifier, "[a]" }, .{ .identifier, "b" }, .{ .invalid, "]" } });
    try expectTokens("\"a\" \"b\"", &.{ .{ .identifier, "\"a\"" }, .{ .identifier, "\"b\"" } });
}

test "unterminated quotes are invalid up to the end of input" {
    try expectOne("\"abc", .invalid);
    try expectOne("`abc", .invalid);
    try expectOne("[abc", .invalid);
    try expectOne("'abc", .invalid);
    try expectOne("\"", .invalid);
    try expectOne("[", .invalid);
    try expectOne("'", .invalid);
    try expectOne("\"a\"\"", .invalid);
    try expectOne("'a''", .invalid);
    try expectTokens("x \"abc", &.{ .{ .identifier, "x" }, .{ .invalid, "\"abc" } });
}

test "strings" {
    try expectOne("'abc'", .string_literal);
    try expectOne("''", .string_literal);
    try expectOne("'a''b'", .string_literal);
    try expectOne("''''", .string_literal);
    try expectOne("'a\"b`c'", .string_literal);
    try expectOne("'a\nb'", .string_literal);
    try expectTokens("'a' 'b'", &.{ .{ .string_literal, "'a'" }, .{ .string_literal, "'b'" } });
}

test "blobs" {
    try expectOne("x'AB'", .blob_literal);
    try expectOne("X'ab01'", .blob_literal);
    try expectOne("x''", .blob_literal);
    try expectTokens("x'AB'c", &.{ .{ .blob_literal, "x'AB'" }, .{ .identifier, "c" } });
}

test "bad blobs are invalid" {
    try expectOne("x'A'", .invalid);
    try expectOne("x'ABC'", .invalid);
    try expectOne("x'G'", .invalid);
    try expectOne("x'AB", .invalid);
    try expectOne("x'ABG", .invalid);
    try expectOne("x'A", .invalid);
    try expectOne("x'", .invalid);
    try expectOne("x'AG12", .invalid);
    try expectTokens("x'AG' 1", &.{ .{ .invalid, "x'AG'" }, .{ .integer_literal, "1" } });
    try expectTokens("x'A'b", &.{ .{ .invalid, "x'A'" }, .{ .identifier, "b" } });
}

test "integers" {
    try expectOne("0", .integer_literal);
    try expectOne("123", .integer_literal);
    try expectOne("0x1F", .integer_literal);
    try expectOne("0X1f", .integer_literal);
    try expectOne("0x0", .integer_literal);
    // The hex branch of tokenize.c returns before the IdChar check.
    try expectTokens("0x1g", &.{ .{ .integer_literal, "0x1" }, .{ .identifier, "g" } });
    try expectTokens("1,2", &.{ .{ .integer_literal, "1" }, .{ .comma, "," }, .{ .integer_literal, "2" } });
}

test "floats" {
    try expectOne("1.", .float_literal);
    try expectOne(".5", .float_literal);
    try expectOne("1.5", .float_literal);
    try expectOne("1.5e10", .float_literal);
    try expectOne("1e-3", .float_literal);
    try expectOne("1E+3", .float_literal);
    try expectOne("1e3", .float_literal);
    try expectOne("1.e3", .float_literal);
    try expectOne(".5E2", .float_literal);
    try expectTokens("1..2", &.{ .{ .float_literal, "1." }, .{ .float_literal, ".2" } });
    try expectTokens("a.1", &.{ .{ .identifier, "a" }, .{ .float_literal, ".1" } });
    try expectTokens(".e1", &.{ .{ .dot, "." }, .{ .identifier, "e1" } });
}

test "a number followed by IdChars is one invalid token" {
    try expectOne("0x", .invalid);
    try expectOne("0xg", .invalid);
    try expectOne("123abc", .invalid);
    try expectOne("1.5x", .invalid);
    try expectOne("1ex", .invalid);
    try expectOne("1e", .invalid);
    try expectOne("1_0", .invalid);
    try expectOne("1$", .invalid);
    try expectOne("1\xc3\xa9", .invalid);
    try expectOne("1.a", .invalid);
    try expectOne("1.5e3x", .invalid);
    try expectTokens("1e+", &.{ .{ .invalid, "1e" }, .{ .plus, "+" } });
    try expectTokens("1e-", &.{ .{ .invalid, "1e" }, .{ .minus, "-" } });
    try expectTokens("12abc 3", &.{ .{ .invalid, "12abc" }, .{ .integer_literal, "3" } });
}

test "question mark variables" {
    try expectOne("?", .variable);
    try expectOne("?12", .variable);
    try expectTokens("?a", &.{ .{ .variable, "?" }, .{ .identifier, "a" } });
    try expectTokens("?1a", &.{ .{ .variable, "?1" }, .{ .identifier, "a" } });
    try expectTokens("??", &.{ .{ .variable, "?" }, .{ .variable, "?" } });
}

test "named variables" {
    try expectOne(":a", .variable);
    try expectOne("@a", .variable);
    try expectOne("$a", .variable);
    try expectOne("#a", .variable);
    try expectOne(":a1_$", .variable);
    try expectOne(":\xc3\xa9", .variable);
    try expectOne("$a::b", .variable);
    try expectOne("$a::b(c)", .variable);
    try expectOne("$a(b)", .variable);
    try expectOne("$a()", .variable);
    try expectOne("$a::", .variable);
    try expectOne("$::a", .variable);
    try expectTokens("$a:b", &.{ .{ .variable, "$a" }, .{ .variable, ":b" } });
}

test "bad variables are invalid" {
    try expectOne(":", .invalid);
    try expectOne("@", .invalid);
    try expectOne("#", .invalid);
    try expectOne("$", .invalid);
    try expectOne("$::", .invalid);
    try expectOne("$a(", .invalid);
    try expectOne("$a(b", .invalid);
    try expectTokens("$a(b c)", &.{ .{ .invalid, "$a(b" }, .{ .identifier, "c" }, .{ .r_paren, ")" } });
    try expectTokens("$(a)", &.{ .{ .invalid, "$" }, .{ .l_paren, "(" }, .{ .identifier, "a" }, .{ .r_paren, ")" } });
    try expectTokens(": a", &.{ .{ .invalid, ":" }, .{ .identifier, "a" } });
}

test "operators" {
    try expectTokens("- + * / % = == < <= << <> != > >= >> , & ~ | || . -> ->> ( ) ;", &.{
        .{ .minus, "-" },
        .{ .plus, "+" },
        .{ .star, "*" },
        .{ .slash, "/" },
        .{ .percent, "%" },
        .{ .equal, "=" },
        .{ .equal_equal, "==" },
        .{ .l_angle_bracket, "<" },
        .{ .angle_bracket_left_equal, "<=" },
        .{ .angle_bracket_left_angle_bracket_left, "<<" },
        .{ .not_equal, "<>" },
        .{ .not_equal, "!=" },
        .{ .r_angle_bracket, ">" },
        .{ .angle_bracket_right_equal, ">=" },
        .{ .angle_bracket_right_angle_bracket_right, ">>" },
        .{ .comma, "," },
        .{ .ampersand, "&" },
        .{ .tilde, "~" },
        .{ .pipe, "|" },
        .{ .pipe_pipe, "||" },
        .{ .dot, "." },
        .{ .arrow, "->" },
        .{ .arrow2, "->>" },
        .{ .l_paren, "(" },
        .{ .r_paren, ")" },
        .{ .semicolon, ";" },
    });
}

test "operators next to each other" {
    try expectTokens("===", &.{ .{ .equal_equal, "==" }, .{ .equal, "=" } });
    try expectTokens("=>", &.{ .{ .equal, "=" }, .{ .r_angle_bracket, ">" } });
    try expectTokens("<<=", &.{ .{ .angle_bracket_left_angle_bracket_left, "<<" }, .{ .equal, "=" } });
    try expectTokens(">>=", &.{ .{ .angle_bracket_right_angle_bracket_right, ">>" }, .{ .equal, "=" } });
    try expectTokens("|||", &.{ .{ .pipe_pipe, "||" }, .{ .pipe, "|" } });
    try expectTokens("->>>", &.{ .{ .arrow2, "->>" }, .{ .r_angle_bracket, ">" } });
    try expectTokens("a->b", &.{ .{ .identifier, "a" }, .{ .arrow, "->" }, .{ .identifier, "b" } });
    try expectTokens("a->>b", &.{ .{ .identifier, "a" }, .{ .arrow2, "->>" }, .{ .identifier, "b" } });
    try expectTokens("- -", &.{ .{ .minus, "-" }, .{ .minus, "-" } });
    try expectTokens("- >", &.{ .{ .minus, "-" }, .{ .r_angle_bracket, ">" } });
    try expectTokens("a-", &.{ .{ .identifier, "a" }, .{ .minus, "-" } });
    try expectTokens("<>=", &.{ .{ .not_equal, "<>" }, .{ .equal, "=" } });
}

test "illegal bytes are one-byte invalid tokens" {
    try expectOne("!", .invalid);
    try expectOne("^", .invalid);
    try expectOne("\\", .invalid);
    try expectOne("\x01", .invalid);
    try expectOne("\x7f", .invalid);
    try expectOne("{", .invalid);
    try expectOne("}", .invalid);
    try expectOne("]", .invalid);
    try expectTokens("!!=", &.{ .{ .invalid, "!" }, .{ .not_equal, "!=" } });
    try expectTokens("a!b", &.{ .{ .identifier, "a" }, .{ .invalid, "!" }, .{ .identifier, "b" } });
    try expectTokens("^^", &.{ .{ .invalid, "^" }, .{ .invalid, "^" } });
}

test "a statement with exact locations" {
    var tokenizer: Tokenizer = .init("SELECT x'0F', 1.5 -- c\n;");
    const expected = [_]Token{
        .{ .tag = .keyword_select, .loc = .{ .start = 0, .end = 6 } },
        .{ .tag = .blob_literal, .loc = .{ .start = 7, .end = 12 } },
        .{ .tag = .comma, .loc = .{ .start = 12, .end = 13 } },
        .{ .tag = .float_literal, .loc = .{ .start = 14, .end = 17 } },
        .{ .tag = .semicolon, .loc = .{ .start = 23, .end = 24 } },
        .{ .tag = .eof, .loc = .{ .start = 24, .end = 24 } },
    };
    for (expected) |token| {
        try std.testing.expectEqualDeep(token, tokenizer.next());
    }
}
