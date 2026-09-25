// SPDX-License-Identifier: BSL-1.0

//! What comes out: what every target wrote, and what a program has to know to
//! bind it.
//!
//! The four languages, two stages each, in the shape
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) takes them - and
//! beside them the numbers a pipeline is described with, so that a location,
//! a slot and a name are written down once, in the shader, and read back from
//! it rather than repeated. Handed over whole, the one shader runs on every
//! backend, and nothing in the program asks which one it is on:
//!
//! ```zig
//! var module = try shader.compile(gpa, source, &log);
//! defer module.deinit();
//!
//! const handle = try device.createShader(.{
//!     .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
//!     .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
//!     .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
//!     .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
//! });
//! ```
//!
//! **`glsl`, `glsl_es`, `hlsl` and `spirv` are four of the rows of
//! `output`.** The targets are a table (see `target`), and what each one
//! wrote is in `outputs` at the position of its id; `output(id)` reads it, as
//! text or as binary words. The four fields are there because every caller
//! wants them and should not have to ask for them by id. A target that was
//! not asked for leaves its field empty and its output `.none`.
//!
//! Everything in here is owned by the module and dies with `deinit`.

const std = @import("std");
const ast = @import("ast.zig");
const target = @import("target.zig");

const Module = @This();

/// One language's two stages. Both are null-terminated, because every shader
/// compiler in both worlds takes a C string.
pub const Sources = struct {
    vertex: [:0]const u8,
    fragment: [:0]const u8,
};

/// One binary target's two stages: SPIR-V, or whatever a words emitter makes.
pub const Words = struct {
    vertex: []const u32,
    fragment: []const u32,

    /// The vertex stage as the bytes a driver's create-shader call takes.
    /// The slice is four-byte aligned, which `vkCreateShaderModule` needs and
    /// a cast from `[]u8` would not promise.
    pub fn vertexBytes(self: Words) []align(4) const u8 {
        return std.mem.sliceAsBytes(self.vertex);
    }

    pub fn fragmentBytes(self: Words) []align(4) const u8 {
        return std.mem.sliceAsBytes(self.fragment);
    }
};

/// What one target produced.
pub const Output = union(enum) {
    /// The target was not asked for, or the id is not a row of the table.
    none,
    text: Sources,
    words: Words,
};

pub const Attribute = struct {
    name: []const u8,
    ty: ast.Type,
    /// `layout(location = n)` on one backend, `ATTRn` on the other.
    location: u32,
};

pub const Field = struct {
    name: []const u8,
    ty: ast.Type,
    /// Bytes from the start of the block, under `std140`: what OpenGL, WebGL
    /// and Vulkan (in the SPIR-V's `Offset` decorations) use, and what the
    /// HLSL says of each member with a `packoffset`.
    offset: u32,
    /// What the shader says the field holds until the program says otherwise
    /// - `float strength = 0.5;` - one float per component, or null when it
    /// says nothing. Only numbers are written there, so this is all of it.
    default: ?[]const f32 = null,
};

pub const Block = struct {
    /// What to name in `PipelineDesc.uniform_blocks`, and what the `cbuffer`
    /// is called.
    name: []const u8,
    slot: u32,
    /// What to make the buffer, in bytes. Already a multiple of sixteen.
    size: u32,
    fields: []const Field,

    /// Where one field starts, or null if there is no field by that name.
    pub fn offsetOf(self: Block, name: []const u8) ?u32 {
        for (self.fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.offset;
        }
        return null;
    }
};

pub const Texture = struct {
    /// What to name in `PipelineDesc.textures`, and what the `Texture2D` is
    /// called.
    name: []const u8,
    slot: u32,
};

