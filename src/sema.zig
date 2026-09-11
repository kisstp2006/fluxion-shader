// SPDX-License-Identifier: BSL-1.0

//! What the tree means, and whether it means anything.
//!
//! Every name is resolved to the thing it names, every expression is given a
//! type, and every call is matched against what it is calling. The emitters
//! read all three: `a * b` is one operator on two floats and another on a
//! matrix and a vector, and only a type says which.
//!
//! **Errors are counted, not thrown.** A type error in one statement does not
//! stop the next one being checked, so a shader with three mistakes in it
//! reports three. An expression that went wrong takes the type `void`, and
//! everything built on `void` is left alone - one complaint per mistake,
//! rather than one per use of it.
//!
//! **A function may not touch a stage.** Parameters, locals, constants,
//! uniform fields and textures, and nothing else: no attributes, no varyings,
//! no `position`, no `target`. That is not tidiness. Every function is
//! emitted into both the vertex and the fragment source, and one that read an
//! attribute could not be.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const Diagnostics = @import("diag.zig");

pub const Error = error{CheckFailed} || Allocator.Error;

/// Which stage a body belongs to, or neither.
pub const Where = enum { vertex, fragment, function };

const Sema = @This();

arena: Allocator,
program: *ast.Program,
diagnostics: *Diagnostics,
locals: std.ArrayListUnmanaged(Local) = .empty,
depth: u32 = 0,
where: Where = .function,
returns: ast.Type = .void,
/// What has been reached, so that what has not can be named at the end. A
/// texture or a block the driver would strip is a binding that fails later
/// with a message about something else.
used_textures: []bool = &.{},
used_blocks: []bool = &.{},
written_varyings: []bool = &.{},

const Local = struct {
    name: []const u8,
    ty: ast.Type,
    depth: u32,
};

/// Resolve and type-check a whole program, in place.
pub fn check(arena: Allocator, program: *ast.Program, diagnostics: *Diagnostics) Error!void {
    var self: Sema = .{ .arena = arena, .program = program, .diagnostics = diagnostics };
    try self.run();
    if (diagnostics.failed()) return error.CheckFailed;
}

fn run(self: *Sema) Error!void {
    try self.checkDeclarations();

    self.used_textures = try self.arena.alloc(bool, self.program.textures.len);
    @memset(self.used_textures, false);
    self.used_blocks = try self.arena.alloc(bool, self.program.blocks.len);
    @memset(self.used_blocks, false);
    self.written_varyings = try self.arena.alloc(bool, self.program.varyings.len);
    @memset(self.written_varyings, false);

    for (self.program.constants) |*c| {
        self.where = .function;
        self.depth = 0;
        self.locals.clearRetainingCapacity();
        const ty = try self.expression(c.value);
        _ = self.coerce(c.value, c.ty, ty, "this constant");
    }

    for (self.program.functions, 0..) |*f, index| {
        _ = index;
        self.where = .function;
        self.returns = f.returns;
        self.depth = 0;
        self.locals.clearRetainingCapacity();
        for (f.params) |param| try self.declareLocal(param.name, param.ty, param.offset);
        try self.body(f.body);
        if (f.returns != .void and !returnsEverywhere(f.body)) {
            self.diagnostics.report(f.offset, "`{s}` returns {s}, and this path reaches the end without returning one", .{
                f.name, f.returns.glsl(),
            });
        }
    }

    if (self.program.vertex) |*stage| {
        self.where = .vertex;
        self.returns = .void;
        self.depth = 0;
        self.locals.clearRetainingCapacity();
        try self.body(stage.body);
        if (!writesTo(stage.body, .position)) {
            self.diagnostics.report(stage.offset, "the vertex stage never writes `position`, so nothing would be drawn", .{});
        }
    } else {
        self.diagnostics.report(0, "there is no vertex stage; a shader needs one", .{});
    }

    if (self.program.fragment) |*stage| {
        self.where = .fragment;
        self.returns = .void;
        self.depth = 0;
        self.locals.clearRetainingCapacity();
        try self.body(stage.body);
        if (!writesTo(stage.body, .target)) {
            self.diagnostics.report(stage.offset, "the fragment stage never writes `target`, so it has no colour to give", .{});
        }
    } else {
        self.diagnostics.report(0, "there is no fragment stage; a shader needs one", .{});
    }

    self.reportUnused();
}

/// What was declared and never reached.
///
/// Not tidiness either: a driver removes a uniform block nothing reads and a
/// sampler nothing samples, and the binding a program then asks for by name
/// is not there. The failure lands at pipeline creation, a long way from the
/// line that caused it, so it is named here instead.
fn reportUnused(self: *Sema) void {
    for (self.program.textures, self.used_textures) |t, used| {
        if (!used) self.diagnostics.report(t.offset, "`{s}` is declared and never sampled; a driver would remove it and binding it would then fail", .{t.name});
    }
    for (self.program.blocks, self.used_blocks) |b, used| {
        if (!used) self.diagnostics.report(b.offset, "nothing reads any field of `{s}`; a driver would remove the block and binding it would then fail", .{b.name});
    }
    for (self.program.varyings, self.written_varyings) |v, written| {
        if (!written) self.diagnostics.report(v.offset, "`{s}` is never written by the vertex stage, so the fragment stage would read whatever was there", .{v.name});
    }
}

