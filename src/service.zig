// SPDX-License-Identifier: BSL-1.0

//! What an editor asks about a shader being written: its colours, what is
//! wrong with it, what it declares, what may be typed at the caret, what a
//! call takes and what a name is.
//!
//! A shader half written is what an editor has most of the time, so nothing
//! here stops at a source that does not read: the colours and the
//! declarations come from a scan that takes any bytes, and only the
//! mistakes need the compiler, which says them as data rather than to a log.
//! A declaration's doc is the `//` comment on the lines right above it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const Diagnostics = @import("diag.zig");

pub const Problem = Diagnostics.Problem;

// ---------------------------------------------------------------------------
// The words

pub const keywords = [_][]const u8{ "attribute", "varying", "uniform", "const", "vertex", "fragment" };
pub const control = [_][]const u8{ "if", "else", "for", "while", "return", "discard" };
pub const constants = [_][]const u8{ "true", "false" };

/// Every type's name, `void` to `texture2d`.
pub const types = blk: {
    const fields = @typeInfo(ast.Type).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    break :blk names;
};

/// What each stage writes: `position` from the vertex stage and `target`
/// from the fragment stage.
pub const outputs = [_]Word{
    .{ .name = "position", .detail = "vec4 position", .doc = "What the vertex stage writes: where the vertex is, in clip space." },
    .{ .name = "target", .detail = "vec4 target", .doc = "What the fragment stage writes: the pixel's colour." },
};

/// A word the language has, with what it is and what it does.
pub const Word = struct {
    name: []const u8,
    detail: []const u8,
    doc: []const u8,
};

/// What each builtin takes and does. Every row of `builtins.table` has one,
/// which a test makes sure of.
pub const builtin_docs = [_]struct { name: []const u8, params: []const u8, doc: []const u8 }{
    .{ .name = "sample", .params = "texture, uv", .doc = "The texture's colour at `uv`, from nought to one across and down, filtered: a vec4." },
    .{ .name = "abs", .params = "x", .doc = "`x` without its sign, each component." },
    .{ .name = "floor", .params = "x", .doc = "The whole number at or below `x`, each component." },
    .{ .name = "ceil", .params = "x", .doc = "The whole number at or above `x`, each component." },
    .{ .name = "fract", .params = "x", .doc = "What `x` has after its point: `x - floor(x)`." },
    .{ .name = "sqrt", .params = "x", .doc = "The square root of `x`, each component." },
    .{ .name = "inversesqrt", .params = "x", .doc = "One over the square root of `x`, each component." },
    .{ .name = "sin", .params = "angle", .doc = "The sine of `angle`, in radians." },
    .{ .name = "cos", .params = "angle", .doc = "The cosine of `angle`, in radians." },
    .{ .name = "tan", .params = "angle", .doc = "The tangent of `angle`, in radians." },
    .{ .name = "asin", .params = "x", .doc = "The angle whose sine is `x`, in radians." },
    .{ .name = "acos", .params = "x", .doc = "The angle whose cosine is `x`, in radians." },
    .{ .name = "exp", .params = "x", .doc = "e to the power `x`." },
    .{ .name = "log", .params = "x", .doc = "The natural logarithm of `x`." },
    .{ .name = "exp2", .params = "x", .doc = "Two to the power `x`." },
    .{ .name = "log2", .params = "x", .doc = "The logarithm of `x` to base two." },
    .{ .name = "sign", .params = "x", .doc = "-1, 0 or 1, as `x` is below, at or above nought." },
    .{ .name = "normalize", .params = "v", .doc = "`v` made one long, pointing the same way." },
    .{ .name = "ddx", .params = "x", .doc = "How much `x` changes from this pixel to the next across. The fragment stage only." },
    .{ .name = "ddy", .params = "x", .doc = "How much `x` changes from this pixel to the next down. The fragment stage only." },
    .{ .name = "min", .params = "a, b", .doc = "The smaller of `a` and `b`, each component." },
    .{ .name = "max", .params = "a, b", .doc = "The larger of `a` and `b`, each component." },
    .{ .name = "pow", .params = "x, y", .doc = "`x` to the power `y`." },
    .{ .name = "step", .params = "edge, x", .doc = "0 where `x` is below `edge`, 1 where it is not." },
    .{ .name = "atan", .params = "y, x", .doc = "The angle whose tangent is `y` - or, given `x` too, the angle of the point `(x, y)` from the x axis - in radians." },
    .{ .name = "atan2", .params = "y, x", .doc = "The angle of the point `(x, y)` from the x axis, in radians." },
    .{ .name = "saturate", .params = "x", .doc = "`x`, kept between nought and one." },
    .{ .name = "mod", .params = "x, y", .doc = "What is left of `x` once whole `y`s are taken away: `x - y * floor(x / y)`." },
    .{ .name = "reflect", .params = "incident, normal", .doc = "`incident` bounced off a surface facing `normal`." },
    .{ .name = "clamp", .params = "x, low, high", .doc = "`x`, kept between `low` and `high`." },
    .{ .name = "mix", .params = "a, b, t", .doc = "From `a` to `b` by `t`: `a` at 0, `b` at 1." },
    .{ .name = "smoothstep", .params = "low, high, x", .doc = "0 below `low`, 1 above `high`, and a smooth curve between." },
    .{ .name = "length", .params = "v", .doc = "How long `v` is: a float." },
    .{ .name = "distance", .params = "a, b", .doc = "How far `a` is from `b`: a float." },
    .{ .name = "dot", .params = "a, b", .doc = "The dot product of `a` and `b`: a float." },
    .{ .name = "cross", .params = "a, b", .doc = "The cross product of two vec3s: a vec3." },
    .{ .name = "transpose", .params = "m", .doc = "The matrix `m` with its rows and columns swapped." },
};

