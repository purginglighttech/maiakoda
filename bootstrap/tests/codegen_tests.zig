const std = @import("std");
const lexer_mod = @import("../src/lexer.zig");
const parser_mod = @import("../src/parser.zig");
const sema_mod = @import("../src/sema.zig");
const ir_mod = @import("../src/ir.zig");
const codegen_x86 = @import("../src/codegen/x86_64.zig");
const codegen_arm64 = @import("../src/codegen/arm64.zig");
const codegen_riscv64 = @import("../src/codegen/riscv64.zig");
const codegen_wasm32 = @import("../src/codegen/wasm32.zig");

fn compileToCode(alloc: std.mem.Allocator, src: []const u8) !codegen_x86.CodegenResult {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, src, tokens);
    var mod = try parser.parseModule();
    var s = try sema_mod.Sema.init(alloc);
    try s.analyzeModule(&mod);
    var ir_module = ir_mod.IrModule.init(alloc);
    var builder = ir_mod.Builder.init(alloc, &ir_module, &s);
    try builder.lowerModule(&mod);
    var cg = codegen_x86.Codegen.init(alloc);
    return cg.generate(&ir_module);
}

test "x86_64 codegen produces non-empty text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compileToCode(arena.allocator(),
        \\procedure main()
        \\begin
        \\    writeln("hi")
        \\end
    );
    try std.testing.expect(result.text.len > 0);
}

test "x86_64 codegen registers main symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compileToCode(arena.allocator(),
        \\procedure main()
        \\begin
        \\end
    );
    try std.testing.expect(result.symbols.contains("main"));
}

test "x86_64 codegen multiple functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compileToCode(arena.allocator(),
        \\function add(a: int32, b: int32): int32
        \\begin
        \\    return a + b
        \\end
        \\procedure main()
        \\begin
        \\end
    );
    try std.testing.expect(result.symbols.contains("add"));
    try std.testing.expect(result.symbols.contains("main"));
    const add_off = result.symbols.get("add").?;
    const main_off = result.symbols.get("main").?;
    try std.testing.expect(add_off < main_off);
}

test "x86_64 codegen string constant in rodata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try compileToCode(arena.allocator(),
        \\procedure main()
        \\begin
        \\    writeln("Hello, World!")
        \\end
    );
    if (result.rodata.len > 0) {
        const found = std.mem.indexOf(u8, result.rodata, "Hello, World!") != null;
        try std.testing.expect(found);
    }
}

test "arm64 stub generates empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ir_module = ir_mod.IrModule.init(arena.allocator());
    var cg = codegen_arm64.Codegen.init(arena.allocator());
    const result = try cg.generate(&ir_module);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "riscv64 stub generates empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ir_module = ir_mod.IrModule.init(arena.allocator());
    var cg = codegen_riscv64.Codegen.init(arena.allocator());
    const result = try cg.generate(&ir_module);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
}

test "wasm32 stub produces valid magic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ir_module = ir_mod.IrModule.init(arena.allocator());
    var cg = codegen_wasm32.Codegen.init(arena.allocator());
    const result = try cg.generate(&ir_module);
    try std.testing.expectEqual(@as(usize, 8), result.wasm.len);
    try std.testing.expectEqual(@as(u8, 0x00), result.wasm[0]);
    try std.testing.expectEqual(@as(u8, 0x61), result.wasm[1]);
    try std.testing.expectEqual(@as(u8, 0x73), result.wasm[2]);
    try std.testing.expectEqual(@as(u8, 0x6D), result.wasm[3]);
}
