// SPDX-License-Identifier: BSL-1.0

//! The tree, written out as SPIR-V: one module per stage, for Vulkan 1.0.
//!
//! The same checked tree the two text emitters read, and words rather than
//! text: a `[]u32` per stage, which is what `vkCreateShaderModule` takes (as
//! bytes, four-aligned - `Module.Words.vertexBytes`). Nothing here talks to a
//! driver, and nothing here needs a later version than SPIR-V 1.0 or an
//! extension.
//!
//! ## The environment
//!
//! Capability `Shader`, addressing `Logical`, memory model `GLSL450`, one
//! entry point named `main`, execution model `Vertex` or `Fragment`, and
//! `OriginUpperLeft` on a fragment stage - which is the only origin Vulkan
//! has. The words are host-endian; on every machine this runs on that is
//! little-endian, which is what a driver reads.
//!
//! ## The interface
//!
//! | This language | SPIR-V |
//! | --- | --- |
//! | `attribute t x : n` | an `Input` variable, `Location n` |
//! | `varying t x` | an `Output` in the vertex module and an `Input` in the fragment module, `Location` = its position in the declaration list |
//! | `position` | an `Output` `vec4`, `BuiltIn Position` |
//! | `target` | an `Output` `vec4`, `Location 0` |
//! | `vertex_index`, `instance_index` | an `Input` `int`, `BuiltIn VertexIndex`, `InstanceIndex` |
//! | `discard` | `OpKill` |
//!
//! **Varyings are matched by position.** The vertex module and the fragment
//! module give the varying declared `n`th (from zero) `Location n`, and every
//! one takes a location whatever its width, since a varying is a scalar or a
//! vector and not a matrix. Both modules declare every varying whether or not
//! its stage reads it, so the interface is a property of the shader and not of
//! what a stage happens to touch. An `int` varying is decorated `Flat`, which
//! Vulkan requires and which the text targets leave to the driver.
//!
//! **`vertex_index` is Vulkan's.** `BuiltIn VertexIndex` includes the draw's
//! first vertex - it is the index in the vertex buffer, not the index of the
//! vertex within the draw - which is what the RHI's `draw` gives it, so
//! `draw(.{ .first_vertex = 4 })` reads 4 first. `gl_VertexID` and Direct3D's
//! `SV_VertexID` are the same on a non-indexed draw, and both count from the
//! base of an indexed one.
//!
//! **Clip space is not touched.** A vertex stage writes `position` and it is
//! `Position`, as it is. Vulkan's clip space has y pointing down and depth in
//! `[0, 1]`; what turns an OpenGL projection into one is the projection, or a
//! negative-height viewport, and not this file.
//!
//! ## Resources
//!
//! **A descriptor set per kind of resource, and binding = slot.** A uniform
//! block at slot `n` is `DescriptorSet 0`, `Binding n`, storage class
//! `Uniform`, and its struct is decorated `Block`. A texture at slot `n` is
//! `DescriptorSet 1`, `Binding n`, `UniformConstant`, a *combined image
//! sampler* - an `OpTypeSampledImage` over a 2D float image. The set numbers
//! are `target.BindingLayout`, which is those two defaults and can be
//! changed; nothing else is added anywhere, so the binding of a resource is a
//! pure function of what it is and its slot, and the RHI's two slot spaces
//! (`setUniformBuffer(slot)`, `setTexture(slot)`) map onto it directly.
//! Every block and texture is declared in both modules whether the stage uses
//! it or not, as the GLSL emitter does, so one pipeline layout serves both.
//!
//! **A block's layout is the one `sema` computed.** `Offset` on every member
//! is the `byte_offset` in `Module.Block`, a matrix is `ColMajor` with
//! `MatrixStride 16`, and that is `std140` - the same numbers a Direct3D
//! constant buffer has for everything this language can put in a block. A
//! test reads the decorations back out of the words and holds them to the
//! module's offsets for every block of every shader it compiles.
//!
//! ## Lowering
//!
//! Locals are `Function` variables, declared at the top of the entry block.
//! Control flow is structured - `OpSelectionMerge` on an `if`, `OpLoopMerge`
//! on a loop - and a branch that returns or discards ends its block, with
//! whatever follows it in that list of statements dropped, since nothing can
//! reach it. A function is written into the module only if a stage reaches
//! it, and SPIR-V has no recursion, so a shader that has some is refused
//! (`error.Unsupported`) rather than written wrongly.
//!
//! A builtin lowers the way its row in `builtins.table` says: an
//! instruction of `GLSL.std.450` or a core opcode, with scalar operands
//! widened to the vector they sit among where the row asks. `mod` is GLSL's
//! definition, `x - y * floor(x / y)`; `saturate` is a clamp to `[0, 1]`;
//! `sample` is `OpImageSampleImplicitLod` in the fragment stage and an
//! explicit level of zero in the vertex stage, where a derivative does not
//! exist and GLSL's `texture` does the same. The one implicit conversion the
//! language has - a whole number meeting a float - is an `OpConvertSToF`, or
//! a constant, exactly where `sema` allows it.
//!
//! Everything comes from one arena inside a `Builder`, which interns types
//! and constants so each is written once, and the module comes back in the
//! memory of the allocator given.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const sema = @import("sema.zig");
const target = @import("target.zig");
const builtins = @import("builtins.zig");

pub const op = @import("spirv/op.zig");
pub const Builder = @import("spirv/Builder.zig");
pub const check = @import("spirv/check.zig");

pub const Error = target.EmitError;

/// What `emit` is asked for besides the tree and the stage.
pub const Options = struct {
    binding: target.BindingLayout = .{},
    debug_names: bool = false,
};

/// One stage as SPIR-V, in memory from `gpa` that the caller frees.
///
/// This is `emitTarget` without the request: the row in `target`'s table goes
/// through the request, and a program that only wants SPIR-V can call this.
pub fn emit(
    gpa: Allocator,
    program: *const ast.Program,
    stage: sema.Where,
    options: Options,
) Error![]u32 {
    var request: target.Request = .{
        .program = program,
        .stage = stage,
        .binding = options.binding,
        .debug_names = options.debug_names,
    };
    return emitTarget(gpa, &request);
}

/// The row in `target.builtin_targets`.
pub fn emitTarget(gpa: Allocator, request: *target.Request) Error![]u32 {
    std.debug.assert(request.stage != .function);
    var builder: Builder = .init(gpa);
    defer builder.deinit();

    var emitter: Emitter = .{
        .b = &builder,
        .program = request.program,
        .stage = request.stage,
        .binding = request.binding,
        .names = request.debug_names,
        .request = request,
    };
    return emitter.run(gpa);
}

// -------------------------------------------------------------------------
// What an operator is
// -------------------------------------------------------------------------

/// The instruction an operator is, by the kind of number it works on. A
/// `null` is a combination the language does not have, which `sema` has
/// already refused.
const OperatorRow = struct {
    int: ?op.Op = null,
    float: ?op.Op = null,
    boolean: ?op.Op = null,
};

