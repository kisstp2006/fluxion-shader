// SPDX-License-Identifier: BSL-1.0

//! SPIR-V's numbers, as data.
//!
//! Every value in here is the one in the Khronos grammar
//! (`spirv.core.grammar.json` and `extinst.glsl.std.450.grammar.json`), and
//! only the ones this library writes are listed. An instruction is a row:
//! its number, whether it carries a result type and a result id, and the
//! kinds of the operands after them. The emitter reads the number, and the
//! structural checker in the tests reads the rest to know which words of a
//! stream are ids that have to be defined and which are literals.
//!
//! Nothing here is code that does anything. Adding an instruction is adding
//! a tag and one line of `info`.

/// First word of every module.
pub const magic: u32 = 0x07230203;

/// SPIR-V 1.0, which is what Vulkan 1.0 takes and what every later Vulkan
/// still accepts.
pub const version_1_0: u32 = 0x0001_0000;

/// What the opcodes are, by their number in the specification.
pub const Op = enum(u16) {
    nop = 0,
    undef = 1,
    source = 3,
    name = 5,
    member_name = 6,
    extension = 10,
    ext_inst_import = 11,
    ext_inst = 12,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_bool = 20,
    type_int = 21,
    type_float = 22,
    type_vector = 23,
    type_matrix = 24,
    type_image = 25,
    type_sampled_image = 27,
    type_struct = 30,
    type_pointer = 32,
    type_function = 33,
    constant_true = 41,
    constant_false = 42,
    constant = 43,
    constant_composite = 44,
    function = 54,
    function_parameter = 55,
    function_end = 56,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    access_chain = 65,
    decorate = 71,
    member_decorate = 72,
    vector_shuffle = 79,
    composite_construct = 80,
    composite_extract = 81,
    composite_insert = 82,
    transpose = 84,
    sampled_image = 86,
    image_sample_implicit_lod = 87,
    image_sample_explicit_lod = 88,
    convert_f_to_s = 110,
    convert_s_to_f = 111,
    s_negate = 126,
    f_negate = 127,
    i_add = 128,
    f_add = 129,
    i_sub = 130,
    f_sub = 131,
    i_mul = 132,
    f_mul = 133,
    s_div = 135,
    f_div = 136,
    s_rem = 138,
    vector_times_scalar = 142,
    matrix_times_scalar = 143,
    vector_times_matrix = 144,
    matrix_times_vector = 145,
    matrix_times_matrix = 146,
    dot = 148,
    logical_equal = 164,
    logical_not_equal = 165,
    logical_or = 166,
    logical_and = 167,
    logical_not = 168,
    select = 169,
    i_equal = 170,
    i_not_equal = 171,
    s_greater_than = 173,
    s_greater_than_equal = 175,
    s_less_than = 177,
    s_less_than_equal = 179,
    f_ord_equal = 180,
    f_unord_not_equal = 183,
    f_ord_less_than = 184,
    f_ord_greater_than = 186,
    f_ord_less_than_equal = 188,
    f_ord_greater_than_equal = 190,
    dpdx = 207,
    dpdy = 208,
    loop_merge = 246,
    selection_merge = 247,
    label = 248,
    branch = 249,
    branch_conditional = 250,
    kill = 252,
    @"return" = 253,
    return_value = 254,
    @"unreachable" = 255,
};

/// The instructions of the `GLSL.std.450` extended set, by their number in
/// it. What a builtin lowers to when it has no core instruction of its own.
pub const Std450 = enum(u32) {
    round = 1,
    round_even = 2,
    trunc = 3,
    f_abs = 4,
    s_abs = 5,
    f_sign = 6,
    s_sign = 7,
    floor = 8,
    ceil = 9,
    fract = 10,
    radians = 11,
    degrees = 12,
    sin = 13,
    cos = 14,
    tan = 15,
    asin = 16,
    acos = 17,
    atan = 18,
    sinh = 19,
    cosh = 20,
    tanh = 21,
    asinh = 22,
    acosh = 23,
    atanh = 24,
    atan2 = 25,
    pow = 26,
    exp = 27,
    log = 28,
    exp2 = 29,
    log2 = 30,
    sqrt = 31,
    inverse_sqrt = 32,
    determinant = 33,
    matrix_inverse = 34,
    f_min = 37,
    u_min = 38,
    s_min = 39,
    f_max = 40,
    u_max = 41,
    s_max = 42,
    f_clamp = 43,
    u_clamp = 44,
    s_clamp = 45,
    f_mix = 46,
    step = 48,
    smooth_step = 49,
    fma = 50,
    length = 66,
    distance = 67,
    cross = 68,
    normalize = 69,
    face_forward = 70,
    reflect = 71,
    refract = 72,
    n_min = 79,
    n_max = 80,
    n_clamp = 81,
};

