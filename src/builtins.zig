// SPDX-License-Identifier: BSL-1.0

//! The functions the language brings with it, as one table.
//!
//! A builtin used to be four things in four places: a name in `ast.Builtin`,
//! how many arguments it takes and how they have to agree in a `switch` in
//! `sema`, and its spelling in a `switch` in `glsl` and another in `hlsl`. A
//! fifth output would have been a fifth `switch`. Now it is a row:
//!
//! | Column | Read by | Says |
//! | --- | --- | --- |
//! | `name` | `sema` | what the source calls it |
//! | `arity` | `sema` | how many arguments, as a range |
//! | `typing` | `sema` | how the argument types decide the result type |
//! | `glsl`, `hlsl` | the two text emitters | how that language spells the call |
//! | `spirv` | the SPIR-V emitter | which instruction, and how its operands are shaped |
//!
//! `ast.Builtin` stays as the identity of a row - it is what a checked call
//! carries around - and `row` turns an identity into its row. A `comptime`
//! block below fails the build when a `Builtin` has no row, has two, or a row
//! spells its name differently from its tag, so adding a builtin is adding a
//! tag and a row, and forgetting either is not a runtime surprise.
//!
//! **What the columns cannot say** is stated rather than hidden. A text
//! column is a name, a name that depends on how many arguments there are, or
//! a template with `{0}`, `{1}` where the arguments go; that covers every
//! spelling the two languages need, including the two that are not a plain
//! call (`mod` in HLSL, and `sample` there). The SPIR-V column is an
//! extended-instruction number or a core opcode, plus whether scalar operands
//! are widened to the widest vector among them - and for the three builtins
//! that are a small program rather than one instruction (`mod`, `sample`,
//! `dot`) a named recipe, which the emitter owns.

const std = @import("std");
const ast = @import("ast.zig");
const op = @import("spirv/op.zig");

pub const Builtin = ast.Builtin;

