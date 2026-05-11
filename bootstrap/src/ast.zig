/// Maia AST node definitions.
/// All heap-allocated nodes are owned by the Arena passed to the parser.

const std = @import("std");
const Token = @import("lexer").Token;

// ── Source location ───────────────────────────────────────────────────────────

pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    col: u32,

    pub fn fromToken(t: Token) Span {
        return .{ .start = t.start, .end = t.end, .line = t.line, .col = t.col };
    }
};

// ── Type expressions ──────────────────────────────────────────────────────────

pub const OwnershipKind = enum { own, ref_, mut_, rc, weak, iso, trn, val, box, tag, none };

pub const TypeExpr = union(enum) {
    /// Named type: `int32`, `string`, `MyStruct`
    named: struct {
        name: []const u8,
        span: Span,
    },
    /// Optional type: `?T`
    optional: struct {
        inner: *TypeExpr,
        span: Span,
    },
    /// Pointer type: `*T`
    pointer: struct {
        inner: *TypeExpr,
        mutable: bool,
        span: Span,
    },
    /// Array type: `[N]T`
    array: struct {
        size: ?*Expr,
        elem: *TypeExpr,
        span: Span,
    },
    /// Slice type: `[]T`
    slice: struct {
        elem: *TypeExpr,
        span: Span,
    },
    /// Generic application: `array(T)`, `channel(T)`
    generic: struct {
        base: []const u8,
        args: []*TypeExpr,
        span: Span,
    },
    /// Qualified ownership: `own T`, `rc T`, etc.
    owned: struct {
        qualifier: OwnershipKind,
        inner: *TypeExpr,
        span: Span,
    },
    /// Function type: `function(A, B): R`
    func: struct {
        params: []*TypeExpr,
        ret: ?*TypeExpr,
        span: Span,
    },
    /// Tuple / anonymous struct (rare)
    unit: Span,
};

// ── Expressions ───────────────────────────────────────────────────────────────

pub const BinOp = enum {
    add, sub, mul, div, mod, int_div,
    eq, ne, lt, gt, le, ge,
    and_, or_,
    bit_and, bit_or, bit_xor,
    shl, shr,
    range, range_excl,
    pipeline,
    assign,
    add_assign, sub_assign, mul_assign, div_assign, mod_assign,
    and_assign, or_assign, xor_assign, shl_assign, shr_assign,
};

pub const UnOp = enum { neg, not_, bit_not, addr_of, deref };