/// The name the extended set is imported under.
pub const std450_name = "GLSL.std.450";

pub const Capability = enum(u32) { shader = 1 };
pub const AddressingModel = enum(u32) { logical = 0 };
pub const MemoryModel = enum(u32) { glsl450 = 1 };
pub const ExecutionModel = enum(u32) { vertex = 0, fragment = 4 };
pub const ExecutionMode = enum(u32) { origin_upper_left = 7 };

pub const StorageClass = enum(u32) {
    uniform_constant = 0,
    input = 1,
    uniform = 2,
    output = 3,
    private = 6,
    function = 7,
};

pub const Decoration = enum(u32) {
    block = 2,
    col_major = 5,
    matrix_stride = 7,
    built_in = 11,
    flat = 14,
    location = 30,
    binding = 33,
    descriptor_set = 34,
    offset = 35,
};

pub const BuiltIn = enum(u32) {
    position = 0,
    vertex_index = 42,
    instance_index = 43,
};

pub const Dim = enum(u32) { @"2d" = 1 };
pub const ImageFormat = enum(u32) { unknown = 0 };

/// `ImageOperands`, the mask that follows the coordinate of a sample.
pub const image_operand_lod: u32 = 0x2;

// -------------------------------------------------------------------------
// The shape of an instruction
// -------------------------------------------------------------------------

/// What one operand word is.
pub const Kind = enum {
    /// A single id that some other instruction defines.
    id,
    /// A single literal or enumerant.
    lit,
    /// A nul-terminated string, packed four bytes to a word.
    str,
    /// Every remaining word is an id.
    ids,
    /// Every remaining word is a literal.
    lits,
};

/// What follows the first word of an instruction: the result type and the
/// result id where it has them, and then these.
pub const Info = struct {
    has_type: bool = false,
    has_result: bool = false,
    operands: []const Kind = &.{},
};

pub fn info(op: Op) Info {
    const t = true;
    return switch (op) {
        .nop => .{},
        .undef => .{ .has_type = t, .has_result = t },
        .source => .{ .operands = &.{ .lit, .lit } },
        .name => .{ .operands = &.{ .id, .str } },
        .member_name => .{ .operands = &.{ .id, .lit, .str } },
        .extension => .{ .operands = &.{.str} },
        .ext_inst_import => .{ .has_result = t, .operands = &.{.str} },
        .ext_inst => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .lit, .ids } },
        .memory_model => .{ .operands = &.{ .lit, .lit } },
        .entry_point => .{ .operands = &.{ .lit, .id, .str, .ids } },
        .execution_mode => .{ .operands = &.{ .id, .lit, .lits } },
        .capability => .{ .operands = &.{.lit} },

        .type_void, .type_bool => .{ .has_result = t },
        .type_int => .{ .has_result = t, .operands = &.{ .lit, .lit } },
        .type_float => .{ .has_result = t, .operands = &.{.lit} },
        .type_vector, .type_matrix => .{ .has_result = t, .operands = &.{ .id, .lit } },
        .type_image => .{ .has_result = t, .operands = &.{ .id, .lit, .lit, .lit, .lit, .lit, .lit } },
        .type_sampled_image => .{ .has_result = t, .operands = &.{.id} },
        .type_struct => .{ .has_result = t, .operands = &.{.ids} },
        .type_pointer => .{ .has_result = t, .operands = &.{ .lit, .id } },
        .type_function => .{ .has_result = t, .operands = &.{ .id, .ids } },

        .constant_true, .constant_false => .{ .has_type = t, .has_result = t },
        .constant => .{ .has_type = t, .has_result = t, .operands = &.{.lits} },
        .constant_composite => .{ .has_type = t, .has_result = t, .operands = &.{.ids} },

        .function => .{ .has_type = t, .has_result = t, .operands = &.{ .lit, .id } },
        .function_parameter => .{ .has_type = t, .has_result = t },
        .function_end => .{},
        .function_call => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .ids } },

        .variable => .{ .has_type = t, .has_result = t, .operands = &.{ .lit, .ids } },
        .load => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .lits } },
        .store => .{ .operands = &.{ .id, .id, .lits } },
        .access_chain => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .ids } },

        .decorate => .{ .operands = &.{ .id, .lit, .lits } },
        .member_decorate => .{ .operands = &.{ .id, .lit, .lit, .lits } },

        .vector_shuffle => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id, .lits } },
        .composite_construct => .{ .has_type = t, .has_result = t, .operands = &.{.ids} },
        .composite_extract => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .lits } },
        .composite_insert => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id, .lits } },
        .transpose => .{ .has_type = t, .has_result = t, .operands = &.{.id} },

        .sampled_image => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id } },
        .image_sample_implicit_lod => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id, .lits } },
        .image_sample_explicit_lod => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id, .lit, .ids } },

        .convert_f_to_s, .convert_s_to_f, .s_negate, .f_negate, .logical_not, .dpdx, .dpdy => .{
            .has_type = t,
            .has_result = t,
            .operands = &.{.id},
        },

        .i_add, .f_add, .i_sub, .f_sub, .i_mul, .f_mul, .s_div, .f_div, .s_rem, .vector_times_scalar, .matrix_times_scalar, .vector_times_matrix, .matrix_times_vector, .matrix_times_matrix, .dot, .logical_equal, .logical_not_equal, .logical_or, .logical_and, .i_equal, .i_not_equal, .s_greater_than, .s_greater_than_equal, .s_less_than, .s_less_than_equal, .f_ord_equal, .f_unord_not_equal, .f_ord_less_than, .f_ord_greater_than, .f_ord_less_than_equal, .f_ord_greater_than_equal => .{
            .has_type = t,
            .has_result = t,
            .operands = &.{ .id, .id },
        },

        .select => .{ .has_type = t, .has_result = t, .operands = &.{ .id, .id, .id } },

        .loop_merge => .{ .operands = &.{ .id, .id, .lit, .lits } },
        .selection_merge => .{ .operands = &.{ .id, .lit } },
        .label => .{ .has_result = t },
        .branch => .{ .operands = &.{.id} },
        .branch_conditional => .{ .operands = &.{ .id, .id, .id, .lits } },
        .kill, .@"return", .@"unreachable" => .{},
        .return_value => .{ .operands = &.{.id} },
    };
}