// -------------------------------------------------------------------------
// The declarations, and what they may not be called
// -------------------------------------------------------------------------

fn checkDeclarations(self: *Sema) Error!void {
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(self.arena);

    const Slots = struct {
        fn clash(
            sema: *Sema,
            used: *std.AutoHashMapUnmanaged(u32, void),
            slot: u32,
            offset: u32,
            what: []const u8,
        ) Allocator.Error!void {
            const gop = try used.getOrPut(sema.arena, slot);
            if (gop.found_existing) {
                sema.diagnostics.report(offset, "two {s} share slot {d}", .{ what, slot });
            }
        }
    };

    var locations: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer locations.deinit(self.arena);
    var block_slots: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer block_slots.deinit(self.arena);
    var texture_slots: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer texture_slots.deinit(self.arena);

    for (self.program.attributes) |a| {
        try self.declareGlobal(&seen, a.name, a.offset);
        try Slots.clash(self, &locations, a.location, a.offset, "attributes");
        if (a.ty == .texture2d or a.ty == .bool or a.ty == .void) {
            self.diagnostics.report(a.offset, "an attribute cannot be {s}", .{a.ty.glsl()});
        }
    }
    for (self.program.varyings) |v| {
        try self.declareGlobal(&seen, v.name, v.offset);
        if (!v.ty.isNumeric() or v.ty.isMatrix()) {
            self.diagnostics.report(v.offset, "a varying is a float or a vector, not {s}", .{v.ty.glsl()});
        }
    }
    for (self.program.textures) |t| {
        try self.declareGlobal(&seen, t.name, t.offset);
        try Slots.clash(self, &texture_slots, t.slot, t.offset, "textures");
    }
    for (self.program.constants) |c| {
        try self.declareGlobal(&seen, c.name, c.offset);
        if (c.ty == .texture2d) self.diagnostics.report(c.offset, "a texture is not a constant", .{});
    }
    for (self.program.functions) |f| {
        try self.declareGlobal(&seen, f.name, f.offset);
        var params: std.StringHashMapUnmanaged(void) = .empty;
        defer params.deinit(self.arena);
        for (f.params) |p| {
            self.checkName(p.name, p.offset);
            const gop = try params.getOrPut(self.arena, p.name);
            if (gop.found_existing) {
                self.diagnostics.report(p.offset, "`{s}` is already a parameter of `{s}`", .{ p.name, f.name });
            }
        }
    }

    // The block's own name goes into the same pool - it is a `cbuffer` name
    // in one language and a block name in the other, and neither lets it
    // clash - and its fields are reachable without it, so they do too.
    for (self.program.blocks) |*block| {
        try self.declareGlobal(&seen, block.name, block.offset);
        try Slots.clash(self, &block_slots, block.slot, block.offset, "uniform blocks");
        try self.layOutBlock(block, &seen);
    }
}

fn declareGlobal(
    self: *Sema,
    seen: *std.StringHashMapUnmanaged(u32),
    text: []const u8,
    offset: u32,
) Allocator.Error!void {
    self.checkName(text, offset);
    const gop = try seen.getOrPut(self.arena, text);
    if (gop.found_existing) {
        self.diagnostics.report(offset, "`{s}` is declared twice", .{text});
    }
    gop.value_ptr.* = offset;
}

/// Where a field of a uniform block starts, and how big the block is.
///
/// The rules `std140` and a Direct3D constant buffer agree on: a value is
/// aligned to its own size, up to sixteen bytes, and the block is rounded up
/// to sixteen. They agree because the language has nothing in a block that
/// they disagree about - no arrays and no nested structs. See the README.
fn layOutBlock(
    self: *Sema,
    block: *ast.UniformBlock,
    seen: *std.StringHashMapUnmanaged(u32),
) Allocator.Error!void {
    var offset: u32 = 0;
    for (block.fields) |*field| {
        try self.declareGlobal(seen, field.name, field.offset);
        if (!field.ty.isNumeric()) {
            self.diagnostics.report(field.offset, "a uniform block holds numbers, not {s}", .{field.ty.glsl()});
            continue;
        }
        const alignment = field.ty.alignmentInBlock();
        offset = std.mem.alignForward(u32, offset, alignment);
        field.byte_offset = offset;
        offset += field.ty.sizeInBlock();
    }
    block.size = std.mem.alignForward(u32, offset, 16);
}

