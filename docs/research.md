# Research: a SQLite SQL parser in Zig

This is the reference brief for everyone working on this repository, human or agent.
Read it before writing code. It records what we are building, which SQLite we match,
how the SQLite grammar works, the rules our tokenizer and parser must follow, how we
prove that they do, and the Zig style we follow.

## 1. Goal

A front end for SQLite's dialect of SQL, written in Zig: a tokenizer and a parser that
turn SQL text into an abstract syntax tree (AST), and report syntax errors with a byte
offset, a line, a column, and SQLite's own message. A small CLI, `sqlcheck`, checks files.

"Correct" has one meaning here: **for any input, our parser accepts it exactly when
SQLite's parser accepts it, and when both reject it, we blame the same token with the
same message.** The oracle is a real SQLite library, called from the tests.

Out of scope: name resolution (no such table, no such column), type checking, query
planning, execution, error recovery after the first error (SQLite stops at the first
error, and so do we), and SQLite compile-time variants other than the one below.

## 2. Which SQLite we match

**SQLite 3.45.1, as built by Ubuntu 24.04 (package `libsqlite3-0`, `libsqlite3-dev`).**

Why this one:

- It is the system SQLite on both our development container and GitHub's `ubuntu-24.04`
  runners, so the oracle is identical locally and in CI without downloading or
  compiling third-party code. The test build links it with `-lsqlite3`.
- Its compile options matter for the grammar. Ubuntu builds it with
  `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`, so `UPDATE ... ORDER BY ... LIMIT` and
  `DELETE ... ORDER BY ... LIMIT` are valid. Window functions, CTEs, UPSERT, RETURNING,
  generated columns, virtual tables, triggers, views, ATTACH and EXPLAIN are all
  compiled in. Run `PRAGMA compile_options` to see the full list.
- A test asserts `sqlite3_libversion() == "3.45.1"`, so a silent upgrade of the oracle
  fails loudly instead of shifting the target.

The SQLite sources for that version are copied into `docs/sqlite-3.45.1/` (SQLite is
public domain): `parse.y` (the grammar), `tokenize.c` (the tokenizer and the driver
loop), `mkkeywordhash.c` (the keyword table), and `complete.c` (`sqlite3_complete`,
which finds statement boundaries). They come from tag `version-3.45.1` of
https://github.com/sqlite/sqlite. **When this brief and those files disagree, the files
win.** Cite the line you relied on in code comments where a rule is surprising.

Differences in later SQLite versions we deliberately do not follow: digit separators
in numbers (`1_000`, 3.46), `WITHIN GROUP` ordered-set aggregates, `RAISE(ABORT, expr)`
with a general expression (3.45 takes a name: `RAISE(ABORT, 'msg')`), and the newer
`ALTER TABLE ... ALTER COLUMN / ADD CHECK / DROP CONSTRAINT` forms.

## 3. How SQLite parses

`sqlite3RunParser` (tokenize.c) runs a loop: get the next token, skip spaces and
comments, and feed the token to a Lemon-generated LALR(1) parser. Things that matter for
an equivalent hand-written parser:

1. **Statements.** The input is `cmdlist ::= cmdlist ecmd | ecmd`, with
   `ecmd ::= SEMI | cmdx SEMI | explain cmdx SEMI`. Empty statements (`;;`) are fine.
   At end of input the driver feeds one synthetic `SEMI` (unless the last token was a
   `SEMI`), then end-of-input. So `SELECT 1` without a semicolon is valid, and an input
   that is only spaces and comments is valid.
2. **First error stops everything.** There is no error recovery
   (`YYNOERRORRECOVERY`). The error is raised at the first token that cannot extend a
   valid prefix. An LR parser never consumes a token past that point, so a correct
   recursive-descent parser blames the same token.
3. **Error messages.** A token that cannot be shifted gives `near "<token text>":
   syntax error`. If that token is the synthetic end-of-input (input ended too early),
   the message is `incomplete input`. A bad token from the tokenizer gives
   `unrecognized token: "<text>"` and stops before the parser sees it.
