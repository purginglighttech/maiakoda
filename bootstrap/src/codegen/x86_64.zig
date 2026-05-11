/// x86_64 code generator.
/// Lowers IrModule to native x86_64 machine code via the Assembler.
/// Targets Linux ELF64, System V AMD64 ABI.

const std = @import("std");
const ir = @import("ir");
const asm_ = @import("assembler");
const sema = @import("sema");

const Reg = asm_.Reg;
const Instr = asm_.Instr;
const MemRef = asm_.MemRef;
const Value = ir.Value;
const VReg = ir.VReg;

// ── Register allocator (linear scan, single-pass) ─────────────────────────────

/// Physical register assignment for a VReg
const PhysReg = union(enum) {
    reg: Reg,
    spill: i32,  // stack offset from RBP (negative)
};

/// Records that a parameter arrived in `reg` and was spilled to `spill_off`.
const ParamSave = struct { reg: Reg, spill_off: i32 };

const RegAlloc = struct {
    map: std.AutoHashMap(VReg, PhysReg),
    /// Next available scratch slot on the stack (grows down from -8)
    next_spill: i32,
    /// Track which physical regs are in use
    used: [16]bool,
    allocator: std.mem.Allocator,
    /// Params to save: (ABI reg, spill offset) pairs, emitted after prologue
    param_saves: [8]ParamSave,
    param_save_count: u32,

    /// Allocatable registers — ONLY callee-saved registers.
    /// This ensures that local variables in registers survive function calls.
    /// Excluded:
    ///   rax — holds call return values, used as arithmetic scratch
    ///   r8  — spill/store/branch scratch (not in alloc_order)
    ///   r9  — indirect-call scratch (not in alloc_order)
    ///   rcx, rdx, rsi, rdi, r10, r11 — caller-saved, clobbered by callees
    /// With only 5 callee-saved registers, most complex functions will spill;
    /// spill correctness is ensured by the spillPersist mechanism.
    const alloc_order = [_]Reg{
        .rbx, .r12, .r13, .r14, .r15,
    };

    fn init(allocator: std.mem.Allocator) RegAlloc {
        return .{
            .map = std.AutoHashMap(VReg, PhysReg).init(allocator),
            .next_spill = 0,
            .used = std.mem.zeroes([16]bool),
            .allocator = allocator,
            .param_saves = std.mem.zeroes([8]ParamSave),
            .param_save_count = 0,
        };
    }

    fn deinit(self: *RegAlloc) void {
        self.map.deinit();
    }

    /// Assign a parameter to a spill slot (so it survives function calls).
    /// Record (reg, spill_off) so the prologue can emit the save.
    fn assignParam(self: *RegAlloc, vreg: VReg, reg: Reg) !void {
        self.next_spill -= 8;
        const off = self.next_spill;
        try self.map.put(vreg, PhysReg{ .spill = off });
        if (self.param_save_count < self.param_saves.len) {
            self.param_saves[self.param_save_count] = .{ .reg = reg, .spill_off = off };
            self.param_save_count += 1;
        }
    }

    fn alloc(self: *RegAlloc, vreg: VReg) !PhysReg {
        if (self.map.get(vreg)) |p| return p;
        // Find a free register
        for (alloc_order) |r| {
            const idx = @intFromEnum(r);
            if (!self.used[idx]) {
                self.used[idx] = true;
                const p = PhysReg{ .reg = r };
                try self.map.put(vreg, p);
                return p;
            }
        }
        // Spill to stack
        self.next_spill -= 8;
        const p = PhysReg{ .spill = self.next_spill };
        try self.map.put(vreg, p);
        return p;
    }

    fn get(self: *RegAlloc, vreg: VReg) PhysReg {
        return self.map.get(vreg) orelse PhysReg{ .reg = .rax };
    }

    fn stackSize(self: *const RegAlloc) u32 {
        const sz: i32 = -self.next_spill;
        // 16-byte align
        return @intCast((sz + 15) & ~@as(i32, 15));
    }
};

// ── Code generator ────────────────────────────────────────────────────────────