/// Names that would come out of the emitter as something the driver already
/// means. Not every keyword of both languages - the ones a shader author
/// reaches for.
const reserved = std.StaticStringMap(void).initComptime(.{
    .{"main"},        .{"input"},        .{"output"},      .{"position"},        .{"target"},
    .{"sample"},      .{"texture"},      .{"sampler"},     .{"cbuffer"},         .{"register"},
    .{"struct"},      .{"in"},           .{"out"},         .{"inout"},           .{"uniform"},
    .{"varying"},     .{"attribute"},    .{"layout"},      .{"precision"},       .{"discard"},
    .{"matrix"},      .{"vector"},       .{"row_major"},   .{"column_major"},    .{"static"},
    .{"groupshared"}, .{"linear"},       .{"centroid"},    .{"nointerpolation"}, .{"noperspective"},
    .{"float2"},      .{"float3"},       .{"float4"},      .{"float2x2"},        .{"float3x3"},
    .{"float4x4"},    .{"half"},         .{"double"},      .{"dword"},           .{"lerp"},
    .{"frac"},        .{"rsqrt"},        .{"ddx"},         .{"ddy"},             .{"mul"},
    .{"gl_Position"}, .{"gl_FragCoord"}, .{"gl_VertexID"}, .{"gl_InstanceID"},   .{"technique"},
    // The precisions GLSL ES writes before a type, and which the ES output
    // declares at the top of every stage.
    .{"lowp"},        .{"mediump"},      .{"highp"},
});

fn checkName(self: *Sema, text: []const u8, offset: u32) void {
    if (ast.Type.fromName(text) != null) {
        self.diagnostics.report(offset, "`{s}` is a type, so nothing may be called that", .{text});
        return;
    }
    if (ast.Builtin.fromName(text) != null) {
        self.diagnostics.report(offset, "`{s}` is a function this language brings with it", .{text});
        return;
    }
    if (reserved.has(text)) {
        self.diagnostics.report(offset, "`{s}` means something to GLSL or to HLSL, so it cannot be a name here", .{text});
        return;
    }
    if (std.ascii.startsWithIgnoreCase(text, "fluxion") or std.mem.startsWith(u8, text, "gl_")) {
        self.diagnostics.report(offset, "names starting `{s}` are the emitter's, not yours", .{
            if (std.mem.startsWith(u8, text, "gl_")) "gl_" else "fluxion",
        });
    }
}

// -------------------------------------------------------------------------
// Statements
// -------------------------------------------------------------------------

fn body(self: *Sema, statements: []ast.Stmt) Error!void {
    self.depth += 1;
    defer self.popScope();
    for (statements) |*stmt| try self.statement(stmt);
}

fn popScope(self: *Sema) void {
    var keep: usize = self.locals.items.len;
    while (keep > 0 and self.locals.items[keep - 1].depth >= self.depth) keep -= 1;
    self.locals.shrinkRetainingCapacity(keep);
    self.depth -= 1;
}

fn statement(self: *Sema, stmt: *ast.Stmt) Error!void {
    switch (stmt.kind) {
        .declare => |*declared| try self.declareStatement(declared, stmt.offset),
        .assign => |*assign| try self.assignment(assign, stmt.offset),
        .expression => |call| {
            const ty = try self.expression(call);
            _ = ty;
            if (call.kind != .call) {
                self.diagnostics.report(stmt.offset, "this does nothing", .{});
            }
        },
        .conditional => |*branch| {
            const ty = try self.expression(branch.cond);
            if (ty != .void and ty != .bool) {
                self.diagnostics.report(branch.cond.offset, "an `if` takes a bool, not {s}", .{ty.glsl()});
            }
            try self.body(branch.then);
            if (branch.otherwise) |otherwise| try self.body(otherwise);
        },
        .loop => |*it| {
            self.depth += 1;
            defer self.popScope();
            if (it.init) |*declared| try self.declareStatement(declared, stmt.offset);
            if (it.cond) |cond| {
                const ty = try self.expression(cond);
                if (ty != .void and ty != .bool) {
                    self.diagnostics.report(cond.offset, "a `for` runs while a bool is true, not {s}", .{ty.glsl()});
                }
            }
            if (it.step) |*step| try self.assignment(step, stmt.offset);
            try self.body(it.body);
        },
        .while_loop => |*it| {
            const ty = try self.expression(it.cond);
            if (ty != .void and ty != .bool) {
                self.diagnostics.report(it.cond.offset, "a `while` runs while a bool is true, not {s}", .{ty.glsl()});
            }
            try self.body(it.body);
        },
        .ret => |value| {
            if (self.where != .function) {
                self.diagnostics.report(stmt.offset, "a stage ends when it ends; there is nothing to return to", .{});
                return;
            }
            if (value) |expr| {
                const ty = try self.expression(expr);
                _ = self.coerce(expr, self.returns, ty, "this return");
            } else if (self.returns != .void) {
                self.diagnostics.report(stmt.offset, "this returns {s}, so it needs a value", .{self.returns.glsl()});
            }
        },
        .discard => if (self.where != .fragment) {
            self.diagnostics.report(stmt.offset, "only the fragment stage can `discard`", .{});
        },
        .block => |inner| try self.body(inner),
    }
}

