const std = @import("std");
const lexer_mod = @import("../src/lexer.zig");
const parser_mod = @import("../src/parser.zig");
const sema_mod = @import("../src/sema.zig");
const ir_mod = @import("../src/ir.zig");

fn buildIR(alloc: std.mem.Allocator, src: []const u8) !ir_mod.IrModule {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, src, tokens);
    var mod = try parser.parseModule();
    var s = try sema_mod.Sema.init(alloc);
    try s.analyzeModule(&mod);
    var ir_module = ir_mod.IrModule.init(alloc);
    var builder = ir_mod.Builder.init(alloc, &ir_module, &s);
    try builder.lowerModule(&mod);
    return ir_module;
}

test "IR generation for simple procedure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure main()
        \\begin
        \\    writeln("hello")
        \\end
    ;
    const irm = try buildIR(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), irm.functions.items.len);
    try std.testing.expectEqualStrings("main", irm.functions.items[0].name);
}

test "IR generation for arithmetic function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\function add(a: int32, b: int32): int32
        \\begin
        \\    return a + b
        \\end
    ;
    const irm = try buildIR(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), irm.functions.items.len);
    try std.testing.expectEqual(@as(usize, 2), irm.functions.items[0].params.len);
}

test "IR string interning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var irm = ir_mod.IrModule.init(arena.allocator());
    const idx1 = try irm.internString("hello");
    const idx2 = try irm.internString("world");
    const idx3 = try irm.internString("hello");
    try std.testing.expectEqual(idx1, idx3);
    try std.testing.expect(idx1 != idx2);
    try std.testing.expectEqual(@as(usize, 2), irm.string_pool.items.len);
}

test "IR function has entry block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure main()
        \\begin
        \\end
    ;
    const irm = try buildIR(arena.allocator(), src);
    try std.testing.expect(irm.functions.items[0].blocks.items.len > 0);
    try std.testing.expectEqualStrings("entry", irm.functions.items[0].blocks.items[0].label);
}

test "IR return instruction emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\function answer(): int32
        \\begin
        \\    return 42
        \\end
    ;
    const irm = try buildIR(arena.allocator(), src);
    const fn_ = &irm.functions.items[0];
    var found_ret = false;
    for (fn_.blocks.items) |*b| {
        for (b.instrs.items) |instr| {
            switch (instr) {
                .ret => found_ret = true,
                else => {},
            }
        }
    }
    try std.testing.expect(found_ret);
}

test "IR value types" {
    const int_val = ir_mod.Value{ .imm_int = 42 };
    const bool_val = ir_mod.Value{ .imm_bool = true };
    const null_val: ir_mod.Value = .imm_null;
    try std.testing.expect(!int_val.isImm() == false);
    try std.testing.expect(bool_val.isImm());
    try std.testing.expect(null_val.isImm());
}
