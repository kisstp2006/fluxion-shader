// SPDX-License-Identifier: BSL-1.0

//! Tokens into a tree.
//!
//! Recursive descent, one token of lookahead, and it stops at the first thing
//! it cannot read. A parser that carried on would have to guess what was
//! meant, and a guess in a fifty-line shader produces three more complaints
//! about a mistake that was not made. `sema` reports as many as it finds,
//! because by then the shape is known and carrying on is honest.
//!
//! Nothing here has an opinion about types. `vec4(a, b)` is a call to
//! something named `vec4` until `sema` says otherwise, and `a * b` is a
//! multiply whatever `a` and `b` turn out to be.

const std = @import("std");
const Allocator = std.mem.Allocator;

const lex = @import("lex.zig");
const ast = @import("ast.zig");
const Diagnostics = @import("diag.zig");

pub const Error = error{ParseFailed} || Allocator.Error;

const Parser = @This();

arena: Allocator,
tokens: []const lex.Token,
index: usize = 0,
diagnostics: *Diagnostics,

/// Read a whole source file. Everything in the result is allocated from
/// `arena` and lives as long as it does.
pub fn parse(
    arena: Allocator,
    tokens: []const lex.Token,
    diagnostics: *Diagnostics,
) Error!ast.Program {
    var self: Parser = .{ .arena = arena, .tokens = tokens, .diagnostics = diagnostics };
    return self.program();
}

// -------------------------------------------------------------------------
// The cursor
// -------------------------------------------------------------------------

fn peek(self: *const Parser) lex.Token {
    return self.tokens[self.index];
}

fn peekAt(self: *const Parser, ahead: usize) lex.Token {
    const at = @min(self.index + ahead, self.tokens.len - 1);
    return self.tokens[at];
}

fn advance(self: *Parser) lex.Token {
    const token = self.tokens[self.index];
    if (token.kind != .eof) self.index += 1;
    return token;
}

fn check(self: *const Parser, kind: lex.Kind) bool {
    return self.peek().kind == kind;
}

fn eat(self: *Parser, kind: lex.Kind) bool {
    if (!self.check(kind)) return false;
    _ = self.advance();
    return true;
}

fn expect(self: *Parser, kind: lex.Kind) Error!lex.Token {
    if (self.check(kind)) return self.advance();
    const found = self.peek();
    self.diagnostics.report(found.offset, "expected {s}, found {s}", .{
        kind.describe(),
        found.kind.describe(),
    });
    return error.ParseFailed;
}

fn fail(self: *Parser, offset: u32, comptime fmt: []const u8, args: anytype) Error {
    self.diagnostics.report(offset, fmt, args);
    return error.ParseFailed;
}

/// The type a name stands for, or null when it names something else.
fn typeAhead(self: *const Parser, ahead: usize) ?ast.Type {
    const token = self.peekAt(ahead);
    if (token.kind != .identifier) return null;
    return ast.Type.fromName(token.bytes);
}

// -------------------------------------------------------------------------
// Declarations
// -------------------------------------------------------------------------

fn program(self: *Parser) Error!ast.Program {
    var attributes: std.ArrayListUnmanaged(ast.Attribute) = .empty;
    var varyings: std.ArrayListUnmanaged(ast.Varying) = .empty;
    var blocks: std.ArrayListUnmanaged(ast.UniformBlock) = .empty;
    var textures: std.ArrayListUnmanaged(ast.Texture) = .empty;
    var constants: std.ArrayListUnmanaged(ast.Constant) = .empty;
    var functions: std.ArrayListUnmanaged(ast.Function) = .empty;
    var vertex: ?ast.Stage = null;
    var fragment: ?ast.Stage = null;

    while (!self.check(.eof)) {
        const token = self.peek();
        switch (token.kind) {
            .kw_attribute => try attributes.append(self.arena, try self.attribute()),
            .kw_varying => try varyings.append(self.arena, try self.varying()),
            .kw_uniform => try blocks.append(self.arena, try self.uniformBlock()),
            .kw_const => try constants.append(self.arena, try self.constant()),
            .kw_vertex, .kw_fragment => {
                _ = self.advance();
                const stage: ast.Stage = .{ .body = try self.block(), .offset = token.offset };
                const slot = if (token.kind == .kw_vertex) &vertex else &fragment;
                if (slot.* != null) {
                    return self.fail(token.offset, "a second {s} stage; there is one of each", .{
                        if (token.kind == .kw_vertex) "vertex" else "fragment",
                    });
                }
                slot.* = stage;
            },
            .identifier => {
                const ty = ast.Type.fromName(token.bytes) orelse {
                    return self.fail(token.offset, "`{s}` is not a type, and nothing else may start a declaration", .{token.bytes});
                };
                // `texture2d atlas : 0;` against `vec4 shade(...) { }`.
                if (self.peekAt(2).kind == .l_paren) {
                    try functions.append(self.arena, try self.function());
                } else if (ty == .texture2d) {
                    try textures.append(self.arena, try self.texture());
                } else {
                    return self.fail(token.offset, "a value declared here has to be `const`, and anything else here has to be a function", .{});
                }
            },
            else => return self.fail(token.offset, "expected a declaration, found {s}", .{token.kind.describe()}),
        }
    }

    return .{
        .attributes = attributes.items,
        .varyings = varyings.items,
        .blocks = blocks.items,
        .textures = textures.items,
        .constants = constants.items,
        .functions = functions.items,
        .vertex = vertex,
        .fragment = fragment,
    };
}