fn declareStatement(self: *Sema, declared: *ast.Stmt.Declare, offset: u32) Error!void {
    if (declared.ty == .texture2d or declared.ty == .void) {
        self.diagnostics.report(offset, "a local cannot be {s}", .{declared.ty.glsl()});
    }
    if (declared.value) |value| {
        const ty = try self.expression(value);
        _ = self.coerce(value, declared.ty, ty, "this value");
    }
    try self.declareLocal(declared.name, declared.ty, offset);
}

fn declareLocal(self: *Sema, text: []const u8, ty: ast.Type, offset: u32) Error!void {
    self.checkName(text, offset);
    for (self.locals.items) |local| {
        if (local.depth == self.depth and std.mem.eql(u8, local.name, text)) {
            self.diagnostics.report(offset, "`{s}` is already declared here", .{text});
        }
    }
    try self.locals.append(self.arena, .{ .name = text, .ty = ty, .depth = self.depth });
}

fn assignment(self: *Sema, assign: *ast.Stmt.Assign, offset: u32) Error!void {
    const target = try self.expression(assign.target);
    const value = try self.expression(assign.value);
    if (!self.isAssignable(assign.target)) return;

    // The target went wrong and has already been complained about; saying
    // that a value is not a `void` on top of it helps nobody.
    if (target == .void) return;

    if (self.where == .vertex) {
        var base = assign.target;
        while (base.kind == .field) base = base.kind.field.base;
        if (base.kind == .name) {
            if (base.kind.name.binding == .varying) {
                const index = base.kind.name.binding.varying;
                if (index < self.written_varyings.len) self.written_varyings[index] = true;
            }
        }
    }

    if (assign.op.binary()) |op| {
        // `a += b` is `a = a + b`, so it is checked as one.
        const result = self.binaryResult(op, target, value, assign.value.offset) orelse return;
        if (result != target) {
            self.diagnostics.report(offset, "`{s}` on {s} and {s} gives {s}, which is not what it is being assigned to", .{
                assign.op.spelling(), target.glsl(), value.glsl(), result.glsl(),
            });
        }
        return;
    }
    _ = self.coerce(assign.value, target, value, "this value");
}

/// Can this be written to, and by this stage?
fn isAssignable(self: *Sema, target: *ast.Expr) bool {
    var base = target;
    while (base.kind == .field) base = base.kind.field.base;
    if (base.kind != .name) {
        self.diagnostics.report(target.offset, "this is a value, and a value cannot be assigned to", .{});
        return false;
    }
    return switch (base.kind.name.binding) {
        .local => true,
        .position, .target, .varying => true,
        .attribute => {
            self.diagnostics.report(target.offset, "an attribute is what the vertex buffer said; it cannot be written", .{});
            return false;
        },
        .uniform_field => {
            self.diagnostics.report(target.offset, "a uniform is what the program uploaded; it cannot be written", .{});
            return false;
        },
        .constant => {
            self.diagnostics.report(target.offset, "a constant cannot be written", .{});
            return false;
        },
        .texture, .vertex_index, .instance_index => {
            self.diagnostics.report(target.offset, "this cannot be written", .{});
            return false;
        },
    };
}

/// Does every path through these statements return?
fn returnsEverywhere(statements: []const ast.Stmt) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .ret => return true,
            .block => |inner| if (returnsEverywhere(inner)) return true,
            .conditional => |branch| {
                const otherwise = branch.otherwise orelse continue;
                if (returnsEverywhere(branch.then) and returnsEverywhere(otherwise)) return true;
            },
            // A loop may run no times, so it promises nothing.
            else => {},
        }
    }
    return false;
}

/// Is `what` written anywhere in here?
fn writesTo(statements: []const ast.Stmt, what: std.meta.Tag(ast.Binding)) bool {
    for (statements) |stmt| {
        switch (stmt.kind) {
            .assign => |assign| {
                var base = assign.target;
                while (base.kind == .field) base = base.kind.field.base;
                if (base.kind == .name and std.meta.activeTag(base.kind.name.binding) == what) return true;
            },
            .block => |inner| if (writesTo(inner, what)) return true,
            .conditional => |branch| {
                if (writesTo(branch.then, what)) return true;
                if (branch.otherwise) |otherwise| if (writesTo(otherwise, what)) return true;
            },
            .loop => |it| if (writesTo(it.body, what)) return true,
            .while_loop => |it| if (writesTo(it.body, what)) return true,
            else => {},
        }
    }
    return false;
}

