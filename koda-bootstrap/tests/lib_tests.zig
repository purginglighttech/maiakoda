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

// ── math lib ────────────────────────────────────────────────────────────────

test "math: floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := floor(3.7)");
    try std.testing.expectEqual(value.Value{ .float = 3.0 }, vm.globals.get("x").?);
}

test "math: ceil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := ceil(3.2)");
    try std.testing.expectEqual(value.Value{ .float = 4.0 }, vm.globals.get("x").?);
}

test "math: sqrt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := sqrt(9.0)");
    try std.testing.expectEqual(value.Value{ .float = 3.0 }, vm.globals.get("x").?);
}

test "math: abs on negative int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := abs(-5)");
    try std.testing.expectEqual(value.Value{ .int = 5 }, vm.globals.get("x").?);
}

test "math: min and max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var a := min(3, 5)\nvar b := max(3, 5)");
    try std.testing.expectEqual(value.Value{ .int = 3 }, vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .int = 5 }, vm.globals.get("b").?);
}

test "math: pow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := pow(2.0, 10.0)");
    try std.testing.expectEqual(value.Value{ .float = 1024.0 }, vm.globals.get("x").?);
}

test "math: PI constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var x := PI");
    const x = vm.globals.get("x").?;
    try std.testing.expect(x == .float);
    try std.testing.expect(x.float > 3.14 and x.float < 3.15);
}

// ── string lib ───────────────────────────────────────────────────────────────

test "string: split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var parts := split(\"a,b,c\", \",\")");
    const parts = vm.globals.get("parts").?;
    try std.testing.expectEqual(@as(usize, 3), parts.array.items.items.len);
}

test "string: join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := join([\"a\", \"b\", \"c\"], \"-\")");
    const s = vm.globals.get("s").?;
    try std.testing.expectEqualStrings("a-b-c", s.string);
}

test "string: trim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := trim(\"  hello  \")");
    try std.testing.expectEqualStrings("hello", vm.globals.get("s").?.string);
}

test "string: starts_with and ends_with" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := starts_with("hello world", "hello")
        \\var b := ends_with("hello world", "world")
        \\var c := starts_with("hello world", "bye")
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("b").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("c").?);
}

test "string: to_upper and to_lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var u := to_upper(\"hello\")\nvar l := to_lower(\"WORLD\")");
    try std.testing.expectEqualStrings("HELLO", vm.globals.get("u").?.string);
    try std.testing.expectEqualStrings("world", vm.globals.get("l").?.string);
}

test "string: replace_str" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := replace_str(\"hello world\", \"world\", \"koda\")");
    try std.testing.expectEqualStrings("hello koda", vm.globals.get("s").?.string);
}

test "string: char_at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var c := char_at(\"hello\", 1)");
    try std.testing.expectEqualStrings("e", vm.globals.get("c").?.string);
}

test "string: contains_str" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := contains_str("hello world", "world")
        \\var b := contains_str("hello world", "xyz")
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("b").?);
}

// ── array lib ────────────────────────────────────────────────────────────────

test "array: contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := contains([1, 2, 3], 2)
        \\var b := contains([1, 2, 3], 9)
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("b").?);
}

test "array: reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var r := reverse([1, 2, 3])");
    const r = vm.globals.get("r").?;
    try std.testing.expectEqual(value.Value{ .int = 3 }, r.array.items.items[0]);
    try std.testing.expectEqual(value.Value{ .int = 1 }, r.array.items.items[2]);
}

test "array: concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var c := concat([1, 2], [3, 4])");
    try std.testing.expectEqual(@as(usize, 4), vm.globals.get("c").?.array.items.items.len);
}

test "array: arr_slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var s := arr_slice([10, 20, 30, 40], 1, 3)");
    const s = vm.globals.get("s").?;
    try std.testing.expectEqual(@as(usize, 2), s.array.items.items.len);
    try std.testing.expectEqual(value.Value{ .int = 20 }, s.array.items.items[0]);
}

test "array: index_of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var i := index_of([10, 20, 30], 20)
        \\var j := index_of([10, 20, 30], 99)
    );
    try std.testing.expectEqual(value.Value{ .int = 1 },  vm.globals.get("i").?);
    try std.testing.expectEqual(value.Value{ .int = -1 }, vm.globals.get("j").?);
}

test "array: arr_sort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var a := [3, 1, 2]\narr_sort(a)\nvar x := a[0]");
    try std.testing.expectEqual(value.Value{ .int = 1 }, vm.globals.get("x").?);
}

// ── table lib ────────────────────────────────────────────────────────────────

test "table: has_key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var t := {x = 1, y = 2}
        \\var a := has_key(t, "x")
        \\var b := has_key(t, "z")
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("b").?);
}

test "table: merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var t1 := {a = 1}
        \\var t2 := {b = 2}
        \\var m := merge(t1, t2)
        \\var n := len(keys(m))
    );
    try std.testing.expectEqual(value.Value{ .int = 2 }, vm.globals.get("n").?);
}

// ── core lib ─────────────────────────────────────────────────────────────────

test "core: is_nil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := is_nil(null)
        \\var b := is_nil(42)
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("b").?);
}

test "core: type predicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := is_int(5)
        \\var b := is_float(3.14)
        \\var c := is_string("hi")
        \\var d := is_array([1])
        \\var e := is_table({x = 1})
        \\var f := is_bool(true)
    );
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("b").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("c").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("d").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("e").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("f").?);
}

test "core: to_bool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm,
        \\var a := to_bool(0)
        \\var b := to_bool(1)
        \\var c := to_bool(null)
    );
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("a").?);
    try std.testing.expectEqual(value.Value{ .bool_ = true },  vm.globals.get("b").?);
    try std.testing.expectEqual(value.Value{ .bool_ = false }, vm.globals.get("c").?);
}

// ── async lib ────────────────────────────────────────────────────────────────

test "async: sleep_ms is no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "sleep_ms(100)");
}

test "async: is_done on non-task" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vm = try vm_mod.Vm.init(arena.allocator(), std.testing.io);
    defer vm.deinit();
    _ = try eval(arena.allocator(), &vm, "var d := is_done(42)");
    try std.testing.expectEqual(value.Value{ .bool_ = true }, vm.globals.get("d").?);
}