/// `attribute vec2 corner : 0;`
fn attribute(self: *Parser) Error!ast.Attribute {
    const keyword = self.advance();
    const ty = try self.typeName();
    const name = try self.expect(.identifier);
    _ = try self.expect(.colon);
    const location = try self.slotNumber();
    _ = try self.expect(.semicolon);
    return .{ .name = name.bytes, .ty = ty, .location = location, .offset = keyword.offset };
}

/// `varying vec2 uv;`
fn varying(self: *Parser) Error!ast.Varying {
    const keyword = self.advance();
    const ty = try self.typeName();
    const name = try self.expect(.identifier);
    _ = try self.expect(.semicolon);
    return .{ .name = name.bytes, .ty = ty, .offset = keyword.offset };
}

/// `uniform Frame : 0 { mat4 projection; }`
fn uniformBlock(self: *Parser) Error!ast.UniformBlock {
    const keyword = self.advance();
    const name = try self.expect(.identifier);
    _ = try self.expect(.colon);
    const slot = try self.slotNumber();
    _ = try self.expect(.l_brace);

    var fields: std.ArrayListUnmanaged(ast.BlockField) = .empty;
    while (!self.check(.r_brace)) {
        if (self.check(.eof)) return self.fail(keyword.offset, "this uniform block was never closed", .{});
        const at = self.peek().offset;
        const ty = try self.typeName();
        const field = try self.expect(.identifier);
        _ = try self.expect(.semicolon);
        try fields.append(self.arena, .{ .name = field.bytes, .ty = ty, .offset = at });
    }
    _ = try self.expect(.r_brace);

    return .{ .name = name.bytes, .slot = slot, .fields = fields.items, .offset = keyword.offset };
}

/// `texture2d atlas : 0;`
fn texture(self: *Parser) Error!ast.Texture {
    const keyword = self.advance();
    const name = try self.expect(.identifier);
    _ = try self.expect(.colon);
    const slot = try self.slotNumber();
    _ = try self.expect(.semicolon);
    return .{ .name = name.bytes, .slot = slot, .offset = keyword.offset };
}

/// `const float pi = 3.14159;`
fn constant(self: *Parser) Error!ast.Constant {
    const keyword = self.advance();
    const ty = try self.typeName();
    const name = try self.expect(.identifier);
    _ = try self.expect(.equal);
    const value = try self.expression();
    _ = try self.expect(.semicolon);
    return .{ .name = name.bytes, .ty = ty, .value = value, .offset = keyword.offset };
}

/// `vec2 scale(vec2 v, float s) { ... }`
fn function(self: *Parser) Error!ast.Function {
    const at = self.peek().offset;
    const returns = try self.typeName();
    const name = try self.expect(.identifier);
    _ = try self.expect(.l_paren);

    var params: std.ArrayListUnmanaged(ast.Parameter) = .empty;
    if (!self.check(.r_paren)) {
        while (true) {
            const param_at = self.peek().offset;
            const ty = try self.typeName();
            const param = try self.expect(.identifier);
            try params.append(self.arena, .{ .name = param.bytes, .ty = ty, .offset = param_at });
            if (!self.eat(.comma)) break;
        }
    }
    _ = try self.expect(.r_paren);

    return .{
        .name = name.bytes,
        .returns = returns,
        .params = params.items,
        .body = try self.block(),
        .offset = at,
    };
}