pub const CodegenResult = struct {
    /// Text (code) section bytes
    text: []u8,
    /// Read-only data section bytes (strings)
    rodata: []u8,
    /// Symbol table: name → offset in text
    symbols: std.StringHashMap(u32),
    /// String pool (in rodata)
    strings: []StringEntry,
    /// Locations in text where an extern function address (imm32) must be patched
    extern_calls: []ExternCallSite,
    /// Locations in text where a string rodata pointer (imm32) must be patched
    string_refs: []StringRef,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CodegenResult) void {
        self.allocator.free(self.text);
        self.allocator.free(self.rodata);
        self.symbols.deinit();
        self.allocator.free(self.strings);
        self.allocator.free(self.extern_calls);
        self.allocator.free(self.string_refs);
    }
};

pub const StringEntry = struct {
    offset: u32, // offset in rodata
    len: u32,
};

/// Records where in the text an extern function's address (imm32) must be patched.
pub const ExternCallSite = struct {
    imm_offset: u32,  // byte offset of the 4-byte immediate within the text section
    name: []const u8, // function name (e.g. "writeln")
};

/// Records where in the text a string pointer (imm32) must be patched.
pub const StringRef = struct {
    imm_offset: u32,  // byte offset of the 4-byte immediate within the text section
    string_idx: u32,  // index into string_pool / strings[]
};

fn is64bitType(ty: ir.TypeId) bool {
    // Always use 64-bit for general loads/stores.
    // Struct field 32-bit ops are emitted as calls to store32/load32 in ir.zig.
    _ = ty;
    return true;
}

