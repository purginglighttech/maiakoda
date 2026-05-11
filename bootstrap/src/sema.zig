/// Maia semantic analyzer.
/// Performs:
///   - Name resolution (scoped symbol table)
///   - Type inference and checking
///   - Ownership / borrow validation (basic)
///   - Produces a typed IR-ready representation via the same AST nodes
///     annotated in the SymbolTable.

const std = @import("std");
const ast = @import("ast");

const Span = ast.Span;
const Decl = ast.Decl;
const Stmt = ast.Stmt;
const Expr = ast.Expr;
const TypeExpr = ast.TypeExpr;

// ── Type representation ───────────────────────────────────────────────────────

pub const TypeId = u32;
pub const TYPE_VOID: TypeId = 0;
pub const TYPE_BOOL: TypeId = 1;
pub const TYPE_INT8: TypeId = 2;
pub const TYPE_INT16: TypeId = 3;
pub const TYPE_INT32: TypeId = 4;
pub const TYPE_INT64: TypeId = 5;
pub const TYPE_UINT8: TypeId = 6;
pub const TYPE_UINT16: TypeId = 7;
pub const TYPE_UINT32: TypeId = 8;
pub const TYPE_UINT64: TypeId = 9;
pub const TYPE_F32: TypeId = 10;
pub const TYPE_F64: TypeId = 11;
pub const TYPE_STRING: TypeId = 12;
pub const TYPE_USIZE: TypeId = 13;
pub const TYPE_ISIZE: TypeId = 14;
pub const TYPE_NULL: TypeId = 15;
pub const TYPE_FIRST_USER: TypeId = 16;

pub const Type = union(enum) {
    void_,
    bool_,
    int: struct { bits: u8, signed: bool },
    float: struct { bits: u8 },
    string_,
    ptr: struct { inner: TypeId, mutable: bool },
    optional: TypeId,
    array: struct { size: u64, elem: TypeId },
    slice: TypeId,
    struct_: StructType,
    enum_: EnumType,
    func: FuncType,
    named: []const u8,   // unresolved forward reference
    never,               // return type of noreturn functions
    null_,
};

pub const StructType = struct {
    name: []const u8,
    fields: []Field,
    methods: []Symbol,
};

pub const Field = struct {
    name: []const u8,
    ty: TypeId,
};

pub const EnumType = struct {
    name: []const u8,
    variants: []Variant,
};

pub const Variant = struct {
    name: []const u8,
    value: i64,
};

pub const FuncType = struct {
    params: []TypeId,
    ret: TypeId,
    is_async: bool,
};

// ── Symbol ────────────────────────────────────────────────────────────────────

pub const SymbolKind = enum {
    variable, constant, function_, procedure_, type_, module_,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    ty: TypeId,
    span: Span,
    is_mutable: bool,
    ownership: ast.OwnershipKind,
};

// ── Scope ─────────────────────────────────────────────────────────────────────