fn typeName(self: *Parser) Error!ast.Type {
    const token = self.peek();
    if (token.kind == .identifier) {
        if (ast.Type.fromName(token.bytes)) |ty| {
            _ = self.advance();
            return ty;
        }
    }
    return self.fail(token.offset, "expected a type, found {s}", .{
        if (token.kind == .identifier) "a name that is not one" else token.kind.describe(),
    });
}

/// The number after a `:`, which is a binding slot and so a plain integer.
fn slotNumber(self: *Parser) Error!u32 {
    const token = try self.expect(.number);
    if (token.isFloatLiteral()) {
        return self.fail(token.offset, "a binding slot is a whole number, not `{s}`", .{token.bytes});
    }
    return std.fmt.parseInt(u32, token.bytes, 10) catch {
        return self.fail(token.offset, "`{s}` is too large for a binding slot", .{token.bytes});
    };
}

// -------------------------------------------------------------------------
// Statements
// -------------------------------------------------------------------------

fn block(self: *Parser) Error![]ast.Stmt {
    const open = try self.expect(.l_brace);
    var statements: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    while (!self.check(.r_brace)) {
        if (self.check(.eof)) return self.fail(open.offset, "this block was never closed", .{});
        try statements.append(self.arena, try self.statement());
    }
    _ = try self.expect(.r_brace);
    return statements.items;
}

fn statement(self: *Parser) Error!ast.Stmt {
    const token = self.peek();
    return switch (token.kind) {
        .l_brace => .{ .kind = .{ .block = try self.block() }, .offset = token.offset },
        .kw_if => self.conditional(),
        .kw_for => self.loop(),
        .kw_while => self.whileLoop(),
        .kw_return => blk: {
            _ = self.advance();
            const value: ?*ast.Expr = if (self.check(.semicolon)) null else try self.expression();
            _ = try self.expect(.semicolon);
            break :blk .{ .kind = .{ .ret = value }, .offset = token.offset };
        },
        .kw_discard => blk: {
            _ = self.advance();
            _ = try self.expect(.semicolon);
            break :blk .{ .kind = .discard, .offset = token.offset };
        },
        else => blk: {
            // A type name followed by a name is a declaration; everything
            // else is an assignment or a bare call.
            if (self.typeAhead(0) != null and self.peekAt(1).kind == .identifier) {
                const declared = try self.declaration();
                _ = try self.expect(.semicolon);
                break :blk .{ .kind = .{ .declare = declared }, .offset = token.offset };
            }
            const statement_kind = try self.assignmentOrCall(token);
            _ = try self.expect(.semicolon);
            break :blk statement_kind;
        },
    };
}

fn declaration(self: *Parser) Error!ast.Stmt.Declare {
    const ty = try self.typeName();
    const name = try self.expect(.identifier);
    const value: ?*ast.Expr = if (self.eat(.equal)) try self.expression() else null;
    return .{ .ty = ty, .name = name.bytes, .value = value };
}

fn assignmentOrCall(self: *Parser, token: lex.Token) Error!ast.Stmt {
    const target = try self.expression();
    const op: ast.AssignOp = switch (self.peek().kind) {
        .equal => .set,
        .plus_equal => .add,
        .minus_equal => .subtract,
        .star_equal => .multiply,
        .slash_equal => .divide,
        else => {
            if (target.kind != .call) {
                return self.fail(token.offset, "this is a value, not a statement; assign it to something or take it out", .{});
            }
            return .{ .kind = .{ .expression = target }, .offset = token.offset };
        },
    };
    _ = self.advance();
    const value = try self.expression();
    return .{
        .kind = .{ .assign = .{ .target = target, .op = op, .value = value } },
        .offset = token.offset,
    };
}

fn conditional(self: *Parser) Error!ast.Stmt {
    const keyword = self.advance();
    _ = try self.expect(.l_paren);
    const cond = try self.expression();
    _ = try self.expect(.r_paren);
    const then = try self.block();

    var otherwise: ?[]ast.Stmt = null;
    if (self.eat(.kw_else)) {
        if (self.check(.kw_if)) {
            // `else if` is one statement in a block of its own, which is what
            // both languages make of it anyway.
            const nested = try self.arena.alloc(ast.Stmt, 1);
            nested[0] = try self.conditional();
            otherwise = nested;
        } else {
            otherwise = try self.block();
        }
    }

    return .{
        .kind = .{ .conditional = .{ .cond = cond, .then = then, .otherwise = otherwise } },
        .offset = keyword.offset,
    };
}