pub const Codegen = struct {
    arena: std.mem.Allocator,
    asm_: asm_.Assembler,
    rodata: std.array_list.AlignedManaged(u8, null),
    string_entries: std.array_list.AlignedManaged(StringEntry, null),
    extern_call_sites: std.array_list.AlignedManaged(ExternCallSite, null),
    string_ref_sites: std.array_list.AlignedManaged(StringRef, null),
    /// Global label registry: function name → label id
    func_labels: std.StringHashMap(u32),
    next_label: u32,

    pub fn init(arena: std.mem.Allocator) Codegen {
        return .{
            .arena = arena,
            .asm_ = asm_.Assembler.init(arena),
            .rodata = std.array_list.AlignedManaged(u8, null).init(arena),
            .string_entries = std.array_list.AlignedManaged(StringEntry, null).init(arena),
            .extern_call_sites = std.array_list.AlignedManaged(ExternCallSite, null).init(arena),
            .string_ref_sites = std.array_list.AlignedManaged(StringRef, null).init(arena),
            .func_labels = std.StringHashMap(u32).init(arena),
            .next_label = 0,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.asm_.deinit();
        self.rodata.deinit();
        self.string_entries.deinit();
        self.extern_call_sites.deinit();
        self.string_ref_sites.deinit();
        self.func_labels.deinit();
    }

    fn freshLabel(self: *Codegen) u32 {
        const l = self.next_label;
        self.next_label += 1;
        return l;
    }

    pub fn generate(self: *Codegen, module: *ir.IrModule) !CodegenResult {
        // First pass: build string table entries in rodata
        for (module.string_pool.items) |s| {
            const off: u32 = @intCast(self.rodata.items.len);
            const len: u32 = @intCast(s.len);
            try self.rodata.appendSlice(s);
            try self.rodata.append(0); // null terminator
            try self.string_entries.append(StringEntry{ .offset = off, .len = len });
        }

        // First pass: assign label ids to all functions
        for (module.functions.items) |*f| {
            if (f.is_external) continue;
            const lbl = self.freshLabel();
            try self.func_labels.put(f.name, lbl);
        }

        // Second pass: generate code for each function
        for (module.functions.items) |*f| {
            if (f.is_external) continue;
            try self.genFunction(f, module);
        }

        // Resolve relocations
        try self.asm_.resolveRelocations();

        // Build symbol table
        var symbols = std.StringHashMap(u32).init(self.arena);
        var it = self.func_labels.iterator();
        while (it.next()) |entry| {
            const off = self.asm_.label_offsets.get(entry.value_ptr.*) orelse 0;
            try symbols.put(entry.key_ptr.*, off);
        }

        return CodegenResult{
            .text = try self.arena.dupe(u8, self.asm_.buf.items),
            .rodata = try self.arena.dupe(u8, self.rodata.items),
            .symbols = symbols,
            .strings = try self.string_entries.toOwnedSlice(),
            .extern_calls = try self.extern_call_sites.toOwnedSlice(),
            .string_refs = try self.string_ref_sites.toOwnedSlice(),
            .allocator = self.arena,
        };
    }

    fn genFunction(self: *Codegen, f: *ir.IrFunction, module: *ir.IrModule) !void {
        // Register the entry label
        const entry_label = self.func_labels.get(f.name).?;
        try self.asm_.encodeOne(Instr{ .label_def = .{ .id = entry_label } });

        // Register allocator
        var ra = RegAlloc.init(self.arena);
        defer ra.deinit();

        // Assign parameters to argument registers
        for (f.params, 0..) |p, i| {
            if (i < asm_.arg_regs.len) {
                try ra.assignParam(p.vreg, asm_.arg_regs[i]);
            } else {
                // Parameters past 6 are on the stack per ABI
                // For bootstrap: just use rax as fallback
                try ra.assignParam(p.vreg, .rax);
            }
        }

        // Pre-allocate all vregs that appear in the function
        for (f.blocks.items) |*b| {
            for (b.instrs.items) |instr| {
                try self.preAllocInstr(&ra, instr);
            }
        }

        // Save callee-saved registers that this function uses.
        // They are pushed BEFORE push rbp so that `mov rsp, rbp; pop rbp`
        // in the epilogue restores rsp to just before these saves, and the
        // caller's register state is preserved across our function calls.
        const callee_saved = [_]Reg{ .rbx, .r12, .r13, .r14, .r15 };
        for (callee_saved) |reg| {
            if (ra.used[@intFromEnum(reg)]) {
                try self.asm_.encodeOne(.{ .push_r = .{ .reg = reg } });
            }
        }

        // Function prologue
        const stack_sz = ra.stackSize() + 8; // +8 for alignment with push rbp
        const aligned_sz = (stack_sz + 15) & ~@as(u32, 15);
        try self.asm_.encodeOne(.{ .push_r = .{ .reg = .rbp } });
        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rbp, .src = .rsp } });
        if (aligned_sz > 0) {
            try self.asm_.encodeOne(.{ .sub_ri = .{ .dst = .rsp, .imm = @intCast(aligned_sz) } });
        }

        // Save parameters from ABI regs to their spill slots.
        // These must come AFTER `sub rsp, N` so the stack frame is ready.
        for (ra.param_saves[0..ra.param_save_count]) |ps| {
            try self.asm_.encodeOne(.{ .mov_mr = .{
                .dst = MemRef{ .base = .rbp, .disp = ps.spill_off },
                .src = ps.reg,
                .w64 = true,
            } });
        }

        // Assign block labels
        var block_labels = try self.arena.alloc(u32, f.blocks.items.len);
        for (f.blocks.items, 0..) |*b, i| {
            block_labels[i] = self.freshLabel();
            _ = b;
        }

        // Generate each basic block
        for (f.blocks.items, 0..) |*b, bi| {
            try self.asm_.encodeOne(Instr{ .label_def = .{ .id = block_labels[bi] } });
            for (b.instrs.items) |instr| {
                try self.genInstr(instr, &ra, block_labels, module, f);
            }
        }
    }

    fn preAllocInstr(self: *Codegen, ra: *RegAlloc, instr: ir.Instr) !void {
        _ = self;
        switch (instr) {
            .binop => |b| _ = try ra.alloc(b.dst),
            .unop  => |u| _ = try ra.alloc(u.dst),
            .copy  => |c| _ = try ra.alloc(c.dst),
            .cast  => |c| _ = try ra.alloc(c.dst),
            .call  => |c| _ = try ra.alloc(c.dst),
            .addr_of => |a| _ = try ra.alloc(a.dst),
            .load  => |l| _ = try ra.alloc(l.dst),
            .alloca => |a| _ = try ra.alloc(a.dst),
            .index_get => |i| _ = try ra.alloc(i.dst),
            .field_get => |f| _ = try ra.alloc(f.dst),
            .phi  => |p| _ = try ra.alloc(p.dst),
            else => {},
        }
    }

    fn genInstr(
        self: *Codegen,
        instr: ir.Instr,
        ra: *RegAlloc,
        block_labels: []u32,
        module: *ir.IrModule,
        fn_: *ir.IrFunction,
    ) !void {
        _ = fn_;
        switch (instr) {
            .copy => |c| {
                const dst = self.physReg(ra, c.dst);
                try self.loadValueRa(c.src, dst, module, ra);
                try self.spillPersist(ra, c.dst, dst);
            },
            .binop => |b| {
                const dst = self.physReg(ra, b.dst);
                try self.loadValueRa(b.lhs, dst, module, ra);
                // Use r8 as scratch — not in alloc_order, so safe from vreg conflicts.
                // If dst is r8 for some reason, fall back to r9.
                const tmp: Reg = if (dst == .r8) .r9 else .r8;
                    try self.loadValueRa(b.rhs, tmp, module, ra);
                switch (b.op) {
                    .add => try self.asm_.encodeOne(.{ .add_rr = .{ .dst = dst, .src = tmp } }),
                    .sub => try self.asm_.encodeOne(.{ .sub_rr = .{ .dst = dst, .src = tmp } }),
                    .mul => try self.asm_.encodeOne(.{ .imul_rr = .{ .dst = dst, .src = tmp } }),
                    .div, .int_div => {
                        // idiv: rdx:rax / src → rax (quotient), rdx (remainder)
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rax, .src = dst } });
                        try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = .rdx, .src = .rdx } });
                        try self.asm_.encodeOne(.{ .idiv_r = .{ .src = tmp } });
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = .rax } });
                    },
                    .mod => {
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rax, .src = dst } });
                        try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = .rdx, .src = .rdx } });
                        try self.asm_.encodeOne(.{ .idiv_r = .{ .src = tmp } });
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = .rdx } });
                    },
                    .eq  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .sete = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .ne  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .setne = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .lt  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .setl = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .gt  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .setg = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .le  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .setle = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .ge  => {
                        try self.asm_.encodeOne(.{ .cmp_rr = .{ .lhs = dst, .rhs = tmp } });
                                                try self.asm_.encodeOne(.{ .setge = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .and_ => try self.asm_.encodeOne(.{ .and_rr = .{ .dst = dst, .src = tmp } }),
                    .or_  => try self.asm_.encodeOne(.{ .or_rr  = .{ .dst = dst, .src = tmp } }),
                    .xor  => try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = dst, .src = tmp } }),
                    .shl  => {
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rcx, .src = tmp } });
                        try self.asm_.encodeOne(.{ .shl_r_cl = .{ .reg = dst } });
                    },
                    .shr  => {
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rcx, .src = tmp } });
                        try self.asm_.encodeOne(.{ .shr_r_cl = .{ .reg = dst } });
                    },
                }
                try self.spillPersist(ra, b.dst, dst);
            },
            .unop => |u| {
                const dst = self.physReg(ra, u.dst);
                try self.loadValueRa(u.src, dst, module, ra);
                switch (u.op) {
                    .neg => try self.asm_.encodeOne(.{ .neg_r = .{ .reg = dst } }),
                    .not_ => {
                        try self.asm_.encodeOne(.{ .test_rr = .{ .lhs = dst, .rhs = dst } });
                                                try self.asm_.encodeOne(.{ .sete = .{ .dst = .al } });
                        try self.asm_.encodeOne(.{ .movzx_rr = .{ .dst = dst, .src = .al } });
                    },
                    .bit_not => try self.asm_.encodeOne(.{ .not_r = .{ .reg = dst } }),
                }
                try self.spillPersist(ra, u.dst, dst);
            },
            .load => |l| {
                const dst = self.physReg(ra, l.dst);
                const load_w64 = is64bitType(l.ty);
                switch (l.addr) {
                    .vreg => |v| {
                        // If the addr vreg is spilled, we must first load the actual
                        // address from the spill slot into a scratch register.
                        const base: Reg = blk: {
                            if (ra.map.get(v)) |p| {
                                switch (p) {
                                    .spill => |off| {
                                        // Pick scratch ≠ dst to avoid conflict
                                        const sc: Reg = if (dst == .r8) .r9 else .r8;
                                        try self.asm_.encodeOne(.{ .mov_rm = .{
                                            .dst = sc,
                                            .src = MemRef{ .base = .rbp, .disp = off },
                                        }});
                                        break :blk sc;
                                    },
                                    .reg => |r| break :blk r,
                                }
                            } else break :blk .r8;
                        };
                        try self.asm_.encodeOne(.{ .mov_rm = .{
                            .dst = dst,
                            .src = MemRef{ .base = base, .disp = 0 },
                            .w64 = load_w64,
                        }});
                    },
                    else => try self.loadValueRa(l.addr, dst, module, ra),
                }
                // If dst vreg is spilled, write the result to its spill slot.
                if (ra.map.get(l.dst)) |p| {
                    switch (p) {
                        .spill => |off| {
                            try self.asm_.encodeOne(.{ .mov_mr = .{
                                .dst = MemRef{ .base = .rbp, .disp = off },
                                .src = dst,
                                .w64 = load_w64,
                            }});
                        },
                        .reg => {},
                    }
                }
            },
            .store => |s| {
                // Resolve the actual address register.  If addr vreg is spilled,
                // load the address from the spill slot into a scratch first.
                const store_w64 = is64bitType(s.ty);
                const addr_reg: Reg = switch (s.addr) {
                    .vreg => |v| blk: {
                        if (ra.map.get(v)) |p| {
                            switch (p) {
                                .spill => |off| {
                                    // Use r9 as the addr scratch so r8 stays free for src
                                    try self.asm_.encodeOne(.{ .mov_rm = .{
                                        .dst = .r9,
                                        .src = MemRef{ .base = .rbp, .disp = off },
                                    }});
                                    break :blk .r9;
                                },
                                .reg => |r| break :blk r,
                            }
                        } else break :blk .r8;
                    },
                    else => .r11,
                };
                // Use r8 as scratch for src (unless addr also uses r8, but addr uses r9 for spills)
                const src_reg: Reg = if (addr_reg == .r8) .r9 else .r8;
                try self.loadValueRa(s.src, src_reg, module, ra);
                switch (s.addr) {
                    .vreg => {
                        // Use addr_reg (already resolved above, including spill loads)
                        // NOT physReg(ra, v) which returns r8 for spills — that's stale.
                        try self.asm_.encodeOne(.{ .mov_mr = .{
                            .dst = MemRef{ .base = addr_reg, .disp = 0 },
                            .src = src_reg,
                            .w64 = store_w64,
                        }});
                    },
                    .global => |name| {
                        // RIP-relative store would require full relocation support
                        // For bootstrap: load address into r11 then store
                        _ = name;
                        try self.asm_.encodeOne(.{ .mov_mr = .{
                            .dst = MemRef{ .base = .r11, .disp = 0 },
                            .src = src_reg,
                            .w64 = store_w64,
                        }});
                    },
                    else => {},
                }
            },
            .alloca => |a| {
                const dst = self.physReg(ra, a.dst);
                // Allocate space on stack and return its address.
                // Both the register and spill cases sub rsp and return the address.
                try self.asm_.encodeOne(.{ .sub_ri = .{ .dst = .rsp, .imm = 8 } });
                try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = .rsp } });
                try self.spillPersist(ra, a.dst, dst);
            },
            .call => |c| {
                const dst = self.physReg(ra, c.dst);
                // Set up arguments in ABI registers
                for (c.args, 0..) |arg, i| {
                    if (i >= asm_.arg_regs.len) break;
                    try self.loadValueRa(arg, asm_.arg_regs[i], module, ra);
                }
                // Call
                switch (c.callee) {
                    .global => |name| {
                        // Check if it's a known internal function
                        if (self.func_labels.get(name)) |label| {
                            try self.asm_.encodeOne(.{ .call_rel = .{ .label = label } });
                        } else {
                            // External call: load address into r9, call r9.
                            // r9 is NOT in alloc_order so it is never assigned to a vreg —
                            // safe to use as a scratch across function boundaries.
                            // r9 (reg 9, no REX.B needed up to r9, but r9 >= 8 → REX.B needed):
                            // REX.B + B8+1 = 41 B9 + imm32 (5 bytes: REX + opcode + 4-byte imm)
                            // imm_off: after REX(1) + opcode(1) = 2 bytes offset.
                            const imm_off: u32 = @as(u32, @intCast(self.asm_.buf.items.len)) + 2;
                            try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = .r9, .imm = 0 } });
                            try self.asm_.encodeOne(.{ .call_r = .{ .reg = .r9 } });
                            try self.extern_call_sites.append(.{ .imm_offset = imm_off, .name = name });
                        }
                    },
                    .vreg => |v| {
                        const r = self.physReg(ra, v);
                        try self.asm_.encodeOne(.{ .call_r = .{ .reg = r } });
                    },
                    else => {
                        try self.asm_.encodeOne(.{ .call_r = .{ .reg = .r9 } });
                    },
                }
                // Return value is in rax; move to dst
                try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = .rax } });
                try self.spillPersist(ra, c.dst, dst);
            },
            .ret => |r| {
                if (r.value) |v| {
                    try self.loadValueRa(v, .rax, module, ra);
                } else {
                    try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = .rax, .src = .rax } });
                }
                // Epilogue: remove locals, restore frame pointer
                try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = .rsp, .src = .rbp } });
                try self.asm_.encodeOne(.{ .pop_r = .{ .reg = .rbp } });
                // Restore callee-saved registers in reverse order
                const callee_saved_ret = [_]Reg{ .rbx, .r12, .r13, .r14, .r15 };
                var ci: usize = callee_saved_ret.len;
                while (ci > 0) {
                    ci -= 1;
                    if (ra.used[@intFromEnum(callee_saved_ret[ci])]) {
                        try self.asm_.encodeOne(.{ .pop_r = .{ .reg = callee_saved_ret[ci] } });
                    }
                }
                try self.asm_.encodeOne(.ret_);
            },
            .jump => |j| {
                const target = block_labels[j.target];
                try self.asm_.encodeOne(.{ .jmp_rel = .{ .label = target } });
            },
            .branch => |b| {
                // Use r8 (not in alloc_order) to avoid clobbering vreg-allocated regs.
                try self.loadValueRa(b.cond, .r8, module, ra);
                try self.asm_.encodeOne(.{ .test_rr = .{ .lhs = .r8, .rhs = .r8 } });
                const true_label = block_labels[b.true_block];
                const false_label = block_labels[b.false_block];
                try self.asm_.encodeOne(.{ .jne_rel = .{ .label = true_label } });
                try self.asm_.encodeOne(.{ .jmp_rel = .{ .label = false_label } });
            },
            .cast => |c| {
                const dst = self.physReg(ra, c.dst);
                try self.loadValueRa(c.src, dst, module, ra);
                try self.spillPersist(ra, c.dst, dst);
            },
            .addr_of => |a| {
                const dst = self.physReg(ra, a.dst);
                switch (ra.get(a.src)) {
                    .spill => |off| {
                        try self.asm_.encodeOne(.{ .lea = .{
                            .dst = dst,
                            .src = MemRef{ .base = .rbp, .disp = off },
                        }});
                    },
                    .reg => |r| {
                        // Can't take address of a register directly; would need to spill first
                        // For bootstrap: move to rsp area
                        try self.asm_.encodeOne(.{ .push_r = .{ .reg = r } });
                        try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = .rsp } });
                    },
                }
            },
            .index_get => |i| {
                const dst = self.physReg(ra, i.dst);
                const arr_reg = Reg.r10;
                try self.loadValueRa(i.array, arr_reg, module, ra);
                const idx_reg = Reg.r11;
                try self.loadValueRa(i.idx, idx_reg, module, ra);
                try self.asm_.encodeOne(.{ .mov_rm = .{
                    .dst = dst,
                    .src = MemRef{ .base = arr_reg, .index = idx_reg, .scale = .x8, .disp = 0 },
                }});
                try self.spillPersist(ra, i.dst, dst);
            },
            .index_set => |i| {
                const arr_reg = Reg.r10;
                const idx_reg = Reg.r11;
                const src_reg = Reg.r9;
                try self.loadValueRa(i.array, arr_reg, module, ra);
                try self.loadValueRa(i.idx, idx_reg, module, ra);
                try self.loadValueRa(i.src, src_reg, module, ra);
                try self.asm_.encodeOne(.{ .mov_mr = .{
                    .dst = MemRef{ .base = arr_reg, .index = idx_reg, .scale = .x8, .disp = 0 },
                    .src = src_reg,
                }});
            },
            .field_get => |f| {
                const dst = self.physReg(ra, f.dst);
                try self.loadValueRa(f.obj, dst, module, ra);
                try self.asm_.encodeOne(.{ .mov_rm = .{
                    .dst = dst,
                    .src = MemRef{ .base = dst, .disp = 0 },
                }});
                try self.spillPersist(ra, f.dst, dst);
            },
            .field_set => |f| {
                const obj_reg = Reg.r10;
                const val_reg = Reg.r11;
                try self.loadValueRa(f.obj, obj_reg, module, ra);
                try self.loadValueRa(f.val, val_reg, module, ra);
                try self.asm_.encodeOne(.{ .mov_mr = .{
                    .dst = MemRef{ .base = obj_reg, .disp = 0 },
                    .src = val_reg,
                }});
            },
            .nop => try self.asm_.encodeOne(.nop_),
            .phi => {}, // handled by block arrangement
        }
    }

    fn physReg(self: *Codegen, ra: *RegAlloc, vreg: VReg) Reg {
        _ = self;
        const p = ra.get(vreg);
        return switch (p) {
            .reg => |r| r,
            // Use r8 as spill temp — r8 is NOT in alloc_order, so it is never
            // assigned to a vreg and is safe to use as a transient scratch here.
            .spill => .r8,
        };
    }

    /// After computing a result into `result_reg`, persist it to the spill slot
    /// if `vreg` is spilled.  Must be called after every instruction that writes
    /// to a destination vreg.
    fn spillPersist(self: *Codegen, ra: *RegAlloc, vreg: VReg, result_reg: Reg) !void {
        if (ra.map.get(vreg)) |p| {
            switch (p) {
                .spill => |off| {
                    try self.asm_.encodeOne(.{ .mov_mr = .{
                        .dst = asm_.MemRef{ .base = .rbp, .disp = off },
                        .src = result_reg,
                    }});
                },
                .reg => {},
            }
        }
    }

    fn loadValue(self: *Codegen, val: Value, dst: Reg, module: *ir.IrModule) !void {
        try self.loadValueRa(val, dst, module, null);
    }

    fn loadValueRa(self: *Codegen, val: Value, dst: Reg, module: *ir.IrModule, ra: ?*RegAlloc) !void {
        switch (val) {
            .imm_int => |i| {
                if (i == 0) {
                    try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = dst, .src = dst } });
                } else {
                    try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = i } });
                }
            },
            .imm_bool => |b| {
                try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = if (b) 1 else 0 } });
            },
            .imm_null => {
                try self.asm_.encodeOne(.{ .xor_rr = .{ .dst = dst, .src = dst } });
            },
            .imm_float => |f| {
                // Load float as integer bits into the register (for bootstrap)
                const bits: i64 = @bitCast(f);
                try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = bits } });
            },
            .vreg => |v| {
                // Move vreg's physical register value into dst.
                if (ra) |r| {
                    const phys = r.get(v);
                    switch (r.map.get(v) orelse PhysReg{ .reg = .rax }) {
                        .spill => |off| {
                            // Load from stack spill slot into dst
                            try self.asm_.encodeOne(.{ .mov_rm = .{
                                .dst = dst,
                                .src = asm_.MemRef{ .base = .rbp, .disp = off },
                            }});
                        },
                        .reg => |src_reg| {
                            if (src_reg != dst) {
                                try self.asm_.encodeOne(.{ .mov_rr = .{ .dst = dst, .src = src_reg } });
                            }
                        },
                    }
                    _ = phys;
                }
                // If ra is null, we cannot resolve the vreg — leave dst unchanged.
            },
            .string_const => |idx| {
                // Load pointer to string in rodata.
                // Emit a mov_ri with a placeholder imm32; the linker patches it
                // with the absolute virtual address (rodata_vaddr + string offset).
                // The imm32 starts after: optional REX (1 byte if r8–r15) + opcode (1 byte)
                const reg_num = @intFromEnum(dst);
                const rex_len: u32 = if (reg_num >= 8) 1 else 0;
                const imm_off: u32 = @as(u32, @intCast(self.asm_.buf.items.len)) + rex_len + 1;
                try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = 0 } });
                try self.string_ref_sites.append(.{ .imm_offset = imm_off, .string_idx = @intCast(idx) });
            },
            .global => |name| {
                // Check if this global is an integer constant
                for (module.globals.items) |g| {
                    if (std.mem.eql(u8, g.name, name)) {
                        if (g.init) |init_val| {
                            switch (init_val) {
                                .imm_int => |v| {
                                    try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = @intCast(v) } });
                                    return;
                                },
                                .imm_bool => |b| {
                                    try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = if (b) 1 else 0 } });
                                    return;
                                },
                                else => {},
                            }
                        }
                        break;
                    }
                }
                // Fall back: load address or zero for non-integer globals
                if (self.func_labels.get(name)) |label| {
                    _ = label;
                    try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = 0 } });
                } else {
                    try self.asm_.encodeOne(.{ .mov_ri = .{ .dst = dst, .imm = 0 } });
                }
            },
        }
    }
};

// NOTE: RIP-relative addressing for string constants is approximated by the
// linker patching the displacement after section layout is known.
// The `loadValue(.string_const, …)` path emits a LEA with a zero displacement
// that is fixed up by the linker at link time.
