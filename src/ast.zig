// SPDX-License-Identifier: BSL-1.0

//! The shape of a shader, as the parser leaves it and the emitters read it.
//!
//! One tree, annotated in place rather than copied: `parse` fills in the
//! shape, `sema` fills in `Expr.ty` and every `binding` and `target`, and the
//! two emitters read both. A second tree would mean two things to keep in
//! step, and the annotations are exactly what tells `a * b` on two matrices
//! from `a * b` on two floats - which is the difference between `*` and
//! `mul` on the way out.
//!
//! Every node carries the byte offset it began at, and nothing else about
//! where it is. A line and a column come from `fluxion-text`'s
//! `Parser.locationAt` when there is something to report.

const std = @import("std");

/// Every type the language has.
///
/// Deliberately short. `int` is here for loop counters and array-free
/// arithmetic; there are no integer vectors, no arrays and no user structs,
/// because each of those is a place where `std140` and Direct3D's constant
/// buffer packing stop agreeing, and a library that emitted both from one
/// description would be promising something it could not keep. See the
/// README.
pub const Type = enum {
    void,
    bool,
    int,
    float,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,
    texture2d,

    pub fn fromName(name: []const u8) ?Type {
        return std.meta.stringToEnum(Type, name);
    }

    pub fn glsl(self: Type) []const u8 {
        return switch (self) {
            .void => "void",
            .bool => "bool",
            .int => "int",
            .float => "float",
            .vec2 => "vec2",
            .vec3 => "vec3",
            .vec4 => "vec4",
            .mat2 => "mat2",
            .mat3 => "mat3",
            .mat4 => "mat4",
            .texture2d => "sampler2D",
        };
    }

    pub fn hlsl(self: Type) []const u8 {
        return switch (self) {
            .void => "void",
            .bool => "bool",
            .int => "int",
            .float => "float",
            .vec2 => "float2",
            .vec3 => "float3",
            .vec4 => "float4",
            .mat2 => "float2x2",
            .mat3 => "float3x3",
            .mat4 => "float4x4",
            .texture2d => "Texture2D",
        };
    }

    pub fn isScalar(self: Type) bool {
        return switch (self) {
            .bool, .int, .float => true,
            else => false,
        };
    }

    pub fn isVector(self: Type) bool {
        return switch (self) {
            .vec2, .vec3, .vec4 => true,
            else => false,
        };
    }

    pub fn isMatrix(self: Type) bool {
        return switch (self) {
            .mat2, .mat3, .mat4 => true,
            else => false,
        };
    }

    /// True where arithmetic makes sense: everything but `void`, `bool` and a
    /// texture.
    pub fn isNumeric(self: Type) bool {
        return switch (self) {
            .int, .float, .vec2, .vec3, .vec4, .mat2, .mat3, .mat4 => true,
            else => false,
        };
    }

    /// How many floats wide, for a scalar or a vector.
    pub fn components(self: Type) u32 {
        return switch (self) {
            .bool, .int, .float => 1,
            .vec2 => 2,
            .vec3 => 3,
            .vec4 => 4,
            else => 0,
        };
    }

    /// How many rows and columns, for a matrix.
    pub fn dimension(self: Type) u32 {
        return switch (self) {
            .mat2 => 2,
            .mat3 => 3,
            .mat4 => 4,
            else => 0,
        };
    }

    /// The vector of that width: 2 is `vec2`, and 1 is `float`.
    pub fn vector(width: u32) ?Type {
        return switch (width) {
            1 => .float,
            2 => .vec2,
            3 => .vec3,
            4 => .vec4,
            else => null,
        };
    }

    pub fn matrix(size: u32) ?Type {
        return switch (size) {
            2 => .mat2,
            3 => .mat3,
            4 => .mat4,
            else => null,
        };
    }

    /// Bytes this occupies in a uniform block, under the rules `std140` and
    /// Direct3D's constant buffers agree on. See `alignmentInBlock`.
    pub fn sizeInBlock(self: Type) u32 {
        return switch (self) {
            .bool, .int, .float => 4,
            .vec2 => 8,
            .vec3 => 12,
            .vec4 => 16,
            // A matrix is its columns, each one padded to sixteen bytes.
            .mat2 => 32,
            .mat3 => 48,
            .mat4 => 64,
            else => 0,
        };
    }

    /// What a field of this type has to start on.
    ///
    /// `std140` rounds a `vec3` up to sixteen and so does Direct3D, which
    /// packs into four-float registers and will not let a value straddle one.
    /// That is why the two layouts agree for everything this language can put
    /// in a block.
    pub fn alignmentInBlock(self: Type) u32 {
        return switch (self) {
            .bool, .int, .float => 4,
            .vec2 => 8,
            .vec3, .vec4, .mat2, .mat3, .mat4 => 16,
            else => 1,
        };
    }
};