fn loop(self: *Parser) Error!ast.Stmt {
    const keyword = self.advance();
    _ = try self.expect(.l_paren);

    var init_part: ?ast.Stmt.Declare = null;
    if (!self.check(.semicolon)) {
        if (self.typeAhead(0) == null) {
            return self.fail(self.peek().offset, "a `for` starts by declaring its counter, as in `for (int i = 0; ...)`", .{});
        }
        init_part = try self.declaration();
    }
    _ = try self.expect(.semicolon);

    const cond: ?*ast.Expr = if (self.check(.semicolon)) null else try self.expression();
    _ = try self.expect(.semicolon);

    var step: ?ast.Stmt.Assign = null;
    if (!self.check(.r_paren)) {
        const at = self.peek();
        const stepped = try self.assignmentOrCall(at);
        step = switch (stepped.kind) {
            .assign => |assign| assign,
            else => return self.fail(at.offset, "the last part of a `for` assigns to its counter, as in `i += 1`", .{}),
        };
    }
    _ = try self.expect(.r_paren);

    return .{
        .kind = .{ .loop = .{ .init = init_part, .cond = cond, .step = step, .body = try self.block() } },
        .offset = keyword.offset,
    };
}

fn whileLoop(self: *Parser) Error!ast.Stmt {
    const keyword = self.advance();
    _ = try self.expect(.l_paren);
    const cond = try self.expression();
    _ = try self.expect(.r_paren);
    return .{
        .kind = .{ .while_loop = .{ .cond = cond, .body = try self.block() } },
        .offset = keyword.offset,
    };
}

// -------------------------------------------------------------------------
// Expressions
//
// Lowest precedence first, each level asking the next one up, which is the
// shape the C family has and the shape both target languages keep.
// -------------------------------------------------------------------------

fn expression(self: *Parser) Error!*ast.Expr {
    return self.ternary();
}

fn ternary(self: *Parser) Error!*ast.Expr {
    const cond = try self.logicalOr();
    if (!self.check(.question)) return cond;
    const at = self.advance();
    const then = try self.expression();
    _ = try self.expect(.colon);
    const other = try self.ternary();
    return self.node(at.offset, .{ .ternary = .{ .cond = cond, .then = then, .other = other } });
}

fn logicalOr(self: *Parser) Error!*ast.Expr {
    var lhs = try self.logicalAnd();
    while (self.check(.or_or)) {
        const at = self.advance();
        const rhs = try self.logicalAnd();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = .logical_or, .lhs = lhs, .rhs = rhs } });
    }
    return lhs;
}

fn logicalAnd(self: *Parser) Error!*ast.Expr {
    var lhs = try self.equality();
    while (self.check(.and_and)) {
        const at = self.advance();
        const rhs = try self.equality();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = .logical_and, .lhs = lhs, .rhs = rhs } });
    }
    return lhs;
}

fn equality(self: *Parser) Error!*ast.Expr {
    var lhs = try self.comparison();
    while (true) {
        const op: ast.BinaryOp = switch (self.peek().kind) {
            .equal_equal => .equal,
            .bang_equal => .not_equal,
            else => return lhs,
        };
        const at = self.advance();
        const rhs = try self.comparison();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }
}

fn comparison(self: *Parser) Error!*ast.Expr {
    var lhs = try self.sum();
    while (true) {
        const op: ast.BinaryOp = switch (self.peek().kind) {
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            else => return lhs,
        };
        const at = self.advance();
        const rhs = try self.sum();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }
}

fn sum(self: *Parser) Error!*ast.Expr {
    var lhs = try self.product();
    while (true) {
        const op: ast.BinaryOp = switch (self.peek().kind) {
            .plus => .add,
            .minus => .subtract,
            else => return lhs,
        };
        const at = self.advance();
        const rhs = try self.product();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }
}

