const std = @import("std");
const lexer_mod = @import("../src/lexer.zig");
const parser_mod = @import("../src/parser.zig");
const ast = @import("../src/ast.zig");

fn parse(alloc: std.mem.Allocator, src: []const u8) !ast.Module {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();
    var parser = parser_mod.Parser.init(alloc, src, tokens);
    return parser.parseModule();
}

test "empty module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mod = try parse(arena.allocator(), "module Empty");
    try std.testing.expectEqualStrings("Empty", mod.name.?);
    try std.testing.expectEqual(@as(usize, 0), mod.decls.len);
}

test "procedure declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\module Main
        \\procedure greet(name: string)
        \\begin
        \\    writeln(name)
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), mod.decls.len);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            try std.testing.expectEqualStrings("greet", p.name);
            try std.testing.expectEqual(@as(usize, 1), p.params.len);
            try std.testing.expectEqualStrings("name", p.params[0].name);
        },
        else => return error.WrongDeclKind,
    }
}

test "function declaration with return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\function add(a: int32, b: int32): int32
        \\begin
        \\    return a + b
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), mod.decls.len);
    switch (mod.decls[0]) {
        .func_decl => |f| {
            try std.testing.expectEqualStrings("add", f.name);
            try std.testing.expectEqual(@as(usize, 2), f.params.len);
            try std.testing.expect(f.ret != null);
        },
        else => return error.WrongDeclKind,
    }
}

test "variable declaration with type inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "procedure p() begin var x := 42 end";
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            const body = p.body.?;
            switch (body.*) {
                .block => |b| {
                    try std.testing.expectEqual(@as(usize, 1), b.stmts.len);
                    switch (b.stmts[0].*) {
                        .var_decl => |vd| {
                            try std.testing.expectEqualStrings("x", vd.name);
                            try std.testing.expect(vd.init != null);
                        },
                        else => return error.WrongStmtKind,
                    }
                },
                else => return error.WrongStmtKind,
            }
        },
        else => return error.WrongDeclKind,
    }
}

test "if-elsif-else statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure p(x: int32)
        \\begin
        \\    if x == 0 then
        \\        writeln("zero")
        \\    elsif x == 1 then
        \\        writeln("one")
        \\    else
        \\        writeln("other")
        \\    end
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            const body = p.body.?;
            switch (body.*) {
                .block => |b| {
                    switch (b.stmts[0].*) {
                        .if_stmt => |ifs| {
                            try std.testing.expectEqual(@as(usize, 1), ifs.elsif_branches.len);
                            try std.testing.expect(ifs.else_branch != null);
                        },
                        else => return error.WrongStmtKind,
                    }
                },
                else => return error.WrongStmtKind,
            }
        },
        else => return error.WrongDeclKind,
    }
}

test "for loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure p()
        \\begin
        \\    for i in 0..9 do
        \\        writeln("hi")
        \\    end
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            const body = p.body.?;
            switch (body.*) {
                .block => |b| {
                    switch (b.stmts[0].*) {
                        .for_stmt => |fs| {
                            try std.testing.expectEqualStrings("i", fs.item_var);
                        },
                        else => return error.WrongStmtKind,
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

test "while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure p()
        \\begin
        \\    while true do
        \\        break
        \\    end
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    _ = mod;
}

test "match statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure p(x: int32)
        \\begin
        \\    match x {
        \\        0 => writeln("zero"),
        \\        1 => writeln("one"),
        \\        else => writeln("other")
        \\    }
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            const body = p.body.?;
            switch (body.*) {
                .block => |b| {
                    switch (b.stmts[0].*) {
                        .match_stmt => |ms| {
                            try std.testing.expectEqual(@as(usize, 3), ms.arms.len);
                        },
                        else => return error.WrongStmtKind,
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

test "type declaration struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\type Point = struct {
        \\    x: int32,
        \\    y: int32,
        \\}
    ;
    const mod = try parse(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), mod.decls.len);
    switch (mod.decls[0]) {
        .type_decl => |td| {
            try std.testing.expectEqualStrings("Point", td.name);
            switch (td.def) {
                .struct_def => |s| {
                    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
                },
                else => return error.WrongTypeDef,
            }
        },
        else => return error.WrongDeclKind,
    }
}

test "type declaration enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\type Color = enum {
        \\    Red,
        \\    Green,
        \\    Blue,
        \\}
    ;
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .type_decl => |td| {
            switch (td.def) {
                .enum_def => |e| {
                    try std.testing.expectEqual(@as(usize, 3), e.variants.len);
                },
                else => return error.WrongTypeDef,
            }
        },
        else => return error.WrongDeclKind,
    }
}

test "const declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "const PI: f64 = 3.14159";
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .const_decl => |cd| {
            try std.testing.expectEqualStrings("PI", cd.name);
        },
        else => return error.WrongDeclKind,
    }
}

test "use declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = "use Math.{add, subtract}";
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .use_decl => |u| {
            try std.testing.expectEqualStrings("Math", u.path[0]);
            try std.testing.expectEqual(@as(usize, 2), u.items.?.len);
        },
        else => return error.WrongDeclKind,
    }
}

test "defer statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\procedure p()
        \\begin
        \\    var f := File.open("x")
        \\    defer f.close()
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    switch (mod.decls[0]) {
        .proc_decl => |p| {
            const body = p.body.?;
            switch (body.*) {
                .block => |b| {
                    try std.testing.expectEqual(@as(usize, 2), b.stmts.len);
                    switch (b.stmts[1].*) {
                        .defer_stmt => {},
                        else => return error.WrongStmtKind,
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

test "hello world parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\module Main
        \\
        \\procedure main()
        \\begin
        \\    writeln("Hello, World!")
        \\end
    ;
    const mod = try parse(arena.allocator(), src);
    try std.testing.expectEqualStrings("Main", mod.name.?);
    try std.testing.expectEqual(@as(usize, 1), mod.decls.len);
}
