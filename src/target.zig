// SPDX-License-Identifier: BSL-1.0

//! What the checked tree can be written out as, as a table.
//!
//! `compile` used to call three emitters by name and `Module` used to have
//! three fields to put what they wrote in. A fourth output would have meant
//! editing both, and a fifth the same. Now an output is a row - a name, the
//! family of language it belongs to, and the function that writes it - and
//! the compiler walks the rows it was asked for.
//!
//! ```zig
//! pub const builtin_targets = [_]Target{
//!     .{ .name = "glsl_330",     .family = .glsl,  .emit = .{ .text = glsl.emit } },
//!     .{ .name = "glsl_es_300",  .family = .glsl,  .emit = .{ .text = glsl.emitEs } },
//!     .{ .name = "hlsl_50",      .family = .hlsl,  .emit = .{ .text = hlsl.emit } },
//!     .{ .name = "spirv_vulkan", .family = .spirv, .emit = .{ .words = spirv.emitTarget } },
//! };
//! ```
//!
//! **An emitter is text or words.** A text emitter writes one stage to a
//! writer, as `glsl.emit` and `hlsl.emit` do. A words emitter returns one
//! stage as a `[]u32`, which is what SPIR-V is and what a DXBC or DXIL packer
//! would be. Either way the compiler calls it once for the vertex stage and
//! once for the fragment stage, and `Module.output` hands back what came out.
//!
//! **A target is asked for, by id.** `Id` is the row's position in the table,
//! with the built-in rows first, so the names of the four that exist are
//! stable and a table with more rows after them keeps them. What runs is
//! `Options.targets`; the default is the three text rows, so `compile` costs
//! what it always did and SPIR-V is only written when somebody wants it.
//!
//! ## Adding a target without touching this library
//!
//! The table is a comptime array of rows, and `builtin_targets ++ mine` is
//! one too. A program that wants a fifth output builds its own and gives the
//! compiler that table:
//!
//! ```zig
//! const shader = @import("fluxion_shader");
//!
//! fn emitGlsl450(program: *const shader.ast.Program, stage: shader.sema.Where, w: *std.Io.Writer) !void {
//!     // ...whatever it writes; `shader.glsl.emitDialect` is a starting point.
//! }
//!
//! const table = shader.target.builtin_targets ++ [_]shader.Target{
//!     .{ .name = "glsl_450", .family = .glsl, .emit = .{ .text = emitGlsl450 } },
//! };
//! const glsl_450 = shader.target.idOf(&table, "glsl_450");
//!
//! var module = try shader.compileWith(gpa, source, &log, .{
//!     .table = &table,
//!     .targets = .of(&.{ .glsl_330, glsl_450 }),
//! });
//! const written = module.output(glsl_450).text; // .vertex and .fragment
//! ```
//!
//! **`family` is what a row shares with the rows around it**, and it is how
//! the builtin table (`builtins.zig`) knows what to give a target that is a
//! new dialect of a language it already knows: a `glsl_450` row reads the
//! `glsl` column of every builtin, because that is what its family is. A
//! target in a family that does not exist yet is one new column in that table
//! and one new variant of `Family` - the only places a genuinely new
//! language is written down - plus its row here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const sema = @import("sema.zig");
const glsl = @import("glsl.zig");
const hlsl = @import("hlsl.zig");
const spirv = @import("spirv.zig");

/// The languages an emitter can be a dialect of. Each one is a column in the
/// builtin table (`builtins.Row`), which is what makes a new dialect of one
/// of them a row here and nothing else.
pub const Family = enum { glsl, hlsl, spirv };

/// What an emitter hands back for one stage.
pub const OutputKind = enum {
    /// Source text, null-terminated, for a driver's compiler.
    text,
    /// Binary words, for a driver that takes a binary.
    words,
};

