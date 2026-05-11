/// Maia IR (Intermediate Representation).
/// Three-address code organized into functions → basic blocks → instructions.
/// Register-based; all temporaries are virtual registers (VReg).

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

pub const TypeId = sema.TypeId;

// ── Value types ───────────────────────────────────────────────────────────────

/// Virtual register index
pub const VReg = u32;
pub const VREG_INVALID: VReg = std.math.maxInt(VReg);

/// An IR value: either a virtual register or an immediate constant.
pub const Value = union(enum) {
    vreg: VReg,
    imm_int: i64,
    imm_float: f64,
    imm_bool: bool,
    imm_null,
    global: []const u8,   // reference to a named global / function
    string_const: u32,    // index into Module.string_pool

    pub fn isImm(self: Value) bool {
        return switch (self) {
            .vreg, .global => false,
            else => true,
        };
    }
};

// ── Instructions ──────────────────────────────────────────────────────────────

pub const BinOp = enum {
    add, sub, mul, div, mod, int_div,
    eq, ne, lt, gt, le, ge,
    and_, or_, xor,
    shl, shr,
};

pub const UnOp = enum { neg, not_, bit_not };

pub const Instr = union(enum) {
    // dst := op lhs, rhs
    binop: struct { dst: VReg, op: BinOp, lhs: Value, rhs: Value, ty: TypeId },
    // dst := op src
    unop: struct { dst: VReg, op: UnOp, src: Value, ty: TypeId },
    // dst := src  (copy / move)
    copy: struct { dst: VReg, src: Value, ty: TypeId },
    // dst := (cast) src
    cast: struct { dst: VReg, src: Value, from_ty: TypeId, to_ty: TypeId },
    // dst := call callee(args…)
    call: struct { dst: VReg, callee: Value, args: []Value, ty: TypeId },
    // dst := &src
    addr_of: struct { dst: VReg, src: VReg, ty: TypeId },
    // dst := *src
    load: struct { dst: VReg, addr: Value, ty: TypeId },
    // *dst := src
    store: struct { addr: Value, src: Value, ty: TypeId },
    // dst := src[idx]
    index_get: struct { dst: VReg, array: Value, idx: Value, elem_ty: TypeId },
    // array[idx] := src
    index_set: struct { array: Value, idx: Value, src: Value, elem_ty: TypeId },
    // dst := src.field
    field_get: struct { dst: VReg, obj: Value, field: []const u8, ty: TypeId },
    // src.field := val
    field_set: struct { obj: Value, field: []const u8, val: Value, ty: TypeId },
    // Unconditional jump
    jump: struct { target: BlockId },
    // Conditional branch: if cond jump true_block else false_block
    branch: struct { cond: Value, true_block: BlockId, false_block: BlockId },
    // Return (optional value)
    ret: struct { value: ?Value },
    // alloca: allocate stack slot, returns pointer
    alloca: struct { dst: VReg, ty: TypeId, count: u32 },
    // nop
    nop,
    // phi (for SSA): dst := phi [(val, pred), …]
    phi: struct { dst: VReg, incoming: []PhiIncoming, ty: TypeId },
};

pub const PhiIncoming = struct {
    value: Value,
    block: BlockId,
};

// ── Basic block ───────────────────────────────────────────────────────────────

pub const BlockId = u32;

pub const BasicBlock = struct {
    id: BlockId,
    label: []const u8,
    instrs: std.array_list.AlignedManaged(Instr, null),
    preds: std.array_list.AlignedManaged(BlockId, null),

    pub fn init(allocator: std.mem.Allocator, id: BlockId, label: []const u8) BasicBlock {
        return .{
            .id = id,
            .label = label,
            .instrs = std.array_list.AlignedManaged(Instr, null).init(allocator),
            .preds = std.array_list.AlignedManaged(BlockId, null).init(allocator),
        };
    }

    pub fn deinit(self: *BasicBlock) void {
        self.instrs.deinit();
        self.preds.deinit();
    }

    pub fn append(self: *BasicBlock, instr: Instr) !void {
        try self.instrs.append(instr);
    }

    pub fn isTerminated(self: *const BasicBlock) bool {
        if (self.instrs.items.len == 0) return false;
        return switch (self.instrs.items[self.instrs.items.len - 1]) {
            .jump, .branch, .ret => true,
            else => false,
        };
    }
};

// ── Function ──────────────────────────────────────────────────────────────────

pub const Param = struct {
    name: []const u8,
    vreg: VReg,
    ty: TypeId,
};

pub const IrFunction = struct {
    name: []const u8,
    params: []Param,
    ret_ty: TypeId,
    blocks: std.array_list.AlignedManaged(BasicBlock, null),
    next_vreg: VReg,
    next_block: BlockId,
    current_block_id: BlockId,  // tracks which block to emit into
    allocator: std.mem.Allocator,
    is_external: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        params: []Param,
        ret_ty: TypeId,
    ) IrFunction {
        return .{
            .name = name,
            .params = params,
            .ret_ty = ret_ty,
            .blocks = std.array_list.AlignedManaged(BasicBlock, null).init(allocator),
            .next_vreg = @intCast(params.len),
            .next_block = 0,
            .current_block_id = 0,
            .allocator = allocator,
            .is_external = false,
        };
    }

    pub fn deinit(self: *IrFunction) void {
        for (self.blocks.items) |*b| b.deinit();
        self.blocks.deinit();
    }

    pub fn freshVReg(self: *IrFunction) VReg {
        const v = self.next_vreg;
        self.next_vreg += 1;
        return v;
    }

    pub fn addBlock(self: *IrFunction, label: []const u8) !BlockId {
        const id = self.next_block;
        self.next_block += 1;
        try self.blocks.append(BasicBlock.init(self.allocator, id, label));
        return id;
    }

    /// Switch the emission target to the block with the given ID.
    pub fn switchToBlock(self: *IrFunction, id: BlockId) void {
        self.current_block_id = id;
    }

    pub fn currentBlock(self: *IrFunction) *BasicBlock {
        return &self.blocks.items[self.current_block_id];
    }

    pub fn getBlock(self: *IrFunction, id: BlockId) *BasicBlock {
        return &self.blocks.items[id];
    }

    pub fn emit(self: *IrFunction, instr: Instr) !void {
        try self.currentBlock().append(instr);
    }
};