const binary_operators: std.EnumArray(ast.BinaryOp, OperatorRow) = .init(.{
    .add = .{ .int = .i_add, .float = .f_add },
    .subtract = .{ .int = .i_sub, .float = .f_sub },
    .multiply = .{ .int = .i_mul, .float = .f_mul },
    .divide = .{ .int = .s_div, .float = .f_div },
    .remainder = .{ .int = .s_rem },
    .less = .{ .int = .s_less_than, .float = .f_ord_less_than },
    .less_equal = .{ .int = .s_less_than_equal, .float = .f_ord_less_than_equal },
    .greater = .{ .int = .s_greater_than, .float = .f_ord_greater_than },
    .greater_equal = .{ .int = .s_greater_than_equal, .float = .f_ord_greater_than_equal },
    // `!=` is true for a NaN, and `==` is false: the ordered form of one and
    // the unordered form of the other, which is what GLSL's are.
    .equal = .{ .int = .i_equal, .float = .f_ord_equal, .boolean = .logical_equal },
    .not_equal = .{ .int = .i_not_equal, .float = .f_unord_not_equal, .boolean = .logical_not_equal },
    .logical_and = .{ .boolean = .logical_and },
    .logical_or = .{ .boolean = .logical_or },
});

const unary_operators: std.EnumArray(ast.UnaryOp, OperatorRow) = .init(.{
    .negate = .{ .int = .s_negate, .float = .f_negate },
    .not = .{ .boolean = .logical_not },
});

fn instructionFor(row: OperatorRow, ty: ast.Type) ?op.Op {
    return switch (ty) {
        .int => row.int,
        .bool => row.boolean,
        else => row.float,
    };
}

// -------------------------------------------------------------------------
// The emitter
// -------------------------------------------------------------------------

/// A value in the middle of an expression: the id that holds it, what type
/// the language says it is, and - for a scalar known at compile time - what
/// it is, so that `-1.0` is one constant and a whole number meeting a float
/// is a float constant rather than a conversion.
const Value = struct {
    id: u32,
    ty: ast.Type,
    known: ?Known = null,

    const Known = union(enum) { float: f32, int: i32 };
};

const Local = struct {
    name: []const u8,
    variable: u32,
    ty: ast.Type,
    depth: u32,
};

const type_count = @typeInfo(ast.Type).@"enum".fields.len;