4. **Keywords as identifiers (`%fallback ID`).** Many keywords fall back to `ID` when
   the grammar has no action for the keyword itself in the current state. The fallback
   list (parse.y, `%fallback ID`) is: ABORT ACTION AFTER ANALYZE ASC ATTACH BEFORE BEGIN
   BY CASCADE CAST COLUMN CONFLICT DATABASE DEFERRED DESC DETACH DO EACH END EXCLUSIVE
   EXPLAIN FAIL FOR IGNORE IMMEDIATE INITIALLY INSTEAD LIKE/GLOB/REGEXP MATCH NO PLAN
   QUERY KEY OF OFFSET PRAGMA RAISE RECURSIVE RELEASE REPLACE RESTRICT ROW ROWS ROLLBACK
   SAVEPOINT TEMP TRIGGER VACUUM VIEW VIRTUAL WITH WITHOUT NULLS FIRST LAST CURRENT
   FOLLOWING PARTITION PRECEDING RANGE UNBOUNDED EXCLUDE GROUPS OTHERS TIES GENERATED
   ALWAYS MATERIALIZED REINDEX RENAME CURRENT_DATE/CURRENT_TIME/CURRENT_TIMESTAMP IF.
   Keywords **not** on the list (SELECT, FROM, WHERE, TABLE, ORDER, GROUP, NULL, ...)
   are never identifiers unless quoted. The subtle part: a fallback keyword is only an
   identifier when the keyword has no meaning of its own at that point. Example:
   `SELECT 1 FROM t ORDER BY x DESC` (DESC is a keyword) versus `SELECT desc FROM t`
   (DESC is a column). In a recursive-descent parser, model this as: "where the grammar
   expects a name, accept `identifier` or any fallback keyword, unless a rule that
   applies here starts with that keyword". The differential tests find the cases
   where that rule is not enough.
5. **Token classes.** `id ::= ID | INDEXED`, `ids ::= ID | STRING`,
   `idj ::= ID | INDEXED | JOIN_KW` (JOIN_KW is CROSS, FULL, INNER, LEFT, NATURAL,
   OUTER, RIGHT), and `nm ::= idj | STRING`. So a table or column name may be a
   single-quoted string (`CREATE TABLE 'abc'(x)`), and `left` is a valid column name.
   Each rule says which class it uses; do not merge them.
6. **Context-sensitive WINDOW, OVER, FILTER** (tokenize.c `analyze*Keyword`). These are
   keywords only in context; otherwise they become `ID`:
   - `WINDOW` is a keyword if the next token is an identifier (or fallback keyword) and
     the one after that is `AS`.
   - `OVER` is a keyword if the previous token was `)` and the next is `(` or an
     identifier.
   - `FILTER` is a keyword if the previous token was `)` and the next is `(`.
7. **`%wildcard ANY`.** Only used in `CREATE VIRTUAL TABLE t USING m(args)`: the module
   arguments are any tokens with balanced parentheses, split on top-level commas.
