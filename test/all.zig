//! Root of the tests that run against the real SQLite library.

test {
    _ = @import("corpus.zig");
    _ = @import("oracle.zig");
    _ = @import("oracle_corpus.zig");
}
