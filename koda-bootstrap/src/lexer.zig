/// Koda lexer — tokenizes Koda source into a flat token list.
const std = @import("std");

pub const TokenKind = enum {
    // Literals
    int_lit, float_lit, string_lit,
    // Identifiers / keywords
    ident,
    kw_var, kw_function, kw_procedure, kw_begin, kw_end,
    kw_if, kw_then, kw_elsif, kw_else,
    kw_while, kw_do, kw_for, kw_in, kw_loop, kw_break, kw_continue,
    kw_return, kw_true, kw_false, kw_null,
    kw_and, kw_or, kw_not,
    kw_async, kw_await, kw_spawn,
    kw_module, kw_import, kw_export, kw_use,
    kw_match, kw_as, kw_defer, kw_unsafe, kw_safe,
    kw_own, kw_ref, kw_mut, kw_rc, kw_weak,
    kw_type, kw_struct, kw_enum, kw_actor, kw_behavior,
    // Operators
    plus, minus, star, slash, percent,
    eq_eq, bang_eq, lt, gt, lt_eq, gt_eq,
    colon_eq, plus_eq, minus_eq, star_eq, slash_eq, percent_eq,
    pipe,           // | (pipeline)
    dot_dot,        // ..
    // Punctuation
    lparen, rparen, lbracket, rbracket, lbrace, rbrace,
    comma, semicolon, dot, colon, eq,
    // Special
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
};

const KEYWORDS = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "var", .kw_var },
    .{ "function", .kw_function },
    .{ "procedure", .kw_procedure },
    .{ "begin", .kw_begin },
    .{ "end", .kw_end },
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "elsif", .kw_elsif },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "do", .kw_do },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "loop", .kw_loop },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "return", .kw_return },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "async", .kw_async },
    .{ "await", .kw_await },
    .{ "spawn", .kw_spawn },
    .{ "module", .kw_module },
    .{ "import", .kw_import },
    .{ "export", .kw_export },
    .{ "use", .kw_use },
    .{ "match", .kw_match },
    .{ "as", .kw_as },
    .{ "defer", .kw_defer },
    .{ "unsafe", .kw_unsafe },
    .{ "safe", .kw_safe },
    .{ "own", .kw_own },
    .{ "ref", .kw_ref },
    .{ "mut", .kw_mut },
    .{ "rc", .kw_rc },
    .{ "weak", .kw_weak },
    .{ "type", .kw_type },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "actor", .kw_actor },
    .{ "behavior", .kw_behavior },
});