/// How a builtin's arguments and result go together. `sema` reads this and
/// nothing else about a builtin's types.
pub const Typing = enum {
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

/// How a text target writes a call.
pub const Text = union(enum) {
    /// `name(a, b)`, spelled as the builtin is in the source.
    same,
    /// `spelling(a, b)`.
    call: []const u8,
    /// `one(a)` when there is one argument and `two(a, b)` when there are two.
    call_by_arity: struct { one: []const u8, two: []const u8 },
    /// Anything that is not a plain call. `{0}` is the first argument and
    /// `{1}` the second, each written as many times as it appears; every
    /// other byte is copied.
    template: []const u8,
};

/// How SPIR-V writes a call.
pub const Spirv = struct {
    lower: Lower,
    /// Scalar operands are splatted to the widest vector among them first.
    /// GLSL has `min(vec3, float)` and the instruction wants two `vec3`s.
    widen: bool = false,
    /// Constants appended to the operands, splatted to the operand width:
    /// `saturate` is a clamp with `0.0` and `1.0` after the argument.
    constants: []const f32 = &.{},

    pub const Lower = union(enum) {
        /// One instruction of `GLSL.std.450`.
        ext: op.Std450,
        /// `one` with one argument and `two` with two: `atan`.
        ext_by_arity: struct { one: op.Std450, two: op.Std450 },
        /// One core instruction, the operands as they are.
        core: op.Op,
        /// A short program, written in `spirv.zig` under this name.
        recipe: Recipe,
    };

    pub const Recipe = enum {
        /// `x - y * floor(x / y)`: GLSL's `mod`, which is not `FRem`, whose
        /// sign is the numerator's. It is written out rather than left to
        /// `FMod` so that every target computes the same expression, as the
        /// HLSL one does.
        mod,
        /// `OpImageSampleImplicitLod` in the fragment stage, and the same
        /// with an explicit level of zero anywhere else, where a derivative
        /// does not exist.
        sample,
        /// `OpDot` on vectors, and a product on two scalars, which `OpDot`
        /// does not take.
        dot,
    };
};

pub const Row = struct {
    builtin: Builtin,
    /// The name it is called by in the source.
    name: []const u8,
    /// The fewest and the most arguments it takes.
    min_args: u8,
    max_args: u8,
    typing: Typing,
    glsl: Text,
    hlsl: Text,
    spirv: Spirv,
};

/// Everything a row says besides which builtin it is and what it is called,
/// so the table below reads as one line per builtin.
const Spec = struct {
    args: [2]u8,
    typing: Typing,
    glsl: Text = .same,
    hlsl: Text = .same,
    spirv: Spirv,
};

fn r(comptime builtin: Builtin, comptime spec: Spec) Row {
    return .{
        .builtin = builtin,
        .name = @tagName(builtin),
        .min_args = spec.args[0],
        .max_args = spec.args[1],
        .typing = spec.typing,
        .glsl = spec.glsl,
        .hlsl = spec.hlsl,
        .spirv = spec.spirv,
    };
}

fn ext(comptime which: op.Std450) Spirv {
    return .{ .lower = .{ .ext = which } };
}

fn extWide(comptime which: op.Std450) Spirv {
    return .{ .lower = .{ .ext = which }, .widen = true };
}

/// The table. One row per builtin, in the order the enum declares them
/// (though nothing depends on that).
pub const table = [_]Row{
    // Reading a texture.
    r(.sample, .{
        .args = .{ 2, 2 },
        .typing = .sample,
        .glsl = .{ .call = "texture" },
        // A texture and its sampler are two objects in Direct3D, and the
        // sampler's name is the texture's with a suffix - which is why a
        // texture may only ever be a global there.
        .hlsl = .{ .template = "{0}.Sample({0}_sampler, {1})" },
        .spirv = .{ .lower = .{ .recipe = .sample } },
    }),

    // One argument, componentwise.
    r(.abs, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.f_abs) }),
    r(.floor, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.floor) }),
    r(.ceil, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.ceil) }),
    r(.fract, .{ .args = .{ 1, 1 }, .typing = .componentwise, .hlsl = .{ .call = "frac" }, .spirv = ext(.fract) }),
    r(.sqrt, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.sqrt) }),
    r(.inversesqrt, .{ .args = .{ 1, 1 }, .typing = .componentwise, .hlsl = .{ .call = "rsqrt" }, .spirv = ext(.inverse_sqrt) }),
    r(.sin, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.sin) }),
    r(.cos, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.cos) }),
    r(.tan, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.tan) }),
    r(.asin, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.asin) }),
    r(.acos, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.acos) }),
    r(.atan, .{
        // One argument is an arc tangent; two is the one that knows which
        // quadrant it is in. GLSL spells both `atan`; HLSL has `atan2`.
        .args = .{ 1, 2 },
        .typing = .uniform_width,
        .hlsl = .{ .call_by_arity = .{ .one = "atan", .two = "atan2" } },
        .spirv = .{ .lower = .{ .ext_by_arity = .{ .one = .atan, .two = .atan2 } } },
    }),
    r(.exp, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.exp) }),
    r(.log, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.log) }),
    r(.exp2, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.exp2) }),
    r(.log2, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.log2) }),
    r(.sign, .{ .args = .{ 1, 1 }, .typing = .componentwise, .spirv = ext(.f_sign) }),
    r(.normalize, .{ .args = .{ 1, 1 }, .typing = .uniform_width, .spirv = ext(.normalize) }),
    r(.saturate, .{
        .args = .{ 1, 1 },
        .typing = .componentwise,
        // `saturate` is HLSL's, and this is what it means.
        .glsl = .{ .template = "clamp({0}, 0.0, 1.0)" },
        .spirv = .{ .lower = .{ .ext = .f_clamp }, .constants = &.{ 0.0, 1.0 } },
    }),
    r(.ddx, .{ .args = .{ 1, 1 }, .typing = .componentwise, .glsl = .{ .call = "dFdx" }, .spirv = .{ .lower = .{ .core = .dpdx } } }),
    r(.ddy, .{ .args = .{ 1, 1 }, .typing = .componentwise, .glsl = .{ .call = "dFdy" }, .spirv = .{ .lower = .{ .core = .dpdy } } }),

    // Two arguments, componentwise.
    r(.min, .{ .args = .{ 2, 2 }, .typing = .componentwise, .spirv = extWide(.f_min) }),
    r(.max, .{ .args = .{ 2, 2 }, .typing = .componentwise, .spirv = extWide(.f_max) }),
    r(.pow, .{ .args = .{ 2, 2 }, .typing = .uniform_width, .spirv = ext(.pow) }),
    r(.mod, .{
        .args = .{ 2, 2 },
        .typing = .componentwise,
        // GLSL's `mod`, written out: HLSL's `fmod` takes the sign of the
        // numerator and GLSL's does not, which differs for every negative
        // input. It evaluates both twice, which costs nothing that matters
        // and is why no expression in this language may have an effect.
        .hlsl = .{ .template = "(({0}) - ({1}) * floor(({0}) / ({1})))" },
        .spirv = .{ .lower = .{ .recipe = .mod }, .widen = true },
    }),
    r(.step, .{ .args = .{ 2, 2 }, .typing = .componentwise, .spirv = extWide(.step) }),
    r(.atan2, .{ .args = .{ 2, 2 }, .typing = .uniform_width, .glsl = .{ .call = "atan" }, .spirv = ext(.atan2) }),
    r(.reflect, .{ .args = .{ 2, 2 }, .typing = .uniform_width, .spirv = ext(.reflect) }),

    // Three arguments, componentwise.
    r(.clamp, .{ .args = .{ 3, 3 }, .typing = .componentwise, .spirv = extWide(.f_clamp) }),
    r(.mix, .{ .args = .{ 3, 3 }, .typing = .componentwise, .hlsl = .{ .call = "lerp" }, .spirv = extWide(.f_mix) }),
    r(.smoothstep, .{ .args = .{ 3, 3 }, .typing = .componentwise, .spirv = extWide(.smooth_step) }),

    // Reductions.
    r(.length, .{ .args = .{ 1, 1 }, .typing = .reduce, .spirv = ext(.length) }),
    r(.distance, .{ .args = .{ 2, 2 }, .typing = .reduce, .spirv = ext(.distance) }),
    r(.dot, .{ .args = .{ 2, 2 }, .typing = .reduce, .spirv = .{ .lower = .{ .recipe = .dot } } }),
    r(.cross, .{ .args = .{ 2, 2 }, .typing = .cross, .spirv = ext(.cross) }),

    // Matrices.
    r(.transpose, .{ .args = .{ 1, 1 }, .typing = .matrix, .spirv = .{ .lower = .{ .core = .transpose } } }),
};