pub const type_docs = [_]Word{
    .{ .name = "void", .detail = "void", .doc = "Nothing: what a function that gives nothing back returns." },
    .{ .name = "bool", .detail = "bool", .doc = "`true` or `false`." },
    .{ .name = "int", .detail = "int", .doc = "A whole number." },
    .{ .name = "float", .detail = "float", .doc = "A number." },
    .{ .name = "vec2", .detail = "vec2", .doc = "Two floats: `x` and `y`, or `r` and `g`." },
    .{ .name = "vec3", .detail = "vec3", .doc = "Three floats: `x`, `y`, `z`, or `r`, `g`, `b`." },
    .{ .name = "vec4", .detail = "vec4", .doc = "Four floats: `x`, `y`, `z`, `w`, or `r`, `g`, `b`, `a`: a colour." },
    .{ .name = "mat2", .detail = "mat2", .doc = "A two by two matrix of floats." },
    .{ .name = "mat3", .detail = "mat3", .doc = "A three by three matrix of floats." },
    .{ .name = "mat4", .detail = "mat4", .doc = "A four by four matrix of floats: a transform." },
    .{ .name = "texture2d", .detail = "texture2d", .doc = "A picture, read with `sample`." },
};

pub const keyword_docs = [_]Word{
    .{ .name = "attribute", .detail = "attribute TYPE NAME : LOCATION;", .doc = "What each vertex brings with it, for the vertex stage." },
    .{ .name = "varying", .detail = "varying TYPE NAME;", .doc = "What the vertex stage hands the fragment stage, blended across the triangle." },
    .{ .name = "uniform", .detail = "uniform NAME : SLOT { TYPE NAME; ... }", .doc = "A block of numbers the program sets for a whole draw. A field may say what it starts as: `float strength = 0.5;`." },
    .{ .name = "const", .detail = "const TYPE NAME = VALUE;", .doc = "A value that never changes." },
    .{ .name = "vertex", .detail = "vertex { ... }", .doc = "The vertex stage: once for every vertex, writing `position`." },
    .{ .name = "fragment", .detail = "fragment { ... }", .doc = "The fragment stage: once for every pixel, writing `target`." },
    .{ .name = "if", .detail = "if (condition) { ... } else { ... }", .doc = "One way or the other." },
    .{ .name = "else", .detail = "else { ... }", .doc = "The other way." },
    .{ .name = "for", .detail = "for (int i = 0; i < n; i = i + 1) { ... }", .doc = "A loop with a counter." },
    .{ .name = "while", .detail = "while (condition) { ... }", .doc = "A loop, while the condition holds." },
    .{ .name = "return", .detail = "return VALUE;", .doc = "What a function gives back." },
    .{ .name = "discard", .detail = "discard;", .doc = "This pixel is not drawn at all. The fragment stage only." },
    .{ .name = "true", .detail = "bool", .doc = "Yes." },
    .{ .name = "false", .detail = "bool", .doc = "No." },
};

