// SPDX-License-Identifier: BSL-1.0

//! The tree, written out as HLSL for shader model 5.0.
//!
//! The harder of the two, because Direct3D has no globals a stage reads and
//! writes: a vertex shader takes a struct and returns a struct, and the
//! semantics on their members are what tie the two ends together. So a name
//! that was `corner` on the way in comes out as `fluxion_in.corner`, and a
//! `varying` written in the vertex stage becomes a member of the struct that
//! stage returns.
//!
//! | This language | HLSL |
//! | --- | --- |
//! | `attribute x : n` | a member of the input struct, semantic `ATTRn` |
//! | `varying x` | a member of the struct the vertex stage returns, `TEXCOORDn` |
//! | `position` | that struct's `SV_POSITION` member |
//! | `target` | the value the fragment stage returns, `SV_TARGET` |
//! | `vertex_index` | `SV_VertexID` |
//! | `sample(t, uv)` | `t.Sample(t_sampler, uv)` |
//! | `fract`, `mix`, `inversesqrt` | `frac`, `lerp`, `rsqrt` |
//! | `m * v` | `mul(m, v)` |
//! | `vec4(x)` for one scalar `x` | `((float4)(x))` |
//!
//! **`ATTRn` is the semantic because the number is the whole point.** A
//! program says `location = 3` on one backend and `ATTR3` on the other, and
//! those have to be the same thing without anybody writing them twice.
//!
//! **`mod` is not `fmod`.** HLSL's takes the sign of the numerator and
//! GLSL's does not, which differs for every negative input. What comes out
//! here is GLSL's definition written down: `a - b * floor(a / b)`. It
//! evaluates both twice, which costs nothing that matters and is why no
//! expression in this language may have an effect.

const std = @import("std");
const ast = @import("ast.zig");
const sema = @import("sema.zig");

/// What the emitter calls the things a shader author cannot: `sema` refuses
/// any name beginning `fluxion`, so none of these can be taken.
pub const input_struct = "FluxionInput";
pub const varyings_struct = "FluxionVaryings";
pub const input_value = "fluxion_in";
pub const output_value = "fluxion_out";
pub const position_member = "fluxion_position";
pub const target_value = "fluxion_target";
pub const vertex_index_member = "fluxion_vertex_index";
pub const instance_index_member = "fluxion_instance_index";

const Emitter = struct {
    program: *const ast.Program,
    w: *std.Io.Writer,
    stage: sema.Where,
    depth: u32 = 1,

    const Error = std.Io.Writer.Error;

    fn indent(self: *Emitter) Error!void {
        for (0..self.depth) |_| try self.w.writeAll("    ");
    }
};

/// Write one stage.
pub fn emit(
    program: *const ast.Program,
    stage: sema.Where,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var e: Emitter = .{ .program = program, .w = w, .stage = stage };

    for (program.blocks) |b| {
        try w.print("cbuffer {s} : register(b{d}) {{\n", .{ b.name, b.slot });
        for (b.fields) |field| {
            try w.print("    {s} {s};\n", .{ field.ty.hlsl(), field.name });
        }
        try w.writeAll("};\n\n");
    }

    for (program.textures) |t| {
        try w.print("Texture2D {s} : register(t{d});\n", .{ t.name, t.slot });
        try w.print("SamplerState {s}_sampler : register(s{d});\n", .{ t.name, t.slot });
    }
    if (program.textures.len > 0) try w.writeByte('\n');

    for (program.constants) |c| {
        try w.print("static const {s} {s} = ", .{ c.ty.hlsl(), c.name });
        try expression(&e, c.value);
        try w.writeAll(";\n");
    }
    if (program.constants.len > 0) try w.writeByte('\n');

    // The two structs. The vertex stage takes the first and returns the
    // second; the fragment stage takes the second.
    if (stage == .vertex) {
        try w.print("struct {s} {{\n", .{input_struct});
        for (program.attributes) |a| {
            try w.print("    {s} {s} : ATTR{d};\n", .{ a.ty.hlsl(), a.name, a.location });
        }
        if (uses(program.vertex.?.body, .vertex_index)) {
            try w.print("    uint {s} : SV_VertexID;\n", .{vertex_index_member});
        }
        if (uses(program.vertex.?.body, .instance_index)) {
            try w.print("    uint {s} : SV_InstanceID;\n", .{instance_index_member});
        }
        try w.writeAll("};\n\n");
    }

    try w.print("struct {s} {{\n", .{varyings_struct});
    try w.print("    float4 {s} : SV_POSITION;\n", .{position_member});
    for (program.varyings, 0..) |v, index| {
        try w.print("    {s} {s} : TEXCOORD{d};\n", .{ v.ty.hlsl(), v.name, index });
    }
    try w.writeAll("};\n\n");

    if (program.functions.len > 0) {
        for (program.functions) |f| {
            try signature(&e, f);
            try w.writeAll(";\n");
        }
        try w.writeByte('\n');
        for (program.functions) |f| {
            try signature(&e, f);
            try w.writeAll(" {\n");
            try body(&e, f.body);
            try w.writeAll("}\n\n");
        }
    }

    if (stage == .vertex) {
        try w.print("{s} main({s} {s}) {{\n", .{ varyings_struct, input_struct, input_value });
        try w.print("    {s} {s};\n", .{ varyings_struct, output_value });
        try body(&e, program.vertex.?.body);
        try w.print("    return {s};\n}}\n", .{output_value});
    } else {
        try w.print("float4 main({s} {s}) : SV_TARGET {{\n", .{ varyings_struct, input_value });
        try w.print("    float4 {s};\n", .{target_value});
        try body(&e, program.fragment.?.body);
        try w.print("    return {s};\n}}\n", .{target_value});
    }
}