arena: std.heap.ArenaAllocator,
/// GLSL 3.30 core, for desktop OpenGL. Empty when `target.Id.glsl_330` was
/// not asked for.
glsl: Sources,
/// GLSL ES 3.00, for WebGL 2. The same text as `glsl` under a different
/// first few lines - see `glsl.Dialect`.
glsl_es: Sources,
/// HLSL for shader model 5.0, for Direct3D 11 - and, unchanged, the input the
/// Direct3D 12 toolchain compiles to DXBC or DXIL.
hlsl: Sources,
/// SPIR-V for Vulkan 1.0, one module per stage. Empty when
/// `target.Id.spirv_vulkan` was not asked for.
spirv: Words,
/// What every target of the table wrote, at the position of its id. Read it
/// with `output`.
outputs: []const Output,
/// Where the SPIR-V target put uniform blocks and textures, so that a
/// pipeline layout can be made from the same numbers the shader was written
/// with. See `target.BindingLayout`.
binding: target.BindingLayout = .{},
/// In the order they were declared, which is not the order of their
/// locations.
attributes: []const Attribute,
blocks: []const Block,
textures: []const Texture,
/// Worked out on demand by `uniformBlockNames` and `textureNames`, and kept
/// so that asking twice costs once.
block_names: ?[]const [:0]const u8 = null,
texture_names: ?[]const [:0]const u8 = null,

pub fn deinit(self: *Module) void {
    self.arena.deinit();
    self.* = undefined;
}

/// What the target with this id wrote, or `.none` if it was not asked for.
///
/// ```zig
/// const vertex_words = module.output(.spirv_vulkan).words.vertex;
/// ```
pub fn output(self: *const Module, id: target.Id) Output {
    const index = @intFromEnum(id);
    if (index >= self.outputs.len) return .none;
    return self.outputs[index];
}

/// The block bound to `slot`, or null.
pub fn blockAt(self: *const Module, slot: u32) ?Block {
    for (self.blocks) |b| {
        if (b.slot == slot) return b;
    }
    return null;
}

/// The block called `name`, or null.
pub fn block(self: *const Module, name: []const u8) ?Block {
    for (self.blocks) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// The uniform block names in slot order, which is the list
/// `PipelineDesc.uniform_blocks` is: slot `n` is entry `n`. Built into the
/// module's own memory the first time it is asked for, so the caller frees
/// nothing.
///
/// Null when the slots have a hole in them - a shader that binds 0 and 2 has
/// no positional list, and saying so is better than handing back an entry
/// that names nothing.
pub fn uniformBlockNames(self: *Module) std.mem.Allocator.Error!?[]const [:0]const u8 {
    if (self.block_names) |names| return names;
    const names = (try self.bySlot(self.blocks.len, blockSlot, blockName)) orelse return null;
    self.block_names = names;
    return names;
}

/// The texture names in slot order, for `PipelineDesc.textures`.
pub fn textureNames(self: *Module) std.mem.Allocator.Error!?[]const [:0]const u8 {
    if (self.texture_names) |names| return names;
    const names = (try self.bySlot(self.textures.len, textureSlot, textureName)) orelse return null;
    self.texture_names = names;
    return names;
}

fn blockSlot(self: *const Module, index: usize) u32 {
    return self.blocks[index].slot;
}

fn blockName(self: *const Module, index: usize) []const u8 {
    return self.blocks[index].name;
}

fn textureSlot(self: *const Module, index: usize) u32 {
    return self.textures[index].slot;
}

fn textureName(self: *const Module, index: usize) []const u8 {
    return self.textures[index].name;
}

fn bySlot(
    self: *Module,
    count: usize,
    comptime slotOf: fn (*const Module, usize) u32,
    comptime nameOf: fn (*const Module, usize) []const u8,
) std.mem.Allocator.Error!?[]const [:0]const u8 {
    const gpa = self.arena.allocator();
    const names = try gpa.alloc([:0]const u8, count);
    var filled = try gpa.alloc(bool, count);
    @memset(filled, false);

    for (0..count) |index| {
        const slot = slotOf(self, index);
        if (slot >= count or filled[slot]) return null;
        names[slot] = try gpa.dupeZ(u8, nameOf(self, index));
        filled[slot] = true;
    }
    return names;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a block says where each of its fields starts" {
    const fields = [_]Field{
        .{ .name = "projection", .ty = .mat4, .offset = 0 },
        .{ .name = "tint", .ty = .vec4, .offset = 64 },
        .{ .name = "time", .ty = .float, .offset = 80 },
    };
    const b: Block = .{ .name = "Frame", .slot = 0, .size = 96, .fields = &fields };

    try testing.expectEqual(@as(?u32, 0), b.offsetOf("projection"));
    try testing.expectEqual(@as(?u32, 80), b.offsetOf("time"));
    try testing.expectEqual(@as(?u32, null), b.offsetOf("nothing"));
}
