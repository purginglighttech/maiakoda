const std = @import("std");
const lexer_mod    = @import("lexer");
const parser_mod   = @import("parser");
const compiler_mod = @import("compiler");
const value        = @import("value");
const bc           = @import("bytecode");

fn compile(alloc: std.mem.Allocator, src: []const u8) !*value.FunctionProto {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, tokens);
    const stmts = try parser.parseProgram();
    var compiler = compiler_mod.Compiler.init(alloc);
    return compiler.compile(stmts);
}

fn hasOp(proto: *value.FunctionProto, op: bc.Op) bool {
    for (proto.chunk.code.items) |byte| {
        if (byte == @intFromEnum(op)) return true;
    }
    return false;
}

test "compile integer literal emits constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "42");
    try std.testing.expect(hasOp(proto, .constant));
    try std.testing.expectEqual(@as(usize, 1), proto.chunk.constants.items.len);
    try std.testing.expectEqual(value.Value{ .int = 42 }, proto.chunk.constants.items[0]);
}

test "compile returns nil at top level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "");
    try std.testing.expect(hasOp(proto, .nil));
    try std.testing.expect(hasOp(proto, .return_));
}

test "compile var decl emits set_global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "var x := 1");
    try std.testing.expect(hasOp(proto, .set_global));
}

test "compile function emits closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "function f() begin return 1 end");
    try std.testing.expect(hasOp(proto, .closure));
}

test "compile if emits jump_if_false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "if true then\n  var x := 1\nend");
    try std.testing.expect(hasOp(proto, .jump_if_false));
}

test "compile while emits loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "while false do\nend");
    try std.testing.expect(hasOp(proto, .loop));
}

test "compile array literal emits create_array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "var a := [1, 2, 3]");
    try std.testing.expect(hasOp(proto, .create_array));
    try std.testing.expect(hasOp(proto, .array_append));
}

test "compile table literal emits create_table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "var t := {x = 1}");
    try std.testing.expect(hasOp(proto, .create_table));
    try std.testing.expect(hasOp(proto, .table_set));
}

test "compile pipeline emits pipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(),
        \\function id(x) begin return x end
        \\var r := 1 | id
    );
    try std.testing.expect(hasOp(proto, .pipe));
}

test "compile range emits make_range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const proto = try compile(arena.allocator(), "for i in 0..10 do\nend");
    try std.testing.expect(hasOp(proto, .make_range));
}