pub const Expr = union(enum) {
    // Literals
    int_lit: struct { value: i64, span: Span },
    float_lit: struct { value: f64, span: Span },
    string_lit: struct { value: []const u8, span: Span },
    bool_lit: struct { value: bool, span: Span },
    null_lit: Span,

    // Identifier
    ident: struct { name: []const u8, span: Span },

    // Binary expression
    binary: struct {
        op: BinOp,
        lhs: *Expr,
        rhs: *Expr,
        span: Span,
    },

    // Unary expression
    unary: struct {
        op: UnOp,
        operand: *Expr,
        span: Span,
    },

    // Type cast: `value as Type`
    cast: struct {
        expr: *Expr,
        ty: *TypeExpr,
        span: Span,
    },

    // Function call: `name(args)`
    call: struct {
        callee: *Expr,
        args: []*Expr,
        span: Span,
    },

    // Method call: `obj.method(args)`
    method_call: struct {
        receiver: *Expr,
        method: []const u8,
        args: []*Expr,
        span: Span,
    },

    // Field access: `obj.field`
    field: struct {
        receiver: *Expr,
        field: []const u8,
        span: Span,
    },

    // Index: `arr[idx]`
    index: struct {
        array: *Expr,
        index: *Expr,
        span: Span,
    },

    // Slice: `arr[a..b]`
    slice_expr: struct {
        array: *Expr,
        lo: ?*Expr,
        hi: ?*Expr,
        exclusive: bool,
        span: Span,
    },

    // Struct literal: `Point { .x = 1, .y = 2 }`
    struct_lit: struct {
        ty: ?*TypeExpr,
        fields: []FieldInit,
        span: Span,
    },

    // Array literal: `[1, 2, 3]`
    array_lit: struct {
        elems: []*Expr,
        span: Span,
    },

    // Closure / lambda: `|a, b| { … }` or `|req| expr`
    closure: struct {
        params: []Param,
        body: *Stmt,
        span: Span,
    },

    // Consume (move): `consume x`
    consume: struct {
        expr: *Expr,
        span: Span,
    },

    // Await: `await expr`
    await_expr: struct {
        expr: *Expr,
        span: Span,
    },

    // Spawn: `spawn f()`
    spawn_expr: struct {
        call: *Expr,
        span: Span,
    },

    // Comptime builtin: `@comptime`, `@target_os()`, etc.
    builtin_call: struct {
        name: []const u8,
        args: []*Expr,
        span: Span,
    },

    // Option unwrap capture: `if maybe |value| then`
    option_capture: struct {
        expr: *Expr,
        binding: []const u8,
        span: Span,
    },

    // Default operator: `maybe ?? default`
    default: struct {
        opt: *Expr,
        fallback: *Expr,
        span: Span,
    },

    // Grouped expression: `( expr )`
    grouped: struct {
        inner: *Expr,
        span: Span,
    },

    // Inline if-expression: `if cond then t else e end`
    if_expr: struct {
        cond:  *Expr,
        then_: *Expr,
        else_: *Expr,
        span:  Span,
    },

    pub fn span(self: Expr) Span {
        return switch (self) {
            .int_lit => |x| x.span,
            .float_lit => |x| x.span,
            .string_lit => |x| x.span,
            .bool_lit => |x| x.span,
            .null_lit => |s| s,
            .ident => |x| x.span,
            .binary => |x| x.span,
            .unary => |x| x.span,
            .cast => |x| x.span,
            .call => |x| x.span,
            .method_call => |x| x.span,
            .field => |x| x.span,
            .index => |x| x.span,
            .slice_expr => |x| x.span,
            .struct_lit => |x| x.span,
            .array_lit => |x| x.span,
            .closure => |x| x.span,
            .consume => |x| x.span,
            .await_expr => |x| x.span,
            .spawn_expr => |x| x.span,
            .builtin_call => |x| x.span,
            .option_capture => |x| x.span,
            .default => |x| x.span,
            .grouped => |x| x.span,
            .if_expr => |x| x.span,
        };
    }
};

pub const FieldInit = struct {
    name: []const u8,
    value: *Expr,
    span: Span,
};

// ── Patterns (for match) ──────────────────────────────────────────────────────

pub const Pattern = union(enum) {
    wildcard: Span,
    int_lit: struct { value: i64, span: Span },
    string_lit: struct { value: []const u8, span: Span },
    ident: struct { name: []const u8, span: Span },
    range: struct { lo: i64, hi: i64, exclusive: bool, span: Span },
    else_: Span,
};

// ── Statements ────────────────────────────────────────────────────────────────

pub const Param = struct {
    name: []const u8,
    ty: ?*TypeExpr,
    ownership: OwnershipKind,
    span: Span,
};

pub const Stmt = union(enum) {
    // Variable declaration: `var x: T := expr` or `var x := expr`
    var_decl: struct {
        name: []const u8,
        names: ?[]const []const u8, // multi-var
        ty: ?*TypeExpr,
        ownership: OwnershipKind,
        init: ?*Expr,
        span: Span,
    },

    // Constant declaration: `const NAME: T = expr`
    const_decl: struct {
        name: []const u8,
        ty: ?*TypeExpr,
        value: *Expr,
        span: Span,
    },

    // Assignment: `x := expr` or `x += expr` etc.
    assign: struct {
        target: *Expr,
        op: BinOp, // .assign or compound
        value: *Expr,
        span: Span,
    },

    // Expression statement (calls, etc.)
    expr_stmt: struct {
        expr: *Expr,
        span: Span,
    },

    // Block: `begin … end`
    block: struct {
        stmts: []*Stmt,
        span: Span,
    },

    // If statement
    if_stmt: struct {
        cond: *Expr,
        then_branch: *Stmt,
        elsif_branches: []ElsIfBranch,
        else_branch: ?*Stmt,
        span: Span,
    },

    // While loop
    while_stmt: struct {
        cond: *Expr,
        body: *Stmt,
        span: Span,
    },

    // For loop
    for_stmt: struct {
        index_var: ?[]const u8,
        item_var: []const u8,
        iter: *Expr,
        body: *Stmt,
        span: Span,
    },

    // Infinite loop
    loop_stmt: struct {
        body: *Stmt,
        span: Span,
    },

    // Break / continue
    break_stmt: Span,
    continue_stmt: Span,

    // Return
    return_stmt: struct {
        value: ?*Expr,
        span: Span,
    },

    // Match
    match_stmt: struct {
        subject: *Expr,
        arms: []MatchArm,
        span: Span,
    },

    // Defer
    defer_stmt: struct {
        body: *Stmt,
        span: Span,
    },

    // Safe / unsafe block
    safe_block: struct {
        body: *Stmt,
        span: Span,
    },
    unsafe_block: struct {
        body: *Stmt,
        span: Span,
    },

    pub fn span(self: Stmt) Span {
        return switch (self) {
            .var_decl => |x| x.span,
            .const_decl => |x| x.span,
            .assign => |x| x.span,
            .expr_stmt => |x| x.span,
            .block => |x| x.span,
            .if_stmt => |x| x.span,
            .while_stmt => |x| x.span,
            .for_stmt => |x| x.span,
            .loop_stmt => |x| x.span,
            .break_stmt => |s| s,
            .continue_stmt => |s| s,
            .return_stmt => |x| x.span,
            .match_stmt => |x| x.span,
            .defer_stmt => |x| x.span,
            .safe_block => |x| x.span,
            .unsafe_block => |x| x.span,
        };
    }
};

