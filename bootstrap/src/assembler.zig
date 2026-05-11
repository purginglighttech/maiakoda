/// x86_64 instruction encoder.
/// Encodes Instr structs to binary machine code bytes.
/// Targets the System V AMD64 ABI on Linux.

const std = @import("std");

// ── Register encoding ─────────────────────────────────────────────────────────

pub const Reg = enum(u4) {
    rax = 0, rcx = 1, rdx = 2, rbx = 3,
    rsp = 4, rbp = 5, rsi = 6, rdi = 7,
    r8  = 8, r9  = 9, r10 = 10, r11 = 11,
    r12 = 12, r13 = 13, r14 = 14, r15 = 15,
};

pub const Reg32 = enum(u4) {
    eax = 0, ecx = 1, edx = 2, ebx = 3,
    esp = 4, ebp = 5, esi = 6, edi = 7,
    r8d  = 8, r9d  = 9, r10d = 10, r11d = 11,
    r12d = 12, r13d = 13, r14d = 14, r15d = 15,
};

pub const Reg8 = enum(u4) {
    al = 0, cl = 1, dl = 2, bl = 3,
    spl = 4, bpl = 5, sil = 6, dil = 7,
};

/// Argument registers in System V AMD64 ABI order
pub const arg_regs = [_]Reg{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
/// Caller-saved scratch registers
pub const scratch_regs = [_]Reg{ .rax, .rcx, .rdx, .rsi, .rdi, .r8, .r9, .r10, .r11 };
/// Callee-saved registers
pub const callee_saved = [_]Reg{ .rbx, .rbp, .r12, .r13, .r14, .r15 };

fn regNum(r: Reg) u4 {
    return @intFromEnum(r);
}

fn regNeedsRex(r: Reg) bool {
    return @intFromEnum(r) >= 8;
}

// ── Instruction types ─────────────────────────────────────────────────────────

pub const Scale = enum(u2) { x1 = 0, x2 = 1, x4 = 2, x8 = 3 };

pub const MemRef = struct {
    base: Reg,
    index: ?Reg = null,
    scale: Scale = .x1,
    disp: i32 = 0,
};

/// High-level instruction representation
pub const Instr = union(enum) {
    // Moves
    mov_rr:    struct { dst: Reg, src: Reg },       // mov dst, src  (64-bit)
    mov_ri:    struct { dst: Reg, imm: i64 },        // mov dst, imm64
    mov_rm:    struct { dst: Reg, src: MemRef, w64: bool = true },     // mov dst, [src]
    mov_mr:    struct { dst: MemRef, src: Reg, w64: bool = true },     // mov [dst], src
    mov_mi:    struct { dst: MemRef, imm: i32 },     // mov qword [dst], imm32
    movsx_rr:  struct { dst: Reg, src: Reg },        // movsx (sign-extend)
    movzx_rr:  struct { dst: Reg, src: Reg8 },      // movzx (zero-extend 8→64)
    lea:       struct { dst: Reg, src: MemRef },     // lea dst, [src]
    // Arithmetic (64-bit)
    add_rr:    struct { dst: Reg, src: Reg },
    add_ri:    struct { dst: Reg, imm: i32 },
    sub_rr:    struct { dst: Reg, src: Reg },
    sub_ri:    struct { dst: Reg, imm: i32 },
    imul_rr:   struct { dst: Reg, src: Reg },
    imul_rri:  struct { dst: Reg, src: Reg, imm: i32 },
    idiv_r:    struct { src: Reg },                  // idiv src  (rdx:rax / src)
    neg_r:     struct { reg: Reg },
    not_r:     struct { reg: Reg },
    // Bitwise
    and_rr:    struct { dst: Reg, src: Reg },
    and_ri:    struct { dst: Reg, imm: i32 },
    or_rr:     struct { dst: Reg, src: Reg },
    or_ri:     struct { dst: Reg, imm: i32 },
    xor_rr:    struct { dst: Reg, src: Reg },
    xor_ri:    struct { dst: Reg, imm: i32 },
    shl_r_cl:  struct { reg: Reg },                  // shl reg, cl
    shr_r_cl:  struct { reg: Reg },                  // shr reg, cl
    sar_r_cl:  struct { reg: Reg },                  // sar reg, cl
    shl_ri:    struct { reg: Reg, imm: u8 },
    shr_ri:    struct { reg: Reg, imm: u8 },
    sar_ri:    struct { reg: Reg, imm: u8 },
    // Comparison / flags
    cmp_rr:    struct { lhs: Reg, rhs: Reg },
    cmp_ri:    struct { lhs: Reg, imm: i32 },
    test_rr:   struct { lhs: Reg, rhs: Reg },
    // Set byte from flags
    sete:      struct { dst: Reg8 },
    setne:     struct { dst: Reg8 },
    setl:      struct { dst: Reg8 },
    setg:      struct { dst: Reg8 },
    setle:     struct { dst: Reg8 },
    setge:     struct { dst: Reg8 },
    // Control flow
    jmp_rel:   struct { label: u32 },                // label index
    jmp_r:     struct { reg: Reg },                  // jmp reg
    je_rel:    struct { label: u32 },
    jne_rel:   struct { label: u32 },
    jl_rel:    struct { label: u32 },
    jg_rel:    struct { label: u32 },
    jle_rel:   struct { label: u32 },
    jge_rel:   struct { label: u32 },
    call_rel:  struct { label: u32 },
    call_r:    struct { reg: Reg },
    ret_,
    // Stack
    push_r:    struct { reg: Reg },
    pop_r:     struct { reg: Reg },
    // System call
    syscall_,
    // No-op / alignment
    nop_,
    // Data (embedded literal bytes)
    db:        struct { bytes: []const u8 },
    // label definition (pseudo)
    label_def: struct { id: u32 },
};

// ── Assembler ─────────────────────────────────────────────────────────────────

pub const Reloc = struct {
    /// Offset in the output buffer where the 4-byte relative displacement should go.
    offset: u32,
    /// Target label id.
    label: u32,
    /// Instruction end offset (for PC-relative calculation).
    instr_end: u32,
};

pub const Assembler = struct {
    buf: std.array_list.AlignedManaged(u8, null),
    /// Map label_id → byte offset in buf
    label_offsets: std.AutoHashMap(u32, u32),
    /// Unresolved relocations
    relocs: std.array_list.AlignedManaged(Reloc, null),

    pub fn init(allocator: std.mem.Allocator) Assembler {
        return .{
            .buf = std.array_list.AlignedManaged(u8, null).init(allocator),
            .label_offsets = std.AutoHashMap(u32, u32).init(allocator),
            .relocs = std.array_list.AlignedManaged(Reloc, null).init(allocator),
        };
    }

    pub fn deinit(self: *Assembler) void {
        self.buf.deinit();
        self.label_offsets.deinit();
        self.relocs.deinit();
    }

    pub fn offset(self: *const Assembler) u32 {
        return @intCast(self.buf.items.len);
    }

    pub fn emit(self: *Assembler, instrs: []const Instr) !void {
        for (instrs) |instr| {
            try self.encodeOne(instr);
        }
    }

    pub fn encodeOne(self: *Assembler, instr: Instr) !void {
        switch (instr) {
            // ── Labels ────────────────────────────────────────────────────────
            .label_def => |l| {
                try self.label_offsets.put(l.id, self.offset());
            },

            // ── Moves ─────────────────────────────────────────────────────────
            .mov_rr => |m| {
                try self.rex(true, regNeedsRex(m.dst), false, regNeedsRex(m.src));
                try self.byte(0x8B);
                try self.modrmReg(m.src, m.dst);
            },
            .mov_ri => |m| {
                if (m.imm >= 0 and m.imm <= 0x7FFFFFFF) {
                    // 32-bit zero-extending immediate (5–7 bytes)
                    const r = regNum(m.dst);
                    if (regNeedsRex(m.dst)) try self.byte(0x41);
                    try self.byte(0xB8 | (@as(u8, r) & 7));
                    try self.imm32(@intCast(m.imm));
                } else {
                    // 64-bit immediate
                    try self.rex(true, false, false, regNeedsRex(m.dst));
                    const r = regNum(m.dst);
                    try self.byte(0xB8 | (@as(u8, r) & 7));
                    try self.imm64(m.imm);
                }
            },
            .mov_rm => |m| {
                try self.rexMem(m.w64, regNeedsRex(m.dst), m.src);
                try self.byte(0x8B);
                try self.modrmMem(m.dst, m.src);
            },
            .mov_mr => |m| {
                try self.rexMem(m.w64, regNeedsRex(m.src), m.dst);
                try self.byte(0x89);
                try self.modrmMemDst(m.src, m.dst);
            },
            .mov_mi => |m| {
                try self.rexMem(true, false, m.dst);
                try self.byte(0xC7);
                try self.modrmMemDst(@enumFromInt(0), m.dst);
                try self.imm32(m.imm);
            },
            .lea => |l| {
                try self.rexMem(true, regNeedsRex(l.dst), l.src);
                try self.byte(0x8D);
                try self.modrmMem(l.dst, l.src);
            },

            // ── Arithmetic ────────────────────────────────────────────────────
            .add_rr => |a| {
                try self.rex(true, regNeedsRex(a.src), false, regNeedsRex(a.dst));
                try self.byte(0x01);
                try self.modrmReg(a.dst, a.src);
            },
            .add_ri => |a| {
                try self.rex(true, false, false, regNeedsRex(a.dst));
                if (a.imm >= -128 and a.imm <= 127) {
                    try self.byte(0x83);
                    try self.modrmReg(@enumFromInt(0), a.dst); // /0
                    try self.byte(@bitCast(@as(i8, @intCast(a.imm))));
                } else {
                    try self.byte(0x81);
                    try self.modrmReg(@enumFromInt(0), a.dst);
                    try self.imm32(a.imm);
                }
            },
            .sub_rr => |s| {
                try self.rex(true, regNeedsRex(s.src), false, regNeedsRex(s.dst));
                try self.byte(0x29);
                try self.modrmReg(s.dst, s.src);
            },
            .sub_ri => |s| {
                try self.rex(true, false, false, regNeedsRex(s.dst));
                if (s.imm >= -128 and s.imm <= 127) {
                    try self.byte(0x83);
                    try self.modrmRegField(5, s.dst); // /5
                    try self.byte(@bitCast(@as(i8, @intCast(s.imm))));
                } else {
                    try self.byte(0x81);
                    try self.modrmRegField(5, s.dst);
                    try self.imm32(s.imm);
                }
            },
            .imul_rr => |m| {
                try self.rex(true, regNeedsRex(m.dst), false, regNeedsRex(m.src));
                try self.byte(0x0F);
                try self.byte(0xAF);
                try self.modrmReg(m.src, m.dst); // note: reversed — dst is reg field
            },
            .imul_rri => |m| {
                try self.rex(true, regNeedsRex(m.dst), false, regNeedsRex(m.src));
                if (m.imm >= -128 and m.imm <= 127) {
                    try self.byte(0x6B);
                    try self.modrmReg(m.src, m.dst);
                    try self.byte(@bitCast(@as(i8, @intCast(m.imm))));
                } else {
                    try self.byte(0x69);
                    try self.modrmReg(m.src, m.dst);
                    try self.imm32(m.imm);
                }
            },
            .idiv_r => |d| {
                try self.rex(true, false, false, regNeedsRex(d.src));
                try self.byte(0xF7);
                try self.modrmRegField(7, d.src);
            },
            .neg_r => |n| {
                try self.rex(true, false, false, regNeedsRex(n.reg));
                try self.byte(0xF7);
                try self.modrmRegField(3, n.reg);
            },
            .not_r => |n| {
                try self.rex(true, false, false, regNeedsRex(n.reg));
                try self.byte(0xF7);
                try self.modrmRegField(2, n.reg);
            },

            // ── Bitwise ───────────────────────────────────────────────────────
            .and_rr => |a| {
                try self.rex(true, regNeedsRex(a.src), false, regNeedsRex(a.dst));
                try self.byte(0x21);
                try self.modrmReg(a.dst, a.src);
            },
            .and_ri => |a| {
                try self.rex(true, false, false, regNeedsRex(a.dst));
                try self.byte(0x81);
                try self.modrmRegField(4, a.dst);
                try self.imm32(a.imm);
            },
            .or_rr => |o| {
                try self.rex(true, regNeedsRex(o.src), false, regNeedsRex(o.dst));
                try self.byte(0x09);
                try self.modrmReg(o.dst, o.src);
            },
            .or_ri => |o| {
                try self.rex(true, false, false, regNeedsRex(o.dst));
                try self.byte(0x81);
                try self.modrmRegField(1, o.dst);
                try self.imm32(o.imm);
            },
            .xor_rr => |x| {
                try self.rex(true, regNeedsRex(x.src), false, regNeedsRex(x.dst));
                try self.byte(0x31);
                try self.modrmReg(x.dst, x.src);
            },
            .xor_ri => |x| {
                try self.rex(true, false, false, regNeedsRex(x.dst));
                try self.byte(0x81);
                try self.modrmRegField(6, x.dst);
                try self.imm32(x.imm);
            },
            .shl_ri => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xC1);
                try self.modrmRegField(4, s.reg);
                try self.byte(s.imm);
            },
            .shr_ri => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xC1);
                try self.modrmRegField(5, s.reg);
                try self.byte(s.imm);
            },
            .sar_ri => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xC1);
                try self.modrmRegField(7, s.reg);
                try self.byte(s.imm);
            },
            .shl_r_cl => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xD3);
                try self.modrmRegField(4, s.reg);
            },
            .shr_r_cl => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xD3);
                try self.modrmRegField(5, s.reg);
            },
            .sar_r_cl => |s| {
                try self.rex(true, false, false, regNeedsRex(s.reg));
                try self.byte(0xD3);
                try self.modrmRegField(7, s.reg);
            },

            // ── Comparison ────────────────────────────────────────────────────
            .cmp_rr => |c| {
                try self.rex(true, regNeedsRex(c.rhs), false, regNeedsRex(c.lhs));
                try self.byte(0x39);
                try self.modrmReg(c.lhs, c.rhs);
            },
            .cmp_ri => |c| {
                try self.rex(true, false, false, regNeedsRex(c.lhs));
                if (c.imm >= -128 and c.imm <= 127) {
                    try self.byte(0x83);
                    try self.modrmRegField(7, c.lhs);
                    try self.byte(@bitCast(@as(i8, @intCast(c.imm))));
                } else {
                    try self.byte(0x81);
                    try self.modrmRegField(7, c.lhs);
                    try self.imm32(c.imm);
                }
            },
            .test_rr => |t| {
                try self.rex(true, regNeedsRex(t.rhs), false, regNeedsRex(t.lhs));
                try self.byte(0x85);
                try self.modrmReg(t.lhs, t.rhs);
            },

            // ── SETcc ─────────────────────────────────────────────────────────
            .sete  => |s| { try self.byte(0x0F); try self.byte(0x94); try self.modrmReg8(s.dst); },
            .setne => |s| { try self.byte(0x0F); try self.byte(0x95); try self.modrmReg8(s.dst); },
            .setl  => |s| { try self.byte(0x0F); try self.byte(0x9C); try self.modrmReg8(s.dst); },
            .setg  => |s| { try self.byte(0x0F); try self.byte(0x9F); try self.modrmReg8(s.dst); },
            .setle => |s| { try self.byte(0x0F); try self.byte(0x9E); try self.modrmReg8(s.dst); },
            .setge => |s| { try self.byte(0x0F); try self.byte(0x9D); try self.modrmReg8(s.dst); },

            // ── Jumps ─────────────────────────────────────────────────────────
            .jmp_rel => |j| {
                try self.byte(0xE9);
                try self.relocImm32(j.label);
            },
            .jmp_r => |j| {
                if (regNeedsRex(j.reg)) try self.byte(0x41);
                try self.byte(0xFF);
                try self.modrmRegField(4, j.reg);
            },
            .je_rel  => |j| { try self.byte(0x0F); try self.byte(0x84); try self.relocImm32(j.label); },
            .jne_rel => |j| { try self.byte(0x0F); try self.byte(0x85); try self.relocImm32(j.label); },
            .jl_rel  => |j| { try self.byte(0x0F); try self.byte(0x8C); try self.relocImm32(j.label); },
            .jg_rel  => |j| { try self.byte(0x0F); try self.byte(0x8F); try self.relocImm32(j.label); },
            .jle_rel => |j| { try self.byte(0x0F); try self.byte(0x8E); try self.relocImm32(j.label); },
            .jge_rel => |j| { try self.byte(0x0F); try self.byte(0x8D); try self.relocImm32(j.label); },

            // ── Call / Ret ────────────────────────────────────────────────────
            .call_rel => |c| {
                try self.byte(0xE8);
                try self.relocImm32(c.label);
            },
            .call_r => |c| {
                if (regNeedsRex(c.reg)) try self.byte(0x41);
                try self.byte(0xFF);
                try self.modrmRegField(2, c.reg);
            },
            .ret_ => try self.byte(0xC3),

            // ── Stack ─────────────────────────────────────────────────────────
            .push_r => |p| {
                if (regNeedsRex(p.reg)) try self.byte(0x41);
                try self.byte(0x50 | (@as(u8, @intFromEnum(p.reg)) & 7));
            },
            .pop_r => |p| {
                if (regNeedsRex(p.reg)) try self.byte(0x41);
                try self.byte(0x58 | (@as(u8, @intFromEnum(p.reg)) & 7));
            },

            // ── Misc ──────────────────────────────────────────────────────────
            .syscall_ => { try self.byte(0x0F); try self.byte(0x05); },
            .nop_     => try self.byte(0x90),
            .movzx_rr => |m| {
                try self.rex(true, regNeedsRex(m.dst), false, false);
                try self.byte(0x0F); try self.byte(0xB6);
                try self.byte(0xC0 | (@as(u8, @intFromEnum(m.dst)) << 3) | @intFromEnum(m.src));
            },
            .movsx_rr => |m| {
                try self.rex(true, regNeedsRex(m.dst), false, regNeedsRex(m.src));
                try self.byte(0x63);
                try self.modrmReg(m.src, m.dst);
            },
            .db => |d| try self.buf.appendSlice(d.bytes),
        }
    }

    /// Resolve all relocations once all labels are known.
    pub fn resolveRelocations(self: *Assembler) !void {
        for (self.relocs.items) |reloc| {
            const target = self.label_offsets.get(reloc.label) orelse return error.UndefinedLabel;
            const disp: i32 = @intCast(@as(i64, @intCast(target)) - @as(i64, @intCast(reloc.instr_end)));
            const bytes = std.mem.asBytes(&disp);
            @memcpy(self.buf.items[reloc.offset .. reloc.offset + 4], bytes);
        }
    }

    // ── Encoding helpers ─────────────────────────────────────────────────────

    fn byte(self: *Assembler, b: u8) !void {
        try self.buf.append(b);
    }

    fn imm32(self: *Assembler, v: i32) !void {
        const u: u32 = @bitCast(v);
        try self.buf.append(@truncate(u));
        try self.buf.append(@truncate(u >> 8));
        try self.buf.append(@truncate(u >> 16));
        try self.buf.append(@truncate(u >> 24));
    }

    fn imm64(self: *Assembler, v: i64) !void {
        const u: u64 = @bitCast(v);
        var i: u6 = 0;
        while (i < 8) : (i += 1) {
            try self.buf.append(@truncate(u >> @intCast(i * 8)));
        }
    }

    /// Emit a 4-byte placeholder + record a relocation.
    fn relocImm32(self: *Assembler, label: u32) !void {
        const off = self.offset();
        try self.imm32(0); // placeholder
        try self.relocs.append(Reloc{
            .offset = off,
            .label = label,
            .instr_end = self.offset(),
        });
    }

    /// REX prefix: W=1 (64-bit), R (reg extension), X (SIB index ext), B (rm/base ext)
    fn rex(self: *Assembler, w: bool, r: bool, x: bool, b: bool) !void {
        const byte_val: u8 = 0x40 |
            (@as(u8, if (w) 1 else 0) << 3) |
            (@as(u8, if (r) 1 else 0) << 2) |
            (@as(u8, if (x) 1 else 0) << 1) |
            (@as(u8, if (b) 1 else 0));
        if (byte_val != 0x40) try self.byte(byte_val);
    }

    fn rexMem(self: *Assembler, w: bool, reg_ext: bool, mem: MemRef) !void {
        const b_ext = regNeedsRex(mem.base);
        const x_ext = if (mem.index) |idx| regNeedsRex(idx) else false;
        try self.rex(w, reg_ext, x_ext, b_ext);
    }

    /// ModRM for reg ← reg (mod=11)
    fn modrmReg(self: *Assembler, rm: Reg, reg: Reg) !void {
        const modrm: u8 = 0xC0 |
            ((@as(u8, @intFromEnum(reg)) & 7) << 3) |
            (@as(u8, @intFromEnum(rm)) & 7);
        try self.byte(modrm);
    }

    /// ModRM for reg ← rm with a /N field in the reg position
    fn modrmRegField(self: *Assembler, field: u3, rm: Reg) !void {
        const modrm: u8 = 0xC0 | (@as(u8, field) << 3) | (@as(u8, @intFromEnum(rm)) & 7);
        try self.byte(modrm);
    }

    fn modrmReg8(self: *Assembler, rm: Reg8) !void {
        const modrm: u8 = 0xC0 | @as(u8, @intFromEnum(rm));
        try self.byte(modrm);
    }

    /// ModRM + SIB + disp for load: dst ← [base + disp]
    fn modrmMem(self: *Assembler, reg: Reg, mem: MemRef) !void {
        const base_enc: u8 = @as(u8, @intFromEnum(mem.base)) & 7;
        const reg_enc: u8 = (@as(u8, @intFromEnum(reg)) & 7) << 3;
        const disp = mem.disp;
        if (disp == 0 and base_enc != 5) {
            // mod=00
            if (base_enc == 4) {
                // RSP base requires SIB
                try self.byte(0x04 | reg_enc);
                try self.byte(0x24); // SIB: scale=0, index=none(4), base=RSP
            } else {
                try self.byte(reg_enc | base_enc);
            }
        } else if (disp >= -128 and disp <= 127) {
            // mod=01 disp8
            if (base_enc == 4) {
                try self.byte(0x44 | reg_enc);
                try self.byte(0x24);
            } else {
                try self.byte(0x40 | reg_enc | base_enc);
            }
            try self.byte(@bitCast(@as(i8, @intCast(disp))));
        } else {
            // mod=10 disp32
            if (base_enc == 4) {
                try self.byte(0x84 | reg_enc);
                try self.byte(0x24);
            } else {
                try self.byte(0x80 | reg_enc | base_enc);
            }
            try self.imm32(disp);
        }
    }

    /// ModRM + SIB + disp for store: [base + disp] ← src
    fn modrmMemDst(self: *Assembler, src: Reg, mem: MemRef) !void {
        return self.modrmMem(src, mem);
    }
};
