const std = @import("std");
const lexer_mod  = @import("lexer");
const parser_mod = @import("parser");
const ast        = @import("ast");

fn parse(alloc: std.mem.Allocator, src: []const u8) ![]ast.Stmt {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, tokens);
    return parser.parseProgram();
}

test "parse integer expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "42");
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const expr = stmts[0].expr_stmt;
    try std.testing.expectEqual(@as(i64, 42), expr.int_lit.value);
}

test "parse var declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "var x := 10");
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const decl = stmts[0].var_decl;
    try std.testing.expectEqualStrings("x", decl.name);
    try std.testing.expectEqual(@as(i64, 10), decl.init.int_lit.value);
}

test "parse function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "function f(a, b) begin return a end");
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    const fn_decl = stmts[0].fn_decl;
    try std.testing.expectEqualStrings("f", fn_decl.name);
    try std.testing.expectEqual(@as(usize, 2), fn_decl.params.len);
    try std.testing.expect(!fn_decl.is_async);
}

test "parse async function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "async function g() begin return 1 end");
    const fn_decl = stmts[0].fn_decl;
    try std.testing.expect(fn_decl.is_async);
}

test "parse if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "if true then\n  var x := 1\nend");
    const if_s = stmts[0].if_stmt;
    try std.testing.expect(if_s.cond.bool_lit.value);
    try std.testing.expectEqual(@as(usize, 1), if_s.then_body.len);
    try std.testing.expect(if_s.else_body == null);
}

test "parse if-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(),
        \\if false then
        \\  var a := 1
        \\else
        \\  var b := 2
        \\end
    );
    const if_s = stmts[0].if_stmt;
    try std.testing.expect(if_s.else_body != null);
    try std.testing.expectEqual(@as(usize, 1), if_s.else_body.?.len);
}

test "parse while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "while x < 10 do\nend");
    _ = stmts[0].while_stmt;
}

test "parse for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "for i in arr do\nend");
    const for_s = stmts[0].for_stmt;
    try std.testing.expectEqualStrings("i", for_s.var_name);
}

test "parse binary expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "1 + 2 * 3");
    const expr = stmts[0].expr_stmt;
    // + is the top-level op due to precedence
    try std.testing.expectEqual(ast.BinaryOp.add, expr.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.mul, expr.binary.rhs.binary.op);
}

test "parse array literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "[1, 2, 3]");
    const expr = stmts[0].expr_stmt;
    try std.testing.expectEqual(@as(usize, 3), expr.array_lit.elements.len);
}

test "parse table literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "{x = 1, y = 2}");
    const expr = stmts[0].expr_stmt;
    try std.testing.expectEqual(@as(usize, 2), expr.table_lit.entries.len);
}

test "parse pipeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "x | f | g");
    const expr = stmts[0].expr_stmt;
    // pipeline is left-associative: (x | f) | g
    try std.testing.expect(expr.* == .pipeline);
    try std.testing.expect(expr.pipeline.lhs.* == .pipeline);
}

test "parse range expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "1..10");
    const expr = stmts[0].expr_stmt;
    try std.testing.expect(expr.* == .range);
}

test "parse return statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "function f() begin return 42 end");
    const body = stmts[0].fn_decl.body;
    try std.testing.expectEqual(@as(i64, 42), body[0].return_stmt.value.?.int_lit.value);
}

test "parse call expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stmts = try parse(arena.allocator(), "f(1, 2)");
    const expr = stmts[0].expr_stmt;
    try std.testing.expectEqual(@as(usize, 2), expr.call.args.len);
}
