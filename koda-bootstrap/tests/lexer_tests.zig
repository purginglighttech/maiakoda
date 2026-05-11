const std = @import("std");
const lexer_mod = @import("lexer");

fn lex(alloc: std.mem.Allocator, src: []const u8) ![]lexer_mod.Token {
    var l = lexer_mod.Lexer.init(alloc, src);
    return l.tokenize();
}

test "lex integer literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "42");
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit, tokens[0].kind);
    try std.testing.expectEqualStrings("42", tokens[0].text);
}

test "lex float literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "3.14");
    try std.testing.expectEqual(lexer_mod.TokenKind.float_lit, tokens[0].kind);
}

test "lex string literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "\"hello\"");
    try std.testing.expectEqual(lexer_mod.TokenKind.string_lit, tokens[0].kind);
    try std.testing.expectEqualStrings("hello", tokens[0].text);
}

test "lex keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "var function if then else end while for in return");
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_var,      tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_function, tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_if,       tokens[2].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_then,     tokens[3].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_else,     tokens[4].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_end,      tokens[5].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_while,    tokens[6].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_for,      tokens[7].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_in,       tokens[8].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_return,   tokens[9].kind);
}

test "lex async keywords" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "async await spawn");
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_async, tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_await, tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.kw_spawn, tokens[2].kind);
}

test "lex pipeline operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "a | b");
    try std.testing.expectEqual(lexer_mod.TokenKind.ident, tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.pipe,  tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.ident, tokens[2].kind);
}

test "lex colon_eq assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "x := 5");
    try std.testing.expectEqual(lexer_mod.TokenKind.ident,    tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.colon_eq, tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit,  tokens[2].kind);
}

test "lex range operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "1..10");
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit,  tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.dot_dot,  tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit,  tokens[2].kind);
}

test "lex block comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "/* comment */ 42");
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit, tokens[0].kind);
}

test "lex nested block comment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "/* outer /* inner */ */ 1");
    try std.testing.expectEqual(lexer_mod.TokenKind.int_lit, tokens[0].kind);
}

test "lex operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "+ - * / % == != < > <= >=");
    try std.testing.expectEqual(lexer_mod.TokenKind.plus,     tokens[0].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.minus,    tokens[1].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.star,     tokens[2].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.slash,    tokens[3].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.percent,  tokens[4].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.eq_eq,    tokens[5].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.bang_eq,  tokens[6].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.lt,       tokens[7].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.gt,       tokens[8].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.lt_eq,    tokens[9].kind);
    try std.testing.expectEqual(lexer_mod.TokenKind.gt_eq,    tokens[10].kind);
}

test "lex eof at end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tokens = try lex(arena.allocator(), "");
    try std.testing.expectEqual(lexer_mod.TokenKind.eof, tokens[0].kind);
}
