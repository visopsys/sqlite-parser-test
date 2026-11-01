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
zig build              # library (and, once it exists, the sqlcheck CLI)
zig build test         # unit tests, oracle tests, differential tests
zig fmt --check build.zig src test
```

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
