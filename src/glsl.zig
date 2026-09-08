// SPDX-License-Identifier: BSL-1.0

//! The tree, written out as GLSL 3.30 core.
//!
//! The easier of the two, because the language was designed around the same
//! ideas: a vertex stage writes `gl_Position`, attributes and varyings are
//! global, and a uniform block declared without an instance name puts its
//! fields in scope. What changes on the way out is small and named here:
//!
//! | This language | GLSL |
//! | --- | --- |
//! | `position` | `gl_Position` |
//! | `target` | an `out vec4` of the emitter's own |
//! | `vertex_index`, `instance_index` | `gl_VertexID`, `gl_InstanceID` |
//! | `sample(t, uv)` | `texture(t, uv)` |
//! | `saturate(x)` | `clamp(x, 0.0, 1.0)` |
//! | `ddx`, `ddy` | `dFdx`, `dFdy` |
//! | `atan2(y, x)` | `atan(y, x)` |
//!
//! Uniform blocks and samplers are declared in both stages whether or not
//! that stage uses them: the two are linked into one program, and a block
//! that appears on one side only is still one block.

const std = @import("std");
const ast = @import("ast.zig");
const sema = @import("sema.zig");

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

/// The name the emitter gives the fragment stage's colour output. Chosen
/// rather than `gl_FragColor`, which GLSL 3.30 core does not have.
pub const target_name = "fluxion_target";

/// Write one stage.
pub fn emit(
    program: *const ast.Program,
    stage: sema.Where,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    var e: Emitter = .{ .program = program, .w = w, .stage = stage };

    try w.writeAll("#version 330 core\n\n");

    if (stage == .vertex) {
        for (program.attributes) |a| {
            try w.print("layout(location = {d}) in {s} {s};\n", .{ a.location, a.ty.glsl(), a.name });
        }
        if (program.attributes.len > 0) try w.writeByte('\n');
    }

    for (program.varyings) |v| {
        try w.print("{s} {s} {s};\n", .{
            if (stage == .vertex) "out" else "in",
            v.ty.glsl(),
            v.name,
        });
    }
    if (program.varyings.len > 0) try w.writeByte('\n');

    if (stage == .fragment) {
        try w.print("out vec4 {s};\n\n", .{target_name});
    }

    for (program.blocks) |b| {
        try w.print("layout(std140) uniform {s} {{\n", .{b.name});
        for (b.fields) |field| {
            try w.print("    {s} {s};\n", .{ field.ty.glsl(), field.name });
        }
        try w.writeAll("};\n\n");
    }

    for (program.textures) |t| {
        try w.print("uniform {s} {s};\n", .{ ast.Type.texture2d.glsl(), t.name });
    }
    if (program.textures.len > 0) try w.writeByte('\n');

    for (program.constants) |c| {
        try w.print("const {s} {s} = ", .{ c.ty.glsl(), c.name });
        try expression(&e, c.value);
        try w.writeAll(";\n");
    }
    if (program.constants.len > 0) try w.writeByte('\n');

    // Prototypes first, so a function may call one declared after it.
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

    try w.writeAll("void main() {\n");
    const stage_body = if (stage == .vertex) program.vertex.?.body else program.fragment.?.body;
    try body(&e, stage_body);
    try w.writeAll("}\n");
}

fn signature(self: *Emitter, f: ast.Function) Emitter.Error!void {
    try self.w.print("{s} {s}(", .{ f.returns.glsl(), f.name });
    for (f.params, 0..) |param, i| {
        if (i > 0) try self.w.writeAll(", ");
        try self.w.print("{s} {s}", .{ param.ty.glsl(), param.name });
    }
    try self.w.writeByte(')');
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
            try self.w.print("{s} {s}", .{ declared.ty.glsl(), declared.name });
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
                try self.w.print("{s} {s}", .{ declared.ty.glsl(), declared.name });
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
    try expression(self, assign.target);
    try self.w.print(" {s} ", .{assign.op.spelling()});
    try expression(self, assign.value);
}

// -------------------------------------------------------------------------
// Expressions
// -------------------------------------------------------------------------

fn expression(self: *Emitter, expr: *const ast.Expr) Emitter.Error!void {
    switch (expr.kind) {
        .number => |number| try writeNumber(self.w, number),
        .boolean => |value| try self.w.writeAll(if (value) "true" else "false"),
        .name => |named| try name(self, named),
        .field => |f| {
            try expression(self, f.base);
            try self.w.print(".{s}", .{f.name});
        },
        .call => |called| try callExpr(self, expr, called),
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

/// A whole number written where a float belongs comes out as one, rather than
/// leaning on a conversion both languages would do quietly.
pub fn writeNumber(w: *std.Io.Writer, number: ast.Expr.Number) std.Io.Writer.Error!void {
    try w.writeAll(number.bytes);
    if (!number.is_float) return;
    for (number.bytes) |c| {
        if (c == '.' or c == 'e' or c == 'E') return;
    }
    try w.writeAll(".0");
}

fn name(self: *Emitter, named: ast.Expr.Name) Emitter.Error!void {
    switch (named.binding) {
        .position => try self.w.writeAll("gl_Position"),
        .target => try self.w.writeAll(target_name),
        .vertex_index => try self.w.writeAll("gl_VertexID"),
        .instance_index => try self.w.writeAll("gl_InstanceID"),
        else => try self.w.writeAll(named.text),
    }
}

fn callExpr(self: *Emitter, expr: *const ast.Expr, called: ast.Expr.Call) Emitter.Error!void {
    switch (called.target) {
        .construct => |ty| {
            try self.w.print("{s}(", .{ty.glsl()});
            try arguments(self, called.args);
            try self.w.writeByte(')');
        },
        .user, .unresolved => {
            try self.w.print("{s}(", .{called.name});
            try arguments(self, called.args);
            try self.w.writeByte(')');
        },
        .builtin => |which| try builtinCall(self, expr, which, called.args),
    }
}

fn arguments(self: *Emitter, args: []const *ast.Expr) Emitter.Error!void {
    for (args, 0..) |arg, i| {
        if (i > 0) try self.w.writeAll(", ");
        try expression(self, arg);
    }
}

fn builtinCall(self: *Emitter, expr: *const ast.Expr, which: ast.Builtin, args: []const *ast.Expr) Emitter.Error!void {
    switch (which) {
        // `saturate` is HLSL's, and this is what it means.
        .saturate => {
            try self.w.writeAll("clamp(");
            try expression(self, args[0]);
            try self.w.writeAll(", 0.0, 1.0)");
            return;
        },
        else => {},
    }

    const spelling: []const u8 = switch (which) {
        .sample => "texture",
        .ddx => "dFdx",
        .ddy => "dFdy",
        // GLSL spells both arities `atan`.
        .atan2 => "atan",
        else => @tagName(which),
    };
    _ = expr;

    try self.w.print("{s}(", .{spelling});
    try arguments(self, args);
    try self.w.writeByte(')');
}
