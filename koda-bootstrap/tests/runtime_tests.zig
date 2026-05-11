const std = @import("std");
const lexer_mod    = @import("lexer");
const parser_mod   = @import("parser");
const compiler_mod = @import("compiler");
const vm_mod       = @import("vm");
const value        = @import("value");

fn eval(alloc: std.mem.Allocator, vm: *vm_mod.Vm, src: []const u8) !value.Value {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, tokens);
    const stmts = try parser.parseProgram();
    var compiler = compiler_mod.Compiler.init(alloc);
    const proto = try compiler.compile(stmts);
    return vm.interpret(proto);
}

test "len on string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var n := len(\"hello\")");
    try std.testing.expectEqual(value.Value{ .int = 5 }, vm.globals.get("n").?);
}

test "len on array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var n := len([1, 2, 3])");
    try std.testing.expectEqual(value.Value{ .int = 3 }, vm.globals.get("n").?);
}

test "type function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var t := type(42)");
    try std.testing.expectEqualStrings("int", vm.globals.get("t").?.string);
}

test "str conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := str(123)");
    try std.testing.expectEqualStrings("123", vm.globals.get("s").?.string);
}

test "int conversion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var n := int(\"42\")");
    try std.testing.expectEqual(value.Value{ .int = 42 }, vm.globals.get("n").?);
}

test "push and pop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var arr := [1, 2]
        \\push(arr, 3)
        \\var n := len(arr)
    );
    try std.testing.expectEqual(value.Value{ .int = 3 }, vm.globals.get("n").?);
}

test "assert passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "assert(true)");
}

test "assert fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    const result = eval(arena.allocator(), &vm, "assert(false)");
    try std.testing.expectError(error.AssertionFailed, result);
}

test "println native" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "println(\"test\")");
}
