/// Koda AST node types.
const std = @import("std");

pub const Span = struct { line: u32 };

pub const Stmt = union(enum) {
    var_decl: VarDecl,
    fn_decl: FnDecl,
    expr_stmt: *Expr,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    return_stmt: ReturnStmt,
    module_decl: ModuleDecl,
    import_stmt: ImportStmt,
};

pub const VarDecl = struct {
    name: []const u8,
    init: *Expr,
    span: Span,
};

pub const FnDecl = struct {
    name: []const u8,
    params: [][]const u8,
    body: []Stmt,
    is_async: bool,
    span: Span,
};

pub const IfStmt = struct {
    cond: *Expr,
    then_body: []Stmt,
    elsif_clauses: []ElsifClause,
    else_body: ?[]Stmt,
    span: Span,
};

pub const ElsifClause = struct {
    cond: *Expr,
    body: []Stmt,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: []Stmt,
    span: Span,
};

pub const ForStmt = struct {
    var_name: []const u8,
    iter: *Expr,
    body: []Stmt,
    span: Span,
};

pub const ReturnStmt = struct {
    value: ?*Expr,
    span: Span,
};

pub const ModuleDecl = struct {
    name: []const u8,
    span: Span,
};

pub const ImportStmt = struct {
    path: []const u8,
    alias: ?[]const u8,
    span: Span,
};

pub const Expr = union(enum) {
    int_lit: IntLit,
    float_lit: FloatLit,
    string_lit: StringLit,
    bool_lit: BoolLit,
    null_lit: Span,
    ident: Ident,
    binary: Binary,
    unary: Unary,
    call: Call,
    index: Index,
    field: Field,
    assign: Assign,
    array_lit: ArrayLit,
    table_lit: TableLit,
    lambda: Lambda,
    await_expr: AwaitExpr,
    spawn_expr: SpawnExpr,
    pipeline: Pipeline,
    range: Range,
};

pub const IntLit = struct { value: i64, span: Span };
pub const FloatLit = struct { value: f64, span: Span };
pub const StringLit = struct { value: []const u8, span: Span };
pub const BoolLit = struct { value: bool, span: Span };
pub const Ident = struct { name: []const u8, span: Span };

pub const BinaryOp = enum {
    add, sub, mul, div, mod,
    eq, ne, lt, gt, le, ge,
    and_, or_,
};

pub const Binary = struct {
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

pub const UnaryOp = enum { neg, not_ };

pub const Unary = struct {
    op: UnaryOp,
    operand: *Expr,
    span: Span,
};

pub const Call = struct {
    callee: *Expr,
    args: []*Expr,
    span: Span,
};

pub const Index = struct {
    object: *Expr,
    key: *Expr,
    span: Span,
};

pub const Field = struct {
    object: *Expr,
    name: []const u8,
    span: Span,
};

pub const Assign = struct {
    target: *Expr,
    value: *Expr,
    span: Span,
};

pub const ArrayLit = struct {
    elements: []*Expr,
    span: Span,
};

pub const TableEntry = struct {
    key: []const u8,
    value: *Expr,
};

pub const TableLit = struct {
    entries: []TableEntry,
    span: Span,
};

pub const Lambda = struct {
    params: [][]const u8,
    body: []Stmt,
    is_async: bool,
    span: Span,
};

pub const AwaitExpr = struct {
    expr: *Expr,
    span: Span,
};

pub const SpawnExpr = struct {
    body: []Stmt,
    span: Span,
};

pub const Pipeline = struct {
    lhs: *Expr,
    rhs: *Expr,
    span: Span,
};

pub const Range = struct {
    start: *Expr,
    end: *Expr,
    span: Span,
};
