/// Koda REPL — read-eval-print loop.
const std = @import("std");
const lexer_mod    = @import("lexer");
const parser_mod   = @import("parser");
const compiler_mod = @import("compiler");
const vm_mod       = @import("vm");
const value        = @import("value");

pub fn run(alloc: std.mem.Allocator, io: std.Io, vm: *vm_mod.Vm) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "Koda 0.1 bootstrap REPL. Type 'quit' to exit.\n");

    var line_buf: [4096]u8 = undefined;
    while (true) {
        try std.Io.File.stdout().writeStreamingAll(io, "> ");

        // Read a line via stdin streaming
        const stdin = std.Io.File.stdin();
        var n: usize = 0;
        while (n < line_buf.len) {
            var buf = [_]u8{0};
            const vecs = [_][]u8{&buf};
            const got = try stdin.readStreaming(io, &vecs);
            if (got == 0 or buf[0] == '\n') break;
            line_buf[n] = buf[0];
            n += 1;
        }
        if (n == 0) break;

        const line = std.mem.trim(u8, line_buf[0..n], " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) break;

        evalLine(alloc, io, vm, line) catch |err| {
            std.debug.print("error: {}\n", .{err});
        };
    }
}

pub fn evalLine(alloc: std.mem.Allocator, io: std.Io, vm: *vm_mod.Vm, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var lex = lexer_mod.Lexer.init(a, src);
    const tokens = try lex.tokenize();

    var parser = parser_mod.Parser.init(a, tokens);
    const stmts = try parser.parseProgram();

    var compiler = compiler_mod.Compiler.init(a);
    const proto = try compiler.compile(stmts);

    const result = try vm.interpret(proto);
    if (result != .nil) {
        const s = try result.format(a);
        try std.Io.File.stdout().writeStreamingAll(io, s);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    }
}