fn signature(self: *Emitter, f: ast.Function) Emitter.Error!void {
    try self.w.print("{s} {s}(", .{ f.returns.hlsl(), f.name });
    for (f.params, 0..) |param, i| {
        if (i > 0) try self.w.writeAll(", ");
        try self.w.print("{s} {s}", .{ param.ty.hlsl(), param.name });
    }
    try self.w.writeByte(')');
}

/// Is one of the stage's own inputs read anywhere in here? Only the two
/// index builtins need asking about, because they cost a struct member.
fn uses(statements: []const ast.Stmt, what: std.meta.Tag(ast.Binding)) bool {
    for (statements) |stmt| {
        const found = switch (stmt.kind) {
            .declare => |d| if (d.value) |v| usesExpr(v, what) else false,
            .assign => |a| usesExpr(a.target, what) or usesExpr(a.value, what),
            .expression => |e| usesExpr(e, what),
            .conditional => |c| usesExpr(c.cond, what) or uses(c.then, what) or
                (if (c.otherwise) |o| uses(o, what) else false),
            .loop => |l| (if (l.init) |i| (if (i.value) |v| usesExpr(v, what) else false) else false) or
                (if (l.cond) |c| usesExpr(c, what) else false) or
                (if (l.step) |s| usesExpr(s.value, what) else false) or
                uses(l.body, what),
            .while_loop => |l| usesExpr(l.cond, what) or uses(l.body, what),
            .ret => |v| if (v) |value| usesExpr(value, what) else false,
            .discard => false,
            .block => |inner| uses(inner, what),
        };
        if (found) return true;
    }
    return false;
}

fn usesExpr(expr: *const ast.Expr, what: std.meta.Tag(ast.Binding)) bool {
    return switch (expr.kind) {
        .name => |named| std.meta.activeTag(named.binding) == what,
        .field => |f| usesExpr(f.base, what),
        .call => |c| blk: {
            for (c.args) |arg| if (usesExpr(arg, what)) break :blk true;
            break :blk false;
        },
        .unary => |u| usesExpr(u.operand, what),
        .binary => |b| usesExpr(b.lhs, what) or usesExpr(b.rhs, what),
        .ternary => |t| usesExpr(t.cond, what) or usesExpr(t.then, what) or usesExpr(t.other, what),
        else => false,
    };
}

// -------------------------------------------------------------------------
// Statements
// -------------------------------------------------------------------------

fn body(self: *Emitter, statements: []const ast.Stmt) Emitter.Error!void {
    for (statements) |stmt| try statement(self, stmt);
}

