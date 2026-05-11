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

test "arithmetic: addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    const result = try eval(arena.allocator(), &vm, "var x := 2 + 3");
    _ = result;
    const x = vm.globals.get("x").?;
    try std.testing.expectEqual(value.Value{ .int = 5 }, x);
}

test "arithmetic: subtraction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := 10 - 3");
    try std.testing.expectEqual(value.Value{ .int = 7 }, vm.globals.get("x").?);
}

test "arithmetic: multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := 4 * 5");
    try std.testing.expectEqual(value.Value{ .int = 20 }, vm.globals.get("x").?);
}

test "arithmetic: division" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := 10 / 2");
    try std.testing.expectEqual(value.Value{ .int = 5 }, vm.globals.get("x").?);
}

test "boolean literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var t := true\nvar f := false");
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("t").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("f").?);
}

test "string concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := \"hello\" + \" world\"");
    const s = vm.globals.get("s").?;
    try std.testing.expectEqualStrings("hello world", s.string);
}

test "comparison operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := 1 < 2
        \\var b := 2 > 3
        \\var c := 1 == 1
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("b").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("c").?);
}

test "if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var x := 0
        \\if 1 < 2 then
        \\  x := 42
        \\end
    );
    try std.testing.expectEqual(value.Value{ .int = 42 }, vm.globals.get("x").?);
}

test "if-else statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var x := 0
        \\if false then
        \\  x := 1
        \\else
        \\  x := 2
        \\end
    );
    try std.testing.expectEqual(value.Value{ .int = 2 }, vm.globals.get("x").?);
}

test "function declaration and call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\function add(a, b) begin
        \\  return a + b
        \\end
        \\var result := add(3, 4)
    );
    try std.testing.expectEqual(value.Value{ .int = 7 }, vm.globals.get("result").?);
}

test "array literal and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var arr := [1, 2, 3]
        \\var x := arr[0]
        \\var y := arr[2]
    );
    try std.testing.expectEqual(value.Value{ .int = 1 }, vm.globals.get("x").?);
    try std.testing.expectEqual(value.Value{ .int = 3 }, vm.globals.get("y").?);
}

test "table literal and field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var t := {name = "Alice", age = 30}
        \\var n := t.name
    );
    const n = vm.globals.get("n").?;
    try std.testing.expectEqualStrings("Alice", n.string);
}

test "while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var i := 0
        \\var sum := 0
        \\while i < 5 do
        \\  sum := sum + i
        \\  i := i + 1
        \\end
    );
    try std.testing.expectEqual(value.Value{ .int = 10 }, vm.globals.get("sum").?);
}

test "for loop over range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var sum := 0
        \\for i in 0..5 do
        \\  sum := sum + i
        \\end
    );
    try std.testing.expectEqual(value.Value{ .int = 10 }, vm.globals.get("sum").?);
}

test "pipeline operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\function double(x) begin
        \\  return x * 2
        \\end
        \\var result := 5 | double
    );
    try std.testing.expectEqual(value.Value{ .int = 10 }, vm.globals.get("result").?);
}

test "async function and await" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\async function fetch() begin
        \\  return 42
        \\end
        \\var result := await fetch()
    );
    try std.testing.expectEqual(value.Value{ .int = 42 }, vm.globals.get("result").?);
}

test "null literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := null");
    try std.testing.expectEqual(value.Value.nil, vm.globals.get("x").?);
}

test "nested function calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\function square(x) begin
        \\  return x * x
        \\end
        \\function add(a, b) begin
        \\  return a + b
        \\end
        \\var result := add(square(2), square(3))
    );
    try std.testing.expectEqual(value.Value{ .int = 13 }, vm.globals.get("result").?);
}

test "unary negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := -5");
    try std.testing.expectEqual(value.Value{ .int = -5 }, vm.globals.get("x").?);
}

test "unary not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := not true");
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("x").?);
}
