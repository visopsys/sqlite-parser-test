//! A front end for SQLite's dialect of SQL: a tokenizer and a parser that accept
//! exactly what SQLite 3.45.1 accepts and report syntax errors the way SQLite
//! does. See docs/research.md for the specification.

const std = @import("std");

pub const Ast = @import("Ast.zig");
pub const tokenizer = @import("tokenizer.zig");

test {
    std.testing.refAllDecls(@This());
}
