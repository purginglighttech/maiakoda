const std = @import("std");
const lexer = @import("../src/lexer.zig");

const TK = lexer.TokenKind;
const Lexer = lexer.Lexer;

fn tokenize(src: []const u8) ![]lexer.Token {
    var lex = Lexer.init(std.testing.allocator, src);
    return lex.tokenize();
}

test "empty source" {
    const toks = try tokenize("");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.eof, toks[0].kind);
}

test "keywords" {
    const toks = try tokenize("module function procedure var const begin end if then else");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.kw_module,    toks[0].kind);
    try std.testing.expectEqual(TK.kw_function,  toks[1].kind);
    try std.testing.expectEqual(TK.kw_procedure, toks[2].kind);
    try std.testing.expectEqual(TK.kw_var,       toks[3].kind);
    try std.testing.expectEqual(TK.kw_const,     toks[4].kind);
    try std.testing.expectEqual(TK.kw_begin,     toks[5].kind);
    try std.testing.expectEqual(TK.kw_end,       toks[6].kind);
    try std.testing.expectEqual(TK.kw_if,        toks[7].kind);
    try std.testing.expectEqual(TK.kw_then,      toks[8].kind);
    try std.testing.expectEqual(TK.kw_else,      toks[9].kind);
}

test "ownership keywords" {
    const toks = try tokenize("own ref mut rc weak iso trn val box tag");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.kw_own,  toks[0].kind);
    try std.testing.expectEqual(TK.kw_ref,  toks[1].kind);
    try std.testing.expectEqual(TK.kw_mut,  toks[2].kind);
    try std.testing.expectEqual(TK.kw_rc,   toks[3].kind);
    try std.testing.expectEqual(TK.kw_weak, toks[4].kind);
    try std.testing.expectEqual(TK.kw_iso,  toks[5].kind);
    try std.testing.expectEqual(TK.kw_trn,  toks[6].kind);
    try std.testing.expectEqual(TK.kw_val,  toks[7].kind);
    try std.testing.expectEqual(TK.kw_box,  toks[8].kind);
    try std.testing.expectEqual(TK.kw_tag,  toks[9].kind);
}

test "logical operator keywords" {
    const toks = try tokenize("and or not");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.kw_and, toks[0].kind);
    try std.testing.expectEqual(TK.kw_or,  toks[1].kind);
    try std.testing.expectEqual(TK.kw_not, toks[2].kind);
}

test "identifiers" {
    const toks = try tokenize("hello _world foo123 camelCase");
    defer std.testing.allocator.free(toks);
    for (toks[0..4]) |tok| {
        try std.testing.expectEqual(TK.identifier, tok.kind);
    }
}

test "integer literals" {
    const toks = try tokenize("42 0xFF 0o755 0b1010 1_000_000");
    defer std.testing.allocator.free(toks);
    for (toks[0..5]) |tok| {
        try std.testing.expectEqual(TK.int_literal, tok.kind);
    }
    const src = "42 0xFF 0o755 0b1010 1_000_000";
    try std.testing.expectEqualStrings("42",        toks[0].text(src));
    try std.testing.expectEqualStrings("0xFF",      toks[1].text(src));
    try std.testing.expectEqualStrings("0o755",     toks[2].text(src));
    try std.testing.expectEqualStrings("0b1010",    toks[3].text(src));
    try std.testing.expectEqualStrings("1_000_000", toks[4].text(src));
}

test "float literals" {
    const toks = try tokenize("3.14 1e-10 1.5e3");
    defer std.testing.allocator.free(toks);
    for (toks[0..3]) |tok| {
        try std.testing.expectEqual(TK.float_literal, tok.kind);
    }
}

test "string literals" {
    const toks = try tokenize("\"hello\" \"escaped \\\"quote\\\"\"");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.string_literal, toks[0].kind);
    try std.testing.expectEqual(TK.string_literal, toks[1].kind);
}

test "operators" {
    const toks = try tokenize(":= += -= *= /= == != <= >= << >> // ..");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.colon_eq,    toks[0].kind);
    try std.testing.expectEqual(TK.plus_eq,     toks[1].kind);
    try std.testing.expectEqual(TK.minus_eq,    toks[2].kind);
    try std.testing.expectEqual(TK.star_eq,     toks[3].kind);
    try std.testing.expectEqual(TK.slash_eq,    toks[4].kind);
    try std.testing.expectEqual(TK.eq_eq,       toks[5].kind);
    try std.testing.expectEqual(TK.bang_eq,     toks[6].kind);
    try std.testing.expectEqual(TK.lt_eq,       toks[7].kind);
    try std.testing.expectEqual(TK.gt_eq,       toks[8].kind);
    try std.testing.expectEqual(TK.lt_lt,       toks[9].kind);
    try std.testing.expectEqual(TK.gt_gt,       toks[10].kind);
    try std.testing.expectEqual(TK.slash_slash, toks[11].kind);
    try std.testing.expectEqual(TK.dot_dot,     toks[12].kind);
}

test "block comment nestable" {
    // Nested block comment: the inner */ should not close the outer one
    const toks = try tokenize("/* outer /* inner */ still_outer */ 42");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.int_literal, toks[0].kind);
}

test "doc comment" {
    const toks = try tokenize("/// this is a doc comment\n42");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.doc_comment, toks[0].kind);
    try std.testing.expectEqual(TK.int_literal,  toks[1].kind);
}

test "line and column tracking" {
    const src = "a\nb\nc";
    const toks = try tokenize(src);
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(@as(u32, 1), toks[0].line);
    try std.testing.expectEqual(@as(u32, 2), toks[1].line);
    try std.testing.expectEqual(@as(u32, 3), toks[2].line);
}

test "delimiters" {
    const toks = try tokenize("( ) [ ] { } , ; :");
    defer std.testing.allocator.free(toks);
    try std.testing.expectEqual(TK.lparen,    toks[0].kind);
    try std.testing.expectEqual(TK.rparen,    toks[1].kind);
    try std.testing.expectEqual(TK.lbracket,  toks[2].kind);
    try std.testing.expectEqual(TK.rbracket,  toks[3].kind);
    try std.testing.expectEqual(TK.lbrace,    toks[4].kind);
    try std.testing.expectEqual(TK.rbrace,    toks[5].kind);
    try std.testing.expectEqual(TK.comma,     toks[6].kind);
    try std.testing.expectEqual(TK.semicolon, toks[7].kind);
    try std.testing.expectEqual(TK.colon,     toks[8].kind);
}

test "hello world program tokenizes" {
    const src =
        \\module Main
        \\
        \\procedure main()
        \\begin
        \\    writeln("Hello, World!")
        \\end
    ;
    const toks = try tokenize(src);
    defer std.testing.allocator.free(toks);
    // Should not error; spot-check a few
    try std.testing.expectEqual(TK.kw_module, toks[0].kind);
    // Find 'writeln' identifier
    var found_writeln = false;
    for (toks) |tok| {
        if (tok.kind == .identifier and std.mem.eql(u8, tok.text(src), "writeln")) {
            found_writeln = true;
            break;
        }
    }
    try std.testing.expect(found_writeln);
}