fn product(self: *Parser) Error!*ast.Expr {
    var lhs = try self.unary();
    while (true) {
        const op: ast.BinaryOp = switch (self.peek().kind) {
            .star => .multiply,
            .slash => .divide,
            .percent => .remainder,
            else => return lhs,
        };
        const at = self.advance();
        const rhs = try self.unary();
        lhs = try self.node(at.offset, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }
}

fn unary(self: *Parser) Error!*ast.Expr {
    const op: ast.UnaryOp = switch (self.peek().kind) {
        .minus => .negate,
        .bang => .not,
        else => return self.postfix(),
    };
    const at = self.advance();
    const operand = try self.unary();
    return self.node(at.offset, .{ .unary = .{ .op = op, .operand = operand } });
}

fn postfix(self: *Parser) Error!*ast.Expr {
    var value = try self.primary();
    while (self.check(.dot)) {
        _ = self.advance();
        const name = try self.expect(.identifier);
        value = try self.node(name.offset, .{ .field = .{ .base = value, .name = name.bytes } });
    }
    return value;
}

fn primary(self: *Parser) Error!*ast.Expr {
    const token = self.peek();
    switch (token.kind) {
        .number => {
            _ = self.advance();
            return self.node(token.offset, .{ .number = .{
                .bytes = token.bytes,
                .is_float = token.isFloatLiteral(),
            } });
        },
        .kw_true, .kw_false => {
            _ = self.advance();
            return self.node(token.offset, .{ .boolean = token.kind == .kw_true });
        },
        .l_paren => {
            _ = self.advance();
            const inner = try self.expression();
            _ = try self.expect(.r_paren);
            return inner;
        },
        .identifier => {
            _ = self.advance();
            if (!self.check(.l_paren)) {
                return self.node(token.offset, .{ .name = .{ .text = token.bytes } });
            }
            _ = self.advance();
            var args: std.ArrayListUnmanaged(*ast.Expr) = .empty;
            if (!self.check(.r_paren)) {
                while (true) {
                    try args.append(self.arena, try self.expression());
                    if (!self.eat(.comma)) break;
                }
            }
            _ = try self.expect(.r_paren);
            return self.node(token.offset, .{ .call = .{ .name = token.bytes, .args = args.items } });
        },
        else => return self.fail(token.offset, "expected a value, found {s}", .{token.kind.describe()}),
    }
}

fn node(self: *Parser, offset: u32, kind: ast.Expr.Kind) Error!*ast.Expr {
    const expr = try self.arena.create(ast.Expr);
    expr.* = .{ .kind = kind, .offset = offset };
    return expr;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    program: ast.Program,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn parseSource(source: []const u8, log: *std.Io.Writer) !Parsed {
    var failure: lex.Failure = undefined;
    const tokens = try lex.tokenize(testing.allocator, source, &failure);
    defer testing.allocator.free(tokens);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    var diagnostics: Diagnostics = .init(source, log);
    const parsed = try parse(arena.allocator(), tokens, &diagnostics);
    return .{ .arena = arena, .program = parsed };
}

fn expectRefused(source: []const u8, wanted: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = parseSource(source, &writer);
    if (result) |*ok| {
        var mutable = ok.*;
        mutable.deinit();
        std.debug.print("expected a complaint about `{s}`, got a shader\n", .{wanted});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.ParseFailed, err);
        if (std.mem.indexOf(u8, writer.buffered(), wanted) == null) {
            std.debug.print("expected `{s}` in:\n{s}\n", .{ wanted, writer.buffered() });
            return error.TestUnexpectedResult;
        }
    }
}

const sprite_source =
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\varying vec2 uv;
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    float time;
    \\}
    \\texture2d atlas : 0;
    \\const float pi = 3.14159;
    \\
    \\vec2 scale(vec2 v, float s) {
    \\    return v * s;
    \\}
    \\
    \\vertex {
    \\    vec2 world = placement.xy + scale(corner, placement.z);
    \\    uv = corner;
    \\    position = projection * vec4(world, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = sample(atlas, uv);
    \\}
;

test "a whole shader comes back as its parts" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var parsed = try parseSource(sprite_source, &writer);
    defer parsed.deinit();
    const p = parsed.program;

    try testing.expectEqual(@as(usize, 2), p.attributes.len);
    try testing.expectEqualStrings("corner", p.attributes[0].name);
    try testing.expectEqual(ast.Type.vec2, p.attributes[0].ty);
    try testing.expectEqual(@as(u32, 1), p.attributes[1].location);

    try testing.expectEqual(@as(usize, 1), p.varyings.len);
    try testing.expectEqualStrings("uv", p.varyings[0].name);

    try testing.expectEqual(@as(usize, 1), p.blocks.len);
    try testing.expectEqualStrings("Frame", p.blocks[0].name);
    try testing.expectEqual(@as(usize, 2), p.blocks[0].fields.len);
    try testing.expectEqualStrings("projection", p.blocks[0].fields[0].name);
    try testing.expectEqual(ast.Type.float, p.blocks[0].fields[1].ty);

    try testing.expectEqual(@as(usize, 1), p.textures.len);
    try testing.expectEqualStrings("atlas", p.textures[0].name);

    try testing.expectEqual(@as(usize, 1), p.constants.len);
    try testing.expectEqual(@as(usize, 1), p.functions.len);
    try testing.expectEqualStrings("scale", p.functions[0].name);
    try testing.expectEqual(@as(usize, 2), p.functions[0].params.len);

    try testing.expect(p.vertex != null);
    try testing.expect(p.fragment != null);
    try testing.expectEqual(@as(usize, 3), p.vertex.?.body.len);
}

