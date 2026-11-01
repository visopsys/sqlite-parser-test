# sqlite-parser-test

A front end for SQLite's dialect of SQL, written in Zig: a tokenizer and a parser that
accept exactly what SQLite accepts, build an AST, and report syntax errors the way SQLite
does (`near "WHERE": syntax error`, with the byte offset, line and column).

The target is **SQLite 3.45.1** as built by Ubuntu 24.04. The tests check our parser
against that real SQLite library on 71,780 statements from SQLite's own test suite, and
on mutated near-miss inputs. See [docs/research.md](docs/research.md) for the
specification, the verification layers, and the code style.

## Requirements

- Zig 0.17.0
- SQLite 3.45.1 development files, for the tests only: `sudo apt-get install
  libsqlite3-dev` on Ubuntu 24.04

## Build and test

```bash
zig build              # library, and the sqlcheck CLI installed as zig-out/bin/sqlcheck
zig build test         # unit tests, oracle tests, differential tests
zig fmt --check build.zig src test
```

## Usage

```bash
zig-out/bin/sqlcheck [FILE...]   # check each file
zig-out/bin/sqlcheck < in.sql    # no files: check standard input
```

Valid input prints nothing. Invalid input prints the first syntax error to stderr as
`<file>:<line>:<column>: error: <message>` (`<stdin>` for standard input), then the source
line and a caret line: `^` under the first byte of the offending token and `~` under the
rest of it. The column counts bytes. For example:

```
$ printf 'SELECT 1;\nSELECT a FROM FROM t;\n' | zig-out/bin/sqlcheck
<stdin>:2:15: error: near "FROM": syntax error
SELECT a FROM FROM t;
              ^~~~
```

Exit codes: `0` every input is valid, `1` at least one input has a syntax error, `2` a file
could not be read (`sqlcheck: <file>: <error>` on stderr). With several files, 2 wins over
1, and 1 over 0.

## API

The module `sqlite_parser` (root `src/root.zig`) exports `Ast` and `tokenizer`.

```zig
const std = @import("std");
const Ast = @import("sqlite_parser").Ast;

fn check(gpa: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var ast = try Ast.parse(gpa, "SELECT 1 FROM FROM t;");
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        const err = ast.errors[0];
        const loc = ast.errorLocation(err); // loc.byte_offset, loc.line, loc.column
        try writer.print("{d}:{d}: ", .{ loc.line, loc.column });
        try ast.renderError(err, writer); // near "FROM": syntax error
        return;
    }
    try ast.render(writer);
}
```

- `Ast.parse(gpa, source: [:0]const u8) error{OutOfMemory}!Ast` tokenizes and parses.
  Syntax errors are data in `ast.errors`, not Zig errors; parsing stops at the first one,
  as SQLite does, so `errors` holds at most one entry. The `Ast` does not own `source`;
  free it with `deinit(gpa)`.
- `renderError` writes SQLite's message (`near "X": syntax error`, `incomplete input`,
  `unrecognized token: "X"`, and the messages of the grammar-action errors).
- `errorLocation` returns the byte offset, the 1-based line and the 1-based byte column of
  the blamed token.
- `render` writes the canonical SQL form: keywords in upper case, every expression fully
  parenthesized, each statement followed by `;`. SQLite accepts the output, and parsing
  it and rendering again gives the same text.

## What correct means

For any input, our parser accepts it exactly when SQLite 3.45.1 (as built by Ubuntu 24.04)
accepts it. When both reject it, we report the same message and the same byte offset.
The judge is the real SQLite library, asked through the C oracle in `test/oracle/`.
Semantic errors (no such table, duplicate column) are out of scope. See
[docs/research.md](docs/research.md) sections 1 to 3.

## How verification works

`zig build test` runs everything; [docs/research.md](docs/research.md) section 6
describes the layers.

- Unit tests next to the code in `src/` cover grammar rules and error kinds. Accepted
  inputs are checked through the canonical rendering, rejected ones by message, offset,
  line and column.
- `test/differential.zig` compares our parser with the oracle on every statement of
  `test/corpus/sqlite-tests.sql`: same verdict, and for rejections the same message and
  offset. Disagreements that depend on something other than the text are listed with a
  reason in `test/known_divergences.txt`; the test fails on an unlisted disagreement and
  on a listed case that now agrees.
- The same file runs a deterministic token-level mutation fuzzer with a fixed seed, and
  `std.testing.fuzz` harnesses for open-ended fuzzing under `zig build test --fuzz`.
- Round-trip: SQLite accepts our rendering of every accepted statement, and rendering
  is idempotent. `test/eval_differential.zig` checks that SQLite evaluates constant
  expressions and their renderings to the same result, which tests precedence.
- `test/tokenizer_differential.zig` and `test/depth.zig` compare the tokenizer and the
  nesting limit with SQLite.
- The CLI tests in `build.zig` run the installed `sqlcheck` on fixtures in `test/cli/`
  and on standard input, and check the exit code and stderr (valid, multi-line, tab,
  caret position, missing file).

## Layout

```
src/                  the library (module `sqlite_parser`); Zig standard library only
test/oracle/          C oracle that asks the real SQLite whether SQL parses (tests only)
test/oracle.zig       Zig interface to the oracle, with its own tests
test/corpus/          SQL scripts extracted from SQLite's test suite
test/known_divergences.txt   accepted disagreements with SQLite, each with a reason
tools/extract_corpus.py      regenerates the corpus from a SQLite checkout
docs/research.md      the specification and verification plan
docs/sqlite-3.45.1/   SQLite's grammar and tokenizer sources (public domain)
```

## Regenerating the corpus

```bash
git clone --depth 1 --branch version-3.45.1 https://github.com/sqlite/sqlite /tmp/sqlite
tools/extract_corpus.py /tmp/sqlite test/corpus/sqlite-tests.sql
```

SQLite is in the public domain; the files under `docs/sqlite-3.45.1/` and the corpus
derived from its test suite keep that status.
