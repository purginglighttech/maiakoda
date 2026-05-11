/// WebAssembly 32-bit code generator — stub.

const std = @import("std");
const ir = @import("ir");

pub const CodegenResult = struct {
    wasm: []u8,
    symbols: std.StringHashMap(u32),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CodegenResult) void {
        self.allocator.free(self.wasm);
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
        // Minimal valid WASM module: magic + version
        const header = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
        const wasm = try self.arena.dupe(u8, &header);
        return CodegenResult{
            .wasm = wasm,
            .symbols = std.StringHashMap(u32).init(self.arena),
            .allocator = self.arena,
        };
    }
};
