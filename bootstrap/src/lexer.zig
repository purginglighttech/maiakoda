/// Maia language lexer.
/// Produces a flat token stream from UTF-8 source text.
/// Block comments /* … */ may be nested.
/// Doc comments use /// syntax.

const std = @import("std");

// ── Token kinds ──────────────────────────────────────────────────────────────

pub const TokenKind = enum {
    // Literals
    int_literal,
    float_literal,
    string_literal,

    // Identifier (non-keyword)
    identifier,

    // Keywords
    kw_module,
    kw_use,
    kw_export,
    kw_var,
    kw_const,
    kw_function,
    kw_procedure,
    kw_type,
    kw_struct,
    kw_enum,
    kw_begin,
    kw_end,
    kw_if,
    kw_then,
    kw_elsif,
    kw_else,
    kw_for,
    kw_while,
    kw_do,
    kw_loop,
    kw_break,
    kw_continue,
    kw_return,
    kw_match,
    kw_as,
    kw_null,
    kw_true,
    kw_false,
    kw_own,
    kw_ref,
    kw_mut,
    kw_rc,
    kw_weak,
    kw_iso,
    kw_trn,
    kw_val,
    kw_box,
    kw_tag,
    kw_actor,
    kw_behavior,
    kw_spawn,
    kw_await,
    kw_async,
    kw_defer,
    kw_unsafe,
    kw_safe,
    kw_consume,
    kw_extern,
    kw_inline,
    kw_package,
    kw_in,
    kw_wait,
    kw_comptime,
    // Logical operators (word form)
    kw_and,
    kw_or,
    kw_not,
    // Builtin attribute prefix is @, handled as .at token

    // Arithmetic operators
    plus,        // +
    minus,       // -
    star,        // *
    slash,       // /
    percent,     // %
    slash_slash, // //  (integer division)

    // Comparison operators
    eq_eq,   // ==
    bang_eq, // !=
    lt,      // <
    gt,      // >
    lt_eq,   // <=
    gt_eq,   // >=

    // Bitwise operators
    amp,    // &
    pipe,   // |
    caret,  // ^
    tilde,  // ~
    lt_lt,  // <<
    gt_gt,  // >>

    // Assignment operators
    colon_eq,  // :=
    plus_eq,   // +=
    minus_eq,  // -=
    star_eq,   // *=
    slash_eq,  // /=
    percent_eq,// %=
    amp_eq,    // &=
    pipe_eq,   // |=
    caret_eq,  // ^=
    lt_lt_eq,  // <<=
    gt_gt_eq,  // >>=

    // Range
    dot_dot,    // ..
    dot_dot_lt, // ..<

    // Misc punctuation / operators
    eq,               // =
    bang,             // !
    question,         // ?
    question_question,// ??
    at,               // @
    arrow,            // ->
    fat_arrow,        // =>
    dot,              // .
    dot_dot_dot,      // ...

    // Delimiters
    lparen,    // (
    rparen,    // )
    lbracket,  // [
    rbracket,  // ]
    lbrace,    // {
    rbrace,    // }
    comma,     // ,
    semicolon, // ;
    colon,     // :

    // Doc comment (carried as token for documentation tooling)
    doc_comment, // ///…

    // Synthetic
    eof,
    invalid,
};

// ── Token ────────────────────────────────────────────────────────────────────

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,  // exclusive byte offset
    line: u32,
    col: u32,

    pub fn text(self: Token, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

// ── Keyword lookup table ─────────────────────────────────────────────────────

const keyword_table = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "module",    .kw_module },
    .{ "use",       .kw_use },
    .{ "export",    .kw_export },
    .{ "var",       .kw_var },
    .{ "const",     .kw_const },
    .{ "function",  .kw_function },
    .{ "procedure", .kw_procedure },
    .{ "type",      .kw_type },
    .{ "struct",    .kw_struct },
    .{ "enum",      .kw_enum },
    .{ "begin",     .kw_begin },
    .{ "end",       .kw_end },
    .{ "if",        .kw_if },
    .{ "then",      .kw_then },
    .{ "elsif",     .kw_elsif },
    .{ "else",      .kw_else },
    .{ "for",       .kw_for },
    .{ "while",     .kw_while },
    .{ "do",        .kw_do },
    .{ "loop",      .kw_loop },
    .{ "break",     .kw_break },
    .{ "continue",  .kw_continue },
    .{ "return",    .kw_return },
    .{ "match",     .kw_match },
    .{ "as",        .kw_as },
    .{ "null",      .kw_null },
    .{ "true",      .kw_true },
    .{ "false",     .kw_false },
    .{ "own",       .kw_own },
    .{ "ref",       .kw_ref },
    .{ "mut",       .kw_mut },
    .{ "rc",        .kw_rc },
    .{ "weak",      .kw_weak },
    .{ "iso",       .kw_iso },
    .{ "trn",       .kw_trn },
    .{ "val",       .kw_val },
    .{ "box",       .kw_box },
    .{ "tag",       .kw_tag },
    .{ "actor",     .kw_actor },
    .{ "behavior",  .kw_behavior },
    .{ "spawn",     .kw_spawn },
    .{ "await",     .kw_await },
    .{ "async",     .kw_async },
    .{ "defer",     .kw_defer },
    .{ "unsafe",    .kw_unsafe },
    .{ "safe",      .kw_safe },
    .{ "consume",   .kw_consume },
    .{ "extern",    .kw_extern },
    .{ "inline",    .kw_inline },
    .{ "package",   .kw_package },
    .{ "in",        .kw_in },
    .{ "wait",      .kw_wait },
    .{ "comptime",  .kw_comptime },
    .{ "and",       .kw_and },
    .{ "or",        .kw_or },
    .{ "not",       .kw_not },
});

