/// RISC-V 64-bit code generator — stub.

const std = @import("std");
const ir = @import("ir");

pub const CodegenResult = struct {
    text: []u8,
    rodata: []u8,
    symbols: std.StringHashMap(u32),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CodegenResult) void {
        self.allocator.free(self.text);
        self.allocator.free(self.rodata);
        self.symbols.deinit();
    }
};

pub const Codegen = struct {
    arena: std.mem.Allocator,

    pub fn init(arena: std.mem.Allocator) Codegen {
        return .{ .arena = arena };
    }

    pub fn deinit(self: *Codegen) void { _ = self; }

    pub fn generate(self: *Codegen, module: *ir.IrModule) !CodegenResult {
        _ = module;
        return CodegenResult{
            .text = try self.arena.alloc(u8, 0),
            .rodata = try self.arena.alloc(u8, 0),
            .symbols = std.StringHashMap(u32).init(self.arena),
            .allocator = self.arena,
        };
    }
};