const Emitter = struct {
    b: *Builder,
    program: *const ast.Program,
    stage: sema.Where,
    binding: target.BindingLayout,
    names: bool,
    request: *target.Request,

    /// The id of each language type, once it has been asked for.
    type_ids: [type_count]u32 = @splat(0),

    // Module-scope variables, by the index of what they stand for.
    attribute_vars: []u32 = &.{},
    varying_vars: []u32 = &.{},
    block_vars: []u32 = &.{},
    texture_vars: []u32 = &.{},
    position_var: u32 = 0,
    target_var: u32 = 0,
    vertex_index_var: u32 = 0,
    instance_index_var: u32 = 0,
    /// The `Input` and `Output` variables the entry point lists.
    interface: Builder.Words = .empty,

    // Which functions the stage reaches, and where.
    function_ids: []u32 = &.{},
    /// 0 not visited, 1 being visited, 2 done: a call graph with a cycle in
    /// it is a function that reaches itself.
    function_state: []u8 = &.{},
    /// Functions in the order to write them: callees first.
    function_order: std.ArrayList(u32) = .empty,
    constant_active: []bool = &.{},
    constant_seen: []bool = &.{},

    // The function being written.
    vars: Builder.Words = .empty,
    code: Builder.Words = .empty,
    locals: std.ArrayList(Local) = .empty,
    depth: u32 = 0,
    /// The current block has ended in a branch, a return or a kill, so
    /// nothing more may be put in it.
    terminated: bool = false,

    fn a(self: *Emitter) Allocator {
        return self.b.allocator();
    }

    fn unsupported(self: *Emitter, reason: []const u8) Error {
        self.request.reason = reason;
        return error.Unsupported;
    }

    // ---------------------------------------------------------------------
    // The module
    // ---------------------------------------------------------------------

    fn run(self: *Emitter, out: Allocator) Error![]u32 {
        const program = self.program;
        const stage_body = if (self.stage == .vertex) program.vertex.?.body else program.fragment.?.body;

        self.function_ids = try self.a().alloc(u32, program.functions.len);
        @memset(self.function_ids, 0);
        self.function_state = try self.a().alloc(u8, program.functions.len);
        @memset(self.function_state, 0);
        self.constant_active = try self.a().alloc(bool, program.constants.len);
        @memset(self.constant_active, false);
        self.constant_seen = try self.a().alloc(bool, program.constants.len);
        @memset(self.constant_seen, false);

        try self.declareInterface();
        try self.declareResources();

        // Only what the stage reaches is written.
        try self.reachStatements(stage_body);
        for (self.function_order.items) |index| try self.emitFunction(index);
        const main_id = try self.emitMain(stage_body);

        try self.writeEntryPoint(main_id);
        return self.b.finish(out);
    }

    fn writeEntryPoint(self: *Emitter, main_id: u32) Error!void {
        var words: Builder.Words = .empty;
        const model: op.ExecutionModel = if (self.stage == .vertex) .vertex else .fragment;
        try words.append(self.a(), @intFromEnum(model));
        try words.append(self.a(), main_id);
        try self.b.appendString(&words, "main");
        try words.appendSlice(self.a(), self.interface.items);
        try self.b.emit(&self.b.entry_points, .entry_point, words.items);

        if (self.stage == .fragment) {
            try self.b.emit(&self.b.execution_modes, .execution_mode, &.{
                main_id, @intFromEnum(op.ExecutionMode.origin_upper_left),
            });
        }
        if (self.names) try self.b.name(main_id, "main");
    }

    // ---------------------------------------------------------------------
    // Types and constants
    // ---------------------------------------------------------------------

    fn typeId(self: *Emitter, ty: ast.Type) Allocator.Error!u32 {
        const slot = &self.type_ids[@intFromEnum(ty)];
        if (slot.* != 0) return slot.*;
        const id: u32 = switch (ty) {
            .void => try self.b.intern(.type_void, &.{}),
            .bool => try self.b.intern(.type_bool, &.{}),
            .int => try self.b.intern(.type_int, &.{ 32, 1 }),
            .float => try self.b.intern(.type_float, &.{32}),
            .vec2, .vec3, .vec4 => try self.b.intern(.type_vector, &.{
                try self.typeId(.float), ty.components(),
            }),
            .mat2, .mat3, .mat4 => try self.b.intern(.type_matrix, &.{
                try self.typeId(ast.Type.vector(ty.dimension()).?), ty.dimension(),
            }),
            .texture2d => blk: {
                // A 2D float image that is sampled, unknown format, and the
                // combination of it with a sampler: what `sample` takes.
                const image = try self.b.intern(.type_image, &.{
                    try self.typeId(.float),
                    @intFromEnum(op.Dim.@"2d"),
                    0, // not a depth image
                    0, // not arrayed
                    0, // not multisampled
                    1, // used with a sampler
                    @intFromEnum(op.ImageFormat.unknown),
                });
                break :blk try self.b.intern(.type_sampled_image, &.{image});
            },
        };
        slot.* = id;
        return id;
    }

    fn pointerTo(self: *Emitter, class: op.StorageClass, ty: u32) Allocator.Error!u32 {
        return self.b.intern(.type_pointer, &.{ @intFromEnum(class), ty });
    }

    /// A vector of `width` bools, which a select on a vector wants for its
    /// condition.
    fn boolVector(self: *Emitter, width: u32) Allocator.Error!u32 {
        return self.b.intern(.type_vector, &.{ try self.typeId(.bool), width });
    }

    fn constFloat(self: *Emitter, value: f32) Allocator.Error!Value {
        const id = try self.b.intern(.constant, &.{ try self.typeId(.float), @bitCast(value) });
        return .{ .id = id, .ty = .float, .known = .{ .float = value } };
    }

    fn constInt(self: *Emitter, value: i32) Allocator.Error!Value {
        const id = try self.b.intern(.constant, &.{ try self.typeId(.int), @bitCast(value) });
        return .{ .id = id, .ty = .int, .known = .{ .int = value } };
    }

    fn constBool(self: *Emitter, value: bool) Allocator.Error!Value {
        const id = try self.b.intern(
            if (value) .constant_true else .constant_false,
            &.{try self.typeId(.bool)},
        );
        return .{ .id = id, .ty = .bool };
    }

    // ---------------------------------------------------------------------
    // The interface and the resources
    // ---------------------------------------------------------------------

    /// A module-scope variable, with a fresh id.
    fn globalVariable(self: *Emitter, class: op.StorageClass, ty: u32) Allocator.Error!u32 {
        const pointer = try self.pointerTo(class, ty);
        return self.b.emitResult(&self.b.globals, .variable, pointer, &.{@intFromEnum(class)});
    }

    fn declareInterface(self: *Emitter) Error!void {
        const program = self.program;
        const b = self.b;

        if (self.stage == .vertex) {
            self.attribute_vars = try self.a().alloc(u32, program.attributes.len);
            for (program.attributes, self.attribute_vars) |attribute, *variable| {
                variable.* = try self.globalVariable(.input, try self.typeId(attribute.ty));
                try b.decorate(variable.*, .location, &.{attribute.location});
                try self.interface.append(self.a(), variable.*);
                if (self.names) try b.name(variable.*, attribute.name);
            }
        }

        // Every varying, in declaration order, in both stages.
        self.varying_vars = try self.a().alloc(u32, program.varyings.len);
        const varying_class: op.StorageClass = if (self.stage == .vertex) .output else .input;
        for (program.varyings, self.varying_vars, 0..) |varying, *variable, location| {
            variable.* = try self.globalVariable(varying_class, try self.typeId(varying.ty));
            try b.decorate(variable.*, .location, &.{@intCast(location)});
            // Vulkan wants an integer that crosses stages to say it is not
            // interpolated.
            if (varying.ty == .int) try b.decorate(variable.*, .flat, &.{});
            try self.interface.append(self.a(), variable.*);
            if (self.names) try b.name(variable.*, varying.name);
        }

        if (self.stage == .vertex) {
            self.position_var = try self.globalVariable(.output, try self.typeId(.vec4));
            try b.decorate(self.position_var, .built_in, &.{@intFromEnum(op.BuiltIn.position)});
            try self.interface.append(self.a(), self.position_var);
            if (self.names) try b.name(self.position_var, "fluxion_position");
        } else {
            self.target_var = try self.globalVariable(.output, try self.typeId(.vec4));
            try b.decorate(self.target_var, .location, &.{0});
            try self.interface.append(self.a(), self.target_var);
            if (self.names) try b.name(self.target_var, "fluxion_target");
        }
    }

    fn declareResources(self: *Emitter) Error!void {
        const program = self.program;
        const b = self.b;

        self.block_vars = try self.a().alloc(u32, program.blocks.len);
        for (program.blocks, self.block_vars) |block, *variable| {
            // The struct: one member per field, laid out where `sema` put it.
            const members = try self.a().alloc(u32, block.fields.len);
            for (block.fields, members) |field, *member| member.* = try self.typeId(field.ty);
            const struct_id = try b.emitDeclaration(&b.globals, .type_struct, members);

            try b.decorate(struct_id, .block, &.{});
            var end: u32 = 0;
            for (block.fields, 0..) |field, index| {
                const member: u32 = @intCast(index);
                try b.decorateMember(struct_id, member, .offset, &.{field.byte_offset});
                if (field.ty.isMatrix()) {
                    // Every column takes a register: `std140`, and a
                    // constant buffer's.
                    try b.decorateMember(struct_id, member, .col_major, &.{});
                    try b.decorateMember(struct_id, member, .matrix_stride, &.{16});
                }
                end = @max(end, field.byte_offset + field.ty.sizeInBlock());
                if (self.names) try b.memberName(struct_id, member, field.name);
            }
            std.debug.assert(end <= block.size);

            variable.* = try self.globalVariable(.uniform, struct_id);
            try b.decorate(variable.*, .descriptor_set, &.{self.binding.uniform_set});
            try b.decorate(variable.*, .binding, &.{block.slot});
            if (self.names) {
                try b.name(struct_id, block.name);
                const label = try std.fmt.allocPrint(self.a(), "fluxion_{s}", .{block.name});
                try b.name(variable.*, label);
            }
        }

        self.texture_vars = try self.a().alloc(u32, program.textures.len);
        for (program.textures, self.texture_vars) |texture, *variable| {
            variable.* = try self.globalVariable(.uniform_constant, try self.typeId(.texture2d));
            try b.decorate(variable.*, .descriptor_set, &.{self.binding.texture_set});
            try b.decorate(variable.*, .binding, &.{texture.slot});
            if (self.names) try b.name(variable.*, texture.name);
        }
    }

    /// `vertex_index` or `instance_index`, declared the first time it is read.
    fn builtinInput(self: *Emitter, which: op.BuiltIn) Allocator.Error!u32 {
        const slot = if (which == .vertex_index) &self.vertex_index_var else &self.instance_index_var;
        if (slot.* != 0) return slot.*;
        slot.* = try self.globalVariable(.input, try self.typeId(.int));
        try self.b.decorate(slot.*, .built_in, &.{@intFromEnum(which)});
        try self.interface.append(self.a(), slot.*);
        if (self.names) try self.b.name(slot.*, if (which == .vertex_index) "fluxion_vertex_index" else "fluxion_instance_index");
        return slot.*;
    }

    // ---------------------------------------------------------------------
    // Which functions a stage reaches
    // ---------------------------------------------------------------------

    fn reach(self: *Emitter, index: u32) Error!void {
        switch (self.function_state[index]) {
            2 => return,
            1 => return self.unsupported("a function that calls itself, directly or through another; SPIR-V has no recursion"),
            else => {},
        }
        const f = self.program.functions[index];
        for (f.params) |param| {
            if (param.ty == .texture2d or param.ty == .void) {
                return self.unsupported("a function parameter that is a texture or void");
            }
        }
        if (f.returns == .texture2d) return self.unsupported("a function that returns a texture");

        self.function_state[index] = 1;
        self.function_ids[index] = self.b.newId();
        try self.reachStatements(f.body);
        self.function_state[index] = 2;
        try self.function_order.append(self.a(), index);
    }

    fn reachStatements(self: *Emitter, statements: []const ast.Stmt) Error!void {
        for (statements) |stmt| {
            switch (stmt.kind) {
                .declare => |d| if (d.value) |v| try self.reachExpr(v),
                .assign => |assign| {
                    try self.reachExpr(assign.target);
                    try self.reachExpr(assign.value);
                },
                .expression => |e| try self.reachExpr(e),
                .conditional => |c| {
                    try self.reachExpr(c.cond);
                    try self.reachStatements(c.then);
                    if (c.otherwise) |o| try self.reachStatements(o);
                },
                .loop => |l| {
                    if (l.init) |d| if (d.value) |v| try self.reachExpr(v);
                    if (l.cond) |c| try self.reachExpr(c);
                    if (l.step) |s| {
                        try self.reachExpr(s.target);
                        try self.reachExpr(s.value);
                    }
                    try self.reachStatements(l.body);
                },
                .while_loop => |l| {
                    try self.reachExpr(l.cond);
                    try self.reachStatements(l.body);
                },
                .ret => |v| if (v) |value| try self.reachExpr(value),
                .discard => {},
                .block => |inner| try self.reachStatements(inner),
            }
        }
    }

    fn reachExpr(self: *Emitter, expr: *const ast.Expr) Error!void {
        switch (expr.kind) {
            .number, .boolean => {},
            .name => |n| switch (n.binding) {
                // A constant is written where it is used, so what it calls is
                // reached from every use.
                .constant => |index| if (!self.constant_seen[index]) {
                    self.constant_seen[index] = true;
                    try self.reachExpr(self.program.constants[index].value);
                },
                else => {},
            },
            .field => |f| try self.reachExpr(f.base),
            .call => |c| {
                for (c.args) |arg| try self.reachExpr(arg);
                switch (c.target) {
                    .user => |index| try self.reach(index),
                    else => {},
                }
            },
            .unary => |u| try self.reachExpr(u.operand),
            .binary => |bin| {
                try self.reachExpr(bin.lhs);
                try self.reachExpr(bin.rhs);
            },
            .ternary => |t| {
                try self.reachExpr(t.cond);
                try self.reachExpr(t.then);
                try self.reachExpr(t.other);
            },
        }
    }

    // ---------------------------------------------------------------------
    // Functions
    // ---------------------------------------------------------------------

    fn beginFunction(self: *Emitter) void {
        self.vars = .empty;
        self.code = .empty;
        self.locals = .empty;
        self.depth = 0;
        self.terminated = false;
    }

    /// Everything of the function, in the order a function is laid out: its
    /// header and parameters, the entry block with the variables first, then
    /// the rest.
    fn finishFunction(self: *Emitter, head: []const u32, entry: u32) Allocator.Error!void {
        const b = self.b;
        try b.functions.appendSlice(self.a(), head);
        try b.emit(&b.functions, .label, &.{entry});
        try b.functions.appendSlice(self.a(), self.vars.items);
        try b.functions.appendSlice(self.a(), self.code.items);
        try b.emit(&b.functions, .function_end, &.{});
    }

    fn emitFunction(self: *Emitter, index: u32) Error!void {
        const f = self.program.functions[index];
        const b = self.b;
        self.beginFunction();

        const params = try self.a().alloc(u32, f.params.len);
        const signature = try self.a().alloc(u32, f.params.len + 1);
        signature[0] = try self.typeId(f.returns);
        for (f.params, signature[1..]) |param, *slot| slot.* = try self.typeId(param.ty);
        const function_type = try b.intern(.type_function, signature);

        var head: Builder.Words = .empty;
        const id = self.function_ids[index];
        try b.emit(&head, .function, &.{ signature[0], id, 0, function_type });
        for (f.params, params, signature[1..]) |_, *param, param_type| {
            param.* = try b.emitResult(&head, .function_parameter, param_type, &.{});
        }
        const entry = b.newId();
        if (self.names) try b.name(id, f.name);

        // A parameter is a value in SPIR-V and a variable in this language -
        // it can be assigned to - so each is copied into one.
        for (f.params, params) |param, value| {
            const variable = try self.newVariable(param.ty, param.name);
            try b.emit(&self.code, .store, &.{ variable, value });
            try self.locals.append(self.a(), .{ .name = param.name, .variable = variable, .ty = param.ty, .depth = 0 });
        }

        try self.scoped(f.body);
        if (!self.terminated) {
            // Every path returns, which `sema` checked; the end of the
            // function is unreachable, and a void one simply returns.
            try b.emit(&self.code, if (f.returns == .void) .@"return" else .@"unreachable", &.{});
        }
        try self.finishFunction(head.items, entry);
    }

    fn emitMain(self: *Emitter, stage_body: []const ast.Stmt) Error!u32 {
        const b = self.b;
        self.beginFunction();

        const void_type = try self.typeId(.void);
        const function_type = try b.intern(.type_function, &.{void_type});
        const id = b.newId();
        var head: Builder.Words = .empty;
        try b.emit(&head, .function, &.{ void_type, id, 0, function_type });
        const entry = b.newId();

        try self.scoped(stage_body);
        if (!self.terminated) try b.emit(&self.code, .@"return", &.{});
        try self.finishFunction(head.items, entry);
        return id;
    }

    /// A `Function` variable, in the list that goes at the top of the entry
    /// block.
    fn newVariable(self: *Emitter, ty: ast.Type, name: []const u8) Allocator.Error!u32 {
        const pointer = try self.pointerTo(.function, try self.typeId(ty));
        const id = try self.b.emitResult(&self.vars, .variable, pointer, &.{@intFromEnum(op.StorageClass.function)});
        if (self.names) try self.b.name(id, name);
        return id;
    }

    fn lookup(self: *const Emitter, name: []const u8) ?Local {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i];
        }
        return null;
    }

    fn popScope(self: *Emitter) void {
        var keep: usize = self.locals.items.len;
        while (keep > 0 and self.locals.items[keep - 1].depth >= self.depth) keep -= 1;
        self.locals.shrinkRetainingCapacity(keep);
        self.depth -= 1;
    }

    // ---------------------------------------------------------------------
    // Blocks and branches
    // ---------------------------------------------------------------------

    fn beginBlock(self: *Emitter, label: u32) Allocator.Error!void {
        try self.b.emit(&self.code, .label, &.{label});
        self.terminated = false;
    }

    /// End the block with a branch, unless it already ended.
    fn branchTo(self: *Emitter, label: u32) Allocator.Error!void {
        if (self.terminated) return;
        try self.b.emit(&self.code, .branch, &.{label});
        self.terminated = true;
    }

    // ---------------------------------------------------------------------
    // Statements
    // ---------------------------------------------------------------------

    fn scoped(self: *Emitter, statements: []const ast.Stmt) Error!void {
        self.depth += 1;
        defer self.popScope();
        try self.statementList(statements);
    }

    fn statementList(self: *Emitter, list: []const ast.Stmt) Error!void {
        for (list) |stmt| {
            // Nothing after a return or a discard can run, and a block that
            // has ended cannot have anything put in it.
            if (self.terminated) return;
            try self.statement(stmt);
        }
    }

    fn statement(self: *Emitter, stmt: ast.Stmt) Error!void {
        const b = self.b;
        switch (stmt.kind) {
            .declare => |d| try self.declare(d),
            .assign => |assign| try self.assignment(assign),
            .expression => |e| _ = try self.evaluate(e),
            .block => |inner| try self.scoped(inner),
            .discard => {
                try b.emit(&self.code, .kill, &.{});
                self.terminated = true;
            },
            .ret => |value| {
                if (value) |v| {
                    const result = try self.evaluate(v);
                    try b.emit(&self.code, .return_value, &.{result.id});
                } else {
                    try b.emit(&self.code, .@"return", &.{});
                }
                self.terminated = true;
            },
            .conditional => |c| try self.conditional(c),
            .loop => |l| try self.forLoop(l),
            .while_loop => |l| try self.whileLoop(l),
        }
    }

    fn declare(self: *Emitter, d: ast.Stmt.Declare) Error!void {
        // The value is read before the name exists, as `sema` reads it.
        const value: ?Value = if (d.value) |v| try self.evaluate(v) else null;
        const variable = try self.newVariable(d.ty, d.name);
        if (value) |v| try self.b.emit(&self.code, .store, &.{ variable, v.id });
        try self.locals.append(self.a(), .{ .name = d.name, .variable = variable, .ty = d.ty, .depth = self.depth });
    }

    fn conditional(self: *Emitter, c: ast.Stmt.Conditional) Error!void {
        const b = self.b;
        const cond = try self.evaluate(c.cond);
        const then_label = b.newId();
        const merge_label = b.newId();
        const else_label = if (c.otherwise != null) b.newId() else merge_label;

        try b.emit(&self.code, .selection_merge, &.{ merge_label, 0 });
        try b.emit(&self.code, .branch_conditional, &.{ cond.id, then_label, else_label });
        self.terminated = true;

        try self.beginBlock(then_label);
        try self.scoped(c.then);
        const then_open = !self.terminated;
        try self.branchTo(merge_label);

        var else_open = true;
        if (c.otherwise) |otherwise| {
            try self.beginBlock(else_label);
            try self.scoped(otherwise);
            else_open = !self.terminated;
            try self.branchTo(merge_label);
        }

        try self.beginBlock(merge_label);
        // With an `else`, the merge block is reached only by an arm that did
        // not end in a return or a discard.
        if (c.otherwise != null and !then_open and !else_open) {
            try b.emit(&self.code, .@"unreachable", &.{});
            self.terminated = true;
        }
    }

    fn forLoop(self: *Emitter, l: ast.Stmt.Loop) Error!void {
        self.depth += 1;
        defer self.popScope();
        if (l.init) |d| try self.declare(d);
        try self.loop(l.cond, l.step, l.body);
    }

    fn whileLoop(self: *Emitter, l: ast.Stmt.WhileLoop) Error!void {
        try self.loop(l.cond, null, l.body);
    }

    /// One loop, the shape SPIR-V wants: a header that says where the loop
    /// merges and where it continues, a block that tests the condition, the
    /// body, and a continue block that runs the step and goes back.
    fn loop(self: *Emitter, cond: ?*ast.Expr, step: ?ast.Stmt.Assign, body: []const ast.Stmt) Error!void {
        const b = self.b;
        const header = b.newId();
        const test_label = b.newId();
        const body_label = b.newId();
        const continue_label = b.newId();
        const merge_label = b.newId();

        try self.branchTo(header);
        try self.beginBlock(header);
        try b.emit(&self.code, .loop_merge, &.{ merge_label, continue_label, 0 });
        try self.branchTo(test_label);

        try self.beginBlock(test_label);
        if (cond) |c| {
            const test_value = try self.evaluate(c);
            try b.emit(&self.code, .branch_conditional, &.{ test_value.id, body_label, merge_label });
            self.terminated = true;
        } else {
            try self.branchTo(body_label);
        }

        try self.beginBlock(body_label);
        try self.scoped(body);
        try self.branchTo(continue_label);

        try self.beginBlock(continue_label);
        if (step) |s| try self.assignment(s);
        try self.branchTo(header);

        try self.beginBlock(merge_label);
        // A loop with no condition leaves only by returning or discarding,
        // so nothing reaches the block after it.
        if (cond == null) {
            try b.emit(&self.code, .@"unreachable", &.{});
            self.terminated = true;
        }
    }

    // ---------------------------------------------------------------------
    // Assignment
    // ---------------------------------------------------------------------

    /// Where a write goes: a variable, and which of its components when the
    /// target was a swizzle. A swizzle of a swizzle is one mapping.
    const Place = struct {
        variable: u32,
        ty: ast.Type,
        /// How many components are written, or zero for the whole variable.
        count: u32 = 0,
        components: [4]u32 = @splat(0),
    };

    fn place(self: *Emitter, expr_: *const ast.Expr) Error!Place {
        switch (expr_.kind) {
            .name => |n| {
                switch (n.binding) {
                    .local => {
                        const local = self.lookup(n.text) orelse return self.unsupported("a name that was not declared");
                        return .{ .variable = local.variable, .ty = local.ty };
                    },
                    .varying => |i| return .{ .variable = self.varying_vars[i], .ty = self.program.varyings[i].ty },
                    .position => return .{ .variable = self.position_var, .ty = .vec4 },
                    .target => return .{ .variable = self.target_var, .ty = .vec4 },
                    else => return self.unsupported("a write to something that cannot be written"),
                }
            },
            .field => |f| {
                var inner = try self.place(f.base);
                var picked: [4]u32 = undefined;
                for (f.name, 0..) |letter, i| picked[i] = swizzleIndex(letter);
                if (inner.count == 0) {
                    inner.components = picked;
                } else {
                    var mapped: [4]u32 = undefined;
                    for (0..f.name.len) |i| mapped[i] = inner.components[picked[i]];
                    inner.components = mapped;
                }
                inner.count = @intCast(f.name.len);
                return inner;
            },
            else => return self.unsupported("a write to a value"),
        }
    }

    fn assignment(self: *Emitter, assign: ast.Stmt.Assign) Error!void {
        const b = self.b;
        var value = try self.evaluate(assign.value);
        const to = try self.place(assign.target);

        if (to.count == 0) {
            if (assign.op.binary()) |operator| {
                const current = try self.load(to.variable, to.ty);
                value = try self.arithmetic(operator, current, value);
            }
            try b.emit(&self.code, .store, &.{ to.variable, value.id });
            return;
        }

        const whole = try self.load(to.variable, to.ty);
        if (assign.op.binary()) |operator| {
            const current = try self.pick(whole, to.components[0..to.count]);
            value = try self.arithmetic(operator, current, value);
        }

        // Put `value` into `whole` at those components: one is an insert, and
        // several are a shuffle of the old vector with the new one, in which
        // the new one's lanes come after the old one's.
        const whole_type = try self.typeId(to.ty);
        const updated: u32 = if (to.count == 1)
            try b.emitResult(&self.code, .composite_insert, whole_type, &.{ value.id, whole.id, to.components[0] })
        else blk: {
            const width = to.ty.components();
            var lanes: [4]u32 = undefined;
            for (0..width) |i| lanes[i] = @intCast(i);
            for (to.components[0..to.count], 0..) |component, lane| lanes[component] = width + @as(u32, @intCast(lane));
            var words: [6]u32 = undefined;
            words[0] = whole.id;
            words[1] = value.id;
            @memcpy(words[2 .. 2 + width], lanes[0..width]);
            break :blk try b.emitResult(&self.code, .vector_shuffle, whole_type, words[0 .. 2 + width]);
        };
        try b.emit(&self.code, .store, &.{ to.variable, updated });
    }

    // ---------------------------------------------------------------------
    // Expressions
    // ---------------------------------------------------------------------

    fn evaluate(self: *Emitter, e: *const ast.Expr) Error!Value {
        switch (e.kind) {
            .number => |n| return self.number(n),
            .boolean => |v| return self.constBool(v),
            .name => |n| return self.nameValue(n),
            .field => |f| {
                const base = try self.evaluate(f.base);
                var picked: [4]u32 = undefined;
                for (f.name, 0..) |letter, i| picked[i] = swizzleIndex(letter);
                return self.pick(base, picked[0..f.name.len]);
            },
            .call => |c| switch (c.target) {
                .construct => |ty| return self.construct(ty, c.args),
                .user => |index| return self.userCall(index, c.args),
                .builtin => |which| return self.builtinCall(e, which, c.args),
                .unresolved => return self.unsupported("a call that was never resolved"),
            },
            .unary => |u| return self.unary(u),
            .binary => |bin| {
                const lhs = try self.evaluate(bin.lhs);
                const rhs = try self.evaluate(bin.rhs);
                return self.arithmetic(bin.op, lhs, rhs);
            },
            .ternary => |t| {
                const cond = try self.evaluate(t.cond);
                const then = try self.evaluate(t.then);
                const other = try self.evaluate(t.other);
                return self.chooseBetween(cond, then, other);
            },
        }
    }

    fn number(self: *Emitter, n: ast.Expr.Number) Error!Value {
        if (n.is_float) {
            const value = std.fmt.parseFloat(f32, n.bytes) catch
                return self.unsupported("a number that is not a float");
            return self.constFloat(value);
        }
        const value = std.fmt.parseInt(i32, n.bytes, 10) catch
            return self.unsupported("an integer that does not fit in 32 bits");
        return self.constInt(value);
    }

    fn load(self: *Emitter, variable: u32, ty: ast.Type) Allocator.Error!Value {
        const id = try self.b.emitResult(&self.code, .load, try self.typeId(ty), &.{variable});
        return .{ .id = id, .ty = ty };
    }

    fn nameValue(self: *Emitter, n: ast.Expr.Name) Error!Value {
        const program = self.program;
        switch (n.binding) {
            .local => {
                const local = self.lookup(n.text) orelse return self.unsupported("a name that was not declared");
                return self.load(local.variable, local.ty);
            },
            .attribute => |i| return self.load(self.attribute_vars[i], program.attributes[i].ty),
            .varying => |i| return self.load(self.varying_vars[i], program.varyings[i].ty),
            .position => return self.load(self.position_var, .vec4),
            .target => return self.load(self.target_var, .vec4),
            .vertex_index => return self.load(try self.builtinInput(.vertex_index), .int),
            .instance_index => return self.load(try self.builtinInput(.instance_index), .int),
            .texture => |i| return self.load(self.texture_vars[i], .texture2d),
            .uniform_field => |where| {
                const field = program.blocks[where.block].fields[where.field];
                const pointer = try self.pointerTo(.uniform, try self.typeId(field.ty));
                const index = try self.constInt(@intCast(where.field));
                const chain = try self.b.emitResult(&self.code, .access_chain, pointer, &.{
                    self.block_vars[where.block], index.id,
                });
                return self.load(chain, field.ty);
            },
            .constant => |index| {
                // A constant is its expression, written where it is used: a
                // literal one is one interned `OpConstant`, and one that reads
                // a uniform is read where it is needed.
                if (self.constant_active[index]) return self.unsupported("a constant that refers to itself");
                self.constant_active[index] = true;
                defer self.constant_active[index] = false;
                return self.evaluate(program.constants[index].value);
            },
        }
    }

    /// A component or several, out of a vector: an extract for one and a
    /// shuffle for more. The whole vector in order is the vector.
    fn pick(self: *Emitter, base: Value, components: []const u32) Error!Value {
        const result_type = ast.Type.vector(@intCast(components.len)).?;
        if (components.len == 1) {
            const id = try self.b.emitResult(&self.code, .composite_extract, try self.typeId(.float), &.{ base.id, components[0] });
            return .{ .id = id, .ty = .float };
        }
        var identity = components.len == base.ty.components();
        for (components, 0..) |component, i| identity = identity and component == i;
        if (identity) return base;

        var words: [6]u32 = undefined;
        words[0] = base.id;
        words[1] = base.id;
        @memcpy(words[2 .. 2 + components.len], components);
        const id = try self.b.emitResult(&self.code, .vector_shuffle, try self.typeId(result_type), words[0 .. 2 + components.len]);
        return .{ .id = id, .ty = result_type };
    }

    fn unary(self: *Emitter, u: ast.Expr.Unary) Error!Value {
        const operand = try self.evaluate(u.operand);
        const opcode = instructionFor(unary_operators.get(u.op), operand.ty) orelse
            return self.unsupported("an operator on a type it does not have");

        if (u.op == .negate) {
            if (operand.known) |known| switch (known) {
                .float => |f| return self.constFloat(-f),
                .int => |i| return self.constInt(-%i),
            };
            if (operand.ty.isMatrix()) {
                return self.eachColumn(opcode, operand, null);
            }
        }
        const id = try self.b.emitResult(&self.code, opcode, try self.typeId(operand.ty), &.{operand.id});
        return .{ .id = id, .ty = operand.ty };
    }

    /// A matrix operation as its columns: SPIR-V's arithmetic does not take a
    /// matrix, so each column is taken out, operated on and put back.
    fn eachColumn(self: *Emitter, opcode: op.Op, matrix: Value, other: ?Value) Error!Value {
        const dimension = matrix.ty.dimension();
        const column_type = ast.Type.vector(dimension).?;
        const column_id = try self.typeId(column_type);
        const columns = try self.a().alloc(u32, dimension);
        for (columns, 0..) |*column, i| {
            const first = try self.b.emitResult(&self.code, .composite_extract, column_id, &.{ matrix.id, @intCast(i) });
            if (other) |second| {
                const second_column = try self.b.emitResult(&self.code, .composite_extract, column_id, &.{ second.id, @intCast(i) });
                column.* = try self.b.emitResult(&self.code, opcode, column_id, &.{ first, second_column });
            } else {
                column.* = try self.b.emitResult(&self.code, opcode, column_id, &.{first});
            }
        }
        const id = try self.b.emitResult(&self.code, .composite_construct, try self.typeId(matrix.ty), columns);
        return .{ .id = id, .ty = matrix.ty };
    }

    // ---------------------------------------------------------------------
    // Arithmetic
    // ---------------------------------------------------------------------

    /// A whole number as a float: the constant, when it is one, and a
    /// conversion when it is not. This is the one implicit conversion in the
    /// language, and it happens here and nowhere else.
    fn asFloat(self: *Emitter, v: Value) Error!Value {
        if (v.ty != .int) return v;
        if (v.known) |known| return self.constFloat(@floatFromInt(known.int));
        const id = try self.b.emitResult(&self.code, .convert_s_to_f, try self.typeId(.float), &.{v.id});
        return .{ .id = id, .ty = .float };
    }

    /// A scalar as a vector of `width` of it.
    fn splat(self: *Emitter, v: Value, width: u32) Error!Value {
        if (width == 1) return v;
        const parts = try self.a().alloc(u32, width);
        @memset(parts, v.id);
        const ty = ast.Type.vector(width).?;
        const type_id = try self.typeId(ty);
        if (v.known != null) {
            // Every part a constant, so the whole is one.
            const operands = try self.a().alloc(u32, width + 1);
            operands[0] = type_id;
            @memcpy(operands[1..], parts);
            return .{ .id = try self.b.intern(.constant_composite, operands), .ty = ty };
        }
        const id = try self.b.emitResult(&self.code, .composite_construct, type_id, parts);
        return .{ .id = id, .ty = ty };
    }

    fn arithmetic(self: *Emitter, operator: ast.BinaryOp, lhs: Value, rhs: Value) Error!Value {
        const row = binary_operators.get(operator);

        if (operator.isLogical()) {
            return self.emitValue(row.boolean.?, .bool, &.{ lhs.id, rhs.id });
        }
        if (operator.isComparison()) {
            // `sema` allows a comparison between two of the same scalar.
            const opcode = instructionFor(row, lhs.ty) orelse
                return self.unsupported("a comparison this type does not have");
            return self.emitValue(opcode, .bool, &.{ lhs.id, rhs.id });
        }
        if (lhs.ty == .int and rhs.ty == .int) {
            return self.emitValue(row.int.?, .int, &.{ lhs.id, rhs.id });
        }

        // Anything else is on floats, and a whole number that met one is now
        // a float.
        const l = try self.asFloat(lhs);
        const r = try self.asFloat(rhs);
        const opcode = row.float orelse return self.unsupported("an operator that has no float form");

        if (l.ty == r.ty) {
            // Two matrices multiplied are a matrix product; any other
            // operator on two is one on each pair of columns.
            if (l.ty.isMatrix()) {
                if (operator == .multiply) return self.emitValue(.matrix_times_matrix, l.ty, &.{ l.id, r.id });
                return self.eachColumn(opcode, l, r);
            }
            return self.emitValue(opcode, l.ty, &.{ l.id, r.id });
        }

        if (operator == .multiply) {
            if (l.ty.isMatrix() and r.ty.isVector()) return self.emitValue(.matrix_times_vector, r.ty, &.{ l.id, r.id });
            if (l.ty.isVector() and r.ty.isMatrix()) return self.emitValue(.vector_times_matrix, l.ty, &.{ l.id, r.id });
        }

        // What is left is a bare float against a vector or a matrix, on
        // either side of the operator.
        const scalar_first = l.ty == .float;
        const scalar = if (scalar_first) l else r;
        const whole = if (scalar_first) r else l;

        if (whole.ty.isVector()) {
            if (operator == .multiply) return self.emitValue(.vector_times_scalar, whole.ty, &.{ whole.id, scalar.id });
            const spread = try self.splat(scalar, whole.ty.components());
            return if (scalar_first)
                self.emitValue(opcode, whole.ty, &.{ spread.id, whole.id })
            else
                self.emitValue(opcode, whole.ty, &.{ whole.id, spread.id });
        }

        if (operator == .multiply) return self.emitValue(.matrix_times_scalar, whole.ty, &.{ whole.id, scalar.id });
        const spread = try self.splat(scalar, whole.ty.dimension());
        const column_type = ast.Type.vector(whole.ty.dimension()).?;
        const column_id = try self.typeId(column_type);
        const columns = try self.a().alloc(u32, whole.ty.dimension());
        for (columns, 0..) |*column, i| {
            const taken = try self.b.emitResult(&self.code, .composite_extract, column_id, &.{ whole.id, @intCast(i) });
            column.* = if (scalar_first)
                try self.b.emitResult(&self.code, opcode, column_id, &.{ spread.id, taken })
            else
                try self.b.emitResult(&self.code, opcode, column_id, &.{ taken, spread.id });
        }
        const id = try self.b.emitResult(&self.code, .composite_construct, try self.typeId(whole.ty), columns);
        return .{ .id = id, .ty = whole.ty };
    }

    fn emitValue(self: *Emitter, opcode: op.Op, ty: ast.Type, operands: []const u32) Error!Value {
        const id = try self.b.emitResult(&self.code, opcode, try self.typeId(ty), operands);
        return .{ .id = id, .ty = ty };
    }

    /// `cond ? a : b`. `OpSelect` on a vector wants a vector of bools in SPIR-V
    /// 1.0, and takes no matrix at all, so a vector's condition is spread and
    /// a matrix goes column by column.
    fn chooseBetween(self: *Emitter, cond: Value, then: Value, other: Value) Error!Value {
        if (then.ty.isMatrix()) {
            const dimension = then.ty.dimension();
            const column_type = ast.Type.vector(dimension).?;
            const column_id = try self.typeId(column_type);
            const columns = try self.a().alloc(u32, dimension);
            for (columns, 0..) |*column, i| {
                const x = try self.b.emitResult(&self.code, .composite_extract, column_id, &.{ then.id, @intCast(i) });
                const y = try self.b.emitResult(&self.code, .composite_extract, column_id, &.{ other.id, @intCast(i) });
                column.* = (try self.chooseBetween(cond, .{ .id = x, .ty = column_type }, .{ .id = y, .ty = column_type })).id;
            }
            const id = try self.b.emitResult(&self.code, .composite_construct, try self.typeId(then.ty), columns);
            return .{ .id = id, .ty = then.ty };
        }

        const width = then.ty.components();
        var condition = cond.id;
        if (width > 1) {
            const parts = try self.a().alloc(u32, width);
            @memset(parts, cond.id);
            condition = try self.b.emitResult(&self.code, .composite_construct, try self.boolVector(width), parts);
        }
        return self.emitValue(.select, then.ty, &.{ condition, then.id, other.id });
    }

    // ---------------------------------------------------------------------
    // Calls
    // ---------------------------------------------------------------------

    fn userCall(self: *Emitter, index: u32, args: []const *ast.Expr) Error!Value {
        const f = self.program.functions[index];
        const words = try self.a().alloc(u32, args.len + 1);
        words[0] = self.function_ids[index];
        for (args, words[1..]) |arg, *word| word.* = (try self.evaluate(arg)).id;
        return self.emitValue(.function_call, f.returns, words);
    }

    /// `vec3(x, y, z)`, `float(i)`, `bool(x)`, and the rest.
    fn construct(self: *Emitter, ty: ast.Type, args: []const *ast.Expr) Error!Value {
        if (ty.isScalar()) return self.convert(try self.evaluate(args[0]), ty);

        // A vector: one scalar fills it, or the parts add up to its width.
        const width = ty.components();
        if (args.len == 1) {
            const only = try self.evaluate(args[0]);
            if (only.ty == ty) return only;
            if (only.ty.isScalar()) return self.splat(try self.asFloat(only), width);
        }

        const parts = try self.a().alloc(Value, args.len);
        var all_known = true;
        for (args, parts) |arg, *part| {
            part.* = try self.asFloat(try self.evaluate(arg));
            all_known = all_known and part.known != null;
        }
        const operands = try self.a().alloc(u32, args.len + 1);
        operands[0] = try self.typeId(ty);
        for (parts, operands[1..]) |part, *word| word.* = part.id;

        // Made of constants, it is one.
        if (all_known and parts.len == width) {
            return .{ .id = try self.b.intern(.constant_composite, operands), .ty = ty };
        }
        const id = try self.b.emitResult(&self.code, .composite_construct, operands[0], operands[1..]);
        return .{ .id = id, .ty = ty };
    }

    /// One scalar as another.
    fn convert(self: *Emitter, v: Value, to: ast.Type) Error!Value {
        if (v.ty == to) return v;
        switch (to) {
            .float => switch (v.ty) {
                .int => return self.asFloat(v),
                .bool => return self.emitValue(.select, .float, &.{ v.id, (try self.constFloat(1.0)).id, (try self.constFloat(0.0)).id }),
                else => {},
            },
            .int => switch (v.ty) {
                .float => return self.emitValue(.convert_f_to_s, .int, &.{v.id}),
                .bool => return self.emitValue(.select, .int, &.{ v.id, (try self.constInt(1)).id, (try self.constInt(0)).id }),
                else => {},
            },
            // Anything that is not zero is true, as it is in GLSL.
            .bool => switch (v.ty) {
                .int => return self.emitValue(.i_not_equal, .bool, &.{ v.id, (try self.constInt(0)).id }),
                .float => return self.emitValue(.f_unord_not_equal, .bool, &.{ v.id, (try self.constFloat(0.0)).id }),
                else => {},
            },
            else => {},
        }
        return self.unsupported("a conversion between these scalars");
    }

    fn builtinCall(self: *Emitter, e: *const ast.Expr, which: ast.Builtin, args: []const *ast.Expr) Error!Value {
        const row = builtins.row(which);
        const lowering = row.spirv;

        switch (lowering.lower) {
            .recipe => |recipe| switch (recipe) {
                .sample => return self.sample(args),
                .mod, .dot => {},
            },
            else => {},
        }

        const values = try self.a().alloc(Value, args.len);
        for (args, values) |arg, *value| value.* = try self.asFloat(try self.evaluate(arg));

        // A scalar among vectors is spread to the width of the widest, for
        // the rows that ask for it.
        var width: u32 = 1;
        for (values) |value| width = @max(width, value.ty.components());
        if (lowering.widen) {
            for (values) |*value| {
                if (value.ty == .float) value.* = try self.splat(value.*, width);
            }
        }

        var operands: std.ArrayList(u32) = .empty;
        for (values) |value| try operands.append(self.a(), value.id);
        for (lowering.constants) |constant| {
            const c = try self.splat(try self.constFloat(constant), values[0].ty.components());
            try operands.append(self.a(), c.id);
        }

        switch (lowering.lower) {
            .ext => |inst| return self.extended(e.ty, inst, operands.items),
            .ext_by_arity => |by| return self.extended(e.ty, if (args.len == 2) by.two else by.one, operands.items),
            .core => |opcode| {
                if (opcode == .dpdx or opcode == .dpdy) {
                    if (self.stage != .fragment) {
                        return self.unsupported("a derivative (`ddx`, `ddy`) outside the fragment stage");
                    }
                }
                return self.emitValue(opcode, e.ty, operands.items);
            },
            .recipe => |recipe| switch (recipe) {
                .sample => unreachable,
                // GLSL's `mod`, which is `x - y * floor(x / y)`.
                .mod => {
                    const quotient = try self.emitValue(.f_div, e.ty, &.{ values[0].id, values[1].id });
                    const floor = try self.extended(e.ty, .floor, &.{quotient.id});
                    const product = try self.emitValue(.f_mul, e.ty, &.{ values[1].id, floor.id });
                    return self.emitValue(.f_sub, e.ty, &.{ values[0].id, product.id });
                },
                // `OpDot` is on vectors; two scalars multiply.
                .dot => {
                    if (values[0].ty == .float) return self.emitValue(.f_mul, .float, &.{ values[0].id, values[1].id });
                    return self.emitValue(.dot, .float, &.{ values[0].id, values[1].id });
                },
            },
        }
    }

    fn extended(self: *Emitter, ty: ast.Type, inst: op.Std450, operands: []const u32) Error!Value {
        const words = try self.a().alloc(u32, operands.len + 2);
        words[0] = self.b.glslStd450();
        words[1] = @intFromEnum(inst);
        @memcpy(words[2..], operands);
        return self.emitValue(.ext_inst, ty, words);
    }

    /// `sample(t, uv)`: the texture is read as the combined image and sampler
    /// it is, and sampled - with the implicit level a fragment stage has, and
    /// with level zero anywhere it has none.
    fn sample(self: *Emitter, args: []const *ast.Expr) Error!Value {
        const image = try self.evaluate(args[0]);
        const coordinate = try self.evaluate(args[1]);
        if (self.stage == .fragment) {
            return self.emitValue(.image_sample_implicit_lod, .vec4, &.{ image.id, coordinate.id });
        }
        const level = try self.constFloat(0.0);
        return self.emitValue(.image_sample_explicit_lod, .vec4, &.{
            image.id, coordinate.id, op.image_operand_lod, level.id,
        });
    }
};

/// `x`, `y`, `z`, `w` and `r`, `g`, `b`, `a` are components 0 to 3.
fn swizzleIndex(letter: u8) u32 {
    return @intCast(std.mem.indexOfScalar(u8, "xyzwrgba", letter).? % 4);
}

test {
    _ = op;
    _ = Builder;
}