/// Which part of a module an instruction may appear in, in the order the
/// specification lays a module out. `variable` is in `.types` at module scope
/// and in `.functions` inside a function; the checker tells them apart.
pub const Section = enum(u8) {
    capabilities,
    extensions,
    ext_imports,
    memory_model,
    entry_points,
    execution_modes,
    debug,
    annotations,
    types,
    functions,
};

pub fn section(op: Op) Section {
    return switch (op) {
        .capability => .capabilities,
        .extension => .extensions,
        .ext_inst_import => .ext_imports,
        .memory_model => .memory_model,
        .entry_point => .entry_points,
        .execution_mode => .execution_modes,
        .source, .name, .member_name => .debug,
        .decorate, .member_decorate => .annotations,
        .type_void, .type_bool, .type_int, .type_float, .type_vector, .type_matrix, .type_image, .type_sampled_image, .type_struct, .type_pointer, .type_function, .constant_true, .constant_false, .constant, .constant_composite, .undef, .variable => .types,
        else => .functions,
    };
}

/// The number of words a string of `len` bytes takes, terminator included.
pub fn stringWords(len: usize) usize {
    return len / 4 + 1;
}

const std = @import("std");

test "the numbers are the specification's" {
    // A few of each kind, checked against the grammar by eye once and held
    // here so that an edit which shifts one is a failure rather than a
    // validator complaint about something else.
    try std.testing.expectEqual(@as(u16, 12), @intFromEnum(Op.ext_inst));
    try std.testing.expectEqual(@as(u16, 54), @intFromEnum(Op.function));
    try std.testing.expectEqual(@as(u16, 87), @intFromEnum(Op.image_sample_implicit_lod));
    try std.testing.expectEqual(@as(u16, 252), @intFromEnum(Op.kill));
    try std.testing.expectEqual(@as(u32, 43), @intFromEnum(Std450.f_clamp));
    try std.testing.expectEqual(@as(u32, 25), @intFromEnum(Std450.atan2));
    try std.testing.expectEqual(@as(u32, 34), @intFromEnum(Decoration.descriptor_set));
    try std.testing.expectEqual(@as(u32, 42), @intFromEnum(BuiltIn.vertex_index));
}

test "every instruction has a row, and a result type never comes without a result" {
    inline for (@typeInfo(Op).@"enum".fields) |field| {
        const op: Op = @enumFromInt(field.value);
        const i = info(op);
        if (i.has_type) try std.testing.expect(i.has_result);
    }
}