// -------------------------------------------------------------------------
// Expressions
// -------------------------------------------------------------------------

fn expression(self: *Sema, expr: *ast.Expr) Error!ast.Type {
    expr.ty = switch (expr.kind) {
        .number => |number| if (number.is_float) .float else .int,
        .boolean => .bool,
        .name => try self.nameExpr(expr),
        .field => try self.fieldExpr(expr),
        .call => try self.callExpr(expr),
        .unary => |unary| blk: {
            const ty = try self.expression(unary.operand);
            if (ty == .void) break :blk .void;
            switch (unary.op) {
                .negate => if (!ty.isNumeric()) {
                    self.diagnostics.report(expr.offset, "there is no negative of a {s}", .{ty.glsl()});
                    break :blk .void;
                },
                .not => if (ty != .bool) {
                    self.diagnostics.report(expr.offset, "`!` takes a bool, not {s}", .{ty.glsl()});
                    break :blk .void;
                },
            }
            break :blk ty;
        },
        .binary => |binary| blk: {
            const lhs = try self.expression(binary.lhs);
            const rhs = try self.expression(binary.rhs);
            break :blk self.binaryResult(binary.op, lhs, rhs, expr.offset) orelse .void;
        },
        .ternary => |ternary| blk: {
            const cond = try self.expression(ternary.cond);
            const then = try self.expression(ternary.then);
            const other = try self.expression(ternary.other);
            if (cond != .void and cond != .bool) {
                self.diagnostics.report(ternary.cond.offset, "the question in `?:` is a bool, not {s}", .{cond.glsl()});
            }
            if (then == .void or other == .void) break :blk .void;
            if (then != other) {
                // One side an integer literal and the other a float is the
                // usual way in, and it costs nothing to allow it.
                if (self.coerceQuietly(ternary.then, other, then)) break :blk other;
                if (self.coerceQuietly(ternary.other, then, other)) break :blk then;
                self.diagnostics.report(expr.offset, "the two answers of `?:` are {s} and {s}", .{ then.glsl(), other.glsl() });
                break :blk .void;
            }
            break :blk then;
        },
    };
    return expr.ty;
}

fn nameExpr(self: *Sema, expr: *ast.Expr) Error!ast.Type {
    const text = expr.kind.name.text;

    // A local shadows everything, and the newest one wins.
    var i = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = self.locals.items[i];
        if (std.mem.eql(u8, local.name, text)) {
            expr.kind.name.binding = .local;
            return local.ty;
        }
    }

    for (self.program.constants, 0..) |c, index| {
        if (std.mem.eql(u8, c.name, text)) {
            expr.kind.name.binding = .{ .constant = @intCast(index) };
            return c.ty;
        }
    }
    for (self.program.blocks, 0..) |block, bi| {
        for (block.fields, 0..) |f, fi| {
            if (std.mem.eql(u8, f.name, text)) {
                expr.kind.name.binding = .{ .uniform_field = .{ .block = @intCast(bi), .field = @intCast(fi) } };
                if (bi < self.used_blocks.len) self.used_blocks[bi] = true;
                return f.ty;
            }
        }
    }
    for (self.program.textures, 0..) |t, index| {
        if (std.mem.eql(u8, t.name, text)) {
            expr.kind.name.binding = .{ .texture = @intCast(index) };
            if (index < self.used_textures.len) self.used_textures[index] = true;
            return .texture2d;
        }
    }

    // Everything below here belongs to a stage.
    for (self.program.attributes, 0..) |a, index| {
        if (std.mem.eql(u8, a.name, text)) {
            if (self.where != .vertex) {
                self.diagnostics.report(expr.offset, "`{s}` is an attribute, which only the vertex stage has", .{text});
                return .void;
            }
            expr.kind.name.binding = .{ .attribute = @intCast(index) };
            return a.ty;
        }
    }
    for (self.program.varyings, 0..) |v, index| {
        if (std.mem.eql(u8, v.name, text)) {
            if (self.where == .function) {
                self.diagnostics.report(expr.offset, "`{s}` is a varying, and a function is shared by both stages; pass it in", .{text});
                return .void;
            }
            expr.kind.name.binding = .{ .varying = @intCast(index) };
            return v.ty;
        }
    }

    if (std.mem.eql(u8, text, "position")) {
        if (self.where != .vertex) {
            self.diagnostics.report(expr.offset, "`position` belongs to the vertex stage", .{});
            return .void;
        }
        expr.kind.name.binding = .position;
        return .vec4;
    }
    if (std.mem.eql(u8, text, "target")) {
        if (self.where != .fragment) {
            self.diagnostics.report(expr.offset, "`target` belongs to the fragment stage", .{});
            return .void;
        }
        expr.kind.name.binding = .target;
        return .vec4;
    }
    if (std.mem.eql(u8, text, "vertex_index") or std.mem.eql(u8, text, "instance_index")) {
        if (self.where != .vertex) {
            self.diagnostics.report(expr.offset, "`{s}` belongs to the vertex stage", .{text});
            return .void;
        }
        expr.kind.name.binding = if (text[0] == 'v') .vertex_index else .instance_index;
        return .int;
    }

    self.diagnostics.report(expr.offset, "`{s}` is not anything this shader declared", .{text});
    return .void;
}