pub const ElsIfBranch = struct {
    cond: *Expr,
    body: *Stmt,
    span: Span,
};

pub const MatchArm = struct {
    pattern: Pattern,
    body: *Stmt,
    span: Span,
};

// ── Declarations ──────────────────────────────────────────────────────────────

pub const ExportLevel = enum { public, module_, package_, private };

pub const Decl = union(enum) {
    // `module Foo`
    module_decl: struct {
        name: []const u8,
        span: Span,
    },

    // `use Math`, `use Math.{add}`, `use Math as M`, `use Math.*`
    use_decl: struct {
        path: []const []const u8,
        alias: ?[]const u8,
        items: ?[]const []const u8, // null = all (*)
        span: Span,
    },

    // `function f(…): T begin … end`
    func_decl: struct {
        name: []const u8,
        type_params: [][]const u8,
        params: []Param,
        ret: ?*TypeExpr,
        body: ?*Stmt,
        is_async: bool,
        is_comptime: bool,
        export_level: ExportLevel,
        span: Span,
    },

    // `procedure p(…) begin … end`
    proc_decl: struct {
        name: []const u8,
        type_params: [][]const u8,
        params: []Param,
        body: ?*Stmt,
        is_async: bool,
        export_level: ExportLevel,
        span: Span,
    },

    // `type Foo = struct { … }`
    type_decl: struct {
        name: []const u8,
        type_params: [][]const u8,
        def: TypeDef,
        export_level: ExportLevel,
        span: Span,
    },

    // `const NAME: T = expr`
    const_decl: struct {
        name: []const u8,
        ty: ?*TypeExpr,
        value: *Expr,
        export_level: ExportLevel,
        span: Span,
    },

    // `var NAME: T = expr`  (top-level)
    var_decl: struct {
        name: []const u8,
        ty: ?*TypeExpr,
        ownership: OwnershipKind,
        init: ?*Expr,
        export_level: ExportLevel,
        span: Span,
    },

    // `actor Foo { … }`
    actor_decl: struct {
        name: []const u8,
        members: []ActorMember,
        export_level: ExportLevel,
        span: Span,
    },

    // `extern function …`
    extern_decl: struct {
        link: ?[]const u8,  // @link("c")
        lang: ?[]const u8,  // "C++", "Rust", etc.
        item: *Decl,
        span: Span,
    },

    pub fn span(self: Decl) Span {
        return switch (self) {
            inline else => |d| d.span,
        };
    }
};

pub const TypeDef = union(enum) {
    struct_def: struct {
        fields: []StructField,
        methods: []Decl,
    },
    enum_def: struct {
        variants: []EnumVariant,
    },
    alias: *TypeExpr,
};

pub const StructField = struct {
    name: []const u8,
    ty: *TypeExpr,
    ownership: OwnershipKind,
    span: Span,
};

pub const EnumVariant = struct {
    name: []const u8,
    value: ?*Expr,
    span: Span,
};

pub const ActorMember = union(enum) {
    field: StructField,
    behavior: Decl, // func_decl tagged as behavior
    func: Decl,
};

// ── Module (root of the tree) ─────────────────────────────────────────────────

pub const Module = struct {
    name: ?[]const u8,
    decls: []Decl,
    source: []const u8,
    allocator: std.mem.Allocator,
};