/// What a name turned out to mean. Filled in by `sema`; the emitters read it
/// to decide whether a name is written as itself, as a field of the stage's
/// input struct, or as something the API spells differently.
pub const Binding = union(enum) {
    /// Declared in this block, or a parameter of the function around it.
    local,
    attribute: u32,
    varying: u32,
    uniform_field: struct { block: u32, field: u32 },
    texture: u32,
    constant: u32,
    /// `position`: the clip-space vertex output.
    position,
    /// `target`: the fragment colour output.
    target,
    /// `vertex_index` and `instance_index`.
    vertex_index,
    instance_index,
};

/// What a call turned out to be.
pub const CallTarget = union(enum) {
    unresolved,
    builtin: Builtin,
    /// `vec4(x, y, z, w)` and the rest.
    construct: Type,
    /// An index into `Program.functions`.
    user: u32,
};

/// The functions the language brings with it.
///
/// Each one exists in both languages; the ones that are spelled differently,
/// or mean something different under the same spelling, are the reason this
/// is a list rather than "whatever the driver has". See `glsl` and `hlsl`.
pub const Builtin = enum {
    // Reading a texture.
    sample,
    // One argument, componentwise.
    abs,
    floor,
    ceil,
    fract,
    sqrt,
    inversesqrt,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    exp,
    log,
    exp2,
    log2,
    sign,
    normalize,
    saturate,
    ddx,
    ddy,
    // Two arguments, componentwise.
    min,
    max,
    pow,
    mod,
    step,
    atan2,
    reflect,
    // Three arguments, componentwise.
    clamp,
    mix,
    smoothstep,
    // Reductions.
    length,
    distance,
    dot,
    cross,
    // Matrices.
    transpose,

    pub fn fromName(name: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, name);
    }
};

pub const UnaryOp = enum { negate, not };

pub const BinaryOp = enum {
    add,
    subtract,
    multiply,
    divide,
    remainder,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
    logical_and,
    logical_or,

    pub fn isComparison(self: BinaryOp) bool {
        return switch (self) {
            .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => true,
            else => false,
        };
    }

    pub fn isLogical(self: BinaryOp) bool {
        return self == .logical_and or self == .logical_or;
    }

    pub fn spelling(self: BinaryOp) []const u8 {
        return switch (self) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .remainder => "%",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .equal => "==",
            .not_equal => "!=",
            .logical_and => "&&",
            .logical_or => "||",
        };
    }
};

pub const AssignOp = enum {
    set,
    add,
    subtract,
    multiply,
    divide,

    /// The binary operator a compound assignment stands for, for the sake of
    /// type checking it.
    pub fn binary(self: AssignOp) ?BinaryOp {
        return switch (self) {
            .set => null,
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .divide => .divide,
        };
    }

    pub fn spelling(self: AssignOp) []const u8 {
        return switch (self) {
            .set => "=",
            .add => "+=",
            .subtract => "-=",
            .multiply => "*=",
            .divide => "/=",
        };
    }
};

pub const Expr = struct {
    kind: Kind,
    /// Filled in by `sema`. `.void` until then.
    ty: Type = .void,
    offset: u32,

    pub const Kind = union(enum) {
        number: Number,
        boolean: bool,
        name: Name,
        field: Field,
        call: Call,
        unary: Unary,
        binary: Binary,
        ternary: Ternary,
    };

    pub const Number = struct {
        /// As written, so `1e-3` stays `1e-3`.
        bytes: []const u8,
        /// Written with a point or an exponent. An integer literal used where
        /// a float is wanted is emitted with a `.0` put on it, because GLSL
        /// and HLSL both accept the conversion and neither is improved by
        /// relying on it.
        is_float: bool,
    };

    pub const Name = struct {
        text: []const u8,
        binding: Binding = .local,
    };

    pub const Field = struct {
        base: *Expr,
        /// `xyz`, `rgba`, or one field of a uniform block reached through no
        /// base at all - see `sema`, which only ever produces swizzles here.
        name: []const u8,
    };

    pub const Call = struct {
        name: []const u8,
        args: []*Expr,
        target: CallTarget = .unresolved,
    };

    pub const Unary = struct {
        op: UnaryOp,
        operand: *Expr,
    };

    pub const Binary = struct {
        op: BinaryOp,
        lhs: *Expr,
        rhs: *Expr,
    };

    pub const Ternary = struct {
        cond: *Expr,
        then: *Expr,
        other: *Expr,
    };
};

pub const Stmt = struct {
    kind: Kind,
    offset: u32,

    pub const Kind = union(enum) {
        declare: Declare,
        assign: Assign,
        /// A call whose result is thrown away.
        expression: *Expr,
        conditional: Conditional,
        loop: Loop,
        while_loop: WhileLoop,
        ret: ?*Expr,
        discard,
        block: []Stmt,
    };

    pub const Declare = struct {
        ty: Type,
        name: []const u8,
        value: ?*Expr,
    };

    pub const Assign = struct {
        target: *Expr,
        op: AssignOp,
        value: *Expr,
    };

    pub const Conditional = struct {
        cond: *Expr,
        then: []Stmt,
        otherwise: ?[]Stmt,
    };

    pub const Loop = struct {
        /// `for (int i = 0; ...)`, always a declaration when there is one.
        init: ?Declare,
        cond: ?*Expr,
        step: ?Assign,
        body: []Stmt,
    };

    pub const WhileLoop = struct {
        cond: *Expr,
        body: []Stmt,
    };
};