/// Which row is each builtin's, by the builtin's number. Built once, at
/// compile time, from the table above.
const index_of: [@typeInfo(Builtin).@"enum".fields.len]u8 = blk: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Builtin).@"enum".fields;
    var index: [fields.len]u8 = undefined;
    for (fields, 0..) |field, slot| {
        const builtin: Builtin = @enumFromInt(field.value);
        var found: ?u8 = null;
        for (table, 0..) |row_, at| {
            if (row_.builtin != builtin) continue;
            if (found != null) {
                @compileError("the builtin `" ++ field.name ++ "` has more than one row in the builtin table");
            }
            found = @intCast(at);
        }
        index[slot] = found orelse
            @compileError("the builtin `" ++ field.name ++ "` has no row in the builtin table; add one to `builtins.table`");
    }
    for (table) |row_| {
        if (row_.min_args > row_.max_args) {
            @compileError("the builtin `" ++ row_.name ++ "` takes at least more arguments than it takes at most");
        }
    }
    break :blk index;
};

/// The row of a builtin. Every builtin has exactly one, which the build
/// checks rather than the caller.
pub fn row(builtin: Builtin) *const Row {
    return &table[index_of[@intFromEnum(builtin)]];
}

/// The builtin called `name`, or null. The table is the one place names
/// live, so this reads it rather than the enum.
pub fn find(name: []const u8) ?*const Row {
    for (&table) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

/// Write one call in the way a text column says, with `writeArg` writing
/// each argument. Shared by the GLSL and HLSL emitters, which differ only in
/// which column they pass.
pub fn writeCall(
    w: *std.Io.Writer,
    spelling: Text,
    name: []const u8,
    args: []const *ast.Expr,
    context: anytype,
    comptime writeArg: fn (@TypeOf(context), *const ast.Expr) std.Io.Writer.Error!void,
) std.Io.Writer.Error!void {
    switch (spelling) {
        .template => |template| {
            var i: usize = 0;
            while (i < template.len) : (i += 1) {
                const c = template[i];
                const is_hole = c == '{' and i + 2 < template.len and template[i + 2] == '}' and
                    template[i + 1] >= '0' and template[i + 1] <= '9';
                if (!is_hole) {
                    try w.writeByte(c);
                    continue;
                }
                try writeArg(context, args[template[i + 1] - '0']);
                i += 2;
            }
        },
        .same, .call, .call_by_arity => {
            const written: []const u8 = switch (spelling) {
                .same => name,
                .call => |call| call,
                .call_by_arity => |by| if (args.len == 2) by.two else by.one,
                .template => unreachable,
            };
            try w.print("{s}(", .{written});
            for (args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                try writeArg(context, arg);
            }
            try w.writeByte(')');
        },
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "every builtin has exactly one row, under its own name" {
    inline for (@typeInfo(Builtin).@"enum".fields) |field| {
        const builtin: Builtin = @enumFromInt(field.value);
        const found = row(builtin);
        try testing.expectEqual(builtin, found.builtin);
        try testing.expectEqualStrings(field.name, found.name);
    }
    try testing.expectEqual(@typeInfo(Builtin).@"enum".fields.len, table.len);
}

test "a name finds its row" {
    try testing.expectEqual(Builtin.smoothstep, find("smoothstep").?.builtin);
    try testing.expectEqual(@as(?*const Row, null), find("texture"));
    try testing.expectEqual(Builtin.smoothstep, Builtin.fromName("smoothstep").?);
}

test "the arity of a row is a range that has an inside" {
    for (table) |candidate| {
        try testing.expect(candidate.min_args >= 1);
        try testing.expect(candidate.min_args <= candidate.max_args);
        try testing.expect(candidate.max_args <= 3);
    }
    try testing.expectEqual(@as(u8, 1), row(.atan).min_args);
    try testing.expectEqual(@as(u8, 2), row(.atan).max_args);
}

test "a template puts its arguments where the holes are" {
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);

    // The two text columns that are not a call, written with arguments that
    // are numbers.
    var one: ast.Expr = .{ .kind = .{ .number = .{ .bytes = "1", .is_float = true } }, .offset = 0 };
    var two: ast.Expr = .{ .kind = .{ .number = .{ .bytes = "2", .is_float = true } }, .offset = 0 };
    var args = [_]*ast.Expr{ &one, &two };

    const Writer = struct {
        w: *std.Io.Writer,
        fn write(self: @This(), expr: *const ast.Expr) std.Io.Writer.Error!void {
            try self.w.writeAll(expr.kind.number.bytes);
        }
    };
    const context: Writer = .{ .w = &w };

    try writeCall(&w, row(.mod).hlsl, "mod", &args, context, Writer.write);
    try testing.expectEqualStrings("((1) - (2) * floor((1) / (2)))", w.buffered());

    w.end = 0;
    try writeCall(&w, row(.atan).hlsl, "atan", &args, context, Writer.write);
    try testing.expectEqualStrings("atan2(1, 2)", w.buffered());

    w.end = 0;
    try writeCall(&w, row(.atan).hlsl, "atan", args[0..1], context, Writer.write);
    try testing.expectEqualStrings("atan(1)", w.buffered());

    w.end = 0;
    try writeCall(&w, row(.mix).glsl, "mix", &args, context, Writer.write);
    try testing.expectEqualStrings("mix(1, 2)", w.buffered());
}