// ── Lexer ────────────────────────────────────────────────────────────────────

pub const LexError = error{
    UnterminatedString,
    UnterminatedComment,
    OutOfMemory,
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .allocator = allocator,
        };
    }

    /// Tokenize the full source into an owned slice.  Caller must free.
    pub fn tokenize(self: *Lexer) LexError![]Token {
        var tokens = std.array_list.AlignedManaged(Token, null).init(self.allocator);
        errdefer tokens.deinit();
        while (true) {
            const tok = try self.next();
            try tokens.append(tok);
            if (tok.kind == .eof) break;
        }
        return tokens.toOwnedSlice();
    }

    /// Advance and return one token (skips whitespace and block comments).
    pub fn next(self: *Lexer) LexError!Token {
        try self.skipWhitespaceAndBlockComments();

        const start = self.pos;
        const line = self.line;
        const col = start - self.line_start + 1;

        if (self.pos >= self.src.len) {
            return Token{ .kind = .eof, .start = start, .end = start, .line = line, .col = col };
        }

        const c = self.eat();
        const kind: TokenKind = switch (c) {
            // Single-char delimiters
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            ',' => .comma,
            ';' => .semicolon,
            '~' => .tilde,
            '@' => .at,

            // . .. ... ..<
            '.' => blk: {
                if (self.tryEat('.')) {
                    if (self.tryEat('.')) break :blk .dot_dot_dot;
                    if (self.tryEat('<')) break :blk .dot_dot_lt;
                    break :blk .dot_dot;
                }
                break :blk .dot;
            },

            // : :=
            ':' => if (self.tryEat('=')) .colon_eq else .colon,

            // = == =>
            '=' => blk: {
                if (self.tryEat('=')) break :blk .eq_eq;
                if (self.tryEat('>')) break :blk .fat_arrow;
                break :blk .eq;
            },

            // ! !=
            '!' => if (self.tryEat('=')) .bang_eq else .bang,

            // < <= << <<=
            '<' => blk: {
                if (self.tryEat('<')) {
                    if (self.tryEat('=')) break :blk .lt_lt_eq;
                    break :blk .lt_lt;
                }
                if (self.tryEat('=')) break :blk .lt_eq;
                break :blk .lt;
            },

            // > >= >> >>=
            '>' => blk: {
                if (self.tryEat('>')) {
                    if (self.tryEat('=')) break :blk .gt_gt_eq;
                    break :blk .gt_gt;
                }
                if (self.tryEat('=')) break :blk .gt_eq;
                break :blk .gt;
            },

            // + +=
            '+' => if (self.tryEat('=')) .plus_eq else .plus,

            // - -= ->
            '-' => blk: {
                if (self.tryEat('>')) break :blk .arrow;
                if (self.tryEat('=')) break :blk .minus_eq;
                break :blk .minus;
            },

            // * *=
            '*' => if (self.tryEat('=')) .star_eq else .star,

            // % %=
            '%' => if (self.tryEat('=')) .percent_eq else .percent,

            // & &=
            '&' => if (self.tryEat('=')) .amp_eq else .amp,

            // | |=
            '|' => if (self.tryEat('=')) .pipe_eq else .pipe,

            // ^ ^=
            '^' => if (self.tryEat('=')) .caret_eq else .caret,

            // ? ??
            '?' => if (self.tryEat('?')) .question_question else .question,

            // / /= // //= (we treat //= as slash_slash + eq for simplicity)
            '/' => blk: {
                if (self.peek() == '/' and self.peekOffset(1) == '/') {
                    // Doc comment ///…
                    self.pos += 2; // consume remaining two slashes
                    while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                        self.pos += 1;
                    }
                    break :blk .doc_comment;
                }
                if (self.tryEat('/')) break :blk .slash_slash; // integer division
                if (self.tryEat('=')) break :blk .slash_eq;
                break :blk .slash;
            },

            // String literals
            '"' => blk: {
                if (self.pos + 1 < self.src.len and
                    self.src[self.pos] == '"' and self.src[self.pos + 1] == '"')
                {
                    self.pos += 2;
                    try self.eatTripleString();
                } else {
                    try self.eatString();
                }
                break :blk .string_literal;
            },

            // Number literals
            '0'...'9' => blk: {
                self.pos -= 1; // un-eat so scanNumber starts fresh
                break :blk try self.scanNumber();
            },

            // Identifiers and keywords
            'a'...'z', 'A'...'Z', '_' => blk: {
                self.pos -= 1;
                break :blk self.scanIdentOrKeyword();
            },

            else => .invalid,
        };

        return Token{
            .kind = kind,
            .start = start,
            .end = self.pos,
            .line = line,
            .col = col,
        };
    }

    // ── Low-level helpers ─────────────────────────────────────────────────────

    /// Consume and return the byte at the current position.
    inline fn eat(self: *Lexer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.line_start = self.pos;
        }
        return c;
    }

    /// Consume `c` if it matches; return true iff consumed.
    inline fn tryEat(self: *Lexer, c: u8) bool {
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            _ = self.eat();
            return true;
        }
        return false;
    }

    inline fn peek(self: *Lexer) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    inline fn peekOffset(self: *Lexer, off: u32) u8 {
        const i = self.pos + off;
        return if (i < self.src.len) self.src[i] else 0;
    }

    /// Skip whitespace and nestable block comments `/* … */`.
    fn skipWhitespaceAndBlockComments(self: *Lexer) LexError!void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => _ = self.eat(),
                '/' => {
                    // Block comment but NOT doc comment (///) and NOT integer division (//)
                    if (self.peekOffset(1) == '*') {
                        self.pos += 2; // consume /*
                        try self.eatBlockComment();
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    /// Consume a nestable block comment.  Opening `/*` already eaten.
    fn eatBlockComment(self: *Lexer) LexError!void {
        var depth: u32 = 1;
        while (self.pos < self.src.len) {
            const c = self.eat();
            if (c == '/' and self.peek() == '*') {
                _ = self.eat();
                depth += 1;
            } else if (c == '*' and self.peek() == '/') {
                _ = self.eat();
                depth -= 1;
                if (depth == 0) return;
            }
        }
        return error.UnterminatedComment;
    }

    /// Eat a double-quoted string.  Opening `"` already eaten.
    fn eatString(self: *Lexer) LexError!void {
        while (self.pos < self.src.len) {
            const c = self.eat();
            if (c == '"') return;
            if (c == '\\') {
                if (self.pos >= self.src.len) return error.UnterminatedString;
                _ = self.eat();
            }
        }
        return error.UnterminatedString;
    }

    /// Eat a triple-quoted string.  Opening `"""` already eaten (3 chars).
    fn eatTripleString(self: *Lexer) LexError!void {
        while (self.pos + 2 < self.src.len) {
            if (self.src[self.pos] == '"' and
                self.src[self.pos + 1] == '"' and
                self.src[self.pos + 2] == '"')
            {
                self.pos += 3;
                return;
            }
            _ = self.eat();
        }
        // Consume any remaining chars before EOF
        while (self.pos < self.src.len) _ = self.eat();
        return error.UnterminatedString;
    }

    /// Scan a numeric literal.  Called with `self.pos` at the first digit.
    fn scanNumber(self: *Lexer) LexError!TokenKind {
        // Prefix detection
        if (self.src[self.pos] == '0' and self.pos + 1 < self.src.len) {
            switch (self.src[self.pos + 1]) {
                'x', 'X' => {
                    self.pos += 2;
                    while (self.pos < self.src.len and isHex(self.src[self.pos])) self.pos += 1;
                    return .int_literal;
                },
                'o', 'O' => {
                    self.pos += 2;
                    while (self.pos < self.src.len and isOct(self.src[self.pos])) self.pos += 1;
                    return .int_literal;
                },
                'b', 'B' => {
                    self.pos += 2;
                    while (self.pos < self.src.len and
                           (self.src[self.pos] == '0' or self.src[self.pos] == '1')) self.pos += 1;
                    return .int_literal;
                },
                else => {},
            }
        }

        // Decimal integer (with optional _ separators)
        while (self.pos < self.src.len and
               (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
        }

        var is_float = false;

        // Fractional part — only if next char after '.' is a digit (not `..`)
        if (self.pos < self.src.len and self.src[self.pos] == '.' and
            self.pos + 1 < self.src.len and self.src[self.pos + 1] != '.')
        {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }

        // Exponent part
        if (self.pos < self.src.len and
            (self.src[self.pos] == 'e' or self.src[self.pos] == 'E'))
        {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.src.len and
                (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }

        return if (is_float) .float_literal else .int_literal;
    }

    /// Scan an identifier and map it to a keyword token if applicable.
    fn scanIdentOrKeyword(self: *Lexer) TokenKind {
        const start = self.pos;
        while (self.pos < self.src.len and isIdentTail(self.src[self.pos])) {
            self.pos += 1;
        }
        const word = self.src[start..self.pos];
        return keyword_table.get(word) orelse .identifier;
    }

    // ── Character predicates ──────────────────────────────────────────────────

    inline fn isHex(c: u8) bool {
        return std.ascii.isDigit(c) or
               (c >= 'a' and c <= 'f') or
               (c >= 'A' and c <= 'F') or
               c == '_';
    }

    inline fn isOct(c: u8) bool {
        return (c >= '0' and c <= '7') or c == '_';
    }

    inline fn isIdentTail(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

// ── Utility ───────────────────────────────────────────────────────────────────

pub fn kindName(k: TokenKind) []const u8 {
    return @tagName(k);
}