/// A field is a swizzle, because the only things with parts are vectors.
fn fieldExpr(self: *Sema, expr: *ast.Expr) Error!ast.Type {
    const base = try self.expression(expr.kind.field.base);
    if (base == .void) return .void;
    const letters = expr.kind.field.name;

    if (!base.isVector()) {
        self.diagnostics.report(expr.offset, "a {s} has no `{s}`; only a vector has parts", .{ base.glsl(), letters });
        return .void;
    }
    if (letters.len > 4) {
        self.diagnostics.report(expr.offset, "`{s}` is more than four components", .{letters});
        return .void;
    }

    const width = base.components();
    var set: ?[]const u8 = null;
    for (letters) |letter| {
        const from: []const u8 = if (std.mem.indexOfScalar(u8, "xyzw", letter) != null)
            "xyzw"
        else if (std.mem.indexOfScalar(u8, "rgba", letter) != null)
            "rgba"
        else {
            self.diagnostics.report(expr.offset, "`{c}` is not a component; they are `xyzw` or `rgba`", .{letter});
            return .void;
        };
        if (set) |already| {
            if (already.ptr != from.ptr) {
                self.diagnostics.report(expr.offset, "`{s}` mixes `xyzw` with `rgba`", .{letters});
                return .void;
            }
        } else set = from;

        const at = std.mem.indexOfScalar(u8, from, letter).?;
        if (at >= width) {
            self.diagnostics.report(expr.offset, "a {s} has no `{c}`", .{ base.glsl(), letter });
            return .void;
        }
    }

    return ast.Type.vector(@intCast(letters.len)).?;
}

// -------------------------------------------------------------------------
// Calls
// -------------------------------------------------------------------------

/// How a builtin's arguments and result go together.
const Rule = enum {
    /// Every argument is the same float or vector, or a bare float where the
    /// others are vectors. The result is the widest of them. This is the
    /// overload set GLSL spells out and HLSL promotes into.
    componentwise,
    /// Every argument is exactly the same float or vector; the result is it.
    uniform_width,
    /// Float or vector in, one float out.
    reduce,
    /// Two `vec3`s in, one out.
    cross,
    /// A texture and a `vec2` in, a `vec4` out.
    sample,
    /// A matrix in, the same one out.
    matrix,
};

const Signature = struct {
    min: u8,
    max: u8,
    rule: Rule,
};

fn signatureOf(builtin: ast.Builtin) Signature {
    return switch (builtin) {
        .sample => .{ .min = 2, .max = 2, .rule = .sample },

        .abs, .floor, .ceil, .fract, .sqrt, .inversesqrt, .sin, .cos, .tan, .asin, .acos, .exp, .log, .exp2, .log2, .sign, .saturate, .ddx, .ddy => .{ .min = 1, .max = 1, .rule = .componentwise },
        .normalize => .{ .min = 1, .max = 1, .rule = .uniform_width },
        // One argument is an arc tangent; two is the one that knows which
        // quadrant it is in.
        .atan => .{ .min = 1, .max = 2, .rule = .uniform_width },
        .atan2 => .{ .min = 2, .max = 2, .rule = .uniform_width },

        .min, .max, .mod, .step => .{ .min = 2, .max = 2, .rule = .componentwise },
        .pow, .reflect => .{ .min = 2, .max = 2, .rule = .uniform_width },

        .clamp, .mix, .smoothstep => .{ .min = 3, .max = 3, .rule = .componentwise },

        .length => .{ .min = 1, .max = 1, .rule = .reduce },
        .distance, .dot => .{ .min = 2, .max = 2, .rule = .reduce },
        .cross => .{ .min = 2, .max = 2, .rule = .cross },
        .transpose => .{ .min = 1, .max = 1, .rule = .matrix },
    };
}

fn callExpr(self: *Sema, expr: *ast.Expr) Error!ast.Type {
    const called = expr.kind.call;

    if (ast.Type.fromName(called.name)) |ty| return self.construct(expr, ty);

    for (self.program.functions, 0..) |f, index| {
        if (!std.mem.eql(u8, f.name, called.name)) continue;
        expr.kind.call.target = .{ .user = @intCast(index) };
        if (called.args.len != f.params.len) {
            self.diagnostics.report(expr.offset, "`{s}` takes {d} argument{s}, and this passes {d}", .{
                f.name, f.params.len, if (f.params.len == 1) "" else "s", called.args.len,
            });
        }
        for (called.args, 0..) |arg, i| {
            const ty = try self.expression(arg);
            if (i < f.params.len) _ = self.coerce(arg, f.params[i].ty, ty, "this argument");
        }
        return f.returns;
    }

    const builtin = ast.Builtin.fromName(called.name) orelse {
        self.diagnostics.report(expr.offset, "nothing here is called `{s}`", .{called.name});
        for (called.args) |arg| _ = try self.expression(arg);
        return .void;
    };
    expr.kind.call.target = .{ .builtin = builtin };
    return self.builtinCall(expr, builtin);
}