fn statement(self: *Emitter, stmt: ast.Stmt) Emitter.Error!void {
    switch (stmt.kind) {
        .declare => |declared| {
            try self.indent();
            try self.w.print("{s} {s}", .{ declared.ty.hlsl(), declared.name });
            if (declared.value) |value| {
                try self.w.writeAll(" = ");
                try expression(self, value);
            }
            try self.w.writeAll(";\n");
        },
        .assign => |assign| {
            try self.indent();
            try assignment(self, assign);
            try self.w.writeAll(";\n");
        },
        .expression => |call| {
            try self.indent();
            try expression(self, call);
            try self.w.writeAll(";\n");
        },
        .conditional => |branch| {
            try self.indent();
            try self.w.writeAll("if (");
            try expression(self, branch.cond);
            try self.w.writeAll(") {\n");
            self.depth += 1;
            try body(self, branch.then);
            self.depth -= 1;
            if (branch.otherwise) |otherwise| {
                try self.indent();
                try self.w.writeAll("} else {\n");
                self.depth += 1;
                try body(self, otherwise);
                self.depth -= 1;
            }
            try self.indent();
            try self.w.writeAll("}\n");
        },
        .loop => |it| {
            try self.indent();
            try self.w.writeAll("for (");
            if (it.init) |declared| {
                try self.w.print("{s} {s}", .{ declared.ty.hlsl(), declared.name });
                if (declared.value) |value| {
                    try self.w.writeAll(" = ");
                    try expression(self, value);
                }
            }
            try self.w.writeAll("; ");
            if (it.cond) |cond| try expression(self, cond);
            try self.w.writeAll("; ");
            if (it.step) |step| try assignment(self, step);
            try self.w.writeAll(") {\n");
            self.depth += 1;
            try body(self, it.body);
            self.depth -= 1;
            try self.indent();
            try self.w.writeAll("}\n");
        },
        .while_loop => |it| {
            try self.indent();
            try self.w.writeAll("while (");
            try expression(self, it.cond);
            try self.w.writeAll(") {\n");
            self.depth += 1;
            try body(self, it.body);
            self.depth -= 1;
            try self.indent();
            try self.w.writeAll("}\n");
        },
        .ret => |value| {
            try self.indent();
            try self.w.writeAll("return");
            if (value) |expr| {
                try self.w.writeByte(' ');
                try expression(self, expr);
            }
            try self.w.writeAll(";\n");
        },
        .discard => {
            try self.indent();
            try self.w.writeAll("discard;\n");
        },
        .block => |inner| {
            try self.indent();
            try self.w.writeAll("{\n");
            self.depth += 1;
            try body(self, inner);
            self.depth -= 1;
            try self.indent();
            try self.w.writeAll("}\n");
        },
    }
}

fn assignment(self: *Emitter, assign: ast.Stmt.Assign) Emitter.Error!void {
    // `m *= n` on two matrices is a matrix product, and HLSL spells that as a
    // call, so the compound form has to be written out long.
    if (assign.op == .multiply and needsMul(assign.target.ty, assign.value.ty)) {
        try expression(self, assign.target);
        try self.w.writeAll(" = mul(");
        try expression(self, assign.target);
        try self.w.writeAll(", ");
        try expression(self, assign.value);
        try self.w.writeByte(')');
        return;
    }
    try expression(self, assign.target);
    try self.w.print(" {s} ", .{assign.op.spelling()});
    try expression(self, assign.value);
}

// -------------------------------------------------------------------------
// Expressions
// -------------------------------------------------------------------------

/// Is this `*` a linear-algebra product rather than a componentwise one?
fn needsMul(lhs: ast.Type, rhs: ast.Type) bool {
    if (lhs.isMatrix() and (rhs.isMatrix() or rhs.isVector())) return true;
    if (lhs.isVector() and rhs.isMatrix()) return true;
    return false;
}

