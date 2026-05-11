const std = @import("std");
const lexer_mod    = @import("lexer");
const parser_mod   = @import("parser");
const compiler_mod = @import("compiler");
const vm_mod       = @import("vm");
const value        = @import("value");
const repl         = @import("repl");

// Helper: evaluate a single line via the REPL's evalLine and inspect globals.
fn evalViaRepl(alloc: std.mem.Allocator, vm: *vm_mod.Vm, src: []const u8) !void {
    try repl.evalLine(alloc, std.testing.io, vm, src);
}

test "repl: evalLine evaluates integer expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm, "var x := 1 + 1");
    try std.testing.expectEqual(value.Value{ .int = 2 }, vm.globals.get("x").?);
}

test "repl: evalLine evaluates string expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm, "var s := \"hello\" + \" repl\"");
    try std.testing.expectEqualStrings("hello repl", vm.globals.get("s").?.string);
}

test "repl: evalLine evaluates function declaration and call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm, "function inc(n) begin return n + 1 end");
    try evalViaRepl(arena.allocator(), &vm, "var result := inc(41)");
    try std.testing.expectEqual(value.Value{ .int = 42 }, vm.globals.get("result").?);
}

test "repl: evalLine preserves state across calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm, "var counter := 0");
    try evalViaRepl(arena.allocator(), &vm, "counter := counter + 1");
    try evalViaRepl(arena.allocator(), &vm, "counter := counter + 1");
    try std.testing.expectEqual(value.Value{ .int = 2 }, vm.globals.get("counter").?);
}

test "repl: evalLine handles if statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm, "var x := 0\nif true then\n  x := 99\nend");
    try std.testing.expectEqual(value.Value{ .int = 99 }, vm.globals.get("x").?);
}

test "repl: evalLine handles async/await" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm,
        \\async function getVal() begin
        \\  return 7
        \\end
        \\var r := await getVal()
    );
    try std.testing.expectEqual(value.Value{ .int = 7 }, vm.globals.get("r").?);
}

test "repl: evalLine handles pipeline operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm,
        \\function triple(x) begin return x * 3 end
        \\var r := 4 | triple
    );
    try std.testing.expectEqual(value.Value{ .int = 12 }, vm.globals.get("r").?);
}

test "repl: evalLine handles for loop over range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    try evalViaRepl(arena.allocator(), &vm,
        \\var total := 0
        \\for i in 1..4 do
        \\  total := total + i
        \\end
    );
    try std.testing.expectEqual(value.Value{ .int = 6 }, vm.globals.get("total").?);
}
