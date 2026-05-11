const std = @import("std");
const lexer_mod    = @import("lexer");
const parser_mod   = @import("parser");
const compiler_mod = @import("compiler");
const vm_mod       = @import("vm");
const repl_mod     = @import("repl");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    var vm = try vm_mod.Vm.init(alloc, io);
    defer vm.deinit();

    const args = try init.minimal.args.toSlice(alloc);

    if (args.len < 2) {
        try repl_mod.run(alloc, io, &vm);
        return;
    }

    const path = args[1];
    const src = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, alloc, .unlimited) catch |err| {
        std.debug.print("error reading '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };

    runSource(alloc, &vm, src) catch |err| {
        std.debug.print("runtime error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn runSource(alloc: std.mem.Allocator, vm: *vm_mod.Vm, src: []const u8) !void {
    var lex = lexer_mod.Lexer.init(alloc, src);
    const tokens = try lex.tokenize();

    var parser = parser_mod.Parser.init(alloc, tokens);
    const stmts = try parser.parseProgram();

    var compiler = compiler_mod.Compiler.init(alloc);
    const proto = try compiler.compile(stmts);

    _ = try vm.interpret(proto);
}
