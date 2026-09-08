// SPDX-License-Identifier: BSL-1.0

//! Source text into tokens.
//!
//! The cursor is `fluxion-text`'s `Parser`, which is where `takeIdentifier`,
//! `skipWhitespace` and - the part that matters when something is wrong -
//! `locationAt` come from. A token keeps the byte offset it started at and
//! nothing else about where it is; a line and a column cost a scan from the
//! start of the file, and that is a price worth paying once per diagnostic
//! rather than once per token.

const std = @import("std");
const text = @import("fluxion_text");

pub const Kind = enum {
    // Punctuation.
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    comma,
    semicolon,
    colon,
    dot,
    question,
    plus,
    minus,
    star,
    slash,
    percent,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    equal,
    equal_equal,
    bang,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    and_and,
    or_or,

    // Names and literals.
    identifier,
    number,

    // Keywords.
    kw_attribute,
    kw_varying,
    kw_uniform,
    kw_const,
    kw_vertex,
    kw_fragment,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_return,
    kw_discard,
    kw_true,
    kw_false,

    eof,

    /// What to call this in a message, as a reader would say it.
    pub fn describe(self: Kind) []const u8 {
        return switch (self) {
            .l_paren => "`(`",
            .r_paren => "`)`",
            .l_brace => "`{`",
            .r_brace => "`}`",
            .comma => "`,`",
            .semicolon => "`;`",
            .colon => "`:`",
            .dot => "`.`",
            .question => "`?`",
            .plus => "`+`",
            .minus => "`-`",
            .star => "`*`",
            .slash => "`/`",
            .percent => "`%`",
            .plus_equal => "`+=`",
            .minus_equal => "`-=`",
            .star_equal => "`*=`",
            .slash_equal => "`/=`",
            .equal => "`=`",
            .equal_equal => "`==`",
            .bang => "`!`",
            .bang_equal => "`!=`",
            .less => "`<`",
            .less_equal => "`<=`",
            .greater => "`>`",
            .greater_equal => "`>=`",
            .and_and => "`&&`",
            .or_or => "`||`",
            .identifier => "a name",
            .number => "a number",
            .kw_attribute => "`attribute`",
            .kw_varying => "`varying`",
            .kw_uniform => "`uniform`",
            .kw_const => "`const`",
            .kw_vertex => "`vertex`",
            .kw_fragment => "`fragment`",
            .kw_if => "`if`",
            .kw_else => "`else`",
            .kw_for => "`for`",
            .kw_while => "`while`",
            .kw_return => "`return`",
            .kw_discard => "`discard`",
            .kw_true => "`true`",
            .kw_false => "`false`",
            .eof => "the end of the source",
        };
    }
};

pub const Token = struct {
    kind: Kind,
    /// The bytes exactly as written, for names and numbers. Points into the
    /// source, which outlives every token.
    bytes: []const u8,
    /// Where it started, for `Parser.locationAt`.
    offset: u32,

    /// True when a number was written with a decimal point or an exponent,
    /// which is what decides whether `3` may be spelled `3` or has to become
    /// `3.0` in the emitted source.
    pub fn isFloatLiteral(self: Token) bool {
        for (self.bytes) |c| {
            if (c == '.' or c == 'e' or c == 'E') return true;
        }
        return false;
    }
};

pub const Error = error{
    /// A byte that begins nothing this language has.
    UnexpectedByte,
    /// `1.2.3`, or `1e` with no digits after it.
    MalformedNumber,
    /// A `/*` that reaches the end of the file.
    UnterminatedComment,
};

/// Where lexing stopped, when it stopped badly.
pub const Failure = struct {
    err: Error,
    offset: u32,
};

const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "attribute", .kw_attribute },
    .{ "varying", .kw_varying },
    .{ "uniform", .kw_uniform },
    .{ "const", .kw_const },
    .{ "vertex", .kw_vertex },
    .{ "fragment", .kw_fragment },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "return", .kw_return },
    .{ "discard", .kw_discard },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
});