/// One output. See the module comment for how to add one.
pub const Target = struct {
    /// Stable, and how `find` looks a row up. Lower case, with the version in
    /// it when there is more than one: `glsl_330`, `spirv_vulkan`.
    name: []const u8,
    family: Family,
    emit: Emit,

    pub const TextFn = *const fn (*const ast.Program, sema.Where, *std.Io.Writer) std.Io.Writer.Error!void;
    pub const WordsFn = *const fn (Allocator, *Request) EmitError![]u32;

    /// The function, and with it whether this row makes text or words: the
    /// kind of a row is the tag of its emitter, so the two cannot disagree.
    pub const Emit = union(OutputKind) {
        text: TextFn,
        words: WordsFn,
    };

    pub fn kind(self: Target) OutputKind {
        return self.emit;
    }
};

/// What a words emitter is given. Everything it may read is in here, and the
/// one thing it may say back is why it could not.
pub const Request = struct {
    program: *const ast.Program,
    stage: sema.Where,
    binding: BindingLayout,
    debug_names: bool,
    /// Set by an emitter that returns `error.Unsupported`, to a message that
    /// is a static string. The compiler writes it to the log.
    reason: []const u8 = "",
};

pub const EmitError = error{
    /// The target cannot express this shader. `Request.reason` says why.
    Unsupported,
} || Allocator.Error;

/// Where each kind of resource goes, for the targets that number them in
/// spaces: SPIR-V's descriptor sets, and a Direct3D register space later.
///
/// **The binding of a resource is a pure function of its kind and its slot**:
/// a uniform block at slot `n` is binding `n` of `uniform_set`, and a texture
/// at slot `n` is binding `n` of `texture_set`. Nothing is added, nothing is
/// a magic base. That is the same contract the RHI has - two slot spaces,
/// `setUniformBuffer(slot)` and `setTexture(slot)` - so a pipeline layout is
/// two sets, and the shader, the layout and the calls agree by construction.
pub const BindingLayout = struct {
    uniform_set: u32 = 0,
    texture_set: u32 = 1,
};

/// The rows this library ships, in the order their ids are.
pub const builtin_targets = [_]Target{
    .{ .name = "glsl_330", .family = .glsl, .emit = .{ .text = glsl.emit } },
    .{ .name = "glsl_es_300", .family = .glsl, .emit = .{ .text = glsl.emitEs } },
    .{ .name = "hlsl_50", .family = .hlsl, .emit = .{ .text = hlsl.emit } },
    .{ .name = "spirv_vulkan", .family = .spirv, .emit = .{ .words = spirv.emitTarget } },
};

/// A row of a table, by its position. The four that ship have names here;
/// a table with more rows after them has ids past these, from `idOf`.
pub const Id = enum(u8) {
    /// Desktop OpenGL 3.3: `Module.glsl`.
    glsl_330 = 0,
    /// WebGL 2, OpenGL ES 3.0: `Module.glsl_es`.
    glsl_es_300 = 1,
    /// Direct3D 11, and the source the Direct3D 12 toolchain compiles:
    /// `Module.hlsl`.
    hlsl_50 = 2,
    /// Vulkan 1.0, as SPIR-V 1.0: one module per stage, in
    /// `Module.output(.spirv_vulkan).words`.
    spirv_vulkan = 3,
    _,
};

comptime {
    // The named ids and the shipped rows are the same list, or neither is
    // trustworthy.
    for (@typeInfo(Id).@"enum".fields) |field| {
        if (field.value >= builtin_targets.len or
            !std.mem.eql(u8, builtin_targets[field.value].name, field.name))
        {
            @compileError("`target.Id." ++ field.name ++ "` is not the row of that name in `builtin_targets`");
        }
    }
    if (@typeInfo(Id).@"enum".fields.len != builtin_targets.len) {
        @compileError("a row of `builtin_targets` has no name in `target.Id`");
    }
}