fn builtinCall(self: *Sema, expr: *ast.Expr, builtin: ast.Builtin) Error!ast.Type {
    const args = expr.kind.call.args;
    const signature = signatureOf(builtin);

    var types = try self.arena.alloc(ast.Type, args.len);
    for (args, types) |arg, *ty| ty.* = try self.expression(arg);

    if (args.len < signature.min or args.len > signature.max) {
        if (signature.min == signature.max) {
            self.diagnostics.report(expr.offset, "`{t}` takes {d} argument{s}, and this passes {d}", .{
                builtin, signature.min, if (signature.min == 1) "" else "s", args.len,
            });
        } else {
            self.diagnostics.report(expr.offset, "`{t}` takes {d} or {d} arguments, and this passes {d}", .{
                builtin, signature.min, signature.max, args.len,
            });
        }
        return .void;
    }
    for (types) |ty| if (ty == .void) return .void;

    switch (signature.rule) {
        .sample => {
            if (types[0] != .texture2d) {
                self.diagnostics.report(args[0].offset, "`sample` reads a texture, and this is {s}", .{types[0].glsl()});
                return .void;
            }
            if (!self.coerce(args[1], .vec2, types[1], "the coordinate")) return .void;
            return .vec4;
        },
        .matrix => {
            if (!types[0].isMatrix()) {
                self.diagnostics.report(args[0].offset, "`{t}` takes a matrix, and this is {s}", .{ builtin, types[0].glsl() });
                return .void;
            }
            return types[0];
        },
        .cross => {
            for (args, types) |arg, ty| {
                if (!self.coerce(arg, .vec3, ty, "an argument to `cross`")) return .void;
            }
            return .vec3;
        },
        .reduce, .uniform_width, .componentwise => {
            // The widest argument decides, and the rest have to reach it.
            var widest: ast.Type = .float;
            for (args, types) |arg, ty| {
                if (ty == .float or ty == .int) continue;
                if (!ty.isVector()) {
                    self.diagnostics.report(arg.offset, "`{t}` works on floats and vectors, and this is {s}", .{ builtin, ty.glsl() });
                    return .void;
                }
                if (widest != .float and ty != widest) {
                    self.diagnostics.report(arg.offset, "`{t}` was given both {s} and {s}", .{ builtin, widest.glsl(), ty.glsl() });
                    return .void;
                }
                widest = ty;
            }
            const wanted: ast.Type = switch (signature.rule) {
                // Only `componentwise` lets a bare float stand in among
                // vectors; the others want every argument the same width.
                .componentwise => .float,
                else => widest,
            };
            for (args, types) |arg, ty| {
                if (ty == widest) continue;
                if (!self.coerce(arg, wanted, ty, "an argument")) return .void;
            }
            return if (signature.rule == .reduce) .float else widest;
        },
    }
}

/// `vec3(x, y, z)`, `float(i)`, and the rest.
fn construct(self: *Sema, expr: *ast.Expr, ty: ast.Type) Error!ast.Type {
    const args = expr.kind.call.args;
    expr.kind.call.target = .{ .construct = ty };

    if (ty.isMatrix()) {
        for (args) |arg| _ = try self.expression(arg);
        self.diagnostics.report(expr.offset, "there is no matrix literal: GLSL builds one from columns and HLSL from rows, and this library will not pick one for you. Pass it in a uniform block.", .{});
        return .void;
    }
    if (ty == .texture2d or ty == .void) {
        for (args) |arg| _ = try self.expression(arg);
        self.diagnostics.report(expr.offset, "a {s} cannot be made out of anything", .{ty.glsl()});
        return .void;
    }

    var types = try self.arena.alloc(ast.Type, args.len);
    for (args, types) |arg, *at| at.* = try self.expression(arg);
    for (types) |at| if (at == .void) return .void;

    if (ty.isScalar()) {
        if (args.len != 1) {
            self.diagnostics.report(expr.offset, "`{s}` converts one value, and this passes {d}", .{ ty.glsl(), args.len });
            return .void;
        }
        if (!types[0].isScalar()) {
            self.diagnostics.report(args[0].offset, "`{s}` converts a scalar, and this is {s}", .{ ty.glsl(), types[0].glsl() });
            return .void;
        }
        return ty;
    }

    // A vector: one scalar fills it, or the parts add up to its width.
    const width = ty.components();
    if (args.len == 1 and types[0].isScalar()) {
        _ = self.coerce(args[0], .float, types[0], "this value");
        return ty;
    }

    var total: u32 = 0;
    for (args, types) |arg, at| {
        if (at == .int) {
            _ = self.coerce(arg, .float, at, "this part");
            total += 1;
            continue;
        }
        if (at != .float and !at.isVector()) {
            self.diagnostics.report(arg.offset, "a {s} is not part of a vector", .{at.glsl()});
            return .void;
        }
        total += at.components();
    }
    if (total != width) {
        self.diagnostics.report(expr.offset, "`{s}` wants {d} components, and this gives {d}", .{ ty.glsl(), width, total });
        return .void;
    }
    return ty;
}

