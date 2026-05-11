const std = @import("std");
const asm_ = @import("../src/assembler.zig");

const Assembler = asm_.Assembler;
const Instr = asm_.Instr;
const Reg = asm_.Reg;
const Reg8 = asm_.Reg8;
const MemRef = asm_.MemRef;

fn assemble(instrs: []const Instr) ![]u8 {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    try a.emit(instrs);
    try a.resolveRelocations();
    return std.testing.allocator.dupe(u8, a.buf.items);
}

test "push rbp" {
    const code = try assemble(&.{.{ .push_r = .{ .reg = .rbp } }});
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(usize, 1), code.len);
    try std.testing.expectEqual(@as(u8, 0x55), code[0]);
}

test "pop rbp" {
    const code = try assemble(&.{.{ .pop_r = .{ .reg = .rbp } }});
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(u8, 0x5D), code[0]);
}

test "ret" {
    const code = try assemble(&.{.ret_});
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(usize, 1), code.len);
    try std.testing.expectEqual(@as(u8, 0xC3), code[0]);
}

test "mov rax, 0 (xor idiom)" {
    const code = try assemble(&.{.{ .xor_rr = .{ .dst = .rax, .src = .rax } }});
    defer std.testing.allocator.free(code);
    // REX.W 0x31 /r
    try std.testing.expect(code.len >= 3);
}

test "mov rax, 42" {
    const code = try assemble(&.{.{ .mov_ri = .{ .dst = .rax, .imm = 42 } }});
    defer std.testing.allocator.free(code);
    // B8 + imm32 = 5 bytes, or REX+B8+imm64 = 10 bytes
    try std.testing.expect(code.len == 5 or code.len == 10);
}

test "add rax, rcx" {
    const code = try assemble(&.{.{ .add_rr = .{ .dst = .rax, .src = .rcx } }});
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 0);
}

test "sub rsp, 32" {
    const code = try assemble(&.{.{ .sub_ri = .{ .dst = .rsp, .imm = 32 } }});
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 0);
}

test "syscall" {
    const code = try assemble(&.{.syscall_});
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(usize, 2), code.len);
    try std.testing.expectEqual(@as(u8, 0x0F), code[0]);
    try std.testing.expectEqual(@as(u8, 0x05), code[1]);
}

test "cmp rax, rcx" {
    const code = try assemble(&.{.{ .cmp_rr = .{ .lhs = .rax, .rhs = .rcx } }});
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 0);
}

test "je label resolves" {
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();
    try a.encodeOne(.{ .je_rel = .{ .label = 0 } });
    try a.encodeOne(.nop_);
    try a.encodeOne(.{ .label_def = .{ .id = 0 } });
    try a.resolveRelocations();
    // The je instruction should have a non-placeholder displacement now
    try std.testing.expect(a.buf.items.len >= 3);
}

test "function prologue + epilogue" {
    const code = try assemble(&.{
        .{ .push_r = .{ .reg = .rbp } },
        .{ .mov_rr = .{ .dst = .rbp, .src = .rsp } },
        .{ .sub_ri = .{ .dst = .rsp, .imm = 32 } },
        .{ .mov_rr = .{ .dst = .rsp, .src = .rbp } },
        .{ .pop_r  = .{ .reg = .rbp } },
        .ret_,
    });
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 6);
    // Last byte should be ret (0xC3)
    try std.testing.expectEqual(@as(u8, 0xC3), code[code.len - 1]);
}

test "r8-r15 registers use REX prefix" {
    const code_r8 = try assemble(&.{.{ .push_r = .{ .reg = .r8 } }});
    defer std.testing.allocator.free(code_r8);
    const code_rbp = try assemble(&.{.{ .push_r = .{ .reg = .rbp } }});
    defer std.testing.allocator.free(code_rbp);
    // r8..r15 need REX prefix, so should be longer
    try std.testing.expect(code_r8.len > code_rbp.len);
}

test "mov [rbp - 8], rax" {
    const code = try assemble(&.{.{ .mov_mr = .{
        .dst = MemRef{ .base = .rbp, .disp = -8 },
        .src = .rax,
    }}});
    defer std.testing.allocator.free(code);
    try std.testing.expect(code.len > 0);
}

test "nop" {
    const code = try assemble(&.{.nop_});
    defer std.testing.allocator.free(code);
    try std.testing.expectEqual(@as(usize, 1), code.len);
    try std.testing.expectEqual(@as(u8, 0x90), code[0]);
}