/// Which rows of a table to run, as a set of ids.
pub const Set = struct {
    bits: u64 = 0,

    /// The most rows a table can have.
    pub const capacity = 64;

    /// The three text targets: what `compile` writes.
    pub const text_targets: Set = .of(&.{ .glsl_330, .glsl_es_300, .hlsl_50 });

    pub fn of(ids: []const Id) Set {
        var set: Set = .{};
        for (ids) |id| set = set.with(id);
        return set;
    }

    pub fn with(self: Set, id: Id) Set {
        std.debug.assert(@intFromEnum(id) < capacity);
        return .{ .bits = self.bits | (@as(u64, 1) << @intCast(@intFromEnum(id))) };
    }

    pub fn contains(self: Set, id: Id) bool {
        if (@intFromEnum(id) >= capacity) return false;
        return self.bits & (@as(u64, 1) << @intCast(@intFromEnum(id))) != 0;
    }
};

/// What `compileWith` is asked for.
pub const Options = struct {
    /// Which rows of `table` to run. The default is the three text ones, so
    /// that `compile` costs what it always has; SPIR-V is asked for by name.
    targets: Set = .text_targets,
    /// The rows there are. `builtin_targets`, or that with more after it: a
    /// table has to start with the shipped rows, because `Module.glsl` and
    /// the rest are read out of them by position.
    table: []const Target = &builtin_targets,
    /// Where SPIR-V puts uniform blocks and textures.
    binding: BindingLayout = .{},
    /// SPIR-V: write `OpName` for every variable, function and member, so a
    /// disassembly reads like the source. Off by default, because a name is
    /// bytes a driver reads past.
    debug_names: bool = false,
};

/// The id of the row called `name`, or null.
pub fn find(table: []const Target, name: []const u8) ?Id {
    for (table, 0..) |row, index| {
        if (std.mem.eql(u8, row.name, name)) return @enumFromInt(index);
    }
    return null;
}

/// The id of a row, which has to be there: the way to name a row of a table
/// of one's own.
pub fn idOf(comptime table: []const Target, comptime name: []const u8) Id {
    return find(table, name) orelse
        @compileError("this table has no target called `" ++ name ++ "`");
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the shipped rows are found by name, and by their ids" {
    try testing.expectEqual(Id.glsl_330, find(&builtin_targets, "glsl_330").?);
    try testing.expectEqual(Id.spirv_vulkan, find(&builtin_targets, "spirv_vulkan").?);
    try testing.expectEqual(@as(?Id, null), find(&builtin_targets, "dxil"));
    try testing.expectEqual(OutputKind.text, builtin_targets[@intFromEnum(Id.hlsl_50)].kind());
    try testing.expectEqual(OutputKind.words, builtin_targets[@intFromEnum(Id.spirv_vulkan)].kind());
    try testing.expectEqual(Family.spirv, builtin_targets[@intFromEnum(Id.spirv_vulkan)].family);
}

test "a set holds ids" {
    const set: Set = .of(&.{ .glsl_330, .spirv_vulkan });
    try testing.expect(set.contains(.glsl_330));
    try testing.expect(!set.contains(.hlsl_50));
    try testing.expect(set.contains(.spirv_vulkan));
    try testing.expect(!set.contains(@enumFromInt(200)));
    try testing.expect(Set.text_targets.contains(.glsl_es_300));
    try testing.expect(!Set.text_targets.contains(.spirv_vulkan));
}

fn nothing(_: *const ast.Program, _: sema.Where, _: *std.Io.Writer) std.Io.Writer.Error!void {}

test "a table of one's own is the shipped rows and more" {
    const table = builtin_targets ++ [_]Target{
        .{ .name = "glsl_450", .family = .glsl, .emit = .{ .text = nothing } },
    };
    try testing.expectEqual(@as(usize, 5), table.len);
    const mine = comptime idOf(&table, "glsl_450");
    try testing.expectEqual(@as(u8, 4), @intFromEnum(mine));
    try testing.expectEqual(Id.spirv_vulkan, comptime idOf(&table, "spirv_vulkan"));
}