test "precedence is the one the C family has" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var parsed = try parseSource("vertex { float x = 1.0 + 2.0 * 3.0; }", &writer);
    defer parsed.deinit();

    // The top of the tree is the add, so the multiply bound tighter.
    const value = parsed.program.vertex.?.body[0].kind.declare.value.?;
    try testing.expectEqual(ast.BinaryOp.add, value.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.multiply, value.kind.binary.rhs.kind.binary.op);
}

test "a parenthesis moves it" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var parsed = try parseSource("vertex { float x = (1.0 + 2.0) * 3.0; }", &writer);
    defer parsed.deinit();

    const value = parsed.program.vertex.?.body[0].kind.declare.value.?;
    try testing.expectEqual(ast.BinaryOp.multiply, value.kind.binary.op);
    try testing.expectEqual(ast.BinaryOp.add, value.kind.binary.lhs.kind.binary.op);
}

test "control flow reads as it is written" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var parsed = try parseSource(
        \\fragment {
        \\    float total = 0.0;
        \\    for (int i = 0; i < 4; i += 1) {
        \\        total += 1.0;
        \\    }
        \\    if (total > 2.0) {
        \\        discard;
        \\    } else if (total > 1.0) {
        \\        total = 1.0;
        \\    } else {
        \\        while (total < 1.0) { total += 0.5; }
        \\    }
        \\    target = vec4(total);
        \\}
    , &writer);
    defer parsed.deinit();

    const body = parsed.program.fragment.?.body;
    try testing.expectEqual(@as(usize, 4), body.len);

    const for_loop = body[1].kind.loop;
    try testing.expectEqualStrings("i", for_loop.init.?.name);
    try testing.expect(for_loop.cond != null);
    try testing.expectEqual(ast.AssignOp.add, for_loop.step.?.op);

    const branch = body[2].kind.conditional;
    try testing.expectEqual(ast.Stmt.Kind.discard, std.meta.activeTag(branch.then[0].kind));
    // `else if` became one conditional inside the else block.
    try testing.expectEqual(@as(usize, 1), branch.otherwise.?.len);
    const nested = branch.otherwise.?[0].kind.conditional;
    try testing.expectEqual(ast.Stmt.Kind.while_loop, std.meta.activeTag(nested.otherwise.?[0].kind));
}

test "a swizzle chain is a chain of fields" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var parsed = try parseSource("vertex { float x = a.xy.y; }", &writer);
    defer parsed.deinit();

    const value = parsed.program.vertex.?.body[0].kind.declare.value.?;
    try testing.expectEqualStrings("y", value.kind.field.name);
    try testing.expectEqualStrings("xy", value.kind.field.base.kind.field.name);
    try testing.expectEqualStrings("a", value.kind.field.base.kind.field.base.kind.name.text);
}

test "what the parser refuses, and what it says" {
    try expectRefused("vertex { position = ; }", "expected a value");
    try expectRefused("vertex { position = vec4(1.0) }", "expected `;`");
    try expectRefused("attribute vec2 corner;", "expected `:`");
    try expectRefused("attribute vec2 corner : 0.5;", "whole number");
    try expectRefused("attribute nonsense corner : 0;", "expected a type");
    try expectRefused("vec4 loose;", "has to be `const`");
    try expectRefused("nonsense;", "not a type");
    try expectRefused("vertex { } vertex { }", "a second vertex stage");
    try expectRefused("uniform Frame : 0 { mat4 m;", "never closed");
    try expectRefused("vertex { float x = 1.0; ", "never closed");
    try expectRefused("vertex { 1.0 + 2.0; }", "not a statement");
    try expectRefused("vertex { for (i = 0; i < 4; i += 1) { } }", "declaring its counter");
    try expectRefused("vertex { for (int i = 0; i < 4; i) { } }", "not a statement");
    try expectRefused("vertex { for (int i = 0; i < 4; nothing()) { } }", "assigns to its counter");
}