// ── Module ────────────────────────────────────────────────────────────────────

pub const Global = struct {
    name: []const u8,
    ty: TypeId,
    init: ?Value,
    is_const: bool,
};

pub const IrModule = struct {
    functions: std.array_list.AlignedManaged(IrFunction, null),
    globals: std.array_list.AlignedManaged(Global, null),
    string_pool: std.array_list.AlignedManaged([]const u8, null),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) IrModule {
        return .{
            .functions = std.array_list.AlignedManaged(IrFunction, null).init(allocator),
            .globals = std.array_list.AlignedManaged(Global, null).init(allocator),
            .string_pool = std.array_list.AlignedManaged([]const u8, null).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IrModule) void {
        for (self.functions.items) |*f| f.deinit();
        self.functions.deinit();
        self.globals.deinit();
        self.string_pool.deinit();
    }

    pub fn internString(self: *IrModule, s: []const u8) !u32 {
        for (self.string_pool.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, s)) return @intCast(i);
        }
        const idx: u32 = @intCast(self.string_pool.items.len);
        try self.string_pool.append(s);
        return idx;
    }
};

// ── IR Builder ────────────────────────────────────────────────────────────────
/// Lowers the AST + Sema output into IrModule.

/// Unwraps ownership-qualified TypeExprs (mut T, ref T, etc.) to get the inner
/// named struct type, if it exists in struct_defs. Returns null otherwise.
fn innerStructName(te: *ast.TypeExpr, struct_defs: *const std.StringHashMap(sema.StructLayout)) ?[]const u8 {
    var cur = te;
    while (true) {
        switch (cur.*) {
            .named => |n| {
                if (struct_defs.contains(n.name)) return n.name;
                return null;
            },
            .owned => |o| { cur = o.inner; },
            .optional => |o| { cur = o.inner; },
            .pointer => |p| { cur = p.inner; },
            else => return null,
        }
    }
}