fn expression(self: *Emitter, expr: *const ast.Expr) Emitter.Error!void {
    switch (expr.kind) {
        .number => |number| try @import("glsl.zig").writeNumber(self.w, number),
        .boolean => |value| try self.w.writeAll(if (value) "true" else "false"),
        .name => |named| try name(self, named),
        .field => |f| {
            try expression(self, f.base);
            try self.w.print(".{s}", .{f.name});
        },
        .call => |called| try callExpr(self, called),
        .unary => |unary| {
            try self.w.writeByte('(');
            try self.w.writeAll(switch (unary.op) {
                .negate => "-",
                .not => "!",
            });
            try expression(self, unary.operand);
            try self.w.writeByte(')');
        },
        .binary => |binary| {
            if (binary.op == .multiply and needsMul(binary.lhs.ty, binary.rhs.ty)) {
                try self.w.writeAll("mul(");
                try expression(self, binary.lhs);
                try self.w.writeAll(", ");
                try expression(self, binary.rhs);
                try self.w.writeByte(')');
                return;
            }
            try self.w.writeByte('(');
            try expression(self, binary.lhs);
            try self.w.print(" {s} ", .{binary.op.spelling()});
            try expression(self, binary.rhs);
            try self.w.writeByte(')');
        },
        .ternary => |ternary| {
            try self.w.writeByte('(');
            try expression(self, ternary.cond);
            try self.w.writeAll(" ? ");
            try expression(self, ternary.then);
            try self.w.writeAll(" : ");
            try expression(self, ternary.other);
            try self.w.writeByte(')');
        },
    }
}

fn name(self: *Emitter, named: ast.Expr.Name) Emitter.Error!void {
    switch (named.binding) {
        .attribute => try self.w.print("{s}.{s}", .{ input_value, named.text }),
        .varying => try self.w.print("{s}.{s}", .{
            if (self.stage == .vertex) output_value else input_value,
            named.text,
        }),
        .position => try self.w.print("{s}.{s}", .{ output_value, position_member }),
        .target => try self.w.writeAll(target_value),
        // `SV_VertexID` arrives unsigned, and this language's is an `int`.
        .vertex_index => try self.w.print("((int){s}.{s})", .{ input_value, vertex_index_member }),
        .instance_index => try self.w.print("((int){s}.{s})", .{ input_value, instance_index_member }),
        else => try self.w.writeAll(named.text),
    }
}

fn callExpr(self: *Emitter, called: ast.Expr.Call) Emitter.Error!void {
    switch (called.target) {
        .construct => |ty| {
            // `float4(x)` with one scalar is not a constructor HLSL has -
            // `vec4(x)` fills a vector in GLSL and this is `error X3014`
            // there. A cast is the spelling that broadcasts, and it is the
            // spelling for a scalar conversion too.
            if (called.args.len == 1 and called.args[0].ty.isScalar()) {
                try self.w.print("(({s})(", .{ty.hlsl()});
                try expression(self, called.args[0]);
                try self.w.writeAll("))");
                return;
            }
            try self.w.print("{s}(", .{ty.hlsl()});
            try arguments(self, called.args);
            try self.w.writeByte(')');
        },
        .user, .unresolved => {
            try self.w.print("{s}(", .{called.name});
            try arguments(self, called.args);
            try self.w.writeByte(')');
        },
        .builtin => |which| try builtinCall(self, which, called.args),
    }
}

fn arguments(self: *Emitter, args: []const *ast.Expr) Emitter.Error!void {
    for (args, 0..) |arg, i| {
        if (i > 0) try self.w.writeAll(", ");
        try expression(self, arg);
    }
}

fn builtinCall(self: *Emitter, which: ast.Builtin, args: []const *ast.Expr) Emitter.Error!void {
    switch (which) {
        // A texture and its sampler are two objects in Direct3D, and the
        // sampler's name is the texture's with a suffix - which is why a
        // texture may only ever be a global here.
        .sample => {
            try expression(self, args[0]);
            try self.w.writeAll(".Sample(");
            try expression(self, args[0]);
            try self.w.writeAll("_sampler, ");
            try expression(self, args[1]);
            try self.w.writeByte(')');
            return;
        },
        // GLSL's `mod`, written out. See the module comment.
        .mod => {
            try self.w.writeAll("((");
            try expression(self, args[0]);
            try self.w.writeAll(") - (");
            try expression(self, args[1]);
            try self.w.writeAll(") * floor((");
            try expression(self, args[0]);
            try self.w.writeAll(") / (");
            try expression(self, args[1]);
            try self.w.writeAll(")))");
            return;
        },
        else => {},
    }

    const spelling: []const u8 = switch (which) {
        .fract => "frac",
        .mix => "lerp",
        .inversesqrt => "rsqrt",
        // One argument is `atan`; two is `atan2`.
        .atan => if (args.len == 2) "atan2" else "atan",
        else => @tagName(which),
    };

    try self.w.print("{s}(", .{spelling});
    try arguments(self, args);
    try self.w.writeByte(')');
}