// -------------------------------------------------------------------------
// What a whole shader is
// -------------------------------------------------------------------------

pub const Attribute = struct {
    name: []const u8,
    ty: Type,
    location: u32,
    offset: u32,
};

pub const Varying = struct {
    name: []const u8,
    ty: Type,
    offset: u32,
};

pub const BlockField = struct {
    name: []const u8,
    ty: Type,
    /// Bytes from the start of the block. Worked out by `sema`, and the same
    /// number under `std140` and Direct3D.
    byte_offset: u32 = 0,
    offset: u32,
};

pub const UniformBlock = struct {
    name: []const u8,
    slot: u32,
    fields: []BlockField,
    /// Bytes the whole block takes, rounded up to sixteen.
    size: u32 = 0,
    offset: u32,
};

pub const Texture = struct {
    name: []const u8,
    slot: u32,
    offset: u32,
};

pub const Constant = struct {
    name: []const u8,
    ty: Type,
    value: *Expr,
    offset: u32,
};

pub const Parameter = struct {
    name: []const u8,
    ty: Type,
    offset: u32,
};

pub const Function = struct {
    name: []const u8,
    returns: Type,
    params: []Parameter,
    body: []Stmt,
    offset: u32,
};

pub const Stage = struct {
    body: []Stmt,
    offset: u32,
};

/// Everything one source file declared.
pub const Program = struct {
    attributes: []Attribute = &.{},
    varyings: []Varying = &.{},
    blocks: []UniformBlock = &.{},
    textures: []Texture = &.{},
    constants: []Constant = &.{},
    functions: []Function = &.{},
    vertex: ?Stage = null,
    fragment: ?Stage = null,
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a type knows what each language calls it" {
    try testing.expectEqualStrings("vec4", Type.vec4.glsl());
    try testing.expectEqualStrings("float4", Type.vec4.hlsl());
    try testing.expectEqualStrings("mat3", Type.mat3.glsl());
    try testing.expectEqualStrings("float3x3", Type.mat3.hlsl());
    try testing.expectEqualStrings("sampler2D", Type.texture2d.glsl());
    try testing.expectEqualStrings("Texture2D", Type.texture2d.hlsl());
}

test "a type is one shape or another" {
    try testing.expect(Type.float.isScalar());
    try testing.expect(Type.vec3.isVector());
    try testing.expect(Type.mat4.isMatrix());
    try testing.expect(!Type.texture2d.isNumeric());
    try testing.expect(!Type.bool.isNumeric());
    try testing.expectEqual(@as(u32, 3), Type.vec3.components());
    try testing.expectEqual(@as(u32, 4), Type.mat4.dimension());
    try testing.expectEqual(Type.vec2, Type.vector(2).?);
    try testing.expectEqual(Type.float, Type.vector(1).?);
    try testing.expectEqual(@as(?Type, null), Type.vector(5));
}

test "the block layout is the one both APIs agree on" {
    // A vec3 is twelve bytes but starts on sixteen, which is what std140 says
    // and what a constant buffer register forces.
    try testing.expectEqual(@as(u32, 12), Type.vec3.sizeInBlock());
    try testing.expectEqual(@as(u32, 16), Type.vec3.alignmentInBlock());
    // A float packs into the space after it rather than starting a register.
    try testing.expectEqual(@as(u32, 4), Type.float.alignmentInBlock());
    // A mat4 is four columns of four floats.
    try testing.expectEqual(@as(u32, 64), Type.mat4.sizeInBlock());
    try testing.expectEqual(@as(u32, 48), Type.mat3.sizeInBlock());
}

test "a name is a type only when the language has one by that name" {
    try testing.expectEqual(Type.vec2, Type.fromName("vec2").?);
    try testing.expectEqual(@as(?Type, null), Type.fromName("vec5"));
    try testing.expectEqual(@as(?Type, null), Type.fromName("projection"));
}

test "the builtins are found by the name they are called by" {
    try testing.expectEqual(Builtin.smoothstep, Builtin.fromName("smoothstep").?);
    try testing.expectEqual(@as(?Builtin, null), Builtin.fromName("texture"));
}

test "a compound assignment knows the operator it stands for" {
    try testing.expectEqual(@as(?BinaryOp, null), AssignOp.set.binary());
    try testing.expectEqual(BinaryOp.multiply, AssignOp.multiply.binary().?);
    try testing.expectEqualStrings("+=", AssignOp.add.spelling());
}
