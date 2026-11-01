//! Checks that the oracle can judge nearly the whole corpus, so that the
//! differential tests built on it compare our parser on real evidence.

const std = @import("std");
const corpus = @import("corpus.zig");
const oracle = @import("oracle.zig");

const Counts = struct {
    scripts: usize = 0,
    statements: usize = 0,
    accept: usize = 0,
    reject: usize = 0,
    unknown: usize = 0,
};

fn countCorpus() !Counts {
    var counts: Counts = .{};
    var it: corpus.Iterator = .init(corpus.sqlite_tests);
    while (it.next()) |case| {
        counts.scripts += 1;
        var pos: usize = 0;
        while (pos < case.sql.len) {
            const r = try oracle.check(case.sql[pos..]);
            // Every statement is at least one byte, so the walk always ends.
            try std.testing.expect(r.length > 0);
            pos += r.length;
            counts.statements += 1;
            switch (r.verdict) {
                .accept => counts.accept += 1,
                .reject => counts.reject += 1,
                .unknown => counts.unknown += 1,
            }
        }
        try std.testing.expectEqual(case.sql.len, pos);
    }
    return counts;
}

test "the oracle judges at least 99.5% of corpus statements" {
    const counts = try countCorpus();
    errdefer std.debug.print(
        "corpus: {d} scripts, {d} statements: {d} accept, {d} reject, {d} unknown\n",
        .{ counts.scripts, counts.statements, counts.accept, counts.reject, counts.unknown },
    );
    try std.testing.expect(counts.scripts > 30_000);
    try std.testing.expect(counts.reject > 0);
    try std.testing.expect(counts.unknown * 200 <= counts.statements);
}