pub const Builder = struct {
    module: *IrModule,
    sema: *sema.Sema,
    arena: std.mem.Allocator,
    current_fn: ?*IrFunction,
    locals: std.StringHashMap(VReg),
    // Variable name → struct type name for field-access resolution in IR lowering.
    // The sema current_scope reverts to global after analysis, so local var types
    // must be tracked here during lowering.
    local_types: std.StringHashMap([]const u8),
    loop_exit_block: ?BlockId,
    loop_cond_block: ?BlockId,

    pub fn init(
        arena: std.mem.Allocator,
        module: *IrModule,
        s: *sema.Sema,
    ) Builder {
        return .{
            .module = module,
            .sema = s,
            .arena = arena,
            .current_fn = null,
            .locals = std.StringHashMap(VReg).init(arena),
            .local_types = std.StringHashMap([]const u8).init(arena),
            .loop_exit_block = null,
            .loop_cond_block = null,
        };
    }

    pub fn lowerModule(self: *Builder, mod: *ast.Module) !void {
        for (mod.decls) |*decl| {
            try self.lowerDecl(decl);
        }
    }

    fn lowerDecl(self: *Builder, decl: *ast.Decl) !void {
        switch (decl.*) {
            .func_decl => |*f| {
                if (f.body == null) return;
                try self.lowerFunction(f.name, f.params, f.ret, f.body.?);
            },
            .proc_decl => |*p| {
                if (p.body == null) return;
                try self.lowerFunction(p.name, p.params, null, p.body.?);
            },
            .const_decl => |*cd| {
                const val = self.evalConstExpr(cd.value);
                const ty: TypeId = if (cd.ty) |t| (self.sema.resolveType(t) catch sema.TYPE_INT32) else sema.TYPE_INT32;
                try self.module.globals.append(Global{
                    .name = cd.name,
                    .ty = ty,
                    .init = val,
                    .is_const = true,
                });
            },
            .var_decl => |*vd| {
                const ty: TypeId = if (vd.ty) |t| (self.sema.resolveType(t) catch sema.TYPE_INT32) else sema.TYPE_INT32;
                const init_val = if (vd.init) |ie| self.evalConstExpr(ie) else null;
                try self.module.globals.append(Global{
                    .name = vd.name,
                    .ty = ty,
                    .init = init_val,
                    .is_const = false,
                });
            },
            .extern_decl => |*ed| {
                switch (ed.item.*) {
                    .func_decl => |*f| {
                        const params = try self.buildParams(f.params);
                        const ret_ty: TypeId = if (f.ret) |r| (self.sema.resolveType(r) catch sema.TYPE_VOID) else sema.TYPE_VOID;
                        var fn_ = IrFunction.init(self.arena, f.name, params, ret_ty);
                        fn_.is_external = true;
                        try self.module.functions.append(fn_);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn lowerFunction(
        self: *Builder,
        name: []const u8,
        ast_params: []ast.Param,
        ret: ?*ast.TypeExpr,
        body: *ast.Stmt,
    ) !void {
        const params = try self.buildParams(ast_params);
        const ret_ty: TypeId = if (ret) |r| (self.sema.resolveType(r) catch sema.TYPE_VOID) else sema.TYPE_VOID;

        const fn_ = IrFunction.init(self.arena, name, params, ret_ty);
        try self.module.functions.append(fn_);
        self.current_fn = &self.module.functions.items[self.module.functions.items.len - 1];

        // Reset locals and type tracking
        self.locals.clearRetainingCapacity();
        self.local_types.clearRetainingCapacity();

        // Entry block
        const entry_id = try self.current_fn.?.addBlock("entry");
        self.current_fn.?.switchToBlock(entry_id);

        // Bind params: alloca a stack slot, store the incoming register value,
        // then access via the slot address.
        for (params, 0..) |p, i| {
            const slot = self.current_fn.?.freshVReg();
            try self.current_fn.?.emit(Instr{ .alloca = .{ .dst = slot, .ty = sema.TYPE_INT32, .count = 1 } });
            try self.current_fn.?.emit(Instr{ .store  = .{ .addr = .{ .vreg = slot }, .src = .{ .vreg = @intCast(i) }, .ty = sema.TYPE_INT32 } });
            try self.locals.put(p.name, slot);
            // Track struct type name for parameters
            if (ast_params[i].ty) |te| {
                if (innerStructName(te, &self.sema.struct_defs)) |sn| {
                    try self.local_types.put(p.name, sn);
                }
            }
        }

        try self.lowerStmt(body);

        // Ensure terminator
        const last_block = self.current_fn.?.currentBlock();
        if (!last_block.isTerminated()) {
            try self.current_fn.?.emit(Instr{ .ret = .{ .value = null } });
        }
    }

    fn buildParams(self: *Builder, ast_params: []ast.Param) ![]Param {
        const params = try self.arena.alloc(Param, ast_params.len);
        for (ast_params, 0..) |p, i| {
            const ty: TypeId = if (p.ty) |t| (self.sema.resolveType(t) catch sema.TYPE_INT32) else sema.TYPE_INT32;
            params[i] = Param{
                .name = p.name,
                .vreg = @intCast(i),
                .ty = ty,
            };
        }
        return params;
    }

    fn lowerStmt(self: *Builder, stmt: *ast.Stmt) !void {
        const fn_ = self.current_fn.?;
        switch (stmt.*) {
            .block => |b| {
                for (b.stmts) |s| try self.lowerStmt(s);
            },
            .var_decl => |*vd| {
                const ty: TypeId = if (vd.ty) |t| (self.sema.resolveType(t) catch sema.TYPE_INT32) else sema.TYPE_INT32;
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .alloca = .{ .dst = dst, .ty = ty, .count = 1 } });
                try self.locals.put(vd.name, dst);
                // Track struct type name for field-access resolution
                if (vd.ty) |t| {
                    if (innerStructName(t, &self.sema.struct_defs)) |sn| {
                        try self.local_types.put(vd.name, sn);
                    }
                } else if (vd.init) |init_expr| {
                    // Infer struct type from initializer (call expression return type)
                    if (init_expr.* == .call) {
                        if (init_expr.call.callee.* == .ident) {
                            const callee_name = init_expr.call.callee.ident.name;
                            if (self.sema.current_scope.lookup(callee_name)) |sym| {
                                if (self.sema.getType(sym.ty)) |fty| {
                                    if (fty.* == .func) {
                                        if (self.sema.getType(fty.func.ret)) |rty| {
                                            if (rty.* == .named) {
                                                if (self.sema.struct_defs.contains(rty.named)) {
                                                    try self.local_types.put(vd.name, rty.named);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (vd.init) |init_expr| {
                    const val = try self.lowerExpr(init_expr);
                    try fn_.emit(Instr{ .store = .{ .addr = .{ .vreg = dst }, .src = val, .ty = ty } });
                }
            },
            .const_decl => |*cd| {
                const ty: TypeId = if (cd.ty) |t| (self.sema.resolveType(t) catch sema.TYPE_INT32) else sema.TYPE_INT32;
                const val = try self.lowerExpr(cd.value);
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .alloca = .{ .dst = dst, .ty = ty, .count = 1 } });
                try fn_.emit(Instr{ .store = .{ .addr = .{ .vreg = dst }, .src = val, .ty = ty } });
                try self.locals.put(cd.name, dst);
            },
            .assign => |a| {
                const rhs = try self.lowerExpr(a.value);
                const ty: TypeId = sema.TYPE_INT32;
                switch (a.target.*) {
                    .ident => |id| {
                        if (self.locals.get(id.name)) |addr_vreg| {
                            try fn_.emit(Instr{ .store = .{ .addr = .{ .vreg = addr_vreg }, .src = rhs, .ty = ty } });
                        } else {
                            try fn_.emit(Instr{ .store = .{ .addr = .{ .global = id.name }, .src = rhs, .ty = ty } });
                        }
                    },
                    .index => |i| {
                        const arr = try self.lowerExpr(i.array);
                        const idx = try self.lowerExpr(i.index);
                        try fn_.emit(Instr{ .index_set = .{ .array = arr, .idx = idx, .src = rhs, .elem_ty = ty } });
                    },
                    .field => |f| {
                        const obj = try self.lowerExpr(f.receiver);
                        const struct_name = self.getExprStructName(f.receiver);
                        const field_offset = if (struct_name.len > 0) self.sema.getFieldOffset(struct_name, f.field) else 0;
                        // Determine field size from struct layout
                        var field_size: u32 = 4;
                        if (struct_name.len > 0) {
                            if (self.sema.struct_defs.get(struct_name)) |layout| {
                                for (layout.fields) |fl| {
                                    if (std.mem.eql(u8, fl.name, f.field)) {
                                        field_size = fl.size;
                                        break;
                                    }
                                }
                            }
                        }
                        // Compute address (ptr + offset for non-zero offsets)
                        const addr_value: Value = if (field_offset == 0) obj else blk: {
                            const addr_dst = fn_.freshVReg();
                            try fn_.emit(Instr{ .binop = .{
                                .dst = addr_dst, .op = .add,
                                .lhs = obj,
                                .rhs = Value{ .imm_int = @as(i64, field_offset) },
                                .ty = sema.TYPE_UINT64,
                            }});
                            break :blk Value{ .vreg = addr_dst };
                        };
                        if (field_size == 4) {
                            // Use store32 extern to avoid 64-bit write corrupting adjacent fields
                            const call_args = try self.arena.alloc(Value, 2);
                            call_args[0] = addr_value;
                            call_args[1] = rhs;
                            const call_dst = fn_.freshVReg();
                            try fn_.emit(Instr{ .call = .{ .dst = call_dst, .callee = Value{ .global = "store32" }, .args = call_args, .ty = sema.TYPE_VOID } });
                        } else {
                            try fn_.emit(Instr{ .store = .{ .addr = addr_value, .src = rhs, .ty = sema.TYPE_UINT64 } });
                        }
                    },
                    else => {
                        // Compound assignments: load, op, store
                        const lhs = try self.lowerExpr(a.target);
                        const binop: BinOp = switch (a.op) {
                            .add_assign => .add,
                            .sub_assign => .sub,
                            .mul_assign => .mul,
                            .div_assign => .div,
                            .mod_assign => .mod,
                            .and_assign => .and_,
                            .or_assign  => .or_,
                            .xor_assign => .xor,
                            .shl_assign => .shl,
                            .shr_assign => .shr,
                            else => { try fn_.emit(Instr.nop); return; },
                        };
                        const result = fn_.freshVReg();
                        try fn_.emit(Instr{ .binop = .{ .dst = result, .op = binop, .lhs = lhs, .rhs = rhs, .ty = ty } });
                        // Store result back (simplified)
                    },
                }
            },
            .expr_stmt => |es| {
                _ = try self.lowerExpr(es.expr);
            },
            .if_stmt => |ifs| {
                const cond_val = try self.lowerExpr(ifs.cond);
                const then_id = try fn_.addBlock("if_then");
                const else_id = try fn_.addBlock("if_else");
                const merge_id = try fn_.addBlock("if_merge");

                // Emit branch into the current block (the one active before the if's
                // sub-blocks were created).  Using current_block_id is correct for any
                // nesting depth; the old `len-4` offset was only valid at top level.
                try fn_.emit(Instr{ .branch = .{ .cond = cond_val, .true_block = then_id, .false_block = else_id } });

                // Then block: emit the then-branch, then add a jump-to-merge
                // to the CURRENT block (which may be an inner if_merge if the
                // then-branch itself contained nested control flow).
                self.switchToBlock(fn_, then_id);
                try self.lowerStmt(ifs.then_branch);
                if (!fn_.currentBlock().isTerminated()) {
                    try fn_.emit(Instr{ .jump = .{ .target = merge_id } });
                }

                // Else block: same principle.
                self.switchToBlock(fn_, else_id);
                if (ifs.else_branch) |eb| {
                    try self.lowerStmt(eb);
                }
                if (!fn_.currentBlock().isTerminated()) {
                    try fn_.emit(Instr{ .jump = .{ .target = merge_id } });
                }

                self.switchToBlock(fn_, merge_id);
            },
            .while_stmt => |ws| {
                const cond_id = try fn_.addBlock("while_cond");
                const body_id = try fn_.addBlock("while_body");
                const exit_id = try fn_.addBlock("while_exit");

                try fn_.emit(Instr{ .jump = .{ .target = cond_id } });
                self.switchToBlock(fn_, cond_id);
                const cond_val = try self.lowerExpr(ws.cond);
                try fn_.emit(Instr{ .branch = .{ .cond = cond_val, .true_block = body_id, .false_block = exit_id } });

                self.switchToBlock(fn_, body_id);
                const prev_exit = self.loop_exit_block;
                const prev_cond = self.loop_cond_block;
                self.loop_exit_block = exit_id;
                self.loop_cond_block = cond_id;
                try self.lowerStmt(ws.body);
                self.loop_exit_block = prev_exit;
                self.loop_cond_block = prev_cond;
                // Add loop-back jump to the CURRENT block (which may be an inner
                // if_merge, not body_id, if the body contained nested control flow).
                if (!fn_.currentBlock().isTerminated()) {
                    try fn_.emit(Instr{ .jump = .{ .target = cond_id } });
                }

                self.switchToBlock(fn_, exit_id);
            },
            .for_stmt => |fs| {
                // for item in iter do … end
                // Simplification: iter is a range; we allocate index var
                const iter_val = try self.lowerExpr(fs.iter);
                _ = iter_val;
                const loop_idx = fn_.freshVReg();
                const item_vreg = fn_.freshVReg();
                try self.locals.put(fs.item_var, item_vreg);
                if (fs.index_var) |iv| try self.locals.put(iv, loop_idx);

                const cond_id = try fn_.addBlock("for_cond");
                const body_id = try fn_.addBlock("for_body");
                const exit_id = try fn_.addBlock("for_exit");

                try fn_.emit(Instr{ .jump = .{ .target = cond_id } });
                self.switchToBlock(fn_, cond_id);
                // Placeholder condition (always true for now — real range iteration handled by codegen)
                const cond_vreg = fn_.freshVReg();
                try fn_.emit(Instr{ .copy = .{ .dst = cond_vreg, .src = .{ .imm_bool = true }, .ty = sema.TYPE_BOOL } });
                try fn_.emit(Instr{ .branch = .{ .cond = .{ .vreg = cond_vreg }, .true_block = body_id, .false_block = exit_id } });

                self.switchToBlock(fn_, body_id);
                const prev_exit = self.loop_exit_block;
                self.loop_exit_block = exit_id;
                try self.lowerStmt(fs.body);
                self.loop_exit_block = prev_exit;
                if (!fn_.currentBlock().isTerminated()) {
                    try fn_.emit(Instr{ .jump = .{ .target = cond_id } });
                }
                self.switchToBlock(fn_, exit_id);
            },
            .loop_stmt => |ls| {
                const body_id = try fn_.addBlock("loop_body");
                const exit_id = try fn_.addBlock("loop_exit");
                try fn_.emit(Instr{ .jump = .{ .target = body_id } });
                self.switchToBlock(fn_, body_id);
                const prev_exit = self.loop_exit_block;
                self.loop_exit_block = exit_id;
                try self.lowerStmt(ls.body);
                self.loop_exit_block = prev_exit;
                if (!fn_.currentBlock().isTerminated()) {
                    try fn_.emit(Instr{ .jump = .{ .target = body_id } });
                }
                self.switchToBlock(fn_, exit_id);
            },
            .break_stmt => {
                if (self.loop_exit_block) |exit| {
                    try fn_.emit(Instr{ .jump = .{ .target = exit } });
                }
            },
            .continue_stmt => {
                if (self.loop_cond_block) |cond| {
                    try fn_.emit(Instr{ .jump = .{ .target = cond } });
                }
            },
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    const val = try self.lowerExpr(v);
                    try fn_.emit(Instr{ .ret = .{ .value = val } });
                } else {
                    try fn_.emit(Instr{ .ret = .{ .value = null } });
                }
            },
            .match_stmt => |ms| {
                const subj = try self.lowerExpr(ms.subject);
                const exit_id = try fn_.addBlock("match_exit");
                for (ms.arms) |arm| {
                    const arm_id = try fn_.addBlock("match_arm");
                    const next_id = try fn_.addBlock("match_next");
                    // Generate condition check
                    const match_cond = fn_.freshVReg();
                    const pattern_val: Value = switch (arm.pattern) {
                        .int_lit => |i| .{ .imm_int = i.value },
                        .ident => |id| .{ .imm_bool = std.mem.eql(u8, id.name, "true") },
                        .else_ => {
                            // Unconditional: always taken
                            try fn_.emit(Instr{ .jump = .{ .target = arm_id } });
                            self.switchToBlock(fn_, arm_id);
                            try self.lowerStmt(arm.body);
                            if (!fn_.getBlock(arm_id).isTerminated()) {
                                try fn_.getBlock(arm_id).append(Instr{ .jump = .{ .target = exit_id } });
                            }
                            self.switchToBlock(fn_, exit_id);
                            return; // done
                        },
                        else => .{ .imm_int = 0 },
                    };
                    _ = pattern_val;
                    _ = match_cond;
                    _ = subj;
                    self.switchToBlock(fn_, arm_id);
                    try self.lowerStmt(arm.body);
                    if (!fn_.getBlock(arm_id).isTerminated()) {
                        try fn_.getBlock(arm_id).append(Instr{ .jump = .{ .target = exit_id } });
                    }
                    self.switchToBlock(fn_, next_id);
                }
                try fn_.emit(Instr{ .jump = .{ .target = exit_id } });
                self.switchToBlock(fn_, exit_id);
            },
            .defer_stmt => |ds| {
                // Simple implementation: inline the deferred stmt immediately
                // A proper implementation would use a defer stack
                try self.lowerStmt(ds.body);
            },
            .safe_block => |sb| {
                try self.lowerStmt(sb.body);
            },
            .unsafe_block => |sb| {
                try self.lowerStmt(sb.body);
            },
        }
    }

    fn switchToBlock(self: *Builder, fn_: *IrFunction, id: BlockId) void {
        _ = self;
        fn_.switchToBlock(id);
    }

    fn lowerExpr(self: *Builder, expr: *ast.Expr) !Value {
        const fn_ = self.current_fn.?;
        switch (expr.*) {
            .int_lit => |i| return Value{ .imm_int = i.value },
            .float_lit => |f| return Value{ .imm_float = f.value },
            .bool_lit => |b| return Value{ .imm_bool = b.value },
            .null_lit => return Value.imm_null,
            .string_lit => |s| {
                const idx = try self.module.internString(s.value);
                return Value{ .string_const = idx };
            },
            .ident => |id| {
                if (self.locals.get(id.name)) |addr_vreg| {
                    // Load from the alloca'd slot
                    const dst = fn_.freshVReg();
                    try fn_.emit(Instr{ .load = .{ .dst = dst, .addr = .{ .vreg = addr_vreg }, .ty = sema.TYPE_INT32 } });
                    return Value{ .vreg = dst };
                }
                return Value{ .global = id.name };
            },
            .binary => |b| {
                const lhs = try self.lowerExpr(b.lhs);
                const rhs = try self.lowerExpr(b.rhs);
                const dst = fn_.freshVReg();
                const ir_op: BinOp = switch (b.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .int_div => .int_div,
                    .eq  => .eq,
                    .ne  => .ne,
                    .lt  => .lt,
                    .gt  => .gt,
                    .le  => .le,
                    .ge  => .ge,
                    .and_  => .and_,
                    .or_   => .or_,
                    .bit_and => .and_,
                    .bit_or  => .or_,
                    .bit_xor => .xor,
                    .shl => .shl,
                    .shr => .shr,
                    else => .add,
                };
                try fn_.emit(Instr{ .binop = .{
                    .dst = dst, .op = ir_op,
                    .lhs = lhs, .rhs = rhs,
                    .ty = sema.TYPE_INT32,
                }});
                return Value{ .vreg = dst };
            },
            .unary => |u| {
                const src = try self.lowerExpr(u.operand);
                const dst = fn_.freshVReg();
                const op: UnOp = switch (u.op) {
                    .neg => .neg,
                    .not_ => .not_,
                    .bit_not => .bit_not,
                    .addr_of => {
                        if (src == .vreg) {
                            try fn_.emit(Instr{ .addr_of = .{ .dst = dst, .src = src.vreg, .ty = sema.TYPE_UINT64 } });
                        }
                        return Value{ .vreg = dst };
                    },
                    .deref => {
                        try fn_.emit(Instr{ .load = .{ .dst = dst, .addr = src, .ty = sema.TYPE_INT32 } });
                        return Value{ .vreg = dst };
                    },
                };
                try fn_.emit(Instr{ .unop = .{ .dst = dst, .op = op, .src = src, .ty = sema.TYPE_INT32 } });
                return Value{ .vreg = dst };
            },
            .cast => |c| {
                const src = try self.lowerExpr(c.expr);
                const to_ty = self.sema.resolveType(c.ty) catch sema.TYPE_INT32;
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .cast = .{ .dst = dst, .src = src, .from_ty = sema.TYPE_INT32, .to_ty = to_ty } });
                return Value{ .vreg = dst };
            },
            .call => |c| {
                const callee = try self.lowerExpr(c.callee);
                const args = try self.arena.alloc(Value, c.args.len);
                for (c.args, 0..) |arg, i| {
                    args[i] = try self.lowerExpr(arg);
                }
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .call = .{
                    .dst = dst,
                    .callee = callee,
                    .args = args,
                    .ty = sema.TYPE_INT32,
                }});
                return Value{ .vreg = dst };
            },
            .method_call => |mc| {
                const recv = try self.lowerExpr(mc.receiver);
                _ = recv;
                const args = try self.arena.alloc(Value, mc.args.len + 1);
                args[0] = try self.lowerExpr(mc.receiver);
                for (mc.args, 0..) |arg, i| {
                    args[i + 1] = try self.lowerExpr(arg);
                }
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .call = .{
                    .dst = dst,
                    .callee = .{ .global = mc.method },
                    .args = args,
                    .ty = sema.TYPE_VOID,
                }});
                return Value{ .vreg = dst };
            },
            .field => |f| {
                const obj = try self.lowerExpr(f.receiver);
                const struct_name: []const u8 = self.getExprStructName(f.receiver);
                const field_offset = if (struct_name.len > 0) self.sema.getFieldOffset(struct_name, f.field) else 0;
                // Determine field size from struct layout
                var field_size: u32 = 4;
                if (struct_name.len > 0) {
                    if (self.sema.struct_defs.get(struct_name)) |layout| {
                        for (layout.fields) |fl| {
                            if (std.mem.eql(u8, fl.name, f.field)) {
                                field_size = fl.size;
                                break;
                            }
                        }
                    }
                }
                // Compute address (ptr + offset for non-zero offsets)
                const addr_value: Value = if (field_offset == 0) obj else blk: {
                    const addr_dst = fn_.freshVReg();
                    try fn_.emit(Instr{ .binop = .{
                        .dst = addr_dst, .op = .add,
                        .lhs = obj,
                        .rhs = Value{ .imm_int = @as(i64, field_offset) },
                        .ty = sema.TYPE_UINT64,
                    }});
                    break :blk Value{ .vreg = addr_dst };
                };
                if (field_size == 4) {
                    // Use load32 extern to avoid 64-bit read corrupting adjacent fields
                    const call_args = try self.arena.alloc(Value, 1);
                    call_args[0] = addr_value;
                    const call_dst = fn_.freshVReg();
                    try fn_.emit(Instr{ .call = .{ .dst = call_dst, .callee = Value{ .global = "load32" }, .args = call_args, .ty = sema.TYPE_INT32 } });
                    return Value{ .vreg = call_dst };
                } else {
                    const dst = fn_.freshVReg();
                    try fn_.emit(Instr{ .load = .{ .dst = dst, .addr = addr_value, .ty = sema.TYPE_UINT64 } });
                    return Value{ .vreg = dst };
                }
            },
            .index => |i| {
                const arr = try self.lowerExpr(i.array);
                const idx = try self.lowerExpr(i.index);
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .index_get = .{ .dst = dst, .array = arr, .idx = idx, .elem_ty = sema.TYPE_INT32 } });
                return Value{ .vreg = dst };
            },
            .default => |d| {
                const opt = try self.lowerExpr(d.opt);
                return opt; // simplified
            },
            .grouped => |g| return self.lowerExpr(g.inner),
            .if_expr => |ie| {
                // alloca must come BEFORE the branch that terminates the current block
                const tmp = fn_.freshVReg();
                try fn_.emit(Instr{ .alloca = .{ .dst = tmp, .ty = sema.TYPE_INT32, .count = 1 } });
                const cond_val = try self.lowerExpr(ie.cond);
                const then_id  = try fn_.addBlock("ifexpr_then");
                const else_id  = try fn_.addBlock("ifexpr_else");
                const merge_id = try fn_.addBlock("ifexpr_merge");
                try fn_.emit(Instr{ .branch = .{ .cond = cond_val, .true_block = then_id, .false_block = else_id } });
                // then branch
                fn_.switchToBlock(then_id);
                const t_val = try self.lowerExpr(ie.then_);
                try fn_.emit(Instr{ .store = .{ .addr = .{ .vreg = tmp }, .src = t_val, .ty = sema.TYPE_INT32 } });
                try fn_.emit(Instr{ .jump = .{ .target = merge_id } });
                // else branch
                fn_.switchToBlock(else_id);
                const e_val = try self.lowerExpr(ie.else_);
                try fn_.emit(Instr{ .store = .{ .addr = .{ .vreg = tmp }, .src = e_val, .ty = sema.TYPE_INT32 } });
                try fn_.emit(Instr{ .jump = .{ .target = merge_id } });
                // merge
                fn_.switchToBlock(merge_id);
                const result = fn_.freshVReg();
                try fn_.emit(Instr{ .load = .{ .dst = result, .addr = .{ .vreg = tmp }, .ty = sema.TYPE_INT32 } });
                return Value{ .vreg = result };
            },
            .consume => |c| return self.lowerExpr(c.expr),
            .await_expr => |a| return self.lowerExpr(a.expr),
            .spawn_expr => |s| return self.lowerExpr(s.call),
            .array_lit => |al| {
                // Allocate an array on the stack
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .alloca = .{ .dst = dst, .ty = sema.TYPE_INT32, .count = @intCast(al.elems.len) } });
                for (al.elems, 0..) |elem, i| {
                    const val = try self.lowerExpr(elem);
                    try fn_.emit(Instr{ .index_set = .{
                        .array = .{ .vreg = dst },
                        .idx = .{ .imm_int = @intCast(i) },
                        .src = val,
                        .elem_ty = sema.TYPE_INT32,
                    }});
                }
                return Value{ .vreg = dst };
            },
            .struct_lit => |sl| {
                // Get struct name from type expr
                const struct_name: []const u8 = if (sl.ty) |te| switch (te.*) {
                    .named => |n| n.name,
                    else => "",
                } else "";
                const struct_size: u32 = if (struct_name.len > 0) self.sema.getStructSize(struct_name) else 8;
                // Allocate memory via maia_mmap
                const size_val = Value{ .imm_int = @as(i64, struct_size) };
                const ptr_dst = fn_.freshVReg();
                try fn_.emit(Instr{ .call = .{
                    .dst = ptr_dst,
                    .callee = Value{ .global = "maia_mmap" },
                    .args = blk: {
                        const args = try self.arena.alloc(Value, 1);
                        args[0] = size_val;
                        break :blk args;
                    },
                    .ty = sema.TYPE_UINT64,
                }});
                // Store each field at its computed offset
                for (sl.fields) |field| {
                    const field_offset = if (struct_name.len > 0) self.sema.getFieldOffset(struct_name, field.name) else 0;
                    const field_val = try self.lowerExpr(field.value);
                    // Determine field size from struct layout
                    var field_size: u32 = 4;
                    if (struct_name.len > 0) {
                        if (self.sema.struct_defs.get(struct_name)) |layout| {
                            for (layout.fields) |fl| {
                                if (std.mem.eql(u8, fl.name, field.name)) {
                                    field_size = fl.size;
                                    break;
                                }
                            }
                        }
                    }
                    // Compute address (ptr + offset for non-zero offsets)
                    const addr_value: Value = if (field_offset == 0) Value{ .vreg = ptr_dst } else blk: {
                        const addr_dst = fn_.freshVReg();
                        try fn_.emit(Instr{ .binop = .{
                            .dst = addr_dst, .op = .add,
                            .lhs = Value{ .vreg = ptr_dst },
                            .rhs = Value{ .imm_int = @as(i64, field_offset) },
                            .ty = sema.TYPE_UINT64,
                        }});
                        break :blk Value{ .vreg = addr_dst };
                    };
                    if (field_size == 4) {
                        // Use store32 extern to avoid 64-bit write corrupting adjacent fields
                        const call_args = try self.arena.alloc(Value, 2);
                        call_args[0] = addr_value;
                        call_args[1] = field_val;
                        const call_dst = fn_.freshVReg();
                        try fn_.emit(Instr{ .call = .{ .dst = call_dst, .callee = Value{ .global = "store32" }, .args = call_args, .ty = sema.TYPE_VOID } });
                    } else {
                        try fn_.emit(Instr{ .store = .{ .addr = addr_value, .src = field_val, .ty = sema.TYPE_UINT64 } });
                    }
                }
                return Value{ .vreg = ptr_dst };
            },
            else => {
                const dst = fn_.freshVReg();
                try fn_.emit(Instr{ .copy = .{ .dst = dst, .src = .{ .imm_int = 0 }, .ty = sema.TYPE_INT32 } });
                return Value{ .vreg = dst };
            },
        }
    }

    fn evalConstExpr(self: *Builder, expr: *ast.Expr) ?Value {
        _ = self;
        return switch (expr.*) {
            .int_lit => |i| Value{ .imm_int = i.value },
            .float_lit => |f| Value{ .imm_float = f.value },
            .bool_lit => |b| Value{ .imm_bool = b.value },
            .string_lit => |s| Value{ .global = s.value },
            .null_lit => Value.imm_null,
            else => null,
        };
    }

    fn getExprStructName(self: *Builder, expr: *ast.Expr) []const u8 {
        switch (expr.*) {
            .ident => |id| {
                // Check local_types first (populated during IR lowering)
                if (self.local_types.get(id.name)) |name| return name;
                // Fall back to sema scope (works for global-scope symbols)
                if (self.sema.current_scope.lookup(id.name)) |sym| {
                    if (self.sema.getType(sym.ty)) |t| {
                        switch (t.*) {
                            .named => |n| return n,
                            else => {},
                        }
                    }
                }
                return "";
            },
            .field => |f| {
                // For chained field access like cg.buf.len, determine the struct type
                // of the intermediate result by looking up the field's type in the parent struct.
                const parent_struct = self.getExprStructName(f.receiver);
                if (parent_struct.len > 0) {
                    if (self.sema.struct_defs.get(parent_struct)) |layout| {
                        for (layout.fields) |fl| {
                            if (std.mem.eql(u8, fl.name, f.field)) {
                                // Return the type name of this field if it's a struct
                                if (fl.type_name.len > 0 and self.sema.struct_defs.contains(fl.type_name)) {
                                    return fl.type_name;
                                }
                                return "";
                            }
                        }
                    }
                }
                return "";
            },
            else => return "",
        }
    }
};