/// Every token in `source`, ending with one `eof`.
///
/// `failure` says where it went wrong when this returns an error, so the
/// caller can put a line and a column on it.
pub fn tokenize(
    gpa: std.mem.Allocator,
    source: []const u8,
    failure: *Failure,
) (Error || std.mem.Allocator.Error)![]Token {
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(gpa);

    var parser: text.Parser = .init(source);

    while (true) {
        try skipTrivia(&parser, failure);

        const start: u32 = @intCast(parser.index);
        const byte = parser.peek() orelse {
            try tokens.append(gpa, .{ .kind = .eof, .bytes = "", .offset = start });
            return tokens.toOwnedSlice(gpa);
        };

        // The two that read more than an operator's worth of bytes.
        switch (byte) {
            'a'...'z', 'A'...'Z', '_' => {
                const word = parser.takeIdentifier().?.bytes;
                try tokens.append(gpa, .{
                    .kind = keywords.get(word) orelse .identifier,
                    .bytes = word,
                    .offset = start,
                });
                continue;
            },
            '0'...'9' => {
                try takeNumber(&parser, failure);
                try tokens.append(gpa, .{
                    .kind = .number,
                    .bytes = source[start..parser.index],
                    .offset = start,
                });
                continue;
            },
            else => {},
        }

        const kind: Kind = switch (byte) {
            '(' => one(&parser, .l_paren),
            ')' => one(&parser, .r_paren),
            '{' => one(&parser, .l_brace),
            '}' => one(&parser, .r_brace),
            ',' => one(&parser, .comma),
            ';' => one(&parser, .semicolon),
            ':' => one(&parser, .colon),
            '.' => one(&parser, .dot),
            '?' => one(&parser, .question),
            '%' => one(&parser, .percent),
            '+' => pair(&parser, '=', .plus_equal, .plus),
            '-' => pair(&parser, '=', .minus_equal, .minus),
            '*' => pair(&parser, '=', .star_equal, .star),
            '/' => pair(&parser, '=', .slash_equal, .slash),
            '=' => pair(&parser, '=', .equal_equal, .equal),
            '!' => pair(&parser, '=', .bang_equal, .bang),
            '<' => pair(&parser, '=', .less_equal, .less),
            '>' => pair(&parser, '=', .greater_equal, .greater),
            '&' => blk: {
                parser.advance(1);
                if (!parser.eat('&')) {
                    failure.* = .{ .err = error.UnexpectedByte, .offset = start };
                    return error.UnexpectedByte;
                }
                break :blk .and_and;
            },
            '|' => blk: {
                parser.advance(1);
                if (!parser.eat('|')) {
                    failure.* = .{ .err = error.UnexpectedByte, .offset = start };
                    return error.UnexpectedByte;
                }
                break :blk .or_or;
            },
            else => {
                failure.* = .{ .err = error.UnexpectedByte, .offset = start };
                return error.UnexpectedByte;
            },
        };

        try tokens.append(gpa, .{
            .kind = kind,
            .bytes = source[start..parser.index],
            .offset = start,
        });
    }
}

fn one(parser: *text.Parser, kind: Kind) Kind {
    parser.advance(1);
    return kind;
}

fn pair(parser: *text.Parser, second: u8, both: Kind, alone: Kind) Kind {
    parser.advance(1);
    return if (parser.eat(second)) both else alone;
}

/// Whitespace and comments, of which there are two kinds.
fn skipTrivia(parser: *text.Parser, failure: *Failure) Error!void {
    while (true) {
        _ = parser.skipWhitespace();
        if (parser.checkSlice("//")) {
            _ = parser.takeUntilScalar('\n');
            continue;
        }
        if (parser.checkSlice("/*")) {
            const start: u32 = @intCast(parser.index);
            parser.advance(2);
            if (parser.takeUntilSlice("*/") == null) {
                failure.* = .{ .err = error.UnterminatedComment, .offset = start };
                return error.UnterminatedComment;
            }
            parser.advance(2);
            continue;
        }
        return;
    }
}