pub const Scope = struct {
    parent: ?*Scope,
    symbols: std.StringHashMap(Symbol),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .parent = parent,
            .symbols = std.StringHashMap(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.symbols.deinit();
    }

    pub fn define(self: *Scope, sym: Symbol) !void {
        try self.symbols.put(sym.name, sym);
    }

    pub fn lookup(self: *Scope, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |s| return s;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};

// ── Struct layout ─────────────────────────────────────────────────────────────

pub const FieldLayout = struct { name: []const u8, offset: u32, size: u32, type_name: []const u8 };
pub const StructLayout = struct { fields: []FieldLayout, total_size: u32 };

// ── Diagnostics ───────────────────────────────────────────────────────────────

pub const DiagKind = enum { err, warn, note };

pub const Diagnostic = struct {
    kind: DiagKind,
    message: []const u8,
    span: Span,
};

// ── Sema context ──────────────────────────────────────────────────────────────

pub const SemaError = error{
    TypeError,
    UndeclaredIdentifier,
    DuplicateSymbol,
    InvalidOperation,
    OutOfMemory,
};

pub const Sema = struct {
    allocator: std.mem.Allocator,
    types: std.array_list.AlignedManaged(Type, null),
    diagnostics: std.array_list.AlignedManaged(Diagnostic, null),
    global_scope: Scope,
    current_scope: *Scope,
    current_return_ty: TypeId,
    struct_defs: std.StringHashMap(StructLayout),

    pub fn init(allocator: std.mem.Allocator) !Sema {
        var sema = Sema{
            .allocator = allocator,
            .types = std.array_list.AlignedManaged(Type, null).init(allocator),
            .diagnostics = std.array_list.AlignedManaged(Diagnostic, null).init(allocator),
            .global_scope = Scope.init(allocator, null),
            .current_scope = undefined,
            .current_return_ty = TYPE_VOID,
            .struct_defs = std.StringHashMap(StructLayout).init(allocator),
        };
        sema.current_scope = &sema.global_scope;

        // Pre-populate primitive types (indices must match TYPE_* constants)
        try sema.types.append(.void_);                             // 0
        try sema.types.append(.bool_);                             // 1
        try sema.types.append(.{ .int = .{ .bits = 8,  .signed = true  } }); // 2
        try sema.types.append(.{ .int = .{ .bits = 16, .signed = true  } }); // 3
        try sema.types.append(.{ .int = .{ .bits = 32, .signed = true  } }); // 4
        try sema.types.append(.{ .int = .{ .bits = 64, .signed = true  } }); // 5
        try sema.types.append(.{ .int = .{ .bits = 8,  .signed = false } }); // 6
        try sema.types.append(.{ .int = .{ .bits = 16, .signed = false } }); // 7
        try sema.types.append(.{ .int = .{ .bits = 32, .signed = false } }); // 8
        try sema.types.append(.{ .int = .{ .bits = 64, .signed = false } }); // 9
        try sema.types.append(.{ .float = .{ .bits = 32 } });      // 10
        try sema.types.append(.{ .float = .{ .bits = 64 } });      // 11
        try sema.types.append(.string_);                            // 12
        try sema.types.append(.{ .int = .{ .bits = 64, .signed = false } }); // 13 usize
        try sema.types.append(.{ .int = .{ .bits = 64, .signed = true  } }); // 14 isize
        try sema.types.append(.null_);                             // 15

        // Register built-in type names
        const builtin_names = [_]struct { name: []const u8, id: TypeId }{
            .{ .name = "void",   .id = TYPE_VOID },
            .{ .name = "bool",   .id = TYPE_BOOL },
            .{ .name = "int8",   .id = TYPE_INT8 },
            .{ .name = "int16",  .id = TYPE_INT16 },
            .{ .name = "int32",  .id = TYPE_INT32 },
            .{ .name = "int64",  .id = TYPE_INT64 },
            .{ .name = "uint8",  .id = TYPE_UINT8 },
            .{ .name = "uint16", .id = TYPE_UINT16 },
            .{ .name = "uint32", .id = TYPE_UINT32 },
            .{ .name = "uint64", .id = TYPE_UINT64 },
            .{ .name = "f32",    .id = TYPE_F32 },
            .{ .name = "f64",    .id = TYPE_F64 },
            .{ .name = "string", .id = TYPE_STRING },
            .{ .name = "usize",  .id = TYPE_USIZE },
            .{ .name = "isize",  .id = TYPE_ISIZE },
            .{ .name = "u8",     .id = TYPE_UINT8 },
        };
        for (builtin_names) |bn| {
            try sema.global_scope.define(Symbol{
                .name = bn.name,
                .kind = .type_,
                .ty = bn.id,
                .span = Span{ .start = 0, .end = 0, .line = 0, .col = 0 },
                .is_mutable = false,
                .ownership = .none,
            });
        }

        // Built-in functions
        const writeln_params = try sema.allocator.dupe(TypeId, &.{TYPE_STRING});
        const writeln_ty = try sema.internType(Type{ .func = .{
            .params = writeln_params,
            .ret = TYPE_VOID,
            .is_async = false,
        }});
        try sema.global_scope.define(Symbol{
            .name = "writeln",
            .kind = .function_,
            .ty = writeln_ty,
            .span = Span{ .start = 0, .end = 0, .line = 0, .col = 0 },
            .is_mutable = false,
            .ownership = .none,
        });
        try sema.global_scope.define(Symbol{
            .name = "write",
            .kind = .function_,
            .ty = writeln_ty,
            .span = Span{ .start = 0, .end = 0, .line = 0, .col = 0 },
            .is_mutable = false,
            .ownership = .none,
        });

        return sema;
    }

    pub fn deinit(self: *Sema) void {
        for (self.types.items) |ty| {
            switch (ty) {
                .func => |f| self.allocator.free(f.params),
                else => {},
            }
        }
        self.types.deinit();
        self.diagnostics.deinit();
        self.global_scope.deinit();
        self.struct_defs.deinit();
    }

    pub fn analyzeModule(self: *Sema, module: *ast.Module) SemaError!void {
        self.current_scope = &self.global_scope;
        // First pass: register all top-level declarations
        for (module.decls) |*decl| {
            try self.registerDecl(decl);
        }
        // Second pass: type-check bodies
        for (module.decls) |*decl| {
            try self.checkDecl(decl);
        }
    }

    // ── First pass: register ───────────────────────────────────────────────────

    fn registerDecl(self: *Sema, decl: *Decl) SemaError!void {
        switch (decl.*) {
            .func_decl => |*f| {
                const param_types = try self.allocator.alloc(TypeId, f.params.len);
                for (f.params, 0..) |p, i| {
                    param_types[i] = if (p.ty) |pt| try self.resolveType(pt) else TYPE_INT32;
                }
                const ret_ty: TypeId = if (f.ret) |r| try self.resolveType(r) else TYPE_VOID;
                const func_ty = try self.internType(Type{ .func = .{
                    .params = param_types,
                    .ret = ret_ty,
                    .is_async = f.is_async,
                }});
                try self.current_scope.define(Symbol{
                    .name = f.name,
                    .kind = .function_,
                    .ty = func_ty,
                    .span = f.span,
                    .is_mutable = false,
                    .ownership = .none,
                });
            },
            .proc_decl => |*p| {
                const param_types = try self.allocator.alloc(TypeId, p.params.len);
                for (p.params, 0..) |param, i| {
                    param_types[i] = if (param.ty) |pt| try self.resolveType(pt) else TYPE_VOID;
                }
                const proc_ty = try self.internType(Type{ .func = .{
                    .params = param_types,
                    .ret = TYPE_VOID,
                    .is_async = p.is_async,
                }});
                try self.current_scope.define(Symbol{
                    .name = p.name,
                    .kind = .procedure_,
                    .ty = proc_ty,
                    .span = p.span,
                    .is_mutable = false,
                    .ownership = .none,
                });
            },
            .type_decl => |*td| {
                const new_ty = try self.internType(Type{ .named = td.name });
                try self.current_scope.define(Symbol{
                    .name = td.name,
                    .kind = .type_,
                    .ty = new_ty,
                    .span = td.span,
                    .is_mutable = false,
                    .ownership = .none,
                });
                // Compute and store struct layout
                if (td.def == .struct_def) {
                    const sd = td.def.struct_def;
                    const field_layouts = try self.allocator.alloc(FieldLayout, sd.fields.len);
                    var offset: u32 = 0;
                    for (sd.fields, 0..) |sf, i| {
                        const sz = self.typeSize(sf.ty);
                        // Align offset to min(sz, 4) — fields are at least 4-byte aligned
                        const align_ = if (sz < 4) sz else 4;
                        if (align_ > 1) {
                            offset = (offset + align_ - 1) & ~(align_ - 1);
                        }
                        // Store the field's type name for chained field access resolution
                        const type_name: []const u8 = switch (sf.ty.*) {
                            .named => |n| n.name,
                            .owned => |o| switch (o.inner.*) { .named => |n| n.name, else => "" },
                            else => "",
                        };
                        field_layouts[i] = FieldLayout{ .name = sf.name, .offset = offset, .size = sz, .type_name = type_name };
                        offset += sz;
                    }
                    // Final struct size aligned to 8
                    const total = (offset + 7) & ~@as(u32, 7);
                    try self.struct_defs.put(td.name, StructLayout{ .fields = field_layouts, .total_size = total });
                }
            },
            .const_decl => |*cd| {
                const ty: TypeId = if (cd.ty) |t| try self.resolveType(t) else TYPE_INT32;
                try self.current_scope.define(Symbol{
                    .name = cd.name,
                    .kind = .constant,
                    .ty = ty,
                    .span = cd.span,
                    .is_mutable = false,
                    .ownership = .none,
                });
            },
            .var_decl => |*vd| {
                const ty: TypeId = if (vd.ty) |t| try self.resolveType(t) else TYPE_INT32;
                try self.current_scope.define(Symbol{
                    .name = vd.name,
                    .kind = .variable,
                    .ty = ty,
                    .span = vd.span,
                    .is_mutable = true,
                    .ownership = vd.ownership,
                });
            },
            .extern_decl => |*ed| {
                try self.registerDecl(ed.item);
            },
            else => {},
        }
    }

    // ── Second pass: type check ────────────────────────────────────────────────

    fn checkDecl(self: *Sema, decl: *Decl) SemaError!void {
        switch (decl.*) {
            .func_decl => |*f| {
                if (f.body) |body| {
                    var scope = Scope.init(self.allocator, self.current_scope);
                    defer scope.deinit();
                    const prev_scope = self.current_scope;
                    self.current_scope = &scope;

                    const prev_ret = self.current_return_ty;
                    self.current_return_ty = if (f.ret) |r| try self.resolveType(r) else TYPE_VOID;

                    for (f.params) |p| {
                        const pty = if (p.ty) |pt| try self.resolveType(pt) else TYPE_INT32;
                        try scope.define(Symbol{
                            .name = p.name,
                            .kind = .variable,
                            .ty = pty,
                            .span = p.span,
                            .is_mutable = p.ownership == .mut_,
                            .ownership = p.ownership,
                        });
                    }
                    try self.checkStmt(body);
                    self.current_scope = prev_scope;
                    self.current_return_ty = prev_ret;
                }
            },
            .proc_decl => |*p| {
                if (p.body) |body| {
                    var scope = Scope.init(self.allocator, self.current_scope);
                    defer scope.deinit();
                    const prev_scope = self.current_scope;
                    self.current_scope = &scope;
                    const prev_ret = self.current_return_ty;
                    self.current_return_ty = TYPE_VOID;
                    for (p.params) |param| {
                        const pty = if (param.ty) |pt| try self.resolveType(pt) else TYPE_VOID;
                        try scope.define(Symbol{
                            .name = param.name,
                            .kind = .variable,
                            .ty = pty,
                            .span = param.span,
                            .is_mutable = param.ownership == .mut_,
                            .ownership = param.ownership,
                        });
                    }
                    try self.checkStmt(body);
                    self.current_scope = prev_scope;
                    self.current_return_ty = prev_ret;
                }
            },
            .const_decl => |*cd| {
                _ = try self.inferExpr(cd.value);
            },
            .var_decl => |*vd| {
                if (vd.init) |init_expr| _ = try self.inferExpr(init_expr);
            },
            else => {},
        }
    }

    fn checkStmt(self: *Sema, stmt: *Stmt) SemaError!void {
        switch (stmt.*) {
            .block => |b| {
                var scope = Scope.init(self.allocator, self.current_scope);
                defer scope.deinit();
                const prev = self.current_scope;
                self.current_scope = &scope;
                for (b.stmts) |s| try self.checkStmt(s);
                self.current_scope = prev;
            },
            .var_decl => |*vd| {
                const ty: TypeId = if (vd.ty) |t| try self.resolveType(t) else blk: {
                    if (vd.init) |init_expr| {
                        break :blk try self.inferExpr(init_expr);
                    }
                    break :blk TYPE_INT32;
                };
                if (vd.init) |init_expr| {
                    const init_ty = try self.inferExpr(init_expr);
                    if (!self.typesCompatible(ty, init_ty)) {
                        try self.emitError("type mismatch in variable declaration", vd.span);
                    }
                }
                try self.current_scope.define(Symbol{
                    .name = vd.name,
                    .kind = .variable,
                    .ty = ty,
                    .span = vd.span,
                    .is_mutable = true,
                    .ownership = vd.ownership,
                });
            },
            .const_decl => |*cd| {
                const ty: TypeId = if (cd.ty) |t| try self.resolveType(t) else try self.inferExpr(cd.value);
                try self.current_scope.define(Symbol{
                    .name = cd.name,
                    .kind = .constant,
                    .ty = ty,
                    .span = cd.span,
                    .is_mutable = false,
                    .ownership = .none,
                });
                _ = try self.inferExpr(cd.value);
            },
            .assign => |a| {
                _ = try self.inferExpr(a.target);
                _ = try self.inferExpr(a.value);
            },
            .expr_stmt => |es| {
                _ = try self.inferExpr(es.expr);
            },
            .if_stmt => |ifs| {
                _ = try self.inferExpr(ifs.cond);
                try self.checkStmt(ifs.then_branch);
                for (ifs.elsif_branches) |eb| {
                    _ = try self.inferExpr(eb.cond);
                    try self.checkStmt(eb.body);
                }
                if (ifs.else_branch) |eb| try self.checkStmt(eb);
            },
            .while_stmt => |ws| {
                _ = try self.inferExpr(ws.cond);
                try self.checkStmt(ws.body);
            },
            .for_stmt => |fs| {
                _ = try self.inferExpr(fs.iter);
                try self.checkStmt(fs.body);
            },
            .loop_stmt => |ls| {
                try self.checkStmt(ls.body);
            },
            .return_stmt => |rs| {
                if (rs.value) |v| {
                    const vty = try self.inferExpr(v);
                    if (!self.typesCompatible(self.current_return_ty, vty)) {
                        try self.emitError("return type mismatch", rs.span);
                    }
                }
            },
            .match_stmt => |ms| {
                _ = try self.inferExpr(ms.subject);
                for (ms.arms) |arm| try self.checkStmt(arm.body);
            },
            .defer_stmt => |ds| try self.checkStmt(ds.body),
            .safe_block => |sb| try self.checkStmt(sb.body),
            .unsafe_block => |ub| try self.checkStmt(ub.body),
            .break_stmt, .continue_stmt => {},
        }
    }

    // ── Type inference ─────────────────────────────────────────────────────────

    pub fn inferExpr(self: *Sema, expr: *Expr) SemaError!TypeId {
        return switch (expr.*) {
            .int_lit => TYPE_INT32,
            .float_lit => TYPE_F64,
            .string_lit => TYPE_STRING,
            .bool_lit => TYPE_BOOL,
            .null_lit => TYPE_NULL,

            .ident => |id| {
                if (self.current_scope.lookup(id.name)) |sym| return sym.ty;
                try self.emitError("undeclared identifier", id.span);
                return TYPE_INT32; // recover
            },

            .binary => |b| {
                const lty = try self.inferExpr(b.lhs);
                const rty = try self.inferExpr(b.rhs);
                return self.binopResultType(b.op, lty, rty);
            },

            .unary => |u| {
                const inner_ty = try self.inferExpr(u.operand);
                return switch (u.op) {
                    .not_ => TYPE_BOOL,
                    .neg => inner_ty,
                    .bit_not => inner_ty,
                    .addr_of => try self.internType(Type{ .ptr = .{ .inner = inner_ty, .mutable = false } }),
                    .deref => self.derefType(inner_ty),
                };
            },

            .cast => |c| try self.resolveType(c.ty),

            .call => |c| {
                const callee_ty = try self.inferExpr(c.callee);
                for (c.args) |arg| _ = try self.inferExpr(arg);
                if (callee_ty < self.types.items.len) {
                    switch (self.types.items[callee_ty]) {
                        .func => |f| return f.ret,
                        else => {},
                    }
                }
                return TYPE_VOID;
            },

            .method_call => |mc| {
                _ = try self.inferExpr(mc.receiver);
                for (mc.args) |arg| _ = try self.inferExpr(arg);
                return TYPE_VOID; // simplified
            },

            .field => |f| {
                _ = try self.inferExpr(f.receiver);
                return TYPE_INT32; // simplified
            },

            .index => |i| {
                _ = try self.inferExpr(i.array);
                _ = try self.inferExpr(i.index);
                return TYPE_INT32; // simplified
            },

            .slice_expr => |s| {
                const arr_ty = try self.inferExpr(s.array);
                if (s.lo) |lo| _ = try self.inferExpr(lo);
                if (s.hi) |hi| _ = try self.inferExpr(hi);
                return try self.internType(Type{ .slice = arr_ty });
            },

            .struct_lit => TYPE_INT32, // TODO: proper struct type
            .array_lit => |al| {
                var elem_ty: TypeId = TYPE_INT32;
                for (al.elems) |e| elem_ty = try self.inferExpr(e);
                return try self.internType(Type{ .slice = elem_ty });
            },

            .closure => TYPE_VOID,
            .consume => |c| try self.inferExpr(c.expr),
            .await_expr => |a| try self.inferExpr(a.expr),
            .spawn_expr => TYPE_VOID,
            .builtin_call => TYPE_INT32,
            .option_capture => |oc| try self.inferExpr(oc.expr),
            .default => |d| try self.inferExpr(d.opt),
            .grouped => |g| try self.inferExpr(g.inner),
            .if_expr => |ie| blk: {
                _ = try self.inferExpr(ie.cond);
                const t = try self.inferExpr(ie.then_);
                _ = try self.inferExpr(ie.else_);
                break :blk t;
            },
        };
    }

    // ── Type resolution ────────────────────────────────────────────────────────

    pub fn resolveType(self: *Sema, te: *TypeExpr) SemaError!TypeId {
        return switch (te.*) {
            .named => |n| {
                if (self.current_scope.lookup(n.name)) |sym| {
                    if (sym.kind == .type_) return sym.ty;
                }
                // Attempt builtin mapping
                return self.resolveBuiltinName(n.name) orelse {
                    try self.emitError("unknown type", n.span);
                    return TYPE_INT32;
                };
            },
            .optional => |o| {
                const inner = try self.resolveType(o.inner);
                return try self.internType(Type{ .optional = inner });
            },
            .pointer => |p| {
                const inner = try self.resolveType(p.inner);
                return try self.internType(Type{ .ptr = .{ .inner = inner, .mutable = p.mutable } });
            },
            .array => |a| {
                const elem = try self.resolveType(a.elem);
                return try self.internType(Type{ .array = .{ .size = 0, .elem = elem } });
            },
            .slice => |s| {
                const elem = try self.resolveType(s.elem);
                return try self.internType(Type{ .slice = elem });
            },
            .generic => |g| {
                // `array(T)` → slice of T, `channel(T)` → placeholder
                if (g.args.len > 0) {
                    const elem = try self.resolveType(g.args[0]);
                    return try self.internType(Type{ .slice = elem });
                }
                return TYPE_INT32;
            },
            .owned => |o| try self.resolveType(o.inner),
            .func => |f| {
                const params = try self.allocator.alloc(TypeId, f.params.len);
                for (f.params, 0..) |p, i| params[i] = try self.resolveType(p);
                const ret: TypeId = if (f.ret) |r| try self.resolveType(r) else TYPE_VOID;
                return try self.internType(Type{ .func = .{
                    .params = params,
                    .ret = ret,
                    .is_async = false,
                }});
            },
            .unit => TYPE_VOID,
        };
    }

    pub fn resolveBuiltinName(self: *Sema, name: []const u8) ?TypeId {
        _ = self;
        const table = std.StaticStringMap(TypeId).initComptime(.{
            .{ "void",   TYPE_VOID },
            .{ "bool",   TYPE_BOOL },
            .{ "int8",   TYPE_INT8 },
            .{ "int16",  TYPE_INT16 },
            .{ "int32",  TYPE_INT32 },
            .{ "int64",  TYPE_INT64 },
            .{ "uint8",  TYPE_UINT8 },
            .{ "uint16", TYPE_UINT16 },
            .{ "uint32", TYPE_UINT32 },
            .{ "uint64", TYPE_UINT64 },
            .{ "f32",    TYPE_F32 },
            .{ "f64",    TYPE_F64 },
            .{ "string", TYPE_STRING },
            .{ "usize",  TYPE_USIZE },
            .{ "isize",  TYPE_ISIZE },
            .{ "u8",     TYPE_UINT8 },
        });
        return table.get(name);
    }

    fn internType(self: *Sema, ty: Type) SemaError!TypeId {
        // Simple interning: linear scan (good enough for bootstrap)
        for (self.types.items, 0..) |existing, i| {
            if (typeEql(existing, ty)) return @intCast(i);
        }
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(ty);
        return id;
    }

    // ── Type utilities ─────────────────────────────────────────────────────────

    pub fn typesCompatible(self: *Sema, expected: TypeId, actual: TypeId) bool {
        if (expected == actual) return true;
        if (actual == TYPE_NULL) return true; // null is compatible with any optional
        // Integer widening
        if (expected < self.types.items.len and actual < self.types.items.len) {
            const et = self.types.items[expected];
            const at = self.types.items[actual];
            switch (et) {
                .int => |ei| switch (at) {
                    .int => |ai| return ei.signed == ai.signed and ei.bits >= ai.bits,
                    else => {},
                },
                .float => |ef| switch (at) {
                    .float => |af| return ef.bits >= af.bits,
                    else => {},
                },
                else => {},
            }
        }
        return false;
    }

    fn binopResultType(self: *Sema, op: ast.BinOp, lty: TypeId, rty: TypeId) TypeId {
        _ = rty;
        _ = self;
        return switch (op) {
            .eq, .ne, .lt, .gt, .le, .ge, .and_, .or_ => TYPE_BOOL,
            .range, .range_excl => TYPE_INT32, // range type
            else => lty, // arithmetic preserves type
        };
    }

    fn derefType(self: *Sema, ty: TypeId) TypeId {
        if (ty < self.types.items.len) {
            switch (self.types.items[ty]) {
                .ptr => |p| return p.inner,
                else => {},
            }
        }
        return ty;
    }

    // ── Diagnostics ───────────────────────────────────────────────────────────

    fn emitError(self: *Sema, msg: []const u8, span: Span) SemaError!void {
        try self.diagnostics.append(Diagnostic{
            .kind = .err,
            .message = msg,
            .span = span,
        });
        // Don't halt — collect all errors
    }

    pub fn hasErrors(self: *const Sema) bool {
        for (self.diagnostics.items) |d| {
            if (d.kind == .err) return true;
        }
        return false;
    }

    pub fn printDiagnostics(self: *const Sema, src: []const u8, writer: anytype) !void {
        _ = src;
        for (self.diagnostics.items) |d| {
            try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
                "<source>",
                d.span.line,
                d.span.col,
                @tagName(d.kind),
                d.message,
            });
        }
    }

    pub fn getFieldOffset(self: *Sema, struct_name: []const u8, field_name: []const u8) u32 {
        if (self.struct_defs.get(struct_name)) |layout| {
            for (layout.fields) |fl| {
                if (std.mem.eql(u8, fl.name, field_name)) return fl.offset;
            }
        }
        return 0;
    }

    pub fn getStructSize(self: *Sema, struct_name: []const u8) u32 {
        if (self.struct_defs.get(struct_name)) |layout| {
            return layout.total_size;
        }
        return 8;
    }

    pub fn getType(self: *Sema, id: TypeId) ?*Type {
        if (id < self.types.items.len) return &self.types.items[id];
        return null;
    }

    fn typeSize(self: *Sema, te: *ast.TypeExpr) u32 {
        _ = self;
        return switch (te.*) {
            .named => |n| {
                if (std.mem.eql(u8, n.name, "uint64") or std.mem.eql(u8, n.name, "int64") or
                    std.mem.eql(u8, n.name, "float64") or std.mem.eql(u8, n.name, "string") or
                    std.mem.eql(u8, n.name, "bool64")) return 8;
                if (std.mem.eql(u8, n.name, "uint32") or std.mem.eql(u8, n.name, "int32") or
                    std.mem.eql(u8, n.name, "float32")) return 4;
                if (std.mem.eql(u8, n.name, "uint16") or std.mem.eql(u8, n.name, "int16")) return 2;
                if (std.mem.eql(u8, n.name, "uint8") or std.mem.eql(u8, n.name, "int8") or
                    std.mem.eql(u8, n.name, "bool")) return 1;
                return 8; // pointer-sized for unknown named types
            },
            .pointer, .optional => 8,
            else => 4,
        };
    }
};

fn typeEql(a: Type, b: Type) bool {
    const ta = std.meta.activeTag(a);
    const tb = std.meta.activeTag(b);
    if (ta != tb) return false;
    return switch (a) {
        .void_  => true,
        .bool_  => true,
        .string_=> true,
        .never  => true,
        .null_  => true,
        .int => |ai| switch (b) { .int => |bi| ai.bits == bi.bits and ai.signed == bi.signed, else => false },
        .float => |af| switch (b) { .float => |bf| af.bits == bf.bits, else => false },
        .ptr => |ap| switch (b) { .ptr => |bp| ap.inner == bp.inner and ap.mutable == bp.mutable, else => false },
        .optional => |ao| switch (b) { .optional => |bo| ao == bo, else => false },
        .slice => |as_| switch (b) { .slice => |bs| as_ == bs, else => false },
        .array => |aa| switch (b) { .array => |ba| aa.size == ba.size and aa.elem == ba.elem, else => false },
        .named => |an| switch (b) { .named => |bn| std.mem.eql(u8, an, bn), else => false },
        .struct_ => false, // identity by name handled elsewhere
        .enum_   => false,
        .func    => false, // structural equality not needed for bootstrap
    };
}
