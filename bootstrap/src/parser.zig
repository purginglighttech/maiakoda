/// Maia recursive-descent parser.
/// Converts a token stream into an AST.Module.
/// All memory is allocated from the supplied Arena allocator.

const std = @import("std");
const lex = @import("lexer");
const ast = @import("ast");

const Token = lex.Token;
const TK = lex.TokenKind;
const Span = ast.Span;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Decl = ast.Decl;
const TypeExpr = ast.TypeExpr;
const Param = ast.Param;
const OwnershipKind = ast.OwnershipKind;
const ExportLevel = ast.ExportLevel;

// ── Error handling ────────────────────────────────────────────────────────────

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    OutOfMemory,
};

pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
};

// ── Parser ────────────────────────────────────────────────────────────────────

pub const Parser = struct {
    tokens: []const Token,
    pos: u32,
    src: []const u8,
    arena: std.mem.Allocator,
    diagnostics: std.array_list.AlignedManaged(Diagnostic, null),

    pub fn init(
        arena: std.mem.Allocator,
        src: []const u8,
        tokens: []const Token,
    ) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .src = src,
            .arena = arena,
            .diagnostics = std.array_list.AlignedManaged(Diagnostic, null).init(arena),
        };
    }

    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var decls = std.array_list.AlignedManaged(Decl, null).init(self.arena);

        // Optional module declaration
        var mod_name: ?[]const u8 = null;
        if (self.check(.kw_module)) {
            _ = self.advance();
            const name_tok = try self.expect(.identifier);
            mod_name = name_tok.text(self.src);
            _ = self.tryConsume(.semicolon);
        }

        while (!self.isAtEnd()) {
            const decl = self.parseDecl() catch |err| {
                if (err == error.UnexpectedToken or err == error.UnexpectedEof) {
                    // Panic-mode recovery: skip to next declaration boundary
                    self.synchronize();
                    continue;
                }
                return err;
            };
            try decls.append(decl);
        }

        return ast.Module{
            .name = mod_name,
            .decls = try decls.toOwnedSlice(),
            .source = self.src,
            .allocator = self.arena,
        };
    }

    // ── Declaration parsing ────────────────────────────────────────────────────

    fn parseDecl(self: *Parser) ParseError!Decl {
        // Collect export/package annotation
        var export_level = ExportLevel.private;
        if (self.check(.kw_export)) {
            _ = self.advance();
            if (self.check(.lparen)) {
                _ = self.advance();
                const qual = try self.expect(.identifier);
                _ = try self.expect(.rparen);
                if (std.mem.eql(u8, qual.text(self.src), "module")) {
                    export_level = .module_;
                }
            } else {
                export_level = .public;
            }
        } else if (self.check(.kw_package)) {
            _ = self.advance();
            export_level = .package_;
        }

        // @comptime / @link attributes
        var is_comptime = false;
        var link_name: ?[]const u8 = null;
        var extern_lang: ?[]const u8 = null;

        while (self.check(.at)) {
            _ = self.advance();
            const attr_name = try self.expect(.identifier);
            const attr = attr_name.text(self.src);
            if (std.mem.eql(u8, attr, "comptime")) {
                is_comptime = true;
            } else if (std.mem.eql(u8, attr, "link")) {
                _ = try self.expect(.lparen);
                const s = try self.expect(.string_literal);
                _ = try self.expect(.rparen);
                link_name = try unquote(self.arena,s.text(self.src));
            }
        }

        // extern declaration
        if (self.check(.kw_extern)) {
            _ = self.advance();
            if (self.check(.string_literal)) {
                const lang_tok = self.advance();
                extern_lang = try unquote(self.arena,lang_tok.text(self.src));
            }
            const inner = try self.parseDecl();
            const inner_ptr = try self.arena.create(Decl);
            inner_ptr.* = inner;
            return Decl{ .extern_decl = .{
                .link = link_name,
                .lang = extern_lang,
                .item = inner_ptr,
                .span = inner_ptr.*.span(),
            }};
        }

        const start_tok = self.current();

        // use declaration
        if (self.check(.kw_use)) return self.parseUse();

        // function declaration
        if (self.check(.kw_async)) {
            _ = self.advance();
            return self.parseFuncOrProc(export_level, true, is_comptime);
        }
        if (self.check(.kw_function)) return self.parseFuncOrProc(export_level, false, is_comptime);
        if (self.check(.kw_procedure)) return self.parseProcDecl(export_level, false);

        // type declaration
        if (self.check(.kw_type)) return self.parseTypeDecl(export_level);

        // const declaration
        if (self.check(.kw_const)) return self.parseTopConst(export_level);

        // var declaration
        if (self.check(.kw_var)) return self.parseTopVar(export_level);

        // actor declaration
        if (self.check(.kw_actor)) return self.parseActor(export_level);

        _ = start_tok;
        return error.UnexpectedToken;
    }

    fn parseUse(self: *Parser) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `use`
        var path = std.array_list.AlignedManaged([]const u8, null).init(self.arena);
        const first = try self.expect(.identifier);
        try path.append(first.text(self.src));
        while (self.check(.dot)) {
            _ = self.advance();
            // `*` = all, `{…}` = specific, or another identifier
            if (self.check(.star)) {
                _ = self.advance();
                return Decl{ .use_decl = .{
                    .path = try path.toOwnedSlice(),
                    .alias = null,
                    .items = null, // null = wildcard
                    .span = Span.fromToken(start),
                }};
            }
            if (self.check(.lbrace)) {
                _ = self.advance();
                var items = std.array_list.AlignedManaged([]const u8, null).init(self.arena);
                while (!self.check(.rbrace) and !self.isAtEnd()) {
                    const item = try self.expect(.identifier);
                    try items.append(item.text(self.src));
                    if (!self.tryConsume(.comma)) break;
                }
                _ = try self.expect(.rbrace);
                return Decl{ .use_decl = .{
                    .path = try path.toOwnedSlice(),
                    .alias = null,
                    .items = try items.toOwnedSlice(),
                    .span = Span.fromToken(start),
                }};
            }
            const seg = try self.expect(.identifier);
            try path.append(seg.text(self.src));
        }
        var alias: ?[]const u8 = null;
        if (self.check(.kw_as)) {
            _ = self.advance();
            const a = try self.expect(.identifier);
            alias = a.text(self.src);
        }
        _ = self.tryConsume(.semicolon);
        return Decl{ .use_decl = .{
            .path = try path.toOwnedSlice(),
            .alias = alias,
            .items = &.{},
            .span = Span.fromToken(start),
        }};
    }

    fn parseFuncOrProc(self: *Parser, export_level: ExportLevel, is_async: bool, is_comptime: bool) ParseError!Decl {
        if (self.check(.kw_function)) {
            return self.parseFuncDecl(export_level, is_async, is_comptime);
        }
        return self.parseProcDecl(export_level, is_async);
    }

    fn parseFuncDecl(self: *Parser, export_level: ExportLevel, is_async: bool, is_comptime: bool) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `function`
        const name_tok = try self.expect(.identifier);
        const name = name_tok.text(self.src);
        const type_params = try self.parseTypeParams();
        const params = try self.parseParamList();
        var ret: ?*TypeExpr = null;
        if (self.check(.colon)) {
            _ = self.advance();
            ret = try self.allocTypeExpr(try self.parseTypeExpr());
        }
        var body: ?*Stmt = null;
        if (self.check(.kw_begin)) {
            body = try self.allocStmt(try self.parseBlock());
        }
        _ = self.tryConsume(.semicolon);
        return Decl{ .func_decl = .{
            .name = name,
            .type_params = type_params,
            .params = params,
            .ret = ret,
            .body = body,
            .is_async = is_async,
            .is_comptime = is_comptime,
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    fn parseProcDecl(self: *Parser, export_level: ExportLevel, is_async: bool) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `procedure`
        const name_tok = try self.expect(.identifier);
        const name = name_tok.text(self.src);
        const type_params = try self.parseTypeParams();
        const params = try self.parseParamList();
        var body: ?*Stmt = null;
        if (self.check(.kw_begin)) {
            body = try self.allocStmt(try self.parseBlock());
        }
        _ = self.tryConsume(.semicolon);
        return Decl{ .proc_decl = .{
            .name = name,
            .type_params = type_params,
            .params = params,
            .body = body,
            .is_async = is_async,
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    fn parseTypeDecl(self: *Parser, export_level: ExportLevel) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `type`
        const name_tok = try self.expect(.identifier);
        const name = name_tok.text(self.src);
        const type_params = try self.parseTypeParams();
        _ = try self.expect(.eq);
        const def = try self.parseTypeDef();
        _ = self.tryConsume(.semicolon);
        return Decl{ .type_decl = .{
            .name = name,
            .type_params = type_params,
            .def = def,
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    fn parseTypeDef(self: *Parser) ParseError!ast.TypeDef {
        if (self.check(.kw_struct)) {
            _ = self.advance();
            _ = try self.expect(.lbrace);
            var fields = std.array_list.AlignedManaged(ast.StructField, null).init(self.arena);
            var methods = std.array_list.AlignedManaged(Decl, null).init(self.arena);
            while (!self.check(.rbrace) and !self.isAtEnd()) {
                if (self.check(.kw_function) or self.check(.kw_procedure)) {
                    const m = try self.parseDecl();
                    try methods.append(m);
                } else {
                    // field: name: Type,
                    const ownership = self.tryOwnership();
                    const fname = try self.expect(.identifier);
                    _ = try self.expect(.colon);
                    const fty = try self.parseTypeExpr();
                    const fty_ptr = try self.allocTypeExpr(fty);
                    _ = self.tryConsume(.comma);
                    try fields.append(ast.StructField{
                        .name = fname.text(self.src),
                        .ty = fty_ptr,
                        .ownership = ownership,
                        .span = Span.fromToken(fname),
                    });
                }
            }
            _ = try self.expect(.rbrace);
            return ast.TypeDef{ .struct_def = .{
                .fields = try fields.toOwnedSlice(),
                .methods = try methods.toOwnedSlice(),
            }};
        }
        if (self.check(.kw_enum)) {
            _ = self.advance();
            _ = try self.expect(.lbrace);
            var variants = std.array_list.AlignedManaged(ast.EnumVariant, null).init(self.arena);
            while (!self.check(.rbrace) and !self.isAtEnd()) {
                const vtok = try self.expect(.identifier);
                var value: ?*Expr = null;
                if (self.tryConsume(.eq)) {
                    value = try self.allocExpr(try self.parseExpr());
                }
                _ = self.tryConsume(.comma);
                try variants.append(ast.EnumVariant{
                    .name = vtok.text(self.src),
                    .value = value,
                    .span = Span.fromToken(vtok),
                });
            }
            _ = try self.expect(.rbrace);
            return ast.TypeDef{ .enum_def = .{ .variants = try variants.toOwnedSlice() }};
        }
        // Alias
        const ty = try self.parseTypeExpr();
        const ty_ptr = try self.allocTypeExpr(ty);
        return ast.TypeDef{ .alias = ty_ptr };
    }

    fn parseTopConst(self: *Parser, export_level: ExportLevel) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `const`
        const name_tok = try self.expect(.identifier);
        var ty: ?*TypeExpr = null;
        if (self.check(.colon)) {
            _ = self.advance();
            ty = try self.allocTypeExpr(try self.parseTypeExpr());
        }
        _ = try self.expect(.eq);
        const val = try self.parseExpr();
        const val_ptr = try self.allocExpr(val);
        _ = self.tryConsume(.semicolon);
        return Decl{ .const_decl = .{
            .name = name_tok.text(self.src),
            .ty = ty,
            .value = val_ptr,
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    fn parseTopVar(self: *Parser, export_level: ExportLevel) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `var`
        const ownership = self.tryOwnership();
        const name_tok = try self.expect(.identifier);
        var ty: ?*TypeExpr = null;
        if (self.check(.colon)) {
            _ = self.advance();
            ty = try self.allocTypeExpr(try self.parseTypeExpr());
        }
        var init_expr: ?*Expr = null;
        if (self.check(.eq) or self.check(.colon_eq)) {
            _ = self.advance();
            init_expr = try self.allocExpr(try self.parseExpr());
        }
        _ = self.tryConsume(.semicolon);
        return Decl{ .var_decl = .{
            .name = name_tok.text(self.src),
            .ty = ty,
            .ownership = ownership,
            .init = init_expr,
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    fn parseActor(self: *Parser, export_level: ExportLevel) ParseError!Decl {
        const start = self.current();
        _ = self.advance(); // consume `actor`
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.lbrace);
        var members = std.array_list.AlignedManaged(ast.ActorMember, null).init(self.arena);
        while (!self.check(.rbrace) and !self.isAtEnd()) {
            if (self.check(.kw_behavior)) {
                _ = self.advance(); // consume `behavior`
                const bd = try self.parseFuncDecl(.private, false, false);
                try members.append(ast.ActorMember{ .behavior = bd });
            } else if (self.check(.kw_function)) {
                const fd = try self.parseFuncDecl(.private, false, false);
                try members.append(ast.ActorMember{ .func = fd });
            } else {
                // field
                const ownership = self.tryOwnership();
                const fname = try self.expect(.identifier);
                _ = try self.expect(.colon);
                const fty = try self.allocTypeExpr(try self.parseTypeExpr());
                if (self.tryConsume(.colon_eq) or self.tryConsume(.eq)) {
                    _ = try self.allocExpr(try self.parseExpr());
                }
                _ = self.tryConsume(.semicolon);
                try members.append(ast.ActorMember{ .field = ast.StructField{
                    .name = fname.text(self.src),
                    .ty = fty,
                    .ownership = ownership,
                    .span = Span.fromToken(fname),
                }});
            }
        }
        _ = try self.expect(.rbrace);
        return Decl{ .actor_decl = .{
            .name = name_tok.text(self.src),
            .members = try members.toOwnedSlice(),
            .export_level = export_level,
            .span = Span.fromToken(start),
        }};
    }

    // ── Type expression parsing ────────────────────────────────────────────────

    fn parseTypeExpr(self: *Parser) ParseError!TypeExpr {
        const span = Span.fromToken(self.current());

        // Ownership qualifier
        const ownq = self.tryOwnership();
        if (ownq != .none) {
            const inner = try self.parseTypeExpr();
            const inner_ptr = try self.allocTypeExpr(inner);
            return TypeExpr{ .owned = .{ .qualifier = ownq, .inner = inner_ptr, .span = span }};
        }

        // ?T  optional
        if (self.tryConsume(.question)) {
            const inner = try self.parseTypeExpr();
            const inner_ptr = try self.allocTypeExpr(inner);
            return TypeExpr{ .optional = .{ .inner = inner_ptr, .span = span }};
        }

        // *T  pointer
        if (self.tryConsume(.star)) {
            const mutable = self.tryConsume(.kw_mut);
            const inner = try self.parseTypeExpr();
            const inner_ptr = try self.allocTypeExpr(inner);
            return TypeExpr{ .pointer = .{ .inner = inner_ptr, .mutable = mutable, .span = span }};
        }

        // [N]T or []T
        if (self.tryConsume(.lbracket)) {
            if (self.check(.rbracket)) {
                _ = self.advance();
                const elem = try self.parseTypeExpr();
                return TypeExpr{ .slice = .{ .elem = try self.allocTypeExpr(elem), .span = span }};
            }
            const size_expr = try self.parseExpr();
            const size_ptr = try self.allocExpr(size_expr);
            _ = try self.expect(.rbracket);
            const elem = try self.parseTypeExpr();
            return TypeExpr{ .array = .{ .size = size_ptr, .elem = try self.allocTypeExpr(elem), .span = span }};
        }

        // Named type (possibly with generic args)
        const name_tok = try self.expect(.identifier);
        const name = name_tok.text(self.src);

        if (self.tryConsume(.lparen)) {
            // Generic application: `array(T)`, `channel(T)`
            var args = std.array_list.AlignedManaged(*TypeExpr, null).init(self.arena);
            while (!self.check(.rparen) and !self.isAtEnd()) {
                const arg = try self.parseTypeExpr();
                try args.append(try self.allocTypeExpr(arg));
                if (!self.tryConsume(.comma)) break;
            }
            _ = try self.expect(.rparen);
            return TypeExpr{ .generic = .{
                .base = name,
                .args = try args.toOwnedSlice(),
                .span = span,
            }};
        }

        return TypeExpr{ .named = .{ .name = name, .span = span }};
    }

    // ── Parameter list parsing ─────────────────────────────────────────────────

    fn parseTypeParams(self: *Parser) ParseError![][]const u8 {
        if (!self.tryConsume(.lt)) return &.{};
        var params = std.array_list.AlignedManaged([]const u8, null).init(self.arena);
        while (!self.check(.gt) and !self.isAtEnd()) {
            const t = try self.expect(.identifier);
            try params.append(t.text(self.src));
            if (!self.tryConsume(.comma)) break;
        }
        _ = try self.expect(.gt);
        return params.toOwnedSlice();
    }

    fn parseParamList(self: *Parser) ParseError![]Param {
        _ = try self.expect(.lparen);
        var params = std.array_list.AlignedManaged(Param, null).init(self.arena);
        while (!self.check(.rparen) and !self.isAtEnd()) {
            const param = try self.parseParam();
            try params.append(param);
            if (!self.tryConsume(.comma)) break;
        }
        _ = try self.expect(.rparen);
        return params.toOwnedSlice();
    }

    fn parseParam(self: *Parser) ParseError!Param {
        const start = self.current();
        const ownership = self.tryOwnership();
        // `&self` / `&mut self` shorthand
        if (self.tryConsume(.amp)) {
            const mutable = self.tryConsume(.kw_mut);
            const name_tok = try self.expect(.identifier);
            return Param{
                .name = name_tok.text(self.src),
                .ty = null,
                .ownership = if (mutable) .mut_ else .ref_,
                .span = Span.fromToken(start),
            };
        }
        const name_tok = try self.expect(.identifier);
        var ty: ?*TypeExpr = null;
        if (self.tryConsume(.colon)) {
            ty = try self.allocTypeExpr(try self.parseTypeExpr());
        }
        return Param{
            .name = name_tok.text(self.src),
            .ty = ty,
            .ownership = ownership,
            .span = Span.fromToken(start),
        };
    }

    // ── Statement parsing ──────────────────────────────────────────────────────

    fn parseBlock(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = try self.expect(.kw_begin);
        var stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
        while (!self.check(.kw_end) and !self.isAtEnd()) {
            const s = try self.parseStmt();
            try stmts.append(try self.allocStmt(s));
        }
        _ = try self.expect(.kw_end);
        return Stmt{ .block = .{
            .stmts = try stmts.toOwnedSlice(),
            .span = Span.fromToken(start),
        }};
    }

    fn parseStmt(self: *Parser) ParseError!Stmt {
        _ = self.tryConsumeDocs();
        const start = self.current();

        if (self.check(.kw_var)) return self.parseVarDecl();
        if (self.check(.kw_const)) return self.parseConstStmt();
        if (self.check(.kw_if)) return self.parseIf();
        if (self.check(.kw_while)) return self.parseWhile();
        if (self.check(.kw_for)) return self.parseFor();
        if (self.check(.kw_loop)) return self.parseLoop();
        if (self.check(.kw_break)) { _ = self.advance(); _ = self.tryConsume(.semicolon); return Stmt{ .break_stmt = Span.fromToken(start) }; }
        if (self.check(.kw_continue)) { _ = self.advance(); _ = self.tryConsume(.semicolon); return Stmt{ .continue_stmt = Span.fromToken(start) }; }
        if (self.check(.kw_return)) return self.parseReturn();
        if (self.check(.kw_match)) return self.parseMatch();
        if (self.check(.kw_defer)) return self.parseDefer();
        if (self.check(.kw_safe)) return self.parseSafeBlock();
        if (self.check(.kw_unsafe)) return self.parseUnsafeBlock();
        if (self.check(.kw_begin)) return self.parseBlock();

        // Expression or assignment statement
        return self.parseExprOrAssignStmt();
    }

    fn parseVarDecl(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance(); // consume `var`
        const ownership = self.tryOwnership();
        const name_tok = try self.expect(.identifier);

        // Multi-var: `var a, b, c: T = …`
        if (self.check(.comma)) {
            var names = std.array_list.AlignedManaged([]const u8, null).init(self.arena);
            try names.append(name_tok.text(self.src));
            while (self.tryConsume(.comma)) {
                const n = try self.expect(.identifier);
                try names.append(n.text(self.src));
            }
            var ty: ?*TypeExpr = null;
            if (self.tryConsume(.colon)) {
                ty = try self.allocTypeExpr(try self.parseTypeExpr());
            }
            var init_expr: ?*Expr = null;
            if (self.tryConsume(.eq) or self.tryConsume(.colon_eq)) {
                init_expr = try self.allocExpr(try self.parseExpr());
            }
            _ = self.tryConsume(.semicolon);
            return Stmt{ .var_decl = .{
                .name = name_tok.text(self.src),
                .names = try names.toOwnedSlice(),
                .ty = ty,
                .ownership = ownership,
                .init = init_expr,
                .span = Span.fromToken(start),
            }};
        }

        var ty: ?*TypeExpr = null;
        if (self.tryConsume(.colon)) {
            // Check if this is `:=` (init without type)
            if (!self.check(.eq)) {
                ty = try self.allocTypeExpr(try self.parseTypeExpr());
            }
        }
        var init_expr: ?*Expr = null;
        if (self.tryConsume(.eq) or self.tryConsume(.colon_eq)) {
            init_expr = try self.allocExpr(try self.parseExpr());
        }
        _ = self.tryConsume(.semicolon);
        return Stmt{ .var_decl = .{
            .name = name_tok.text(self.src),
            .names = null,
            .ty = ty,
            .ownership = ownership,
            .init = init_expr,
            .span = Span.fromToken(start),
        }};
    }

    fn parseConstStmt(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        const name_tok = try self.expect(.identifier);
        var ty: ?*TypeExpr = null;
        if (self.tryConsume(.colon)) {
            if (!self.check(.eq)) {
                ty = try self.allocTypeExpr(try self.parseTypeExpr());
            }
        }
        if (!self.tryConsume(.eq) and !self.tryConsume(.colon_eq)) {
            return error.UnexpectedToken;
        }
        const val = try self.allocExpr(try self.parseExpr());
        _ = self.tryConsume(.semicolon);
        return Stmt{ .const_decl = .{
            .name = name_tok.text(self.src),
            .ty = ty,
            .value = val,
            .span = Span.fromToken(start),
        }};
    }

    fn parseIf(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance(); // consume `if`
        const cond = try self.allocExpr(try self.parseExpr());
        _ = try self.expect(.kw_then);
        var then_stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
        while (!self.check(.kw_elsif) and !self.check(.kw_else) and !self.check(.kw_end) and !self.isAtEnd()) {
            const s = try self.parseStmt();
            try then_stmts.append(try self.allocStmt(s));
        }
        const then_block = try self.allocStmt(Stmt{ .block = .{
            .stmts = try then_stmts.toOwnedSlice(),
            .span = Span.fromToken(start),
        }});

        var elsif_branches = std.array_list.AlignedManaged(ast.ElsIfBranch, null).init(self.arena);
        while (self.check(.kw_elsif)) {
            const eb_start = self.current();
            _ = self.advance();
            const eb_cond = try self.allocExpr(try self.parseExpr());
            _ = try self.expect(.kw_then);
            var eb_stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
            while (!self.check(.kw_elsif) and !self.check(.kw_else) and !self.check(.kw_end) and !self.isAtEnd()) {
                try eb_stmts.append(try self.allocStmt(try self.parseStmt()));
            }
            const eb_body = try self.allocStmt(Stmt{ .block = .{
                .stmts = try eb_stmts.toOwnedSlice(),
                .span = Span.fromToken(eb_start),
            }});
            try elsif_branches.append(ast.ElsIfBranch{
                .cond = eb_cond,
                .body = eb_body,
                .span = Span.fromToken(eb_start),
            });
        }

        var else_branch: ?*Stmt = null;
        if (self.check(.kw_else)) {
            const else_start = self.current();
            _ = self.advance();
            var else_stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
            while (!self.check(.kw_end) and !self.isAtEnd()) {
                try else_stmts.append(try self.allocStmt(try self.parseStmt()));
            }
            else_branch = try self.allocStmt(Stmt{ .block = .{
                .stmts = try else_stmts.toOwnedSlice(),
                .span = Span.fromToken(else_start),
            }});
        }
        _ = try self.expect(.kw_end);
        return Stmt{ .if_stmt = .{
            .cond = cond,
            .then_branch = then_block,
            .elsif_branches = try elsif_branches.toOwnedSlice(),
            .else_branch = else_branch,
            .span = Span.fromToken(start),
        }};
    }

    fn parseWhile(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        const cond = try self.allocExpr(try self.parseExpr());
        _ = try self.expect(.kw_do);
        var stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
        while (!self.check(.kw_end) and !self.isAtEnd()) {
            try stmts.append(try self.allocStmt(try self.parseStmt()));
        }
        _ = try self.expect(.kw_end);
        const body = try self.allocStmt(Stmt{ .block = .{
            .stmts = try stmts.toOwnedSlice(),
            .span = Span.fromToken(start),
        }});
        return Stmt{ .while_stmt = .{ .cond = cond, .body = body, .span = Span.fromToken(start) }};
    }

    fn parseFor(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        const first_tok = try self.expect(.identifier);
        var index_var: ?[]const u8 = null;
        var item_var: []const u8 = first_tok.text(self.src);
        if (self.tryConsume(.comma)) {
            index_var = first_tok.text(self.src);
            const second = try self.expect(.identifier);
            item_var = second.text(self.src);
        }
        _ = try self.expect(.kw_in);
        const iter = try self.allocExpr(try self.parseExpr());
        _ = try self.expect(.kw_do);
        var stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
        while (!self.check(.kw_end) and !self.isAtEnd()) {
            try stmts.append(try self.allocStmt(try self.parseStmt()));
        }
        _ = try self.expect(.kw_end);
        const body = try self.allocStmt(Stmt{ .block = .{
            .stmts = try stmts.toOwnedSlice(),
            .span = Span.fromToken(start),
        }});
        return Stmt{ .for_stmt = .{
            .index_var = index_var,
            .item_var = item_var,
            .iter = iter,
            .body = body,
            .span = Span.fromToken(start),
        }};
    }

    fn parseLoop(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        var stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
        while (!self.check(.kw_end) and !self.isAtEnd()) {
            try stmts.append(try self.allocStmt(try self.parseStmt()));
        }
        _ = try self.expect(.kw_end);
        const body = try self.allocStmt(Stmt{ .block = .{
            .stmts = try stmts.toOwnedSlice(),
            .span = Span.fromToken(start),
        }});
        return Stmt{ .loop_stmt = .{ .body = body, .span = Span.fromToken(start) }};
    }

    fn parseReturn(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        var value: ?*Expr = null;
        if (!self.check(.kw_end) and !self.check(.kw_elsif) and
            !self.check(.kw_else) and !self.isAtEnd() and !self.check(.semicolon))
        {
            value = try self.allocExpr(try self.parseExpr());
        }
        _ = self.tryConsume(.semicolon);
        return Stmt{ .return_stmt = .{ .value = value, .span = Span.fromToken(start) }};
    }

    fn parseMatch(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        const subject = try self.allocExpr(try self.parseExpr());
        _ = try self.expect(.lbrace);
        var arms = std.array_list.AlignedManaged(ast.MatchArm, null).init(self.arena);
        while (!self.check(.rbrace) and !self.isAtEnd()) {
            const arm_start = self.current();
            const pattern = try self.parsePattern();
            _ = try self.expect(.fat_arrow);
            // Body can be a statement or a single expression
            const arm_body = if (self.check(.kw_begin))
                try self.allocStmt(try self.parseBlock())
            else blk: {
                const e = try self.parseExpr();
                const ep = try self.allocExpr(e);
                _ = self.tryConsume(.comma);
                break :blk try self.allocStmt(Stmt{ .expr_stmt = .{
                    .expr = ep,
                    .span = ep.*.span(),
                }});
            };
            try arms.append(ast.MatchArm{
                .pattern = pattern,
                .body = arm_body,
                .span = Span.fromToken(arm_start),
            });
        }
        _ = try self.expect(.rbrace);
        return Stmt{ .match_stmt = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(),
            .span = Span.fromToken(start),
        }};
    }

    fn parsePattern(self: *Parser) ParseError!ast.Pattern {
        const tok = self.current();
        if (self.check(.kw_else)) {
            _ = self.advance();
            return ast.Pattern{ .else_ = Span.fromToken(tok) };
        }
        if (self.check(.int_literal)) {
            _ = self.advance();
            const v = parseIntLiteral(tok.text(self.src));
            if (self.tryConsume(.dot_dot)) {
                // Range pattern
                const end_tok = self.current();
                const exclusive = self.tryConsume(.lt);
                if (!exclusive) _ = self.tryConsume(.identifier); // skip nothing
                if (self.check(.int_literal)) {
                    const hi_tok = self.advance();
                    const hi = parseIntLiteral(hi_tok.text(self.src));
                    return ast.Pattern{ .range = .{
                        .lo = v, .hi = hi,
                        .exclusive = exclusive,
                        .span = Span.fromToken(tok),
                    }};
                }
                _ = end_tok;
            }
            return ast.Pattern{ .int_lit = .{ .value = v, .span = Span.fromToken(tok) }};
        }
        if (self.check(.string_literal)) {
            _ = self.advance();
            return ast.Pattern{ .string_lit = .{
                .value = try unquote(self.arena,tok.text(self.src)),
                .span = Span.fromToken(tok),
            }};
        }
        if (self.check(.identifier)) {
            _ = self.advance();
            return ast.Pattern{ .ident = .{ .name = tok.text(self.src), .span = Span.fromToken(tok) }};
        }
        return ast.Pattern{ .wildcard = Span.fromToken(tok) };
    }

    fn parseDefer(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        const body = try self.allocStmt(try self.parseStmt());
        return Stmt{ .defer_stmt = .{ .body = body, .span = Span.fromToken(start) }};
    }

    fn parseSafeBlock(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        _ = try self.expect(.kw_do);
        const body = try self.allocStmt(try self.parseBlock());
        return Stmt{ .safe_block = .{ .body = body, .span = Span.fromToken(start) }};
    }

    fn parseUnsafeBlock(self: *Parser) ParseError!Stmt {
        const start = self.current();
        _ = self.advance();
        _ = try self.expect(.kw_do);
        const body = try self.allocStmt(try self.parseBlock());
        return Stmt{ .unsafe_block = .{ .body = body, .span = Span.fromToken(start) }};
    }

    fn parseExprOrAssignStmt(self: *Parser) ParseError!Stmt {
        const start_tok = self.current();
        const lhs = try self.parseExpr();
        const lhs_ptr = try self.allocExpr(lhs);

        // Check for assignment operators
        const assign_op: ?ast.BinOp = switch (self.current().kind) {
            .colon_eq => .assign,
            .plus_eq  => .add_assign,
            .minus_eq => .sub_assign,
            .star_eq  => .mul_assign,
            .slash_eq => .div_assign,
            .percent_eq => .mod_assign,
            .amp_eq   => .and_assign,
            .pipe_eq  => .or_assign,
            .caret_eq => .xor_assign,
            .lt_lt_eq => .shl_assign,
            .gt_gt_eq => .shr_assign,
            else => null,
        };
        if (assign_op) |op| {
            _ = self.advance();
            const rhs = try self.allocExpr(try self.parseExpr());
            _ = self.tryConsume(.semicolon);
            return Stmt{ .assign = .{
                .target = lhs_ptr,
                .op = op,
                .value = rhs,
                .span = Span.fromToken(start_tok),
            }};
        }
        _ = self.tryConsume(.semicolon);
        return Stmt{ .expr_stmt = .{ .expr = lhs_ptr, .span = Span.fromToken(start_tok) }};
    }

    // ── Expression parsing  (Pratt / precedence climbing) ─────────────────────

    fn parseExpr(self: *Parser) ParseError!Expr {
        return self.parseExprPrec(0);
    }

    fn parseExprPrec(self: *Parser, min_prec: u8) ParseError!Expr {
        var lhs = try self.parseUnary();

        outer: while (true) {
            // Binary operators (Pratt precedence climbing)
            while (true) {
                const op_tok = self.current();
                const info = binopInfo(op_tok.kind) orelse break;
                if (info.prec < min_prec) break;
                _ = self.advance();
                const next_prec: u8 = if (info.right_assoc) info.prec else info.prec + 1;
                const rhs = try self.parseExprPrec(next_prec);
                const lhs_ptr = try self.allocExpr(lhs);
                const rhs_ptr = try self.allocExpr(rhs);
                lhs = Expr{ .binary = .{
                    .op = info.op,
                    .lhs = lhs_ptr,
                    .rhs = rhs_ptr,
                    .span = Span.fromToken(op_tok),
                }};
            }
            // `as` cast — re-enter outer loop so subsequent binary ops are picked up
            if (self.check(.kw_as)) {
                _ = self.advance();
                const ty = try self.parseTypeExpr();
                const ty_ptr = try self.allocTypeExpr(ty);
                const lhs_ptr = try self.allocExpr(lhs);
                lhs = Expr{ .cast = .{ .expr = lhs_ptr, .ty = ty_ptr, .span = lhs_ptr.*.span() }};
                continue :outer;
            }
            break;
        }

        // `??` default operator
        if (self.check(.question_question)) {
            _ = self.advance();
            const fallback = try self.parseExpr();
            const opt_ptr = try self.allocExpr(lhs);
            const fb_ptr = try self.allocExpr(fallback);
            lhs = Expr{ .default = .{ .opt = opt_ptr, .fallback = fb_ptr, .span = opt_ptr.*.span() }};
        }

        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!Expr {
        const tok = self.current();
        if (self.tryConsume(.minus)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .unary = .{ .op = .neg, .operand = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_not)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .unary = .{ .op = .not_, .operand = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.tilde)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .unary = .{ .op = .bit_not, .operand = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.amp)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .unary = .{ .op = .addr_of, .operand = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.caret)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .unary = .{ .op = .deref, .operand = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_consume)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .consume = .{ .expr = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_await)) {
            const operand = try self.allocExpr(try self.parseUnary());
            return Expr{ .await_expr = .{ .expr = operand, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_spawn)) {
            const call = try self.allocExpr(try self.parsePostfix(try self.parsePrimary()));
            return Expr{ .spawn_expr = .{ .call = call, .span = Span.fromToken(tok) }};
        }
        return self.parsePostfix(try self.parsePrimary());
    }

    fn parsePostfix(self: *Parser, base: Expr) ParseError!Expr {
        var expr = base;
        while (true) {
            if (self.tryConsume(.dot)) {
                if (self.check(.identifier)) {
                    const field_tok = self.advance();
                    const field_name = field_tok.text(self.src);
                    const recv = try self.allocExpr(expr);
                    if (self.tryConsume(.lparen)) {
                        // method call
                        var args = std.array_list.AlignedManaged(*Expr, null).init(self.arena);
                        while (!self.check(.rparen) and !self.isAtEnd()) {
                            const arg = try self.allocExpr(try self.parseExpr());
                            try args.append(arg);
                            if (!self.tryConsume(.comma)) break;
                        }
                        _ = try self.expect(.rparen);
                        expr = Expr{ .method_call = .{
                            .receiver = recv,
                            .method = field_name,
                            .args = try args.toOwnedSlice(),
                            .span = Span.fromToken(field_tok),
                        }};
                    } else {
                        expr = Expr{ .field = .{
                            .receiver = recv,
                            .field = field_name,
                            .span = Span.fromToken(field_tok),
                        }};
                    }
                } else {
                    // Numeric field access (tuples) — not in spec, just return dot-expr
                    break;
                }
            } else if (self.tryConsume(.lbracket)) {
                const idx_expr = try self.parseExpr();
                const recv = try self.allocExpr(expr);
                if (self.tryConsume(.dot_dot)) {
                    const hi = try self.allocExpr(try self.parseExpr());
                    const exclusive = false;
                    _ = try self.expect(.rbracket);
                    expr = Expr{ .slice_expr = .{
                        .array = recv,
                        .lo = try self.allocExpr(idx_expr),
                        .hi = hi,
                        .exclusive = exclusive,
                        .span = recv.*.span(),
                    }};
                } else if (self.tryConsume(.dot_dot_lt)) {
                    const hi = try self.allocExpr(try self.parseExpr());
                    _ = try self.expect(.rbracket);
                    expr = Expr{ .slice_expr = .{
                        .array = recv,
                        .lo = try self.allocExpr(idx_expr),
                        .hi = hi,
                        .exclusive = true,
                        .span = recv.*.span(),
                    }};
                } else {
                    _ = try self.expect(.rbracket);
                    expr = Expr{ .index = .{
                        .array = recv,
                        .index = try self.allocExpr(idx_expr),
                        .span = recv.*.span(),
                    }};
                }
            } else if (self.check(.lparen)) {
                // Direct call
                _ = self.advance();
                var args = std.array_list.AlignedManaged(*Expr, null).init(self.arena);
                while (!self.check(.rparen) and !self.isAtEnd()) {
                    const arg = try self.allocExpr(try self.parseExpr());
                    try args.append(arg);
                    if (!self.tryConsume(.comma)) break;
                }
                _ = try self.expect(.rparen);
                const callee = try self.allocExpr(expr);
                expr = Expr{ .call = .{
                    .callee = callee,
                    .args = try args.toOwnedSlice(),
                    .span = callee.*.span(),
                }};
            } else {
                break;
            }
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!Expr {
        const tok = self.current();

        // Literals
        if (self.tryConsume(.int_literal)) {
            return Expr{ .int_lit = .{
                .value = parseIntLiteral(tok.text(self.src)),
                .span = Span.fromToken(tok),
            }};
        }
        if (self.tryConsume(.float_literal)) {
            const v = std.fmt.parseFloat(f64, tok.text(self.src)) catch 0.0;
            return Expr{ .float_lit = .{ .value = v, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.string_literal)) {
            return Expr{ .string_lit = .{
                .value = try unquote(self.arena,tok.text(self.src)),
                .span = Span.fromToken(tok),
            }};
        }
        if (self.tryConsume(.kw_true)) {
            return Expr{ .bool_lit = .{ .value = true, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_false)) {
            return Expr{ .bool_lit = .{ .value = false, .span = Span.fromToken(tok) }};
        }
        if (self.tryConsume(.kw_null)) {
            return Expr{ .null_lit = Span.fromToken(tok) };
        }

        // Builtin call @name(…)
        if (self.tryConsume(.at)) {
            const name_tok = try self.expect(.identifier);
            _ = try self.expect(.lparen);
            var args = std.array_list.AlignedManaged(*Expr, null).init(self.arena);
            while (!self.check(.rparen) and !self.isAtEnd()) {
                const arg = try self.allocExpr(try self.parseExpr());
                try args.append(arg);
                if (!self.tryConsume(.comma)) break;
            }
            _ = try self.expect(.rparen);
            return Expr{ .builtin_call = .{
                .name = name_tok.text(self.src),
                .args = try args.toOwnedSlice(),
                .span = Span.fromToken(tok),
            }};
        }

        // Struct literal: `Name { .field = val, … }` or `{ .field = val }`
        if (self.check(.identifier)) {
            const ident_tok = self.advance();
            const name = ident_tok.text(self.src);
            if (self.check(.lbrace)) {
                _ = self.advance();
                if (self.check(.dot)) {
                    return self.parseStructLitFields(name, Span.fromToken(ident_tok));
                }
                // Not a struct literal — back up (can't easily back up, so treat as block)
                // This is tricky; for simplicity emit ident and break
                self.pos -= 1; // un-eat lbrace
                return Expr{ .ident = .{ .name = name, .span = Span.fromToken(ident_tok) }};
            }
            return Expr{ .ident = .{ .name = name, .span = Span.fromToken(ident_tok) }};
        }

        // Grouped expression
        if (self.tryConsume(.lparen)) {
            const inner = try self.parseExpr();
            _ = try self.expect(.rparen);
            const inner_ptr = try self.allocExpr(inner);
            return Expr{ .grouped = .{ .inner = inner_ptr, .span = Span.fromToken(tok) }};
        }

        // Array literal: `[1, 2, 3]`
        if (self.tryConsume(.lbracket)) {
            var elems = std.array_list.AlignedManaged(*Expr, null).init(self.arena);
            while (!self.check(.rbracket) and !self.isAtEnd()) {
                try elems.append(try self.allocExpr(try self.parseExpr()));
                if (!self.tryConsume(.comma)) break;
            }
            _ = try self.expect(.rbracket);
            return Expr{ .array_lit = .{
                .elems = try elems.toOwnedSlice(),
                .span = Span.fromToken(tok),
            }};
        }

        // Closure: `|params| { … }` or `|params| expr`
        if (self.tryConsume(.pipe)) {
            var params = std.array_list.AlignedManaged(Param, null).init(self.arena);
            while (!self.check(.pipe) and !self.isAtEnd()) {
                const p = try self.parseParam();
                try params.append(p);
                if (!self.tryConsume(.comma)) break;
            }
            _ = try self.expect(.pipe);
            const body = if (self.check(.lbrace)) blk: {
                _ = self.advance();
                var stmts = std.array_list.AlignedManaged(*Stmt, null).init(self.arena);
                while (!self.check(.rbrace) and !self.isAtEnd()) {
                    try stmts.append(try self.allocStmt(try self.parseStmt()));
                }
                _ = try self.expect(.rbrace);
                break :blk try self.allocStmt(Stmt{ .block = .{
                    .stmts = try stmts.toOwnedSlice(),
                    .span = Span.fromToken(tok),
                }});
            } else blk: {
                const e = try self.parseExpr();
                const ep = try self.allocExpr(e);
                break :blk try self.allocStmt(Stmt{ .expr_stmt = .{
                    .expr = ep,
                    .span = ep.*.span(),
                }});
            };
            return Expr{ .closure = .{
                .params = try params.toOwnedSlice(),
                .body = body,
                .span = Span.fromToken(tok),
            }};
        }

        // Inline if-expression: `if cond then expr1 else expr2 end`
        if (self.tryConsume(.kw_if)) {
            const cond = try self.allocExpr(try self.parseExpr());
            _ = try self.expect(.kw_then);
            const then_ = try self.allocExpr(try self.parseExpr());
            _ = try self.expect(.kw_else);
            const else_ = try self.allocExpr(try self.parseExpr());
            _ = try self.expect(.kw_end);
            return Expr{ .if_expr = .{ .cond = cond, .then_ = then_, .else_ = else_, .span = Span.fromToken(tok) }};
        }

        return error.UnexpectedToken;
    }

    fn parseStructLitFields(self: *Parser, ty_name: []const u8, span: Span) ParseError!Expr {
        var fields = std.array_list.AlignedManaged(ast.FieldInit, null).init(self.arena);
        while (!self.check(.rbrace) and !self.isAtEnd()) {
            _ = try self.expect(.dot);
            const fname = try self.expect(.identifier);
            _ = try self.expect(.eq);
            const fval = try self.allocExpr(try self.parseExpr());
            _ = self.tryConsume(.comma);
            try fields.append(ast.FieldInit{
                .name = fname.text(self.src),
                .value = fval,
                .span = Span.fromToken(fname),
            });
        }
        _ = try self.expect(.rbrace);
        const ty_expr = try self.allocTypeExpr(TypeExpr{ .named = .{ .name = ty_name, .span = span }});
        return Expr{ .struct_lit = .{
            .ty = ty_expr,
            .fields = try fields.toOwnedSlice(),
            .span = span,
        }};
    }

    // ── Binary operator table ──────────────────────────────────────────────────

    const BinOpInfo = struct { op: ast.BinOp, prec: u8, right_assoc: bool };

    fn binopInfo(kind: TK) ?BinOpInfo {
        return switch (kind) {
            .kw_or  => .{ .op = .or_,       .prec = 1, .right_assoc = false },
            .kw_and => .{ .op = .and_,      .prec = 2, .right_assoc = false },
            .eq_eq  => .{ .op = .eq,        .prec = 3, .right_assoc = false },
            .bang_eq=> .{ .op = .ne,        .prec = 3, .right_assoc = false },
            .lt     => .{ .op = .lt,        .prec = 4, .right_assoc = false },
            .gt     => .{ .op = .gt,        .prec = 4, .right_assoc = false },
            .lt_eq  => .{ .op = .le,        .prec = 4, .right_assoc = false },
            .gt_eq  => .{ .op = .ge,        .prec = 4, .right_assoc = false },
            .dot_dot=> .{ .op = .range,     .prec = 5, .right_assoc = false },
            .dot_dot_lt => .{ .op = .range_excl, .prec = 5, .right_assoc = false },
            .pipe   => .{ .op = .pipeline,  .prec = 5, .right_assoc = false },
            .plus   => .{ .op = .add,       .prec = 6, .right_assoc = false },
            .minus  => .{ .op = .sub,       .prec = 6, .right_assoc = false },
            .amp    => .{ .op = .bit_and,   .prec = 7, .right_assoc = false },
            .caret  => .{ .op = .bit_xor,   .prec = 7, .right_assoc = false },
            .lt_lt  => .{ .op = .shl,       .prec = 8, .right_assoc = false },
            .gt_gt  => .{ .op = .shr,       .prec = 8, .right_assoc = false },
            .star   => .{ .op = .mul,       .prec = 9, .right_assoc = false },
            .slash  => .{ .op = .div,       .prec = 9, .right_assoc = false },
            .slash_slash => .{ .op = .int_div, .prec = 9, .right_assoc = false },
            .percent => .{ .op = .mod,      .prec = 9, .right_assoc = false },
            else => null,
        };
    }

    // ── Ownership qualifier ────────────────────────────────────────────────────

    fn tryOwnership(self: *Parser) OwnershipKind {
        const kind: OwnershipKind = switch (self.current().kind) {
            .kw_own  => .own,
            .kw_ref  => .ref_,
            .kw_mut  => .mut_,
            .kw_rc   => .rc,
            .kw_weak => .weak,
            .kw_iso  => .iso,
            .kw_trn  => .trn,
            .kw_val  => .val,
            .kw_box  => .box,
            .kw_tag  => .tag,
            else     => return .none,
        };
        _ = self.advance();
        return kind;
    }

    // ── Token stream helpers ───────────────────────────────────────────────────

    fn current(self: *Parser) Token {
        // Skip doc comments transparently
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].kind == .doc_comment) i += 1;
        if (i < self.tokens.len) return self.tokens[i];
        return self.tokens[self.tokens.len - 1]; // eof
    }

    fn advance(self: *Parser) Token {
        const tok = self.current();
        // Skip past any doc_comment tokens up to and including the one we returned
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .doc_comment) {
            self.pos += 1;
        }
        if (self.pos < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn check(self: *Parser, kind: TK) bool {
        return self.current().kind == kind;
    }

    fn tryConsume(self: *Parser, kind: TK) bool {
        if (self.check(kind)) { _ = self.advance(); return true; }
        return false;
    }

    fn tryConsumeDocs(self: *Parser) bool {
        var consumed = false;
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .doc_comment) {
            self.pos += 1;
            consumed = true;
        }
        return consumed;
    }

    fn expect(self: *Parser, kind: TK) ParseError!Token {
        if (self.check(kind)) return self.advance();
        return error.UnexpectedToken;
    }

    fn isAtEnd(self: *Parser) bool {
        return self.current().kind == .eof;
    }

    fn synchronize(self: *Parser) void {
        while (!self.isAtEnd()) {
            switch (self.current().kind) {
                .kw_function, .kw_procedure, .kw_type,
                .kw_var, .kw_const,
                .kw_use, .kw_actor, .kw_extern => return,
                // Skip `module Name` — multiple modules appear in concatenated builds
                .kw_module => {
                    _ = self.advance();
                    if (self.check(.identifier)) _ = self.advance();
                    _ = self.tryConsume(.semicolon);
                },
                else => _ = self.advance(),
            }
        }
    }

    // ── Arena allocation helpers ───────────────────────────────────────────────

    fn allocExpr(self: *Parser, e: Expr) ParseError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    fn allocStmt(self: *Parser, s: Stmt) ParseError!*Stmt {
        const p = try self.arena.create(Stmt);
        p.* = s;
        return p;
    }

    fn allocTypeExpr(self: *Parser, t: TypeExpr) ParseError!*TypeExpr {
        const p = try self.arena.create(TypeExpr);
        p.* = t;
        return p;
    }
};

// ── Utilities ─────────────────────────────────────────────────────────────────

/// Strip quotes from a string literal token text.
fn unquote(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const content: []const u8 = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
        raw[1 .. raw.len - 1]
    else
        raw;

    var out = std.array_list.AlignedManaged(u8, null).init(allocator);
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            const esc = content[i + 1];
            switch (esc) {
                'n'  => { try out.append('\n'); i += 2; },
                't'  => { try out.append('\t'); i += 2; },
                'r'  => { try out.append('\r'); i += 2; },
                '0'  => { try out.append(0);    i += 2; },
                '\\' => { try out.append('\\'); i += 2; },
                '"'  => { try out.append('"');  i += 2; },
                'x'  => {
                    if (i + 3 < content.len) {
                        const hi = hexNibble(content[i + 2]);
                        const lo = hexNibble(content[i + 3]);
                        try out.append(hi * 16 + lo);
                        i += 4;
                    } else {
                        try out.append('\\');
                        i += 1;
                    }
                },
                else => { try out.append('\\'); i += 1; },
            }
        } else {
            try out.append(content[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice();
}

fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i64 {
    // Strip underscores
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (c != '_') {
            buf[len] = c;
            len += 1;
        }
    }
    const s = buf[0..len];
    if (s.len >= 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => return @as(i64, @bitCast(std.fmt.parseInt(u64, s[2..], 16) catch 0)),
            'o', 'O' => return @as(i64, @bitCast(std.fmt.parseInt(u64, s[2..], 8) catch 0)),
            'b', 'B' => return @as(i64, @bitCast(std.fmt.parseInt(u64, s[2..], 2) catch 0)),
            else => {},
        }
    }
    return std.fmt.parseInt(i64, s, 10) catch 0;
}