8. **Errors raised by grammar actions.** Some rules are accepted by the grammar and then
   rejected by the rule's C action. We treat these as syntax errors, because SQLite
   raises them while parsing and they depend only on the text:
   - `unknown table option: X` (table options other than `WITHOUT ROWID` and `STRICT`)
   - `unknown join type: X` (join keyword combinations `sqlite3JoinType` rejects; valid
     ones are NATURAL? with LEFT/RIGHT/FULL [OUTER], INNER, CROSS, and plain JOIN;
     check select.c's `sqlite3JoinType` behavior with the oracle)
   - `ORDER BY clause should come after UNION not before` (and the LIMIT and other
     compound operator variants)
   - `syntax error after column name "x"` (COLLATE, ASC or DESC in the column list of a
     CREATE VIEW or a CTE)
   - `qualified table names are not allowed on INSERT, UPDATE, and DELETE statements
     within triggers`
   - `the INDEXED BY clause is not allowed on UPDATE or DELETE statements within
     triggers`, and the same for `NOT INDEXED`
   - `near "#1": syntax error` for `#NNN` register variables outside nested parses
   Everything else an action raises (duplicate column name, more than one primary key,
   non-constant default, ...) is semantic and out of scope: we accept those inputs.

## 4. Tokenizer rules (tokenize.c, `sqlite3GetToken`)

- **Whitespace:** space, `\t`, `\n`, `\f`, `\r`. A UTF-8 BOM (EF BB BF) anywhere counts
  as whitespace. A NUL byte ends the input.
- **Comments:** `-- ...` to end of line. `/* ... */`; an unterminated block comment
  runs to end of input and is not an error. `/` followed by `*` and then end of input is
  `/` (SLASH).
- **Identifiers:** start with a letter, `_`, or any byte >= 0x80; continue with letters,
  digits, `_`, `$`, or bytes >= 0x80 (`IdChar`). Quoted: `"..."`, `` `...` `` (doubled
  quote escapes itself), `[...]` (no escapes). An unterminated quote is an
  `unrecognized token`. Note: `"abc"` is always an identifier token to the parser; SQLite
  only later may treat it as a string.
- **Keywords:** the 147 words in mkkeywordhash.c, matched case-insensitively (ASCII only).
  A word is only a keyword if every character is a letter or `_`... see `CC_KYWD0`: a
  keyword candidate made of keyword characters followed by an IdChar is an identifier.
  Several words share a token: `TEMP`/`TEMPORARY`; `GLOB`/`LIKE`/`REGEXP` are LIKE_KW;
  `CURRENT_DATE`/`CURRENT_TIME`/`CURRENT_TIMESTAMP` are CTIME_KW; the seven join words
  are JOIN_KW.
- **Strings:** `'...'` with `''` as the escape. Unterminated: `unrecognized token`.
- **Blobs:** `x'...'` or `X'...'` with an even number of hex digits; anything else up to
  the closing quote is an `unrecognized token`.
- **Numbers:** decimal integers, `0x` hex integers (needs at least one hex digit), floats
  (`1.`, `.5`, `1.5e10`, `1e-3`; an `e` not followed by digits ends the number). A number
  immediately followed by an IdChar (`123abc`, `1.5x`, `0x1g`) is one `unrecognized
  token` that extends over the IdChars.
- **Variables:** `?` followed by optional digits; `:name`, `@name`, `$name`, `#name`
  (`$` also takes Tcl-style `::` and a `(...)` suffix, see `CC_DOLLAR`). A prefix with no
  name (`:` alone) is an `unrecognized token`.
- **Operators:** `- ( ) ; + * / % = == < <= <> << > >= >> != , & ~ | || . -> ->>`.
  `!` alone is illegal. Any other byte (for example `^`, `\`, control characters) is an
  `unrecognized token` of one byte.

## 5. Grammar overview (parse.y)

Every statement form, by family. The grammar file is the authority for details.

- **Transactions:** `BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION [name]]`,
  `COMMIT|END [TRANSACTION [name]]`, `ROLLBACK [TRANSACTION [name]] [TO [SAVEPOINT] name]`,
  `SAVEPOINT name`, `RELEASE [SAVEPOINT] name`.
- **SELECT:** `[WITH [RECURSIVE] cte, ...]` then one or more `oneselect` joined by
  `UNION [ALL] | INTERSECT | EXCEPT`, then `ORDER BY` and `LIMIT` (LIMIT x [OFFSET y |
  , y]). `oneselect` is `SELECT [DISTINCT|ALL] result-columns [FROM ...] [WHERE ...]
  [GROUP BY ... [HAVING ...]] [WINDOW ...] [ORDER BY ...] [LIMIT ...]` or
  `VALUES (...), (...)`. Note that HAVING without GROUP BY is accepted by the grammar
  (`having_opt` is independent). FROM takes table names with optional schema, alias,
  `INDEXED BY` / `NOT INDEXED`, table-valued functions `f(args)`, subqueries, and
  parenthesized join lists, joined by `,` or join operators, each with `ON expr` or
  `USING (cols)`. CTEs take `AS [NOT] MATERIALIZED`.
- **INSERT / REPLACE:** `[WITH ...] INSERT [OR conflict] INTO name [AS alias] [(cols)]
  (select | DEFAULT VALUES) [upsert...] [RETURNING ...]`. Upsert clauses chain: `ON
  CONFLICT [(cols) [WHERE]] DO NOTHING | DO UPDATE SET ... [WHERE]`, repeatable; only
  the last may omit the conflict target.
- **UPDATE:** `[WITH ...] UPDATE [OR conflict] name [AS alias] [INDEXED BY | NOT INDEXED]
  SET col = expr | (cols) = expr, ... [FROM ...] [WHERE ...] [RETURNING ...]
  [ORDER BY ...] [LIMIT ...]` (the last two because of UPDATE_DELETE_LIMIT).
- **DELETE:** `[WITH ...] DELETE FROM name [AS alias] [INDEXED BY | NOT INDEXED]
  [WHERE ...] [RETURNING ...] [ORDER BY ...] [LIMIT ...]`.
- **CREATE TABLE:** `CREATE [TEMP] TABLE [IF NOT EXISTS] [schema.]name ( columns
  [, constraints] ) [WITHOUT ROWID | STRICT, ...]` or `... AS select`. Column type is
  zero or more `ids` tokens with optional `(n)` or `(n, m)` of signed numbers. Column
  constraints: CONSTRAINT name, DEFAULT (term | (expr) | +term | -term | id), NULL,
  NOT NULL, PRIMARY KEY [ASC|DESC] [conflict] [AUTOINCREMENT], UNIQUE, CHECK, REFERENCES,
  DEFERRABLE clauses, COLLATE, [GENERATED ALWAYS] AS (expr) [STORED|VIRTUAL]. Table
  constraints: PRIMARY KEY, UNIQUE, CHECK, FOREIGN KEY; commas between table
  constraints are optional (`tconscomma ::= COMMA | .`).
- **Other DDL:** CREATE [UNIQUE] INDEX ... ON t (indexed columns) [WHERE expr];
  CREATE [TEMP] VIEW [IF NOT EXISTS] name [(cols)] AS select; CREATE [TEMP] TRIGGER
  ... BEGIN (update|insert|delete|select ;)+ END (trigger bodies have their own
  restricted forms, see `trigger_cmd`); CREATE VIRTUAL TABLE ... USING module [(args)];
  DROP TABLE|VIEW|INDEX|TRIGGER [IF EXISTS] name; ALTER TABLE name RENAME TO new |
  RENAME [COLUMN] a TO b | ADD [COLUMN] coldef | DROP [COLUMN] name.
- **Utility:** `PRAGMA [schema.]name [= value | (value)]` (value: number with sign,
  name, `ON`, `DELETE`, `DEFAULT`), `ATTACH [DATABASE] expr AS expr [KEY expr]`,
  `DETACH [DATABASE] expr`, `VACUUM [name] [INTO expr]`, `REINDEX [name[.name]]`,
  `ANALYZE [name[.name]]`, `EXPLAIN [QUERY PLAN] statement`.
- **Expressions** (precedence low to high, from parse.y):
  `OR` < `AND` < `NOT` (prefix) < `IS MATCH LIKE BETWEEN IN ISNULL NOTNULL != =` <
  `< <= > >=` < `ESCAPE` (right) < `& | << >>` < `+ -` < `* / %` < `|| -> ->>` <
  `COLLATE` < `~` and unary `+ -` (prefix). All binary operators are left-associative
  except where noted. Primary forms: literals (NULL, numbers, strings, blobs,
  CURRENT_*), variables, names `a`, `a.b`, `a.b.c`, `(expr)`, row values `(a, b, ...)`,
  `CAST(expr AS type)`, `CASE [x] WHEN ... THEN ... [ELSE ...] END`, `EXISTS (select)`,
  `(select)`, function calls `f()`, `f(*)`, `f([DISTINCT|ALL] args [ORDER BY ...])`
  with optional `FILTER (WHERE expr)` and `OVER (window) | OVER name`, and
  `RAISE(IGNORE | ROLLBACK|ABORT|FAIL, name)`. Postfix and infix forms: `x [NOT] LIKE|
  GLOB|REGEXP|MATCH y [ESCAPE z]`, `x ISNULL`, `x NOTNULL`, `x NOT NULL`, `x IS [NOT]
  [DISTINCT FROM] y`, `x [NOT] BETWEEN y AND z`, `x [NOT] IN (list | select)`, `x [NOT]
  IN [schema.]table`, `x [NOT] IN [schema.]func(args)`, `x COLLATE name`. Windows:
  `[base] [PARTITION BY ...] [ORDER BY ...] [RANGE|ROWS|GROUPS frame [EXCLUDE ...]]`.
  Mind the Lemon precedence quirks: `NOT` binds looser than comparison (`NOT a = b` is
  `NOT (a = b)`), and `a BETWEEN b AND c AND d` takes the first AND as BETWEEN's.

## 6. How we prove it works

Tests are the product as much as the parser is. Five layers, all run by `zig build test`
and in CI:

1. **Unit tests** next to the code (`test` blocks in `src/*.zig`): for every grammar
   rule, at least one accepted input with its AST shape checked through the canonical
   rendering (see 5), and rejected inputs that check the error message, byte offset,
   line and column. Not just "it failed".
2. **Oracle self-tests** (`test/oracle.zig`): the oracle classifies known inputs
   correctly, and links SQLite 3.45.1.
3. **Corpus differential** (`test/differential.zig`): 31k SQL scripts extracted from
   SQLite's own test suite at tag version-3.45.1 (`test/corpus/sqlite-tests.sql`, built
   by `tools/extract_corpus.py`). Each script is split into statements the way SQLite
   splits them (`sqlite3_complete`), and each statement is checked by both SQLite and
   our parser. They must agree on accept/reject, and on rejection, on the message and
   byte offset. A statement the oracle cannot judge (a semantic error hid the rest of
   the statement from SQLite's parser, about 0.15% of statements) is counted and
   skipped. Any disagreement must be fixed or listed in `test/known_divergences.txt`
   with a reason; a listed case that starts agreeing is also a failure, so the list
   stays honest. While the parser is being built, the test only checks the statement
   families listed as implemented in `test/differential.zig`.
4. **Differential fuzzing:** a deterministic mutation fuzzer (fixed seed, runs in every
   CI build) takes corpus statements and applies token-level mutations (delete,
   duplicate, swap, replace with a keyword or operator, truncate) to make near-miss
   inputs, then compares our parser with SQLite as in 3. A `std.testing.fuzz` harness
   runs the same comparison open-ended with `zig build test --fuzz`.
5. **AST fidelity:** `Ast.render` writes a canonical SQL form (keywords upper case,
   every expression fully parenthesized). For every accepted statement: SQLite accepts
   the rendering, and parsing the rendering renders the same text again (idempotence).
   For constant expressions (`SELECT expr` with no FROM), SQLite evaluates the original
   and the rendering to the same result, which checks precedence and associativity
   against the real engine.

The oracle (`test/oracle/oracle.c`) uses only SQLite's public API. It prepares each
statement on a fresh in-memory database without running it (nothing touches the
filesystem; `ATTACH 'x.db'` is prepared, not executed). Error messages are classified
into syntax errors (section 3, item 8) and other errors. A non-syntax error counts as
"accepted" only when SQLite's parser reached the end of the statement before the error;
otherwise it creates a stand-in for the missing table, view, database or collation and
tries again (up to 8 times), and reports "unknown" if that does not help.

## 7. Zig style and standards

The reference is the Zig standard library's own SQL-shaped problem: Zig's parser,
`lib/std/zig/tokenizer.zig`, `lib/std/zig/Parse.zig` and `lib/std/zig/Ast.zig`
(https://codeberg.org/ziglang/zig; the same files ship with the compiler under
`lib/std/zig/` and are readable locally, see `zig env` for the lib dir). Follow their
architecture and the language reference's style guide:

- **Toolchain:** Zig 0.17.0 exactly (CI pins it; locally `pip install ziglang==0.17.0`
  gives `python3 -m ziglang`). Use its APIs: `pub fn main(init: std.process.Init) !void`,
  `std.Io.Writer` / `std.Io.File.Writer` for output, unmanaged containers
  (`std.ArrayList(T)` initialized with `.empty`, every call takes the allocator),
  `std.MultiArrayList` for token and node arrays, `std.testing.allocator` in tests (it
  fails on leaks), `std.testing.fuzz` with `*std.testing.Smith` for fuzz tests.
- **Formatting:** `zig fmt` is law; CI runs `zig fmt --check`. Four-space indent, aim
  for 100 columns, trailing commas in lists longer than two items so `zig fmt` puts one
  item per line.
- **Naming:** `TitleCase` for types and for files that are structs with fields
  (`Ast.zig`, `Parse.zig`); `snake_case` for namespace files (`tokenizer.zig`),
  variables, fields and constants; `camelCase` for functions. No redundant segments:
  `Token.Tag`, not `TokenType`; `Ast.Node.Tag`, not `AstNodeTag`. Avoid `Value`,
  `Data`, `Context`, `Manager`, `utils`, `misc` in type names.
- **Architecture (as in std.zig):** the tokenizer is a state machine over a
  sentinel-terminated slice (`[:0]const u8`) producing `Token{ .tag, .loc = .{ .start,
  .end } }`; keywords via `std.StaticStringMap`. `Ast.parse(gpa, source)` tokenizes
  everything first, then runs `Parse` over the token list and returns an `Ast` that owns
  `tokens`, `nodes`, `extra_data` and `errors`. A syntax error is data, not a Zig
  error: `parse` only fails with `error.OutOfMemory`. Node indices are `u32`-backed
  enums, not pointers. `Ast.deinit(gpa)` frees everything.
- **Errors:** an `Ast.Error` has a `tag` (an enum, one per message kind) and a `token`;
  `Ast.renderError` writes the SQLite message text; `Ast.errorLocation` gives line and
  column (both 1-based; column counts bytes, like SQLite's offsets).
- **Doc comments** (`///`, `//!`) on every public declaration, saying what it is for, not
  restating its type. Comments explain why, not what. Use "assert" for safety-checked
  invariants (`std.debug.assert`).
- **No hidden allocation and no globals:** functions that allocate take an
  `std.mem.Allocator`; clean up with `defer` / `errdefer`.
- **Recursion depth:** SQLite limits expression depth to 1000 (`SQLITE_MAX_EXPR_DEPTH`)
  and its parser stack to a fixed size; our parser must not overflow the native stack
  on deeply nested input. Track depth and report an error past a limit.
- **Never silence a check:** no skipped tests, no `catch unreachable` on fallible input
  paths, no `_ = err`. A test that cannot run fails with a message.