/// A number: digits, then at most one point and at most one exponent.
fn takeNumber(parser: *text.Parser, failure: *Failure) Error!void {
    const start: u32 = @intCast(parser.index);
    _ = parser.takeWhile(isDigit);

    if (parser.check('.')) {
        // A point that is not followed by a digit is a field access on a
        // number, which is nothing, so it belongs to no token.
        if (isDigitOpt(parser.peekAt(1))) {
            parser.advance(1);
            _ = parser.takeWhile(isDigit);
        }
    }

    if (parser.check('e') or parser.check('E')) {
        const mark = parser.save();
        parser.advance(1);
        _ = parser.eatAny("+-");
        if (!isDigitOpt(parser.peek())) {
            failure.* = .{ .err = error.MalformedNumber, .offset = start };
            return error.MalformedNumber;
        }
        _ = parser.takeWhile(isDigit);
        _ = mark;
    }

    // `1.2.3` and `1.0abc` are mistakes worth naming here rather than three
    // tokens later.
    if (parser.check('.') or isAlphaOpt(parser.peek())) {
        failure.* = .{ .err = error.MalformedNumber, .offset = start };
        return error.MalformedNumber;
    }
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isDigitOpt(c: ?u8) bool {
    return if (c) |b| isDigit(b) else false;
}

fn isAlphaOpt(c: ?u8) bool {
    const b = c orelse return false;
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or b == '_';
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn kindsOf(source: []const u8) ![]Kind {
    var failure: Failure = undefined;
    const tokens = try tokenize(testing.allocator, source, &failure);
    defer testing.allocator.free(tokens);
    const kinds = try testing.allocator.alloc(Kind, tokens.len);
    for (tokens, kinds) |token, *kind| kind.* = token.kind;
    return kinds;
}

test "the shapes of the language come out as themselves" {
    const kinds = try kindsOf("vertex { position = vec4(corner, 0.0, 1.0); }");
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(Kind, &.{
        .kw_vertex, .l_brace,    .identifier, .equal,   .identifier,
        .l_paren,   .identifier, .comma,      .number,  .comma,
        .number,    .r_paren,    .semicolon,  .r_brace, .eof,
    }, kinds);
}

test "the two-character operators are one token each" {
    const kinds = try kindsOf("a <= b && c != d || e >= f += 1 -= 2 *= 3 /= 4 == 5");
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(Kind, &.{
        .identifier, .less_equal, .identifier,  .and_and,     .identifier,
        .bang_equal, .identifier, .or_or,       .identifier,  .greater_equal,
        .identifier, .plus_equal, .number,      .minus_equal, .number,
        .star_equal, .number,     .slash_equal, .number,      .equal_equal,
        .number,     .eof,
    }, kinds);
}

test "comments are not tokens" {
    const kinds = try kindsOf(
        \\// a line
        \\a /* and a block
        \\   over two lines */ b
    );
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(Kind, &.{ .identifier, .identifier, .eof }, kinds);
}

test "a number keeps the text it was written as" {
    var failure: Failure = undefined;
    const tokens = try tokenize(testing.allocator, "1 2.5 3e2 4.0e-3", &failure);
    defer testing.allocator.free(tokens);

    try testing.expectEqualStrings("1", tokens[0].bytes);
    try testing.expect(!tokens[0].isFloatLiteral());
    try testing.expectEqualStrings("2.5", tokens[1].bytes);
    try testing.expect(tokens[1].isFloatLiteral());
    try testing.expectEqualStrings("3e2", tokens[2].bytes);
    try testing.expect(tokens[2].isFloatLiteral());
    try testing.expectEqualStrings("4.0e-3", tokens[3].bytes);
}

test "a swizzle on a number is a malformed number, not three tokens" {
    var failure: Failure = undefined;
    try testing.expectError(error.MalformedNumber, tokenize(testing.allocator, "1.2.3", &failure));
    try testing.expectEqual(@as(u32, 0), failure.offset);
    try testing.expectError(error.MalformedNumber, tokenize(testing.allocator, "  1e", &failure));
    try testing.expectEqual(@as(u32, 2), failure.offset);
}

test "a byte that begins nothing is named where it is" {
    var failure: Failure = undefined;
    try testing.expectError(error.UnexpectedByte, tokenize(testing.allocator, "a # b", &failure));
    try testing.expectEqual(@as(u32, 2), failure.offset);
    try testing.expectError(error.UnexpectedByte, tokenize(testing.allocator, "a & b", &failure));
}

test "a block comment that never ends says so" {
    var failure: Failure = undefined;
    try testing.expectError(error.UnterminatedComment, tokenize(testing.allocator, "a /* forever", &failure));
    try testing.expectEqual(@as(u32, 2), failure.offset);
}

test "keywords are keywords and everything else is a name" {
    const kinds = try kindsOf("attribute varying uniform const vertex fragment if else for while return discard true false vec4");
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(Kind, &.{
        .kw_attribute, .kw_varying, .kw_uniform, .kw_const, .kw_vertex,
        .kw_fragment,  .kw_if,      .kw_else,    .kw_for,   .kw_while,
        .kw_return,    .kw_discard, .kw_true,    .kw_false, .identifier,
        .eof,
    }, kinds);
}