pub const LexError = error{ UnexpectedChar, UnterminatedString };

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) Lexer {
        return .{ .src = src, .pos = 0, .line = 1, .alloc = alloc };
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) u8 {
        if (self.pos + offset >= self.src.len) return 0;
        return self.src[self.pos + offset];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn skipWhitespaceAndComments(self: *Lexer) !void {
        while (self.pos < self.src.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
            } else if (c == '/' and self.peekAt(1) == '*') {
                // Block comment (nestable)
                self.pos += 2;
                var depth: usize = 1;
                while (self.pos < self.src.len and depth > 0) {
                    if (self.peek() == '/' and self.peekAt(1) == '*') {
                        self.pos += 2;
                        depth += 1;
                    } else if (self.peek() == '*' and self.peekAt(1) == '/') {
                        self.pos += 2;
                        depth -= 1;
                    } else {
                        if (self.peek() == '\n') self.line += 1;
                        self.pos += 1;
                    }
                }
            } else if (c == '/' and self.peekAt(1) == '/' and self.peekAt(2) == '/') {
                // Doc comment — treat as line comment
                while (self.pos < self.src.len and self.peek() != '\n') self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn lexString(self: *Lexer) !Token {
        const line = self.line;
        self.pos += 1; // skip opening "
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.peek();
            if (c == '"') break;
            if (c == '\\') self.pos += 1; // skip escape
            if (self.pos < self.src.len) {
                if (self.peek() == '\n') self.line += 1;
                self.pos += 1;
            }
        }
        if (self.pos >= self.src.len) return error.UnterminatedString;
        const text = self.src[start..self.pos];
        self.pos += 1; // skip closing "
        return Token{ .kind = .string_lit, .text = text, .line = line };
    }

    fn lexNumber(self: *Lexer) Token {
        const line = self.line;
        const start = self.pos;
        while (self.pos < self.src.len and (std.ascii.isDigit(self.peek()) or self.peek() == '_')) {
            self.pos += 1;
        }
        var kind: TokenKind = .int_lit;
        if (self.pos < self.src.len and self.peek() == '.' and
            self.pos + 1 < self.src.len and std.ascii.isDigit(self.peekAt(1)))
        {
            kind = .float_lit;
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.peek())) self.pos += 1;
        }
        return Token{ .kind = kind, .text = self.src[start..self.pos], .line = line };
    }

    fn lexIdent(self: *Lexer) Token {
        const line = self.line;
        const start = self.pos;
        while (self.pos < self.src.len and
            (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_'))
        {
            self.pos += 1;
        }
        const text = self.src[start..self.pos];
        const kind = KEYWORDS.get(text) orelse .ident;
        return Token{ .kind = kind, .text = text, .line = line };
    }

    pub fn tokenize(self: *Lexer) ![]Token {
        var tokens = std.ArrayListUnmanaged(Token).empty;
        while (true) {
            try self.skipWhitespaceAndComments();
            if (self.pos >= self.src.len) {
                try tokens.append(self.alloc, .{ .kind = .eof, .text = "", .line = self.line });
                break;
            }
            const line = self.line;
            const c = self.peek();
            const tok: Token = switch (c) {
                '"' => try self.lexString(),
                '0'...'9' => self.lexNumber(),
                'a'...'z', 'A'...'Z', '_' => self.lexIdent(),
                '+' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .plus_eq, .text = "+=", .line = line }; }
                    break :blk Token{ .kind = .plus, .text = "+", .line = line };
                },
                '-' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .minus_eq, .text = "-=", .line = line }; }
                    break :blk Token{ .kind = .minus, .text = "-", .line = line };
                },
                '*' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .star_eq, .text = "*=", .line = line }; }
                    break :blk Token{ .kind = .star, .text = "*", .line = line };
                },
                '/' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .slash_eq, .text = "/=", .line = line }; }
                    break :blk Token{ .kind = .slash, .text = "/", .line = line };
                },
                '%' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .percent_eq, .text = "%=", .line = line }; }
                    break :blk Token{ .kind = .percent, .text = "%", .line = line };
                },
                '=' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .eq_eq, .text = "==", .line = line }; }
                    break :blk Token{ .kind = .eq, .text = "=", .line = line };
                },
                '!' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .bang_eq, .text = "!=", .line = line }; }
                    break :blk Token{ .kind = .bang_eq, .text = "!", .line = line }; // treat lone ! as !=
                },
                '<' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .lt_eq, .text = "<=", .line = line }; }
                    break :blk Token{ .kind = .lt, .text = "<", .line = line };
                },
                '>' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .gt_eq, .text = ">=", .line = line }; }
                    break :blk Token{ .kind = .gt, .text = ">", .line = line };
                },
                ':' => blk: {
                    self.pos += 1;
                    if (self.peek() == '=') { self.pos += 1; break :blk Token{ .kind = .colon_eq, .text = ":=", .line = line }; }
                    break :blk Token{ .kind = .colon, .text = ":", .line = line };
                },
                '.' => blk: {
                    self.pos += 1;
                    if (self.peek() == '.') { self.pos += 1; break :blk Token{ .kind = .dot_dot, .text = "..", .line = line }; }
                    break :blk Token{ .kind = .dot, .text = ".", .line = line };
                },
                '|' => blk: {
                    self.pos += 1;
                    break :blk Token{ .kind = .pipe, .text = "|", .line = line };
                },
                '(' => blk: { self.pos += 1; break :blk Token{ .kind = .lparen, .text = "(", .line = line }; },
                ')' => blk: { self.pos += 1; break :blk Token{ .kind = .rparen, .text = ")", .line = line }; },
                '[' => blk: { self.pos += 1; break :blk Token{ .kind = .lbracket, .text = "[", .line = line }; },
                ']' => blk: { self.pos += 1; break :blk Token{ .kind = .rbracket, .text = "]", .line = line }; },
                '{' => blk: { self.pos += 1; break :blk Token{ .kind = .lbrace, .text = "{", .line = line }; },
                '}' => blk: { self.pos += 1; break :blk Token{ .kind = .rbrace, .text = "}", .line = line }; },
                ',' => blk: { self.pos += 1; break :blk Token{ .kind = .comma, .text = ",", .line = line }; },
                ';' => blk: { self.pos += 1; break :blk Token{ .kind = .semicolon, .text = ";", .line = line }; },
                else => return error.UnexpectedChar,
            };
            try tokens.append(self.alloc, tok);
        }
        return try tokens.toOwnedSlice(self.alloc);
    }
};
