/// Koda recursive-descent parser.
const std = @import("std");
const lexer_mod = @import("lexer");
const ast = @import("ast");

const Token = lexer_mod.Token;
const TokenKind = lexer_mod.TokenKind;
const Span = ast.Span;

pub const ParseError = error{ UnexpectedToken, OutOfMemory };

pub const Parser = struct {
    tokens: []Token,
    pos: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, tokens: []Token) Parser {
        return .{ .tokens = tokens, .pos = 0, .alloc = alloc };
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn peekKind(self: *Parser) TokenKind {
        return self.tokens[self.pos].kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.peekKind() == kind;
    }

    fn eat(self: *Parser, kind: TokenKind) ?Token {
        if (self.check(kind)) return self.advance();
        return null;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.check(kind)) return self.advance();
        return error.UnexpectedToken;
    }

    fn span(self: *Parser) Span {
        return .{ .line = self.peek().line };
    }

    fn allocExpr(self: *Parser, e: ast.Expr) !*ast.Expr {
        const p = try self.alloc.create(ast.Expr);
        p.* = e;
        return p;
    }

    // ── Public entry ──────────────────────────────────────────────────────────

    pub fn parseProgram(self: *Parser) ![]ast.Stmt {
        var stmts = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            try stmts.append(self.alloc, try self.parseStmt());
        }
        return try stmts.toOwnedSlice(self.alloc);
    }

    // ── Statements ────────────────────────────────────────────────────────────

    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        return switch (self.peekKind()) {
            .kw_var => try self.parseVarDecl(),
            .kw_function => blk: {
                _ = self.advance();
                break :blk try self.parseFnDecl(false);
            },
            .kw_async => blk: {
                _ = self.advance();
                _ = try self.expect(.kw_function);
                break :blk try self.parseFnDecl(true);
            },
            .kw_procedure => try self.parseProcDecl(),
            .kw_if => try self.parseIfStmt(),
            .kw_while => try self.parseWhileStmt(),
            .kw_for => try self.parseForStmt(),
            .kw_return => try self.parseReturnStmt(),
            .kw_module => blk: {
                _ = self.advance();
                const name_tok = try self.expect(.ident);
                _ = self.eat(.semicolon);
                break :blk ast.Stmt{ .module_decl = .{ .name = name_tok.text, .span = s } };
            },
            .kw_import, .kw_use => blk: {
                _ = self.advance();
                const path = try self.parseImportPath();
                var alias: ?[]const u8 = null;
                if (self.eat(.kw_as) != null) {
                    alias = (try self.expect(.ident)).text;
                }
                _ = self.eat(.semicolon);
                break :blk ast.Stmt{ .import_stmt = .{ .path = path, .alias = alias, .span = s } };
            },
            else => blk: {
                const e = try self.parseExpr();
                _ = self.eat(.semicolon);
                break :blk ast.Stmt{ .expr_stmt = e };
            },
        };
    }

    fn parseImportPath(self: *Parser) ParseError![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        const first = try self.expect(.ident);
        buf.appendSlice(self.alloc, first.text) catch return error.OutOfMemory;
        while (self.eat(.dot) != null) {
            buf.append(self.alloc, '.') catch return error.OutOfMemory;
            const next = try self.expect(.ident);
            buf.appendSlice(self.alloc, next.text) catch return error.OutOfMemory;
        }
        return try buf.toOwnedSlice(self.alloc);
    }

    fn parseVarDecl(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_var);
        const name = (try self.expect(.ident)).text;
        // Skip optional type annotation
        if (self.eat(.colon) != null) {
            _ = try self.parseTypeAnnotation();
        }
        _ = try self.expect(.colon_eq);
        const init_expr = try self.parseExpr();
        _ = self.eat(.semicolon);
        return ast.Stmt{ .var_decl = .{ .name = name, .init = init_expr, .span = s } };
    }

    fn parseTypeAnnotation(self: *Parser) ParseError![]const u8 {
        // Just consume the type token(s) and return the name
        const name = (try self.expect(.ident)).text;
        // Handle generics like array(int)
        if (self.eat(.lparen) != null) {
            _ = self.eat(.ident);
            _ = try self.expect(.rparen);
        }
        return name;
    }

    fn parseParams(self: *Parser) ParseError![][]const u8 {
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged([]const u8).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            const p = (try self.expect(.ident)).text;
            params.append(self.alloc, p) catch return error.OutOfMemory;
            // Skip optional type annotation
            if (self.eat(.colon) != null) _ = try self.parseTypeAnnotation();
            if (self.eat(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        return try params.toOwnedSlice(self.alloc);
    }

    fn parseBody(self: *Parser) ParseError![]ast.Stmt {
        _ = try self.expect(.kw_begin);
        var stmts = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.kw_end) and !self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            stmts.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
        }
        _ = try self.expect(.kw_end);
        return try stmts.toOwnedSlice(self.alloc);
    }

    fn parseBraceBody(self: *Parser) ParseError![]ast.Stmt {
        _ = try self.expect(.lbrace);
        var stmts = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            stmts.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
        }
        _ = try self.expect(.rbrace);
        return try stmts.toOwnedSlice(self.alloc);
    }

    fn parseFnDecl(self: *Parser, is_async: bool) ParseError!ast.Stmt {
        const s = self.span();
        const name = (try self.expect(.ident)).text;
        const params = try self.parseParams();
        // Skip optional return type
        if (self.eat(.colon) != null) _ = try self.parseTypeAnnotation();
        const body = try self.parseBody();
        return ast.Stmt{ .fn_decl = .{ .name = name, .params = params, .body = body, .is_async = is_async, .span = s } };
    }

    fn parseProcDecl(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_procedure);
        const name = (try self.expect(.ident)).text;
        const params = try self.parseParams();
        const body = try self.parseBody();
        return ast.Stmt{ .fn_decl = .{ .name = name, .params = params, .body = body, .is_async = false, .span = s } };
    }

    fn parseIfStmt(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_if);
        const cond = try self.parseExpr();
        _ = try self.expect(.kw_then);
        var then_body = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.kw_elsif) and !self.check(.kw_else) and !self.check(.kw_end) and !self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            then_body.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
        }
        var elsif_clauses = std.ArrayListUnmanaged(ast.ElsifClause).empty;
        while (self.eat(.kw_elsif) != null) {
            const ec = try self.parseExpr();
            _ = try self.expect(.kw_then);
            var eb = std.ArrayListUnmanaged(ast.Stmt).empty;
            while (!self.check(.kw_elsif) and !self.check(.kw_else) and !self.check(.kw_end) and !self.check(.eof)) {
                if (self.eat(.semicolon) != null) continue;
                eb.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
            }
            elsif_clauses.append(self.alloc, .{ .cond = ec, .body = try eb.toOwnedSlice(self.alloc) }) catch return error.OutOfMemory;
        }
        var else_body: ?[]ast.Stmt = null;
        if (self.eat(.kw_else) != null) {
            var eb = std.ArrayListUnmanaged(ast.Stmt).empty;
            while (!self.check(.kw_end) and !self.check(.eof)) {
                if (self.eat(.semicolon) != null) continue;
                eb.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
            }
            else_body = try eb.toOwnedSlice(self.alloc);
        }
        _ = try self.expect(.kw_end);
        return ast.Stmt{ .if_stmt = .{
            .cond = cond,
            .then_body = try then_body.toOwnedSlice(self.alloc),
            .elsif_clauses = try elsif_clauses.toOwnedSlice(self.alloc),
            .else_body = else_body,
            .span = s,
        }};
    }

    fn parseWhileStmt(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_while);
        const cond = try self.parseExpr();
        _ = try self.expect(.kw_do);
        var body = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.kw_end) and !self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            body.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
        }
        _ = try self.expect(.kw_end);
        return ast.Stmt{ .while_stmt = .{ .cond = cond, .body = try body.toOwnedSlice(self.alloc), .span = s } };
    }

    fn parseForStmt(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_for);
        const var_name = (try self.expect(.ident)).text;
        _ = try self.expect(.kw_in);
        const iter = try self.parseExpr();
        _ = try self.expect(.kw_do);
        var body = std.ArrayListUnmanaged(ast.Stmt).empty;
        while (!self.check(.kw_end) and !self.check(.eof)) {
            if (self.eat(.semicolon) != null) continue;
            body.append(self.alloc, try self.parseStmt()) catch return error.OutOfMemory;
        }
        _ = try self.expect(.kw_end);
        return ast.Stmt{ .for_stmt = .{ .var_name = var_name, .iter = iter, .body = try body.toOwnedSlice(self.alloc), .span = s } };
    }

    fn parseReturnStmt(self: *Parser) ParseError!ast.Stmt {
        const s = self.span();
        _ = try self.expect(.kw_return);
        var value: ?*ast.Expr = null;
        if (!self.check(.kw_end) and !self.check(.kw_else) and !self.check(.kw_elsif) and
            !self.check(.eof) and !self.check(.semicolon) and !self.check(.rbrace))
        {
            value = try self.parseExpr();
        }
        _ = self.eat(.semicolon);
        return ast.Stmt{ .return_stmt = .{ .value = value, .span = s } };
    }

    // ── Expressions ───────────────────────────────────────────────────────────

    pub fn parseExpr(self: *Parser) ParseError!*ast.Expr {
        return self.parsePipeline();
    }

    fn parsePipeline(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseAssign();
        while (self.check(.pipe)) {
            const s = self.span();
            _ = self.advance();
            const rhs = try self.parseAssign();
            lhs = try self.allocExpr(ast.Expr{ .pipeline = .{ .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseAssign(self: *Parser) ParseError!*ast.Expr {
        const lhs = try self.parseOr();
        if (self.check(.colon_eq) or self.check(.plus_eq) or self.check(.minus_eq) or
            self.check(.star_eq) or self.check(.slash_eq) or self.check(.percent_eq))
        {
            const s = self.span();
            const op_tok = self.advance();
            const rhs = try self.parseAssign();
            // Desugar compound assignment: x += y  →  x := x + y
            const rhs_val: *ast.Expr = switch (op_tok.kind) {
                .colon_eq => rhs,
                .plus_eq => try self.allocExpr(ast.Expr{ .binary = .{ .op = .add, .lhs = lhs, .rhs = rhs, .span = s } }),
                .minus_eq => try self.allocExpr(ast.Expr{ .binary = .{ .op = .sub, .lhs = lhs, .rhs = rhs, .span = s } }),
                .star_eq => try self.allocExpr(ast.Expr{ .binary = .{ .op = .mul, .lhs = lhs, .rhs = rhs, .span = s } }),
                .slash_eq => try self.allocExpr(ast.Expr{ .binary = .{ .op = .div, .lhs = lhs, .rhs = rhs, .span = s } }),
                .percent_eq => try self.allocExpr(ast.Expr{ .binary = .{ .op = .mod, .lhs = lhs, .rhs = rhs, .span = s } }),
                else => rhs,
            };
            return self.allocExpr(ast.Expr{ .assign = .{ .target = lhs, .value = rhs_val, .span = s } });
        }
        return lhs;
    }

    fn parseOr(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseAnd();
        while (self.check(.kw_or)) {
            const s = self.span();
            _ = self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.allocExpr(ast.Expr{ .binary = .{ .op = .or_, .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseNot();
        while (self.check(.kw_and)) {
            const s = self.span();
            _ = self.advance();
            const rhs = try self.parseNot();
            lhs = try self.allocExpr(ast.Expr{ .binary = .{ .op = .and_, .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseNot(self: *Parser) ParseError!*ast.Expr {
        if (self.check(.kw_not)) {
            const s = self.span();
            _ = self.advance();
            const operand = try self.parseNot();
            return self.allocExpr(ast.Expr{ .unary = .{ .op = .not_, .operand = operand, .span = s } });
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseRange();
        while (true) {
            const s = self.span();
            const op: ast.BinaryOp = switch (self.peekKind()) {
                .eq_eq => .eq,
                .bang_eq => .ne,
                .lt => .lt,
                .gt => .gt,
                .lt_eq => .le,
                .gt_eq => .ge,
                else => break,
            };
            _ = self.advance();
            const rhs = try self.parseAddSub();
            lhs = try self.allocExpr(ast.Expr{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseRange(self: *Parser) ParseError!*ast.Expr {
        const lhs = try self.parseAddSub();
        if (self.eat(.dot_dot) != null) {
            const s = self.span();
            const rhs = try self.parseAddSub();
            return self.allocExpr(ast.Expr{ .range = .{ .start = lhs, .end = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseAddSub(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseMulDiv();
        while (self.check(.plus) or self.check(.minus)) {
            const s = self.span();
            const op: ast.BinaryOp = if (self.peekKind() == .plus) .add else .sub;
            _ = self.advance();
            const rhs = try self.parseMulDiv();
            lhs = try self.allocExpr(ast.Expr{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseMulDiv(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parseUnary();
        while (self.check(.star) or self.check(.slash) or self.check(.percent)) {
            const s = self.span();
            const op: ast.BinaryOp = switch (self.peekKind()) {
                .star => .mul,
                .slash => .div,
                else => .mod,
            };
            _ = self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.allocExpr(ast.Expr{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs, .span = s } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expr {
        if (self.check(.minus)) {
            const s = self.span();
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.allocExpr(ast.Expr{ .unary = .{ .op = .neg, .operand = operand, .span = s } });
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*ast.Expr {
        var lhs = try self.parsePrimary();
        while (true) {
            const s = self.span();
            if (self.eat(.dot) != null) {
                const field_name = (try self.expect(.ident)).text;
                // Check for method call
                if (self.check(.lparen)) {
                    _ = self.advance();
                    const args = try self.parseArgs();
                    _ = try self.expect(.rparen);
                    const field_expr = try self.allocExpr(ast.Expr{ .field = .{ .object = lhs, .name = field_name, .span = s } });
                    lhs = try self.allocExpr(ast.Expr{ .call = .{ .callee = field_expr, .args = args, .span = s } });
                } else {
                    lhs = try self.allocExpr(ast.Expr{ .field = .{ .object = lhs, .name = field_name, .span = s } });
                }
            } else if (self.eat(.lbracket) != null) {
                const key = try self.parseExpr();
                _ = try self.expect(.rbracket);
                lhs = try self.allocExpr(ast.Expr{ .index = .{ .object = lhs, .key = key, .span = s } });
            } else if (self.check(.lparen)) {
                _ = self.advance();
                const args = try self.parseArgs();
                _ = try self.expect(.rparen);
                lhs = try self.allocExpr(ast.Expr{ .call = .{ .callee = lhs, .args = args, .span = s } });
            } else break;
        }
        return lhs;
    }

    fn parseArgs(self: *Parser) ParseError![]*ast.Expr {
        var args = std.ArrayListUnmanaged(*ast.Expr).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            args.append(self.alloc, try self.parseExpr()) catch return error.OutOfMemory;
            if (self.eat(.comma) == null) break;
        }
        return try args.toOwnedSlice(self.alloc);
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Expr {
        const s = self.span();
        const tok = self.peek();
        switch (tok.kind) {
            .int_lit => {
                _ = self.advance();
                const text = std.mem.replaceOwned(u8, self.alloc, tok.text, "_", "") catch return error.OutOfMemory;
                defer self.alloc.free(text);
                const val = std.fmt.parseInt(i64, text, 10) catch 0;
                return self.allocExpr(ast.Expr{ .int_lit = .{ .value = val, .span = s } });
            },
            .float_lit => {
                _ = self.advance();
                const val = std.fmt.parseFloat(f64, tok.text) catch 0.0;
                return self.allocExpr(ast.Expr{ .float_lit = .{ .value = val, .span = s } });
            },
            .string_lit => {
                _ = self.advance();
                const unescaped = try self.unescape(tok.text);
                return self.allocExpr(ast.Expr{ .string_lit = .{ .value = unescaped, .span = s } });
            },
            .kw_true => { _ = self.advance(); return self.allocExpr(ast.Expr{ .bool_lit = .{ .value = true, .span = s } }); },
            .kw_false => { _ = self.advance(); return self.allocExpr(ast.Expr{ .bool_lit = .{ .value = false, .span = s } }); },
            .kw_null => { _ = self.advance(); return self.allocExpr(ast.Expr{ .null_lit = s }); },
            .ident => {
                _ = self.advance();
                return self.allocExpr(ast.Expr{ .ident = .{ .name = tok.text, .span = s } });
            },
            .lparen => {
                _ = self.advance();
                const e = try self.parseExpr();
                _ = try self.expect(.rparen);
                return e;
            },
            .lbracket => return self.parseArrayLit(),
            .lbrace => return self.parseTableOrBlock(),
            .pipe => return self.parseLambda(),
            .kw_await => {
                _ = self.advance();
                const e = try self.parseExpr();
                return self.allocExpr(ast.Expr{ .await_expr = .{ .expr = e, .span = s } });
            },
            .kw_spawn => {
                _ = self.advance();
                const body = if (self.check(.kw_begin)) try self.parseBody() else try self.parseBraceBody();
                return self.allocExpr(ast.Expr{ .spawn_expr = .{ .body = body, .span = s } });
            },
            // Allow reserved words that are also registered as native functions to be called as identifiers.
            .kw_type => {
                _ = self.advance();
                return self.allocExpr(ast.Expr{ .ident = .{ .name = "type", .span = s } });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn unescape(self: *Parser, raw: []const u8) ParseError![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const c: u8 = switch (raw[i + 1]) {
                    'n' => '\n', 't' => '\t', 'r' => '\r',
                    '"' => '"', '\\' => '\\', else => raw[i + 1],
                };
                buf.append(self.alloc, c) catch return error.OutOfMemory;
                i += 2;
            } else {
                buf.append(self.alloc, raw[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        return try buf.toOwnedSlice(self.alloc);
    }

    fn parseArrayLit(self: *Parser) ParseError!*ast.Expr {
        const s = self.span();
        _ = try self.expect(.lbracket);
        var elements = std.ArrayListUnmanaged(*ast.Expr).empty;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            elements.append(self.alloc, try self.parseExpr()) catch return error.OutOfMemory;
            if (self.eat(.comma) == null) break;
        }
        _ = try self.expect(.rbracket);
        return self.allocExpr(ast.Expr{ .array_lit = .{ .elements = try elements.toOwnedSlice(self.alloc), .span = s } });
    }

    fn parseTableOrBlock(self: *Parser) ParseError!*ast.Expr {
        // Lookahead: if next is ident followed by = (not ==), it's a table literal
        const s = self.span();
        _ = try self.expect(.lbrace);
        // Empty braces = empty table
        if (self.check(.rbrace)) {
            _ = self.advance();
            return self.allocExpr(ast.Expr{ .table_lit = .{ .entries = &.{}, .span = s } });
        }
        // Check if first token is ident and second is '='
        const is_table = self.check(.ident) and
            self.pos + 1 < self.tokens.len and
            self.tokens[self.pos + 1].kind == .eq;
        if (is_table) {
            var entries = std.ArrayListUnmanaged(ast.TableEntry).empty;
            while (!self.check(.rbrace) and !self.check(.eof)) {
                const key = (try self.expect(.ident)).text;
                _ = try self.expect(.eq);
                const val = try self.parseExpr();
                entries.append(self.alloc, .{ .key = key, .value = val }) catch return error.OutOfMemory;
                if (self.eat(.comma) == null) break;
            }
            _ = try self.expect(.rbrace);
            return self.allocExpr(ast.Expr{ .table_lit = .{ .entries = try entries.toOwnedSlice(self.alloc), .span = s } });
        }
        // Otherwise it's an error (Koda blocks are begin/end, not {})
        return error.UnexpectedToken;
    }

    fn parseLambda(self: *Parser) ParseError!*ast.Expr {
        const s = self.span();
        _ = try self.expect(.pipe);
        // Parse params until next |
        var params = std.ArrayListUnmanaged([]const u8).empty;
        while (!self.check(.pipe) and !self.check(.eof)) {
            const p = (try self.expect(.ident)).text;
            params.append(self.alloc, p) catch return error.OutOfMemory;
            if (self.eat(.comma) == null) break;
        }
        _ = try self.expect(.pipe);
        // Body: begin..end or { .. }
        const body = if (self.check(.kw_begin)) try self.parseBody() else try self.parseBraceBody();
        return self.allocExpr(ast.Expr{ .lambda = .{ .params = try params.toOwnedSlice(self.alloc), .body = body, .is_async = false, .span = s } });
    }
};
