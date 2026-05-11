const std = @import("std");
const lexer_mod = @import("../src/lexer.zig");
const parser_mod = @import("../src/parser.zig");
const sema_mod = @import("../src/sema.zig");

fn analyzeSource(alloc: std.mem.Allocator, src: []const u8) !sema_mod.Sema {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, src, tokens);
    var mod = try parser.parseModule();
    var s = try sema_mod.Sema.init(alloc);
    try s.analyzeModule(&mod);
    return s;
}

test "primitive type resolution" {
    var s = try sema_mod.Sema.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(sema_mod.TYPE_INT32, s.resolveBuiltinName("int32").?);
    try std.testing.expectEqual(sema_mod.TYPE_BOOL,  s.resolveBuiltinName("bool").?);
    try std.testing.expectEqual(sema_mod.TYPE_F64,   s.resolveBuiltinName("f64").?);
    try std.testing.expectEqual(sema_mod.TYPE_STRING,s.resolveBuiltinName("string").?);
}

test "no errors on valid procedure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure main()
        \\begin
        \\    writeln("Hello")
        \\end
    ;
    var s = try analyzeSource(arena.allocator(), src);
    _ = &s;
    try std.testing.expect(!s.hasErrors());
}

test "no errors on arithmetic function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\function add(a: int32, b: int32): int32
        \\begin
        \\    return a + b
        \\end
    ;
    var s = try analyzeSource(arena.allocator(), src);
    _ = &s;
    try std.testing.expect(!s.hasErrors());
}

test "no errors on const declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "const PI: f64 = 3.14159";
    var s = try analyzeSource(arena.allocator(), src);
    _ = &s;
    try std.testing.expect(!s.hasErrors());
}

test "no errors on struct type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\type Point = struct {
        \\    x: int32,
        \\    y: int32,
        \\}
    ;
    var s = try analyzeSource(arena.allocator(), src);
    _ = &s;
    try std.testing.expect(!s.hasErrors());
}

test "writeln builtin is registered" {
    var s = try sema_mod.Sema.init(std.testing.allocator);
    defer s.deinit();
    const sym = s.global_scope.lookup("writeln");
    try std.testing.expect(sym != null);
    try std.testing.expectEqual(sema_mod.SymbolKind.function_, sym.?.kind);
}

test "type compatibility int32 with int32" {
    var s = try sema_mod.Sema.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.typesCompatible(sema_mod.TYPE_INT32, sema_mod.TYPE_INT32));
}

test "type compatibility null with optional" {
    var s = try sema_mod.Sema.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.typesCompatible(sema_mod.TYPE_INT32, sema_mod.TYPE_NULL));
}

test "hello world sema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\module Main
        \\procedure main()
        \\begin
        \\    writeln("Hello, World!")
        \\end
    ;
    var s = try analyzeSource(arena.allocator(), src);
    _ = &s;
    try std.testing.expect(!s.hasErrors());
}