// -------------------------------------------------------------------------
// The rules of the operators
// -------------------------------------------------------------------------

fn binaryResult(self: *Sema, op: ast.BinaryOp, lhs: ast.Type, rhs: ast.Type, offset: u32) ?ast.Type {
    if (lhs == .void or rhs == .void) return null;

    if (op.isLogical()) {
        if (lhs != .bool or rhs != .bool) {
            self.diagnostics.report(offset, "`{s}` joins two bools, and these are {s} and {s}", .{ op.spelling(), lhs.glsl(), rhs.glsl() });
            return null;
        }
        return .bool;
    }

    if (op.isComparison()) {
        // Scalars only. GLSL's `==` on two vectors is one bool and HLSL's is
        // a vector of them, and a library that emitted both from one line
        // would be handing back a different answer on each backend.
        if (!lhs.isScalar() or !rhs.isScalar()) {
            self.diagnostics.report(offset, "`{s}` compares two scalars; compare the components you mean", .{op.spelling()});
            return null;
        }
        if (lhs != rhs) {
            self.diagnostics.report(offset, "`{s}` compares two of the same, and these are {s} and {s}", .{ op.spelling(), lhs.glsl(), rhs.glsl() });
            return null;
        }
        return .bool;
    }

    if (op == .remainder) {
        if (lhs != .int or rhs != .int) {
            self.diagnostics.report(offset, "`%` is for whole numbers; `mod` is the one for floats", .{});
            return null;
        }
        return .int;
    }

    if (!lhs.isNumeric() or !rhs.isNumeric()) {
        self.diagnostics.report(offset, "`{s}` needs numbers, and these are {s} and {s}", .{ op.spelling(), lhs.glsl(), rhs.glsl() });
        return null;
    }

    if (lhs == rhs) {
        // Two matrices multiplied is a matrix product, not sixteen products.
        return lhs;
    }

    // A matrix against a vector, which is the whole point of having matrices.
    if (op == .multiply) {
        if (lhs.isMatrix() and rhs.isVector()) {
            if (lhs.dimension() != rhs.components()) {
                self.diagnostics.report(offset, "a {s} multiplies a {s}, not a {s}", .{
                    lhs.glsl(), ast.Type.vector(lhs.dimension()).?.glsl(), rhs.glsl(),
                });
                return null;
            }
            return rhs;
        }
        if (lhs.isVector() and rhs.isMatrix()) {
            if (rhs.dimension() != lhs.components()) {
                self.diagnostics.report(offset, "a {s} multiplies a {s}, not a {s}", .{
                    rhs.glsl(), ast.Type.vector(rhs.dimension()).?.glsl(), lhs.glsl(),
                });
                return null;
            }
            return lhs;
        }
    }

    // Anything else against a lone number is that thing, componentwise.
    if (rhs == .float or rhs == .int) return lhs;
    if (lhs == .float or lhs == .int) return rhs;

    self.diagnostics.report(offset, "`{s}` is not defined between {s} and {s}", .{ op.spelling(), lhs.glsl(), rhs.glsl() });
    return null;
}

/// Make `expr` a `wanted`, or say why it cannot be.
fn coerce(self: *Sema, expr: *ast.Expr, wanted: ast.Type, actual: ast.Type, what: []const u8) bool {
    if (actual == .void) return false;
    if (self.coerceQuietly(expr, wanted, actual)) return true;
    self.diagnostics.report(expr.offset, "{s} is {s}, and a {s} was wanted", .{ what, actual.glsl(), wanted.glsl() });
    return false;
}

/// The one conversion this language does on its own: a whole number written
/// where a float belongs. It happens to the literal rather than around it, so
/// `1` becomes `1.0` in the emitted source and no cast appears anywhere.
fn coerceQuietly(self: *Sema, expr: *ast.Expr, wanted: ast.Type, actual: ast.Type) bool {
    _ = self;
    if (actual == wanted) return true;
    if (wanted == .float and actual == .int and expr.kind == .number) {
        expr.kind.number.is_float = true;
        expr.ty = .float;
        return true;
    }
    return false;
}
