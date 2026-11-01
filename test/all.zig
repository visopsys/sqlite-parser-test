//! Root of the tests that run against the real SQLite library.

test {
    _ = @import("corpus.zig");
    _ = @import("differential.zig");
    _ = @import("eval_differential.zig");
    _ = @import("oracle.zig");
    _ = @import("oracle_corpus.zig");
    _ = @import("tokenizer_differential.zig");
}