fn isIn(words: []const []const u8, word: []const u8) bool {
    for (words) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn docOf(table: []const Word, name: []const u8) ?Word {
    for (table) |w| if (std.mem.eql(u8, w.name, name)) return w;
    return null;
}

fn builtinDoc(name: []const u8) ?@TypeOf(builtin_docs[0]) {
    for (builtin_docs) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

// ---------------------------------------------------------------------------
// The scan

/// A piece of the source as the scan sees it: never an error, whatever the
/// bytes.
const Lexeme = struct {
    kind: enum { word, number, comment, punct },
    start: u32,
    end: u32,

    fn text(self: Lexeme, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn scan(arena: Allocator, source: []const u8) Allocator.Error![]const Lexeme {
    var out: std.ArrayList(Lexeme) = .empty;
    var at: usize = 0;
    while (at < source.len) {
        const c = source[at];
        const start = at;
        if (std.ascii.isWhitespace(c)) {
            at += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[at..], "//")) {
            at = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
            try out.append(arena, .{ .kind = .comment, .start = @intCast(start), .end = @intCast(at) });
        } else if (std.mem.startsWith(u8, source[at..], "/*")) {
            at = if (std.mem.indexOfPos(u8, source, at + 2, "*/")) |close| close + 2 else source.len;
            try out.append(arena, .{ .kind = .comment, .start = @intCast(start), .end = @intCast(at) });
        } else if (isWordStart(c)) {
            while (at < source.len and isWordChar(source[at])) at += 1;
            try out.append(arena, .{ .kind = .word, .start = @intCast(start), .end = @intCast(at) });
        } else if (std.ascii.isDigit(c) or (c == '.' and at + 1 < source.len and std.ascii.isDigit(source[at + 1]))) {
            while (at < source.len) : (at += 1) {
                const d = source[at];
                if (std.ascii.isAlphanumeric(d) or d == '.') continue;
                if ((d == '-' or d == '+') and (source[at - 1] == 'e' or source[at - 1] == 'E')) continue;
                break;
            }
            try out.append(arena, .{ .kind = .number, .start = @intCast(start), .end = @intCast(at) });
        } else {
            at += 1;
            try out.append(arena, .{ .kind = .punct, .start = @intCast(start), .end = @intCast(at) });
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Declarations

pub const DeclarationKind = enum { attribute, varying, block, field, texture, constant, function, parameter, variable };

pub const Declaration = struct {
    name: []const u8,
    kind: DeclarationKind,
    /// Its type's name, or a function's return type; empty for a block.
    type_name: []const u8,
    /// Where its name is.
    offset: u32,
    /// Where it may be named: the whole source, or the braces it is in.
    scope: [2]u32,
    /// The `//` lines right above it, without their slashes.
    doc: ?[]const u8 = null,
    /// A function's parameters, as written: `float x, vec2 y`.
    params: []const u8 = "",

    /// How it is shown: `uniform Look`, `varying vec2 UV`, `float mix2(float a)`.
    pub fn detail(self: Declaration, arena: Allocator) Allocator.Error![]const u8 {
        return switch (self.kind) {
            .block => std.fmt.allocPrint(arena, "uniform {s}", .{self.name}),
            .attribute, .varying => std.fmt.allocPrint(arena, "{s} {s} {s}", .{ @tagName(self.kind), self.type_name, self.name }),
            .constant => std.fmt.allocPrint(arena, "const {s} {s}", .{ self.type_name, self.name }),
            .function => std.fmt.allocPrint(arena, "{s} {s}({s})", .{ self.type_name, self.name, self.params }),
            else => std.fmt.allocPrint(arena, "{s} {s}", .{ self.type_name, self.name }),
        };
    }

    fn visibleAt(self: Declaration, offset: u32) bool {
        if (offset < self.scope[0] or offset > self.scope[1]) return false;
        // A local is named after it is declared.
        return switch (self.kind) {
            .variable, .constant => self.scope[0] == 0 or self.offset < offset,
            else => true,
        };
    }
};

fn isType(word: []const u8) bool {
    return ast.Type.fromName(word) != null;
}

/// What the source declares, found by a scan that takes a source that does
/// not read.
fn declarations(arena: Allocator, source: []const u8, lexemes: []const Lexeme) Allocator.Error![]const Declaration {
    var out: std.ArrayList(Declaration) = .empty;
    // The braces open now: where each opened, and the declarations waiting
    // for it to close, whose scope ends there.
    const Open = struct { start: u32, first: usize, block: bool };
    var open: std.ArrayList(Open) = .empty;
    const whole: [2]u32 = .{ 0, @intCast(source.len) };
    // A function's parameters take the scope of the body that follows.
    var params_from: ?usize = null;
    var in_block = false;

    var i: usize = 0;
    while (i < lexemes.len) : (i += 1) {
        const l = lexemes[i];
        if (l.kind == .comment) continue;
        const word = l.text(source);
        if (l.kind == .punct) {
            switch (word[0]) {
                '{' => {
                    const block = in_block;
                    in_block = false;
                    try open.append(arena, .{ .start = l.start, .first = params_from orelse out.items.len, .block = block });
                    params_from = null;
                },
                '}' => if (open.pop()) |o| {
                    if (!o.block) for (out.items[o.first..]) |*d| {
                        if (d.scope[1] == std.math.maxInt(u32)) d.scope[1] = l.end;
                    };
                },
                ';' => params_from = null,
                else => {},
            }
            continue;
        }
        if (l.kind != .word) continue;
        const depth = open.items.len;
        const next = nextSolid(lexemes, i + 1);
        const scope: [2]u32 = if (depth == 0) whole else .{ open.items[depth - 1].start, std.math.maxInt(u32) };

        if (std.mem.eql(u8, word, "uniform")) {
            if (nameAt(source, lexemes, next)) |n| {
                try out.append(arena, .{ .name = n.text, .kind = .block, .type_name = "", .offset = n.offset, .scope = whole, .doc = docAbove(arena, source, lexemes, i) });
                in_block = true;
            }
            continue;
        }
        const kind: ?DeclarationKind = if (std.mem.eql(u8, word, "attribute")) .attribute else if (std.mem.eql(u8, word, "varying")) .varying else if (std.mem.eql(u8, word, "const")) .constant else null;
        if (kind) |k| {
            // `attribute vec2 NAME`, `const float NAME`.
            if (typeAt(source, lexemes, next)) |_| if (nameAt(source, lexemes, nextSolid(lexemes, next + 1))) |n| {
                try out.append(arena, .{ .name = n.text, .kind = k, .type_name = lexemes[next].text(source), .offset = n.offset, .scope = scope, .doc = docAbove(arena, source, lexemes, i) });
                i = n.index;
            };
            continue;
        }
        if (!isType(word)) continue;
        // `TYPE NAME`: a field, a texture, a function, a parameter or a variable.
        const n = nameAt(source, lexemes, next) orelse continue;
        const after = nextSolid(lexemes, n.index + 1);
        const after_text = if (after < lexemes.len) lexemes[after].text(source) else "";
        const in_uniform = depth > 0 and open.items[depth - 1].block;
        const in_params = params_from != null and depth == 0;
        var decl: Declaration = .{ .name = n.text, .kind = .variable, .type_name = word, .offset = n.offset, .scope = scope, .doc = docAbove(arena, source, lexemes, i) };
        if (in_uniform) {
            decl.kind = .field;
            decl.scope = whole;
        } else if (std.mem.eql(u8, word, "texture2d") and depth == 0) {
            decl.kind = .texture;
        } else if (depth == 0 and !in_params and std.mem.eql(u8, after_text, "(")) {
            decl.kind = .function;
            const close = matching(source, lexemes, after) orelse lexemes.len;
            if (close < lexemes.len) decl.params = std.mem.trim(u8, source[lexemes[after].end..lexemes[close].start], " \t\r\n");
            try out.append(arena, decl);
            // Its parameters are next, and share the body's scope.
            params_from = out.items.len;
            i = after;
            continue;
        } else if (in_params) {
            decl.kind = .parameter;
            decl.scope = .{ l.start, std.math.maxInt(u32) };
        }
        try out.append(arena, decl);
        i = n.index;
    }
    // What never closed reaches the end.
    for (out.items) |*d| if (d.scope[1] == std.math.maxInt(u32)) {
        d.scope[1] = @intCast(source.len);
    };
    return out.items;
}

fn nextSolid(lexemes: []const Lexeme, from: usize) usize {
    var at = from;
    while (at < lexemes.len and lexemes[at].kind == .comment) at += 1;
    return at;
}

fn typeAt(source: []const u8, lexemes: []const Lexeme, at: usize) ?void {
    if (at >= lexemes.len or lexemes[at].kind != .word or !isType(lexemes[at].text(source))) return null;
}

/// A name the source declares at `at`: a word that is not one of the
/// language's.
fn nameAt(source: []const u8, lexemes: []const Lexeme, at: usize) ?struct { text: []const u8, offset: u32, index: usize } {
    if (at >= lexemes.len or lexemes[at].kind != .word) return null;
    const word = lexemes[at].text(source);
    if (isType(word) or isIn(&keywords, word) or isIn(&control, word) or isIn(&constants, word)) return null;
    return .{ .text = word, .offset = lexemes[at].start, .index = at };
}

/// The closing parenthesis of the one at `at`.
fn matching(source: []const u8, lexemes: []const Lexeme, at: usize) ?usize {
    var depth: usize = 0;
    var i = at;
    while (i < lexemes.len) : (i += 1) {
        if (lexemes[i].kind != .punct) continue;
        switch (lexemes[i].text(source)[0]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            '{', ';' => return null,
            else => {},
        }
    }
    return null;
}

/// The `//` comments on the lines right above the lexeme at `index`, their
/// slashes taken off, as one text.
fn docAbove(arena: Allocator, source: []const u8, lexemes: []const Lexeme, index: usize) ?[]const u8 {
    var first = index;
    var line_start = lineStart(source, lexemes[index].start);
    while (first > 0) {
        const prev = lexemes[first - 1];
        if (prev.kind != .comment or !std.mem.startsWith(u8, prev.text(source), "//")) break;
        // On the line just above, alone on it.
        if (prev.end + 1 != line_start and !(prev.end + 2 == line_start and source[prev.end] == '\r')) break;
        const own = lineStart(source, prev.start);
        if (std.mem.trim(u8, source[own..prev.start], " \t").len != 0) break;
        first -= 1;
        line_start = own;
    }
    if (first == index) return null;
    var out: std.ArrayList(u8) = .empty;
    for (lexemes[first..index]) |c| {
        var line = c.text(source);
        while (line.len > 0 and line[0] == '/') line = line[1..];
        line = std.mem.trim(u8, line, " \t\r");
        if (out.items.len > 0) out.append(arena, ' ') catch return null;
        out.appendSlice(arena, line) catch return null;
    }
    return out.items;
}

fn lineStart(source: []const u8, offset: u32) u32 {
    const at = @min(offset, source.len);
    return if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |nl| @intCast(nl + 1) else 0;
}

/// The declaration a name at `offset` means: the innermost one it can see.
pub fn declarationOf(decls: []const Declaration, name: []const u8, offset: u32) ?Declaration {
    var best: ?Declaration = null;
    for (decls) |d| {
        if (!std.mem.eql(u8, d.name, name) or !d.visibleAt(offset)) continue;
        if (best == null or d.scope[0] >= best.?.scope[0]) best = d;
    }
    return best;
}

// ---------------------------------------------------------------------------
// The analysis

pub const TokenKind = enum { keyword, control, type, builtin, constant, number, comment, output, block, field, texture, function, parameter, variable, varying, attribute };

pub const Token = struct { start: u32, len: u32, kind: TokenKind };

pub const Analysis = struct {
    tokens: []const Token,
    declarations: []const Declaration,
    problems: []const Problem,
};

/// Everything said of `source`: its colours, what it declares, and what is
/// wrong with it. What comes back is in `arena`; `gpa` is for the compiler's
/// own work.
pub fn analyze(gpa: Allocator, arena: Allocator, source: []const u8) Allocator.Error!Analysis {
    const lexemes = try scan(arena, source);
    const decls = try declarations(arena, source, lexemes);
    return .{
        .tokens = try tokensOf(arena, source, lexemes, decls),
        .declarations = decls,
        .problems = try check(gpa, arena, source),
    };
}

/// What is wrong with `source`, as the compiler says it.
pub fn check(gpa: Allocator, arena: Allocator, source: []const u8) Allocator.Error![]const Problem {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var list: std.ArrayList(Problem) = .empty;
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    var diagnostics: Diagnostics = .init(source, &discarding.writer);
    diagnostics.keepIn(arena, &list);
    _ = root.front(scratch.allocator(), source, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CompileFailed => {},
    };
    return list.items;
}

fn tokensOf(arena: Allocator, source: []const u8, lexemes: []const Lexeme, decls: []const Declaration) Allocator.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
    for (lexemes) |l| {
        const kind: TokenKind = switch (l.kind) {
            .comment => .comment,
            .number => .number,
            .punct => continue,
            .word => kindOfWord(source, l, decls) orelse continue,
        };
        try out.append(arena, .{ .start = l.start, .len = l.end - l.start, .kind = kind });
    }
    return out.items;
}

fn kindOfWord(source: []const u8, l: Lexeme, decls: []const Declaration) ?TokenKind {
    const word = l.text(source);
    if (isIn(&control, word)) return .control;
    if (isIn(&keywords, word)) return .keyword;
    if (isIn(&constants, word)) return .constant;
    if (isType(word)) return .type;
    if (builtins.find(word) != null) return .builtin;
    if (docOf(&outputs, word) != null) return .output;
    const d = declarationOf(decls, word, l.start) orelse return null;
    return switch (d.kind) {
        .attribute => .attribute,
        .varying => .varying,
        .block => .block,
        .field => .field,
        .texture => .texture,
        .constant => .constant,
        .function => .function,
        .parameter => .parameter,
        .variable => .variable,
    };
}

// ---------------------------------------------------------------------------
// Completion, signatures and hovers

pub const ItemKind = enum { keyword, type, builtin, output, block, field, texture, constant, function, parameter, variable, varying, attribute, swizzle };

pub const Item = struct {
    label: []const u8,
    kind: ItemKind,
    detail: []const u8 = "",
    doc: ?[]const u8 = null,
    /// Offered first when lower: what the caret's braces declare, then the
    /// source's own, then what the language has.
    rank: u8 = 0,
};

pub const Completions = struct {
    items: []const Item,
    /// The word at the caret, which a completion replaces.
    start: u32,
    end: u32,
};

const swizzles = [_][]const u8{ "x", "y", "z", "w", "xy", "xyz", "r", "g", "b", "a", "rgb", "rgba" };

/// What may be typed at `offset`: nothing in a comment, a component after a
/// `.`, and otherwise what the caret can see and what the language has.
pub fn complete(arena: Allocator, source: []const u8, offset: u32, analysis: *const Analysis) Allocator.Error!?Completions {
    const at = @min(offset, source.len);
    if (inComment(source, at)) return null;
    var start = at;
    while (start > 0 and isWordChar(source[start - 1])) start -= 1;
    var end = at;
    while (end < source.len and isWordChar(source[end])) end += 1;
    var items: std.ArrayList(Item) = .empty;

    if (start > 0 and source[start - 1] == '.') {
        for (swizzles) |s| try items.append(arena, .{ .label = s, .kind = .swizzle, .detail = "component" });
        return .{ .items = items.items, .start = @intCast(start), .end = @intCast(end) };
    }
    if (start > 0 and std.ascii.isDigit(source[start - 1])) return null;

    for (analysis.declarations) |d| {
        if (!d.visibleAt(@intCast(at)) or d.offset == start) continue;
        const local = d.scope[0] != 0;
        try items.append(arena, .{
            .label = d.name,
            .kind = itemKindOf(d.kind),
            .detail = try d.detail(arena),
            .doc = d.doc,
            .rank = if (local) 0 else 1,
        });
    }
    for (builtin_docs) |b| try items.append(arena, .{
        .label = b.name,
        .kind = .builtin,
        .detail = try std.fmt.allocPrint(arena, "{s}({s})", .{ b.name, b.params }),
        .doc = b.doc,
        .rank = 2,
    });
    for (outputs) |o| try items.append(arena, .{ .label = o.name, .kind = .output, .detail = o.detail, .doc = o.doc, .rank = 2 });
    for (type_docs) |t| try items.append(arena, .{ .label = t.name, .kind = .type, .detail = t.detail, .doc = t.doc, .rank = 3 });
    for (keyword_docs) |k| try items.append(arena, .{ .label = k.name, .kind = .keyword, .detail = k.detail, .doc = k.doc, .rank = 4 });
    return .{ .items = items.items, .start = @intCast(start), .end = @intCast(end) };
}

fn itemKindOf(kind: DeclarationKind) ItemKind {
    return switch (kind) {
        .attribute => .attribute,
        .varying => .varying,
        .block => .block,
        .field => .field,
        .texture => .texture,
        .constant => .constant,
        .function => .function,
        .parameter => .parameter,
        .variable => .variable,
    };
}

fn inComment(source: []const u8, at: usize) bool {
    const line = source[lineStart(source, @intCast(at))..at];
    if (std.mem.indexOf(u8, line, "//") != null) return true;
    const opened = std.mem.lastIndexOf(u8, source[0..at], "/*") orelse return false;
    return std.mem.indexOfPos(u8, source[0..at], opened, "*/") == null;
}

pub const Signature = struct {
    /// `mix(a, b, t)`.
    label: []const u8,
    /// Where each parameter is in `label`.
    params: []const [2]u32,
    /// The one the caret is at.
    active: u32,
    doc: ?[]const u8 = null,
};

/// The call whose parentheses `offset` is in: a builtin's, or a function's
/// the source declares.
pub fn signature(arena: Allocator, source: []const u8, offset: u32, analysis: *const Analysis) Allocator.Error!?Signature {
    var depth: usize = 0;
    var commas: u32 = 0;
    var at = @min(offset, source.len);
    const open = while (at > 0) {
        at -= 1;
        switch (source[at]) {
            ')' => depth += 1,
            '(' => if (depth == 0) break at else {
                depth -= 1;
            },
            ',' => if (depth == 0) {
                commas += 1;
            },
            ';', '{', '}' => return null,
            else => {},
        }
    } else return null;
    var name_end = open;
    while (name_end > 0 and source[name_end - 1] == ' ') name_end -= 1;
    var name_start = name_end;
    while (name_start > 0 and isWordChar(source[name_start - 1])) name_start -= 1;
    const name = source[name_start..name_end];
    if (name.len == 0) return null;

    var params_text: []const u8 = "";
    var doc: ?[]const u8 = null;
    if (builtinDoc(name)) |b| {
        params_text = b.params;
        doc = b.doc;
    } else if (declarationOf(analysis.declarations, name, @intCast(open))) |d| {
        if (d.kind != .function) return null;
        params_text = d.params;
        doc = d.doc;
    } else return null;

    const label = try std.fmt.allocPrint(arena, "{s}({s})", .{ name, params_text });
    var spans: std.ArrayList([2]u32) = .empty;
    var from: u32 = @intCast(name.len + 1);
    var rest = params_text;
    while (rest.len > 0) {
        const comma = std.mem.indexOf(u8, rest, ", ") orelse rest.len;
        try spans.append(arena, .{ from, from + @as(u32, @intCast(comma)) });
        if (comma == rest.len) break;
        from += @intCast(comma + 2);
        rest = rest[comma + 2 ..];
    }
    return .{ .label = label, .params = spans.items, .active = commas, .doc = doc };
}

pub const Hover = struct {
    start: u32,
    end: u32,
    code: []const u8,
    doc: ?[]const u8 = null,
};

/// What the word at `offset` is.
pub fn hover(arena: Allocator, source: []const u8, offset: u32, analysis: *const Analysis) Allocator.Error!?Hover {
    const at = @min(offset, source.len);
    if (inComment(source, at)) return null;
    var start = at;
    while (start > 0 and isWordChar(source[start - 1])) start -= 1;
    var end = at;
    while (end < source.len and isWordChar(source[end])) end += 1;
    if (start == end or !isWordStart(source[start])) return null;
    const word = source[start..end];
    const span: [2]u32 = .{ @intCast(start), @intCast(end) };
    if (builtinDoc(word)) |b| return .{ .start = span[0], .end = span[1], .code = try std.fmt.allocPrint(arena, "{s}({s})", .{ b.name, b.params }), .doc = b.doc };
    if (docOf(&type_docs, word) orelse docOf(&keyword_docs, word) orelse docOf(&outputs, word)) |w| {
        return .{ .start = span[0], .end = span[1], .code = w.detail, .doc = w.doc };
    }
    const d = declarationOf(analysis.declarations, word, @intCast(start)) orelse return null;
    return .{ .start = span[0], .end = span[1], .code = try d.detail(arena), .doc = d.doc };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const example =
    \\// What a Material gives it.
    \\uniform Look : 1 {
    \\    // How much of the tint.
    \\    float strength = 0.5;
    \\    vec4 tint;
    \\}
    \\texture2d picture : 0;
    \\varying vec2 uv;
    \\attribute vec2 corner : 0;
    \\
    \\// Brighter by `amount`.
    \\vec4 brighten(vec4 colour, float amount) {
    \\    return colour * amount;
    \\}
    \\
    \\vertex {
    \\    uv = corner;
    \\    position = vec4(corner, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 seen = sample(picture, uv); /* a comment */
    \\    target = mix(seen, brighten(seen, 2.0), strength);
    \\}
;

test "every builtin has what it takes and what it does" {
    for (builtins.table) |row| {
        if (builtinDoc(row.name) == null) {
            std.debug.print("no doc for the builtin `{s}`\n", .{row.name});
            return error.TestExpectedEqual;
        }
    }
    try testing.expectEqual(builtins.table.len, builtin_docs.len);
    try testing.expectEqual(@typeInfo(ast.Type).@"enum".fields.len, type_docs.len);
}

test "what a source declares is found, with its scope and the doc above it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try analyze(testing.allocator, arena.allocator(), example);
    try testing.expectEqual(@as(usize, 0), a.problems.len);
    const want = [_]struct { []const u8, DeclarationKind }{
        .{ "Look", .block },
        .{ "strength", .field },
        .{ "tint", .field },
        .{ "picture", .texture },
        .{ "uv", .varying },
        .{ "corner", .attribute },
        .{ "brighten", .function },
        .{ "colour", .parameter },
        .{ "amount", .parameter },
        .{ "seen", .variable },
    };
    try testing.expectEqual(want.len, a.declarations.len);
    for (want, a.declarations) |w, d| {
        try testing.expectEqualStrings(w[0], d.name);
        try testing.expectEqual(w[1], d.kind);
    }
    try testing.expectEqualStrings("What a Material gives it.", a.declarations[0].doc.?);
    try testing.expectEqualStrings("How much of the tint.", a.declarations[1].doc.?);
    try testing.expectEqualStrings("vec4 colour, float amount", a.declarations[6].params);
    // A parameter is seen in its function's body and not in the fragment stage.
    const in_body: u32 = @intCast(std.mem.indexOf(u8, example, "colour * amount").?);
    const in_stage: u32 = @intCast(std.mem.indexOf(u8, example, "target").?);
    try testing.expect(declarationOf(a.declarations, "amount", in_body) != null);
    try testing.expect(declarationOf(a.declarations, "amount", in_stage) == null);
}

test "names are coloured by what they are, and the comments are kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try analyze(testing.allocator, arena.allocator(), example);
    const Want = struct { []const u8, TokenKind };
    for ([_]Want{
        .{ "uniform", .keyword },
        .{ "float", .type },
        .{ "return", .control },
        .{ "sample", .builtin },
        .{ "target", .output },
        .{ "strength);", .field },
        .{ "picture, uv", .texture },
        .{ "uv);", .varying },
        .{ "brighten(seen", .function },
        .{ "/* a comment */", .comment },
        .{ "2.0", .number },
    }) |w| {
        const at: u32 = @intCast(std.mem.lastIndexOf(u8, example, w[0]).?);
        const found = for (a.tokens) |t| {
            if (t.start == at) break t;
        } else return error.TestExpectedEqual;
        try testing.expectEqual(w[1], found.kind);
    }
}

test "a source that does not read is still coloured, and what is wrong is said where it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source = "fragment {\n    target = vec4(1.0, 0.0, 0.0, 1.0) +;\n}\n";
    const a = try analyze(testing.allocator, arena.allocator(), source);
    try testing.expect(a.problems.len >= 1);
    try testing.expectEqual(@as(u32, 2), a.problems[0].line);
    try testing.expect(a.tokens.len > 0);

    const unclosed = "fragment {\n    /* never closed";
    const b = try analyze(testing.allocator, arena.allocator(), unclosed);
    try testing.expectEqual(@as(u32, 2), b.problems[0].line);
    try testing.expectEqual(TokenKind.comment, b.tokens[b.tokens.len - 1].kind);
}

test "completions offer what the caret can see, and components after a point" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try analyze(testing.allocator, arena.allocator(), example);
    const in_stage: u32 = @intCast(std.mem.indexOf(u8, example, "target =").?);
    const found = (try complete(arena.allocator(), example, in_stage + 2, &a)).?;
    try testing.expectEqual(in_stage, found.start);
    var labels: std.ArrayList([]const u8) = .empty;
    for (found.items) |item| try labels.append(arena.allocator(), item.label);
    for ([_][]const u8{ "seen", "strength", "brighten", "mix", "vec4", "target", "discard" }) |want| {
        for (labels.items) |l| {
            if (std.mem.eql(u8, l, want)) break;
        } else return error.TestExpectedEqual;
    }
    for (labels.items) |l| try testing.expect(!std.mem.eql(u8, l, "amount"));

    const dot: u32 = @intCast(std.mem.indexOf(u8, example, "uv)").? + 2);
    const source = try std.mem.concat(arena.allocator(), u8, &.{ example[0..dot], ".", example[dot..] });
    const parts = (try complete(arena.allocator(), source, dot + 1, &a)).?;
    try testing.expectEqual(ItemKind.swizzle, parts.items[0].kind);
    try testing.expect((try complete(arena.allocator(), example, 5, &a)) == null);
}

test "a call's signature marks the argument the caret is at, and a hover says what a name is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try analyze(testing.allocator, arena.allocator(), example);
    const second: u32 = @intCast(std.mem.indexOf(u8, example, "brighten(seen, 2.0)").? + 15);
    const inner = (try signature(arena.allocator(), example, second, &a)).?;
    try testing.expectEqualStrings("brighten(vec4 colour, float amount)", inner.label);
    try testing.expectEqual(@as(u32, 1), inner.active);
    try testing.expectEqualStrings("float amount", inner.label[inner.params[1][0]..inner.params[1][1]]);
    const third: u32 = @intCast(std.mem.indexOf(u8, example, "strength);").?);
    const outer = (try signature(arena.allocator(), example, third, &a)).?;
    try testing.expectEqualStrings("mix(a, b, t)", outer.label);
    try testing.expectEqual(@as(u32, 2), outer.active);

    const on_field: u32 = @intCast(std.mem.lastIndexOf(u8, example, "strength").? + 2);
    const shown = (try hover(arena.allocator(), example, on_field, &a)).?;
    try testing.expectEqualStrings("float strength", shown.code);
    try testing.expectEqualStrings("How much of the tint.", shown.doc.?);
    const on_builtin: u32 = @intCast(std.mem.indexOf(u8, example, "mix").? + 1);
    try testing.expectEqualStrings("mix(a, b, t)", (try hover(arena.allocator(), example, on_builtin, &a)).?.code);
}
