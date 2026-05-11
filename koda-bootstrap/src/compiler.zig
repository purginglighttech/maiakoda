/// Koda AST → bytecode compiler.
const std = @import("std");
const ast = @import("ast");
const value = @import("value");
const bc = @import("bytecode");

pub const CompileError = error{
    TooManyConstants,
    TooManyLocals,
    TooManyUpvalues,
    UndefinedVariable,
    OutOfMemory,
};

const MAX_LOCALS = 256;
const MAX_UPVALUES = 256;

const Local = struct {
    name: []const u8,
    depth: i32,
};

const UpvalueDesc = struct {
    index: u8,
    is_local: bool,
};

const FnScope = struct {
    enclosing: ?*FnScope,
    proto: *value.FunctionProto,
    locals: [MAX_LOCALS]Local,
    local_count: u32,
    upvalues: [MAX_UPVALUES]UpvalueDesc,
    upvalue_count: u32,
    scope_depth: i32,

    fn init(enclosing: ?*FnScope, proto: *value.FunctionProto) FnScope {
        return .{
            .enclosing = enclosing,
            .proto = proto,
            .locals = undefined,
            .local_count = 0,
            .upvalues = undefined,
            .upvalue_count = 0,
            .scope_depth = 0,
        };
    }
};

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    scope: *FnScope,

    pub fn init(alloc: std.mem.Allocator) Compiler {
        return .{ .alloc = alloc, .scope = undefined };
    }

    pub fn compile(self: *Compiler, stmts: []ast.Stmt) CompileError!*value.FunctionProto {
        const proto = value.FunctionProto.init(self.alloc, "<script>", 0, false) catch return error.OutOfMemory;
        var top_scope = FnScope.init(null, proto);
        self.scope = &top_scope;
        // Match compileFnProto: bump depth and reserve slot 0 for the closure.
        self.scope.scope_depth += 1;
        try self.declareLocal("");

        for (stmts) |stmt| try self.compileStmt(stmt);
        try self.emitOp(.nil);
        try self.emitOp(.return_);

        return proto;
    }

    // ── Statement dispatch ─────────────────────────────────────────────────

    fn compileStmt(self: *Compiler, stmt: ast.Stmt) CompileError!void {
        switch (stmt) {
            .var_decl   => |d| try self.compileVarDecl(d),
            .fn_decl    => |d| try self.compileFnDecl(d),
            .expr_stmt  => |e| {
                try self.compileExpr(e.*);
                // Assign expressions consume the value internally; don't double-pop.
                if (e.* != .assign) try self.emitOp(.pop);
            },
            .if_stmt    => |s| try self.compileIf(s),
            .while_stmt => |s| try self.compileWhile(s),
            .for_stmt   => |s| try self.compileFor(s),
            .return_stmt => |s| try self.compileReturn(s),
            .module_decl => {}, // no-op in bootstrap
            .import_stmt => {}, // no-op in bootstrap
        }
    }

    fn compileVarDecl(self: *Compiler, d: ast.VarDecl) CompileError!void {
        try self.compileExpr(d.init.*);
        // Top-level script scope: enclosing==null and depth==1 means we're at
        // the outermost function body — store as a global so vm.globals sees it.
        const is_top_level = self.scope.enclosing == null and self.scope.scope_depth == 1;
        if (!is_top_level and self.scope.scope_depth > 0) {
            try self.declareLocal(d.name);
        } else {
            const idx = try self.addStringConstant(d.name);
            try self.emitOp(.set_global);
            try self.emitByte(idx);
        }
    }

    fn compileFnDecl(self: *Compiler, d: ast.FnDecl) CompileError!void {
        const closure_val = try self.compileFnProto(d.name, d.params, d.body, d.is_async);
        const is_top_level = self.scope.enclosing == null and self.scope.scope_depth == 1;
        if (!is_top_level and self.scope.scope_depth > 0) {
            _ = closure_val;
            try self.declareLocal(d.name);
        } else {
            const idx = try self.addStringConstant(d.name);
            try self.emitOp(.set_global);
            try self.emitByte(idx);
        }
    }

    fn compileFnProto(
        self: *Compiler,
        name: []const u8,
        params: [][]const u8,
        body: []ast.Stmt,
        is_async: bool,
    ) CompileError!void {
        const proto = value.FunctionProto.init(self.alloc, name, @intCast(params.len), is_async)
            catch return error.OutOfMemory;
        var fn_scope = FnScope.init(self.scope, proto);
        const saved = self.scope;
        self.scope = &fn_scope;
        defer self.scope = saved;

        self.scope.scope_depth += 1;
        // Slot 0 is implicitly the closure/function value itself
        try self.declareLocal("");
        for (params) |p| try self.declareLocal(p);

        for (body) |s| try self.compileStmt(s);

        // Implicit nil return
        try self.emitOp(.nil);
        try self.emitOp(.return_);

        // Emit closure instruction in the enclosing scope
        const template = self.alloc.create(value.Closure) catch return error.OutOfMemory;
        template.* = .{ .proto = proto, .upvalue_vals = &.{}, .name = name };
        const proto_idx = try self.addConstantToScope(saved, .{ .closure = template });
        try self.emitOpIn(saved, .closure);
        try self.emitByteIn(saved, proto_idx);

        // Emit upvalue descriptors
        for (fn_scope.upvalues[0..fn_scope.upvalue_count]) |uv| {
            try self.emitByteIn(saved, if (uv.is_local) 1 else 0);
            try self.emitByteIn(saved, uv.index);
        }
    }

    fn compileIf(self: *Compiler, s: ast.IfStmt) CompileError!void {
        try self.compileExpr(s.cond.*);
        const then_jump = try self.emitJump(.jump_if_false);
        try self.emitOp(.pop);

        for (s.then_body) |st| try self.compileStmt(st);

        // elsif / else chain
        var end_jumps = std.ArrayListUnmanaged(usize).empty;
        defer end_jumps.deinit(self.alloc);

        const end_j = try self.emitJump(.jump);
        try end_jumps.append(self.alloc, end_j);
        self.patchJump(then_jump);
        try self.emitOp(.pop);

        for (s.elsif_clauses) |clause| {
            try self.compileExpr(clause.cond.*);
            const elsif_jump = try self.emitJump(.jump_if_false);
            try self.emitOp(.pop);
            for (clause.body) |st| try self.compileStmt(st);
            const ej = try self.emitJump(.jump);
            try end_jumps.append(self.alloc, ej);
            self.patchJump(elsif_jump);
            try self.emitOp(.pop);
        }

        if (s.else_body) |eb| {
            for (eb) |st| try self.compileStmt(st);
        }

        for (end_jumps.items) |j| self.patchJump(j);
    }

    fn compileWhile(self: *Compiler, s: ast.WhileStmt) CompileError!void {
        const loop_start = self.currentChunk().code.items.len;
        try self.compileExpr(s.cond.*);
        const exit_jump = try self.emitJump(.jump_if_false);
        try self.emitOp(.pop);
        for (s.body) |st| try self.compileStmt(st);
        try self.emitLoop(loop_start);
        self.patchJump(exit_jump);
        try self.emitOp(.pop);
    }

    fn compileFor(self: *Compiler, s: ast.ForStmt) CompileError!void {
        try self.enterScope();
        try self.compileExpr(s.iter.*);
        // Iterator occupies this local slot; iter_next will push cur_val above it.
        try self.declareLocal("");

        const loop_start = self.currentChunk().code.items.len;
        const exit_placeholder = try self.emitJump(.iter_next);
        // iter_next pushed cur_val; declare loop var at that slot.
        try self.declareLocal(s.var_name);
        for (s.body) |st| try self.compileStmt(st);
        // Pop loop var manually so exitScope only pops the iterator.
        try self.emitOp(.pop);
        self.scope.local_count -= 1;
        try self.emitLoop(loop_start);
        self.patchJump(exit_placeholder);
        try self.exitScope(); // pops iterator
    }

    fn compileReturn(self: *Compiler, s: ast.ReturnStmt) CompileError!void {
        if (s.value) |v| {
            try self.compileExpr(v.*);
        } else {
            try self.emitOp(.nil);
        }
        try self.emitOp(.return_);
    }

    // ── Expression dispatch ────────────────────────────────────────────────

    fn compileExpr(self: *Compiler, expr: ast.Expr) CompileError!void {
        switch (expr) {
            .int_lit    => |l| try self.emitConstant(.{ .int = l.value }),
            .float_lit  => |l| try self.emitConstant(.{ .float = l.value }),
            .string_lit => |l| try self.emitConstant(.{ .string = l.value }),
            .bool_lit   => |l| try self.emitOp(if (l.value) .true_ else .false_),
            .null_lit   => try self.emitOp(.nil),
            .ident      => |i| try self.compileIdent(i.name),
            .binary     => |b| try self.compileBinary(b),
            .unary      => |u| try self.compileUnary(u),
            .call       => |c| try self.compileCall(c),
            .index      => |i| try self.compileIndex(i),
            .field      => |f| try self.compileField(f),
            .assign     => |a| try self.compileAssign(a),
            .array_lit  => |a| try self.compileArray(a),
            .table_lit  => |t| try self.compileTable(t),
            .lambda     => |l| try self.compileLambda(l),
            .await_expr => |a| { try self.compileExpr(a.expr.*); try self.emitOp(.await_); },
            .spawn_expr => |s| try self.compileSpawn(s),
            .pipeline   => |p| try self.compilePipeline(p),
            .range      => |r| try self.compileRange(r),
        }
    }

    fn compileIdent(self: *Compiler, name: []const u8) CompileError!void {
        if (self.resolveLocal(self.scope, name)) |slot| {
            try self.emitOp(.get_local);
            try self.emitByte(@intCast(slot));
        } else if (try self.resolveUpvalue(self.scope, name)) |uv| {
            try self.emitOp(.get_upvalue);
            try self.emitByte(@intCast(uv));
        } else {
            const idx = try self.addStringConstant(name);
            try self.emitOp(.get_global);
            try self.emitByte(idx);
        }
    }

    fn compileBinary(self: *Compiler, b: ast.Binary) CompileError!void {
        try self.compileExpr(b.lhs.*);
        try self.compileExpr(b.rhs.*);
        const op: bc.Op = switch (b.op) {
            .add  => .add,
            .sub  => .sub,
            .mul  => .mul,
            .div  => .div,
            .mod  => .mod,
            .eq   => .eq,
            .ne   => .ne,
            .lt   => .lt,
            .gt   => .gt,
            .le   => .le,
            .ge   => .ge,
            .and_ => .and_,
            .or_  => .or_,
        };
        try self.emitOp(op);
    }

    fn compileUnary(self: *Compiler, u: ast.Unary) CompileError!void {
        try self.compileExpr(u.operand.*);
        try self.emitOp(switch (u.op) { .neg => .neg, .not_ => .not_ });
    }

    fn compileCall(self: *Compiler, c: ast.Call) CompileError!void {
        try self.compileExpr(c.callee.*);
        for (c.args) |arg| try self.compileExpr(arg.*);
        try self.emitOp(.call);
        try self.emitByte(@intCast(c.args.len));
    }

    fn compileIndex(self: *Compiler, i: ast.Index) CompileError!void {
        try self.compileExpr(i.object.*);
        try self.compileExpr(i.key.*);
        try self.emitOp(.array_get);
    }

    fn compileField(self: *Compiler, f: ast.Field) CompileError!void {
        try self.compileExpr(f.object.*);
        const idx = try self.addStringConstant(f.name);
        try self.emitOp(.table_get);
        try self.emitByte(idx);
    }

    fn compileAssign(self: *Compiler, a: ast.Assign) CompileError!void {
        try self.compileExpr(a.value.*);
        try self.compileAssignTarget(a.target.*);
    }

    fn compileAssignTarget(self: *Compiler, target: ast.Expr) CompileError!void {
        switch (target) {
            .ident => |i| {
                if (self.resolveLocal(self.scope, i.name)) |slot| {
                    try self.emitOp(.set_local);
                    try self.emitByte(@intCast(slot));
                } else if (try self.resolveUpvalue(self.scope, i.name)) |uv| {
                    try self.emitOp(.set_upvalue);
                    try self.emitByte(@intCast(uv));
                } else {
                    const idx = try self.addStringConstant(i.name);
                    try self.emitOp(.set_global);
                    try self.emitByte(idx);
                }
            },
            .index => |i| {
                try self.compileExpr(i.object.*);
                try self.compileExpr(i.key.*);
                try self.emitOp(.array_set);
            },
            .field => |f| {
                try self.compileExpr(f.object.*);
                const idx = try self.addStringConstant(f.name);
                try self.emitOp(.table_set);
                try self.emitByte(idx);
            },
            else => unreachable,
        }
    }

    fn compileArray(self: *Compiler, a: ast.ArrayLit) CompileError!void {
        try self.emitOp(.create_array);
        try self.emitByte(0);
        for (a.elements) |el| {
            try self.compileExpr(el.*);
            try self.emitOp(.array_append);
        }
    }

    fn compileTable(self: *Compiler, t: ast.TableLit) CompileError!void {
        try self.emitOp(.create_table);
        for (t.entries) |entry| {
            const k_idx = try self.addStringConstant(entry.key);
            try self.compileExpr(entry.value.*);
            try self.emitOp(.table_set);
            try self.emitByte(k_idx);
        }
    }

    fn compileLambda(self: *Compiler, l: ast.Lambda) CompileError!void {
        try self.compileFnProto("<lambda>", l.params, l.body, l.is_async);
    }

    fn compileSpawn(self: *Compiler, s: ast.SpawnExpr) CompileError!void {
        // spawn { body } compiles body as a zero-arg async lambda and spawns it
        try self.compileFnProto("<spawn>", &.{}, s.body, true);
        try self.emitOp(.spawn);
        try self.emitByte(0);
    }

    fn compilePipeline(self: *Compiler, p: ast.Pipeline) CompileError!void {
        try self.compileExpr(p.lhs.*);
        try self.compileExpr(p.rhs.*);
        try self.emitOp(.pipe);
    }

    fn compileRange(self: *Compiler, r: ast.Range) CompileError!void {
        try self.compileExpr(r.start.*);
        try self.compileExpr(r.end.*);
        try self.emitOp(.make_range);
    }

    // ── Scope helpers ──────────────────────────────────────────────────────

    fn enterScope(self: *Compiler) CompileError!void {
        self.scope.scope_depth += 1;
    }

    fn exitScope(self: *Compiler) CompileError!void {
        self.scope.scope_depth -= 1;
        while (self.scope.local_count > 0 and
            self.scope.locals[self.scope.local_count - 1].depth > self.scope.scope_depth)
        {
            try self.emitOp(.pop);
            self.scope.local_count -= 1;
        }
    }

    fn declareLocal(self: *Compiler, name: []const u8) CompileError!void {
        if (self.scope.local_count >= MAX_LOCALS) return error.TooManyLocals;
        self.scope.locals[self.scope.local_count] = .{ .name = name, .depth = self.scope.scope_depth };
        self.scope.local_count += 1;
    }

    fn resolveLocal(_: *Compiler, scope: *FnScope, name: []const u8) ?u32 {
        var i = scope.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, scope.locals[i].name, name)) return i;
        }
        return null;
    }

    fn resolveUpvalue(self: *Compiler, scope: *FnScope, name: []const u8) CompileError!?u32 {
        const enc = scope.enclosing orelse return null;
        if (self.resolveLocal(enc, name)) |slot| {
            return try self.addUpvalue(scope, @intCast(slot), true);
        }
        if (try self.resolveUpvalue(enc, name)) |uv| {
            return try self.addUpvalue(scope, @intCast(uv), false);
        }
        return null;
    }

    fn addUpvalue(self: *Compiler, scope: *FnScope, index: u8, is_local: bool) CompileError!u32 {
        _ = self;
        for (scope.upvalues[0..scope.upvalue_count], 0..) |uv, i| {
            if (uv.index == index and uv.is_local == is_local) return @intCast(i);
        }
        if (scope.upvalue_count >= MAX_UPVALUES) return error.TooManyUpvalues;
        scope.upvalues[scope.upvalue_count] = .{ .index = index, .is_local = is_local };
        const idx = scope.upvalue_count;
        scope.upvalue_count += 1;
        return idx;
    }

    // ── Emit helpers ───────────────────────────────────────────────────────

    fn currentChunk(self: *Compiler) *value.Chunk {
        return &self.scope.proto.chunk;
    }

    fn emitOp(self: *Compiler, op: bc.Op) CompileError!void {
        self.currentChunk().write(self.alloc, @intFromEnum(op), 0) catch return error.OutOfMemory;
    }

    fn emitByte(self: *Compiler, b: u8) CompileError!void {
        self.currentChunk().write(self.alloc, b, 0) catch return error.OutOfMemory;
    }

    fn emitOpIn(self: *Compiler, scope: *FnScope, op: bc.Op) CompileError!void {
        scope.proto.chunk.write(self.alloc, @intFromEnum(op), 0) catch return error.OutOfMemory;
    }

    fn emitByteIn(self: *Compiler, scope: *FnScope, b: u8) CompileError!void {
        scope.proto.chunk.write(self.alloc, b, 0) catch return error.OutOfMemory;
    }

    fn emitConstant(self: *Compiler, val: value.Value) CompileError!void {
        const idx = self.currentChunk().addConstant(self.alloc, val) catch return error.OutOfMemory;
        if (idx > 255) return error.TooManyConstants;
        try self.emitOp(.constant);
        try self.emitByte(idx);
    }

    fn addStringConstant(self: *Compiler, s: []const u8) CompileError!u8 {
        const idx = self.currentChunk().addConstant(self.alloc, .{ .string = s }) catch return error.OutOfMemory;
        if (idx > 255) return error.TooManyConstants;
        return idx;
    }

    fn addConstantToScope(self: *Compiler, scope: *FnScope, val: value.Value) CompileError!u8 {
        const idx = scope.proto.chunk.addConstant(self.alloc, val) catch return error.OutOfMemory;
        if (idx > 255) return error.TooManyConstants;
        return idx;
    }

    fn emitJump(self: *Compiler, op: bc.Op) CompileError!usize {
        try self.emitOp(op);
        try self.emitByte(0xFF);
        try self.emitByte(0xFF);
        return self.currentChunk().code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const chunk = self.currentChunk();
        const jump = chunk.code.items.len - offset - 2;
        chunk.code.items[offset]     = @intCast((jump >> 8) & 0xFF);
        chunk.code.items[offset + 1] = @intCast(jump & 0xFF);
    }

    fn emitLoop(self: *Compiler, loop_start: usize) CompileError!void {
        try self.emitOp(.loop);
        const offset = self.currentChunk().code.items.len - loop_start + 2;
        try self.emitByte(@intCast((offset >> 8) & 0xFF));
        try self.emitByte(@intCast(offset & 0xFF));
    }
};