// ── IR Printer (for debugging) ─────────────────────────────────────────────────

pub fn printModule(module: *const IrModule, writer: anytype) !void {
    for (module.string_pool.items, 0..) |s, i| {
        try writer.print("  @str{d} = \"{s}\"\n", .{ i, s });
    }
    for (module.globals.items) |g| {
        try writer.print("  @{s}: <ty{d}>{s}\n", .{
            g.name, g.ty,
            if (g.is_const) " [const]" else "",
        });
    }
    for (module.functions.items) |*f| {
        if (f.is_external) {
            try writer.print("extern fn {s}\n", .{f.name});
            continue;
        }
        try writer.print("fn {s}(", .{f.name});
        for (f.params, 0..) |p, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("%{d}: <ty{d}>", .{ p.vreg, p.ty });
        }
        try writer.print("): <ty{d}> {{\n", .{f.ret_ty});
        for (f.blocks.items) |*b| {
            try writer.print("  {s}:\n", .{b.label});
            for (b.instrs.items) |instr| {
                try writer.print("    ", .{});
                try printInstr(instr, writer);
                try writer.print("\n", .{});
            }
        }
        try writer.print("}}\n", .{});
    }
}

fn printInstr(instr: Instr, writer: anytype) !void {
    switch (instr) {
        .binop => |b| try writer.print("%{d} = binop.{s} {}, {}", .{ b.dst, @tagName(b.op), printVal(b.lhs), printVal(b.rhs) }),
        .unop  => |u| try writer.print("%{d} = unop.{s} {}", .{ u.dst, @tagName(u.op), printVal(u.src) }),
        .copy  => |c| try writer.print("%{d} = {}", .{ c.dst, printVal(c.src) }),
        .cast  => |c| try writer.print("%{d} = cast {} to <ty{d}>", .{ c.dst, printVal(c.src), c.to_ty }),
        .call  => |c| try writer.print("%{d} = call {}", .{ c.dst, printVal(c.callee) }),
        .addr_of=> |a| try writer.print("%{d} = &%{d}", .{ a.dst, a.src }),
        .load  => |l| try writer.print("%{d} = *{}", .{ l.dst, printVal(l.addr) }),
        .store => |s| try writer.print("*{} = {}", .{ printVal(s.addr), printVal(s.src) }),
        .index_get => |i| try writer.print("%{d} = {}[{}]", .{ i.dst, printVal(i.array), printVal(i.idx) }),
        .index_set => |i| try writer.print("{}[{}] = {}", .{ printVal(i.array), printVal(i.idx), printVal(i.src) }),
        .field_get => |f| try writer.print("%{d} = {}.{s}", .{ f.dst, printVal(f.obj), f.field }),
        .field_set => |f| try writer.print("{}.{s} = {}", .{ printVal(f.obj), f.field, printVal(f.val) }),
        .jump   => |j| try writer.print("jump block{d}", .{j.target}),
        .branch => |b| try writer.print("branch {} ? block{d} : block{d}", .{ printVal(b.cond), b.true_block, b.false_block }),
        .ret    => |r| if (r.value) |v| try writer.print("ret {}", .{printVal(v)}) else try writer.print("ret", .{}),
        .alloca => |a| try writer.print("%{d} = alloca <ty{d}>[{d}]", .{ a.dst, a.ty, a.count }),
        .nop    => try writer.print("nop", .{}),
        .phi    => |p| try writer.print("%{d} = phi …", .{p.dst}),
    }
}

const PrintVal = struct { v: Value };
fn printVal(v: Value) PrintVal { return .{ .v = v }; }

pub fn format(pv: PrintVal, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    switch (pv.v) {
        .vreg => |r| try writer.print("%{d}", .{r}),
        .imm_int => |i| try writer.print("{d}", .{i}),
        .imm_float => |f| try writer.print("{d}", .{f}),
        .imm_bool => |b| try writer.print("{}", .{b}),
        .imm_null => try writer.print("null", .{}),
        .global => |g| try writer.print("@{s}", .{g}),
        .string_const => |i| try writer.print("@str{d}", .{i}),
    }
}
