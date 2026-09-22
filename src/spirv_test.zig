// SPDX-License-Identifier: BSL-1.0

//! What the SPIR-V target has to be, held to.
//!
//! Three kinds of question, in the order they are cheapest to ask. **What the
//! words say**, which needs nothing: the header, lengths, ids and sections
//! (`spirv/check.zig`), and then the interface, the descriptors and the block
//! layout read back out of the decorations and held to what the shader said.
//! **What the target table does**, which is `compileWith` and `Module.output`
//! and a target row written outside the library. And **what other people's
//! readers make of it**: `spirv-val` under a Vulkan 1.0 environment,
//! `spirv-cross` turning it back into HLSL, and `dxc` compiling the HLSL the
//! library already wrote as shader model 6 - all through `toolchain.zig`, all
//! skipped, visibly, on a machine that has none of them.

const std = @import("std");
const testing = std.testing;

const shader = @import("root.zig");
const corpus = @import("corpus.zig");
const toolchain = @import("toolchain.zig");
const op = shader.spirv.op;
const check = shader.spirv.check;

const spirv_only: shader.Options = .{ .targets = .of(&.{.spirv_vulkan}) };

fn compileSpirv(source: []const u8, options: shader.Options) !shader.Module {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    return shader.compileWith(testing.allocator, source, &log.writer, options) catch |err| {
        std.debug.print("\n{s}\n", .{log.written()});
        return err;
    };
}

fn named(options: shader.Options) shader.Options {
    var with = options;
    with.debug_names = true;
    return with;
}

/// A module read for what it declares: names, decorations, and counts of what
/// it contains. Every question is a scan, which is fine at this size.
const Reader = struct {
    words: []const u32,

    fn instructions(self: Reader) check.Iterator {
        return .init(self.words);
    }

    /// The id `OpName` gave this name to.
    fn idOf(self: Reader, name: []const u8) ?u32 {
        var it = self.instructions();
        while (it.next() catch null) |instruction| {
            if (instruction.op != .name) continue;
            const bytes = std.mem.sliceAsBytes(instruction.words[2..]);
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse continue;
            if (std.mem.eql(u8, bytes[0..end], name)) return instruction.words[1];
        }
        return null;
    }

    /// The literal after a decoration on an id, zero for one that has none, or
    /// null when the id does not carry it.
    fn decoration(self: Reader, id: u32, which: op.Decoration) ?u32 {
        var it = self.instructions();
        while (it.next() catch null) |instruction| {
            if (instruction.op != .decorate) continue;
            if (instruction.words[1] != id or instruction.words[2] != @intFromEnum(which)) continue;
            return if (instruction.words.len > 3) instruction.words[3] else 0;
        }
        return null;
    }

    fn storageClass(self: Reader, variable: u32) ?u32 {
        var it = self.instructions();
        while (it.next() catch null) |instruction| {
            if (instruction.op == .variable and instruction.words[2] == variable) return instruction.words[3];
        }
        return null;
    }

    fn count(self: Reader, opcode: op.Op) usize {
        var n: usize = 0;
        var it = self.instructions();
        while (it.next() catch null) |instruction| {
            if (instruction.op == opcode) n += 1;
        }
        return n;
    }
};

fn expectDecoration(r: Reader, name: []const u8, which: op.Decoration, value: u32) !void {
    const id = r.idOf(name) orelse {
        std.debug.print("\nno variable is named `{s}`\n", .{name});
        return error.TestUnexpectedResult;
    };
    const found = r.decoration(id, which) orelse {
        std.debug.print("\n`{s}` has no {t}\n", .{ name, which });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(value, found);
}

// -------------------------------------------------------------------------
// What the words say
// -------------------------------------------------------------------------

test "every shader of the corpus is a well-formed module in both stages" {
    for (corpus.all) |entry| {
        var module = try compileSpirv(entry.source, spirv_only);
        defer module.deinit();
        const words = module.output(.spirv_vulkan).words;
        for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
            var problems: std.Io.Writer.Allocating = .init(testing.allocator);
            defer problems.deinit();
            check.verify(testing.allocator, stage, &problems.writer) catch |err| {
                std.debug.print("\n`{s}`:\n{s}\n", .{ entry.name, problems.written() });
                return err;
            };
        }
    }
}

test "the header is SPIR-V 1.0, and the bound is one past the last id" {
    var module = try compileSpirv(corpus.sprites, spirv_only);
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
        try testing.expectEqual(op.magic, stage[0]);
        try testing.expectEqual(@as(u32, 0x00010000), stage[1]);
        try testing.expectEqual(@as(u32, 0), stage[4]);
        var highest: u32 = 0;
        var it: check.Iterator = .init(stage);
        while (try it.next()) |instruction| {
            const info = op.info(instruction.op);
            if (info.has_result) highest = @max(highest, instruction.words[if (info.has_type) 2 else 1]);
        }
        try testing.expectEqual(highest + 1, stage[3]);
    }
}

test "capability Shader, logical addressing, GLSL450, one entry point called main" {
    var module = try compileSpirv(corpus.sprites, spirv_only);
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;

    for ([_]struct { []const u32, u32 }{ .{ words.vertex, 0 }, .{ words.fragment, 4 } }) |stage| {
        const r: Reader = .{ .words = stage[0] };
        try testing.expectEqual(@as(usize, 1), r.count(.capability));
        try testing.expectEqual(@as(usize, 1), r.count(.memory_model));
        try testing.expectEqual(@as(usize, 1), r.count(.entry_point));
        try testing.expectEqual(@as(usize, 0), r.count(.extension));

        var it = r.instructions();
        while (try it.next()) |instruction| switch (instruction.op) {
            .capability => try testing.expectEqual(@as(u32, 1), instruction.words[1]),
            .memory_model => {
                try testing.expectEqual(@as(u32, 0), instruction.words[1]);
                try testing.expectEqual(@as(u32, 1), instruction.words[2]);
            },
            .entry_point => {
                // Vertex is model 0 and fragment is 4.
                try testing.expectEqual(stage[1], instruction.words[1]);
                const bytes = std.mem.sliceAsBytes(instruction.words[3..]);
                try testing.expect(std.mem.startsWith(u8, bytes, "main\x00"));
            },
            else => {},
        };
    }

    // The fragment stage has an origin, and the vertex stage has no mode.
    try testing.expectEqual(@as(usize, 0), (Reader{ .words = words.vertex }).count(.execution_mode));
    const fragment: Reader = .{ .words = words.fragment };
    try testing.expectEqual(@as(usize, 1), fragment.count(.execution_mode));
    var it = fragment.instructions();
    while (try it.next()) |instruction| {
        // OriginUpperLeft is execution mode 7.
        if (instruction.op == .execution_mode) try testing.expectEqual(@as(u32, 7), instruction.words[2]);
    }
}

test "attributes are inputs at their locations, varyings are matched by position" {
    var module = try compileSpirv(corpus.many_varyings, named(spirv_only));
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    const vertex: Reader = .{ .words = words.vertex };
    const fragment: Reader = .{ .words = words.fragment };
    const input = @intFromEnum(op.StorageClass.input);
    const output = @intFromEnum(op.StorageClass.output);

    // Attribute locations are the shader's own, holes and all.
    try expectDecoration(vertex, "a_pos", .location, 0);
    try expectDecoration(vertex, "a_col", .location, 3);
    try expectDecoration(vertex, "a_extra", .location, 5);
    try testing.expectEqual(input, vertex.storageClass(vertex.idOf("a_pos").?).?);
    // A fragment stage has no attributes at all.
    try testing.expectEqual(@as(?u32, null), fragment.idOf("a_pos"));

    // Varyings: declaration order, consecutive from zero, an output in the
    // vertex module and an input in the fragment module - every one of them,
    // although the fragment stage reads only two.
    const varyings = [_][]const u8{ "k_one", "k_two", "k_three", "k_four", "k_last" };
    for (varyings, 0..) |name, location| {
        try expectDecoration(vertex, name, .location, @intCast(location));
        try expectDecoration(fragment, name, .location, @intCast(location));
        try testing.expectEqual(output, vertex.storageClass(vertex.idOf(name).?).?);
        try testing.expectEqual(input, fragment.storageClass(fragment.idOf(name).?).?);
    }

    // `position` is an output that is the `Position` built-in; `target` is an
    // output at location 0.
    try expectDecoration(vertex, "fluxion_position", .built_in, @intFromEnum(op.BuiltIn.position));
    try testing.expectEqual(output, vertex.storageClass(vertex.idOf("fluxion_position").?).?);
    try expectDecoration(fragment, "fluxion_target", .location, 0);
    try testing.expectEqual(output, fragment.storageClass(fragment.idOf("fluxion_target").?).?);
}

test "an integer that crosses stages is flat, and a float is not" {
    var module = try compileSpirv(corpus.flat_varying, named(spirv_only));
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
        const r: Reader = .{ .words = stage };
        try testing.expect(r.decoration(r.idOf("which").?, .flat) != null);
        try testing.expect(r.decoration(r.idOf("shade").?, .flat) == null);
    }
}

test "vertex_index and instance_index are the built-ins, and only where they are read" {
    var module = try compileSpirv(corpus.index_builtins, named(spirv_only));
    defer module.deinit();
    const vertex: Reader = .{ .words = module.output(.spirv_vulkan).words.vertex };
    try expectDecoration(vertex, "fluxion_vertex_index", .built_in, @intFromEnum(op.BuiltIn.vertex_index));
    try expectDecoration(vertex, "fluxion_instance_index", .built_in, @intFromEnum(op.BuiltIn.instance_index));
    try testing.expectEqual(@as(u32, 42), vertex.decoration(vertex.idOf("fluxion_vertex_index").?, .built_in).?);
    try testing.expectEqual(@as(u32, 43), vertex.decoration(vertex.idOf("fluxion_instance_index").?, .built_in).?);

    // Only one of the two read: only one is declared, and it is an input the
    // entry point lists.
    var one = try compileSpirv(
        \\vertex { position = vec4(float(vertex_index)); }
        \\fragment { target = vec4(1.0); }
    , named(spirv_only));
    defer one.deinit();
    const only: Reader = .{ .words = one.output(.spirv_vulkan).words.vertex };
    try testing.expect(only.idOf("fluxion_vertex_index") != null);
    try testing.expectEqual(@as(?u32, null), only.idOf("fluxion_instance_index"));

    // Neither: no such variable at all.
    var none = try compileSpirv(corpus.sprites, named(spirv_only));
    defer none.deinit();
    const nothing: Reader = .{ .words = none.output(.spirv_vulkan).words.vertex };
    try testing.expectEqual(@as(?u32, null), nothing.idOf("fluxion_vertex_index"));
}

test "a block is a descriptor in set 0 at its slot, a texture is one in set 1" {
    var module = try compileSpirv(corpus.many_varyings, named(spirv_only));
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;

    // Every block and texture is in both modules, read or not: the vertex
    // stage does not sample either texture.
    for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
        const r: Reader = .{ .words = stage };
        try expectDecoration(r, "fluxion_Frame", .descriptor_set, 0);
        try expectDecoration(r, "fluxion_Frame", .binding, 0);
        try expectDecoration(r, "fluxion_Tint", .descriptor_set, 0);
        try expectDecoration(r, "fluxion_Tint", .binding, 2);
        try expectDecoration(r, "first", .descriptor_set, 1);
        try expectDecoration(r, "first", .binding, 0);
        try expectDecoration(r, "second", .descriptor_set, 1);
        try expectDecoration(r, "second", .binding, 3);
        try testing.expectEqual(@intFromEnum(op.StorageClass.uniform), r.storageClass(r.idOf("fluxion_Tint").?).?);
        try testing.expectEqual(@intFromEnum(op.StorageClass.uniform_constant), r.storageClass(r.idOf("second").?).?);
        // A block is decorated `Block`, and it is the struct that is.
        try testing.expect(r.decoration(r.idOf("Tint").?, .block) != null);
    }
    try testing.expectEqual(shader.BindingLayout{}, module.binding);
}

test "the two set numbers are the layout's, and nothing else moves" {
    var module = try compileSpirv(corpus.many_varyings, named(.{
        .targets = .of(&.{.spirv_vulkan}),
        .binding = .{ .uniform_set = 3, .texture_set = 7 },
    }));
    defer module.deinit();
    const vertex: Reader = .{ .words = module.output(.spirv_vulkan).words.vertex };
    try expectDecoration(vertex, "fluxion_Tint", .descriptor_set, 3);
    try expectDecoration(vertex, "fluxion_Tint", .binding, 2);
    try expectDecoration(vertex, "second", .descriptor_set, 7);
    try expectDecoration(vertex, "second", .binding, 3);
    try testing.expectEqual(@as(u32, 3), module.binding.uniform_set);
}

test "every field of every block has the offset sema computed" {
    for (corpus.all) |entry| {
        var module = try compileSpirv(entry.source, spirv_only);
        defer module.deinit();
        const words = module.output(.spirv_vulkan).words;

        for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const layouts = try check.uniformBlocks(arena.allocator(), stage);
            try testing.expectEqual(module.blocks.len, layouts.len);

            for (module.blocks) |block| {
                // The layout of the block that sits at this binding.
                const layout = for (layouts) |candidate| {
                    if (candidate.binding == block.slot) break candidate;
                } else {
                    std.debug.print("\n`{s}`: no block at binding {d}\n", .{ entry.name, block.slot });
                    return error.TestUnexpectedResult;
                };
                try testing.expectEqual(@as(u32, 0), layout.set);
                try testing.expectEqual(block.fields.len, layout.members.len);
                for (block.fields, layout.members) |field, member| {
                    if (field.offset != member.offset) {
                        std.debug.print("\n`{s}`: `{s}.{s}` is at {d} in the module and {d} in Module.Block\n", .{
                            entry.name, block.name, field.name, member.offset, field.offset,
                        });
                        return error.TestUnexpectedResult;
                    }
                    // A matrix is column-major with a register per column;
                    // nothing else carries either.
                    try testing.expectEqual(field.ty.isMatrix(), member.col_major);
                    try testing.expectEqual(@as(?u32, if (field.ty.isMatrix()) 16 else null), member.matrix_stride);
                    // And the field fits in the block that holds it.
                    try testing.expect(field.offset + field.ty.sizeInBlock() <= block.size);
                }
            }
        }
    }
}

test "a mat3 and a mat2 in a block start a register and take a register per column" {
    var module = try compileSpirv(corpus.matrix_block, spirv_only);
    defer module.deinit();
    const frame = module.block("Frame").?;
    // A float, then a mat3 that starts a register, a float packed after it,
    // a mat2 that starts one, a vec3 and the float that goes in its fourth
    // word, a vec2, a mat4, an int.
    try testing.expectEqual(@as(?u32, 0), frame.offsetOf("lead"));
    try testing.expectEqual(@as(?u32, 16), frame.offsetOf("m3"));
    try testing.expectEqual(@as(?u32, 64), frame.offsetOf("between"));
    try testing.expectEqual(@as(?u32, 80), frame.offsetOf("m2"));
    try testing.expectEqual(@as(?u32, 112), frame.offsetOf("v"));
    try testing.expectEqual(@as(?u32, 124), frame.offsetOf("pinch"));
    try testing.expectEqual(@as(?u32, 128), frame.offsetOf("w"));
    try testing.expectEqual(@as(?u32, 144), frame.offsetOf("m4"));
    try testing.expectEqual(@as(?u32, 208), frame.offsetOf("count"));
    try testing.expectEqual(@as(u32, 224), frame.size);
}

test "a type or a constant is written once" {
    for (corpus.all) |entry| {
        var module = try compileSpirv(entry.source, spirv_only);
        defer module.deinit();
        const words = module.output(.spirv_vulkan).words;
        for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var seen: std.StringHashMapUnmanaged(void) = .empty;

            var it: check.Iterator = .init(stage);
            while (try it.next()) |instruction| {
                if (op.section(instruction.op) != .types) continue;
                // A struct is one type per block and a variable is one variable, and
                // neither is the same as another; everything else is its opcode and operands.
                if (instruction.op == .type_struct or instruction.op == .variable) continue;
                const info = op.info(instruction.op);
                var key: std.ArrayList(u32) = .empty;
                try key.append(arena.allocator(), @intFromEnum(instruction.op));
                // Leave out the result id, which is what differs.
                const result_at: usize = if (info.has_type) 2 else 1;
                for (instruction.words[1..], 1..) |word, at| {
                    if (at != result_at) try key.append(arena.allocator(), word);
                }
                const gop = try seen.getOrPut(arena.allocator(), std.mem.sliceAsBytes(key.items));
                if (gop.found_existing) {
                    std.debug.print("\n`{s}`: {t} is written twice\n", .{ entry.name, instruction.op });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "the extended set is imported only when a builtin uses it" {
    var plain = try compileSpirv(corpus.sprites, spirv_only);
    defer plain.deinit();
    try testing.expectEqual(@as(usize, 0), (Reader{ .words = plain.output(.spirv_vulkan).words.fragment }).count(.ext_inst_import));

    var busy = try compileSpirv(corpus.quad, spirv_only);
    defer busy.deinit();
    const vertex: Reader = .{ .words = busy.output(.spirv_vulkan).words.vertex };
    try testing.expectEqual(@as(usize, 1), vertex.count(.ext_inst_import));
    try testing.expect(vertex.count(.ext_inst) >= 1);
}

test "names are there when asked for and not otherwise" {
    var quiet = try compileSpirv(corpus.kitchen_sink, spirv_only);
    defer quiet.deinit();
    const q: Reader = .{ .words = quiet.output(.spirv_vulkan).words.vertex };
    try testing.expectEqual(@as(usize, 0), q.count(.name));
    try testing.expectEqual(@as(usize, 0), q.count(.member_name));

    var loud = try compileSpirv(corpus.kitchen_sink, named(spirv_only));
    defer loud.deinit();
    const l: Reader = .{ .words = loud.output(.spirv_vulkan).words.vertex };
    try testing.expect(l.count(.name) > 10);
    try testing.expect(l.count(.member_name) >= 8);
    try testing.expect(l.idOf("spin") != null);
    try testing.expect(l.idOf("main") != null);
}

test "the same shader is the same words, every time" {
    for (corpus.all) |entry| {
        var one = try compileSpirv(entry.source, spirv_only);
        defer one.deinit();
        var two = try compileSpirv(entry.source, spirv_only);
        defer two.deinit();
        const a = one.output(.spirv_vulkan).words;
        const b = two.output(.spirv_vulkan).words;
        try testing.expectEqualSlices(u32, a.vertex, b.vertex);
        try testing.expectEqualSlices(u32, a.fragment, b.fragment);
    }
}

test "the words are handed over as four-aligned bytes" {
    var module = try compileSpirv(corpus.quad, spirv_only);
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    try testing.expectEqual(words.vertex.len * 4, words.vertexBytes().len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(words.vertexBytes().ptr) % 4);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(words.fragmentBytes().ptr) % 4);
    try testing.expectEqual(@as(u8, 0x03), words.vertexBytes()[0]);
    try testing.expectEqual(@as(u8, 0x02), words.vertexBytes()[1]);
    try testing.expectEqual(@as(u8, 0x23), words.vertexBytes()[2]);
    try testing.expectEqual(@as(u8, 0x07), words.vertexBytes()[3]);
}

// -------------------------------------------------------------------------
// What the lowering does
// -------------------------------------------------------------------------

test "discard is OpKill and a loop is a loop merge" {
    var module = try compileSpirv(corpus.loops_and_discard, spirv_only);
    defer module.deinit();
    const fragment: Reader = .{ .words = module.output(.spirv_vulkan).words.fragment };
    try testing.expect(fragment.count(.kill) >= 5);
    // march: a for and a while; the stage: for, for, while, for.
    try testing.expectEqual(@as(usize, 6), fragment.count(.loop_merge));
    try testing.expect(fragment.count(.selection_merge) >= 8);
    // The vertex stage has neither, and does not have the functions either.
    const vertex: Reader = .{ .words = module.output(.spirv_vulkan).words.vertex };
    try testing.expectEqual(@as(usize, 0), vertex.count(.kill));
    try testing.expectEqual(@as(usize, 0), vertex.count(.loop_merge));
    try testing.expectEqual(@as(usize, 1), vertex.count(.function));
    try testing.expectEqual(@as(usize, 4), fragment.count(.function));
}

test "sample is an implicit level in a fragment and level zero in a vertex" {
    var module = try compileSpirv(corpus.vertex_texture, spirv_only);
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    const vertex: Reader = .{ .words = words.vertex };
    try testing.expectEqual(@as(usize, 1), vertex.count(.image_sample_explicit_lod));
    try testing.expectEqual(@as(usize, 0), vertex.count(.image_sample_implicit_lod));

    var sprites = try compileSpirv(corpus.sprites, spirv_only);
    defer sprites.deinit();
    const fragment: Reader = .{ .words = sprites.output(.spirv_vulkan).words.fragment };
    try testing.expectEqual(@as(usize, 1), fragment.count(.image_sample_implicit_lod));
    try testing.expectEqual(@as(usize, 0), fragment.count(.image_sample_explicit_lod));
}

test "a function is written into a stage only if the stage reaches it" {
    var module = try compileSpirv(corpus.derivative_in_a_function, spirv_only);
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;
    // The vertex module is `main` alone, so its derivatives-free; the
    // fragment module has `slope` and `main`, and `OpDPdx` once.
    try testing.expectEqual(@as(usize, 1), (Reader{ .words = words.vertex }).count(.function));
    try testing.expectEqual(@as(usize, 0), (Reader{ .words = words.vertex }).count(.dpdx));
    try testing.expectEqual(@as(usize, 2), (Reader{ .words = words.fragment }).count(.function));
    try testing.expectEqual(@as(usize, 1), (Reader{ .words = words.fragment }).count(.dpdx));
    try testing.expectEqual(@as(usize, 1), (Reader{ .words = words.fragment }).count(.dpdy));
}

test "a whole number meets a float as a constant when it can and a conversion when it must" {
    var literal = try compileSpirv(
        \\vertex { float t = 3.0; t = t * 2; t += 1; position = vec4(t * 4); }
        \\fragment { target = vec4(1.0); }
    , spirv_only);
    defer literal.deinit();
    // Three whole numbers written where a float is wanted, and not one
    // conversion: they are float constants.
    try testing.expectEqual(@as(usize, 0), (Reader{ .words = literal.output(.spirv_vulkan).words.vertex }).count(.convert_s_to_f));

    var variable = try compileSpirv(
        \\attribute int lane : 0;
        \\vertex { float t = 3.0; t = t * lane; position = vec4(t); }
        \\fragment { target = vec4(1.0); }
    , spirv_only);
    defer variable.deinit();
    try testing.expectEqual(@as(usize, 1), (Reader{ .words = variable.output(.spirv_vulkan).words.vertex }).count(.convert_s_to_f));
}

test "a constant made of constants is one constant" {
    var module = try compileSpirv(
        \\vertex { position = vec4(1.0, 0.0, 0.0, 1.0) + vec4(-1.0); }
        \\fragment { target = vec4(0.5); }
    , spirv_only);
    defer module.deinit();
    const vertex: Reader = .{ .words = module.output(.spirv_vulkan).words.vertex };
    // Two composite constants, and no construction at run time at all.
    try testing.expectEqual(@as(usize, 2), vertex.count(.constant_composite));
    try testing.expectEqual(@as(usize, 0), vertex.count(.composite_construct));
}

// -------------------------------------------------------------------------
// What it will not do, and says so
// -------------------------------------------------------------------------

fn expectUnsupported(source: []const u8, wanted: []const u8) !void {
    // The text targets are fine with it: only SPIR-V objects.
    var text = try compileSpirv(source, .{});
    text.deinit();

    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const result = shader.compileWith(testing.allocator, source, &log.writer, spirv_only);
    try testing.expectError(shader.Error.CompileFailed, result);
    if (std.mem.indexOf(u8, log.written(), wanted) == null) {
        std.debug.print("\nexpected `{s}` in:\n{s}\n", .{ wanted, log.written() });
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.indexOf(u8, log.written(), "spirv_vulkan") != null);
}

test "recursion is refused, by name, rather than written" {
    try expectUnsupported(
        \\float loop_forever(float x) { return loop_forever(x); }
        \\vertex { position = vec4(loop_forever(1.0)); }
        \\fragment { target = vec4(1.0); }
    , "no recursion");
    try expectUnsupported(
        \\float ping(float x) { return pong(x); }
        \\float pong(float x) { return ping(x); }
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(ping(1.0)); }
    , "no recursion");
}

test "a derivative in the vertex stage is refused" {
    try expectUnsupported(
        \\varying float v;
        \\vertex { v = 1.0; position = vec4(ddx(v)); }
        \\fragment { target = vec4(v); }
    , "derivative");
}

test "a function that takes a texture is refused: a sampled image is not a value SPIR-V passes" {
    try expectUnsupported(
        \\texture2d atlas : 0;
        \\float first(texture2d t) { return sample(t, vec2(0.0)).x; }
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(first(atlas)); }
    , "texture");
}

test "a constant that refers to itself is refused rather than looped on" {
    try expectUnsupported(
        \\const float a = b;
        \\const float b = a;
        \\vertex { position = vec4(a); }
        \\fragment { target = vec4(1.0); }
    , "refers to itself");
}

// -------------------------------------------------------------------------
// The two rules `sema` gained because SPIR-V could not lower without them
// -------------------------------------------------------------------------

fn expectRefused(source: []const u8, wanted: []const u8) !void {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const result = shader.compile(testing.allocator, source, &log.writer);
    try testing.expectError(shader.Error.CompileFailed, result);
    if (std.mem.indexOf(u8, log.written(), wanted) == null) {
        std.debug.print("\nexpected `{s}` in:\n{s}\n", .{ wanted, log.written() });
        return error.TestUnexpectedResult;
    }
}

test "a whole number and a float make a float, whichever is on the left" {
    var module = try compileSpirv(
        \\attribute int lane : 0;
        \\vertex { float a = lane + 0.5; float b = 0.5 + lane; float c = lane * 2.0; position = vec4(a, b, c, 1.0); }
        \\fragment { target = vec4(1.0); }
    , .{});
    module.deinit();
    // `lane * 0.5` used to be typed as an int - the left operand's type - so
    // this was accepted, and a driver said no later. It is a float, which does
    // not go in an int.
    try expectRefused(
        \\attribute int lane : 0;
        \\vertex { int a = lane * 0.5; position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "a int was wanted");
}

test "two bools are compared for equality and not for order" {
    try expectRefused(
        \\vertex { position = vec4(1.0); bool a = true < false; }
        \\fragment { target = vec4(1.0); }
    , "orders numbers");
    var equal = try compileSpirv(
        \\vertex { bool a = true == false; bool b = a != true; position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , spirv_only);
    equal.deinit();
}

// -------------------------------------------------------------------------
// The table of targets
// -------------------------------------------------------------------------

test "compile writes the three text targets and no SPIR-V, and asking for SPIR-V alone writes only that" {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();

    var text = try shader.compile(testing.allocator, corpus.sprites, &log.writer);
    defer text.deinit();
    try testing.expect(text.glsl.vertex.len > 0);
    try testing.expect(text.hlsl.fragment.len > 0);
    try testing.expectEqual(std.meta.Tag(shader.Output).none, std.meta.activeTag(text.output(.spirv_vulkan)));
    // The fields are three of the table's rows.
    try testing.expectEqualStrings(text.glsl.vertex, text.output(.glsl_330).text.vertex);
    try testing.expectEqualStrings(text.glsl_es.fragment, text.output(.glsl_es_300).text.fragment);
    try testing.expectEqualStrings(text.hlsl.vertex, text.output(.hlsl_50).text.vertex);

    var binary = try shader.compileWith(testing.allocator, corpus.sprites, &log.writer, spirv_only);
    defer binary.deinit();
    try testing.expectEqual(@as(usize, 0), binary.glsl.vertex.len);
    try testing.expectEqual(@as(usize, 0), binary.hlsl.fragment.len);
    try testing.expect(binary.output(.spirv_vulkan).words.vertex.len > 5);
    try testing.expectEqual(std.meta.Tag(shader.Output).none, std.meta.activeTag(binary.output(.glsl_330)));
    // The reflection is the same whichever targets ran.
    try testing.expectEqual(text.attributes.len, binary.attributes.len);
    try testing.expectEqual(text.blocks[0].size, binary.blocks[0].size);
}

test "asking for everything gives everything, and the words are the words asked for alone" {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    var all = try shader.compileWith(testing.allocator, corpus.quad, &log.writer, .{
        .targets = .of(&.{ .glsl_330, .glsl_es_300, .hlsl_50, .spirv_vulkan }),
    });
    defer all.deinit();
    var alone = try shader.compileWith(testing.allocator, corpus.quad, &log.writer, spirv_only);
    defer alone.deinit();
    try testing.expect(all.glsl.vertex.len > 0);
    try testing.expectEqualSlices(u32, alone.output(.spirv_vulkan).words.fragment, all.output(.spirv_vulkan).words.fragment);
}

fn shout(program: *const shader.ast.Program, stage: shader.sema.Where, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("// {t}: {d} attributes\n", .{ stage, program.attributes.len });
}

fn tally(gpa: std.mem.Allocator, request: *shader.target.Request) shader.target.EmitError![]u32 {
    const out = try gpa.alloc(u32, 3);
    out[0] = @intCast(request.program.attributes.len);
    out[1] = @intFromEnum(request.stage);
    out[2] = request.binding.texture_set;
    return out;
}

fn refuse(_: std.mem.Allocator, request: *shader.target.Request) shader.target.EmitError![]u32 {
    request.reason = "it is just a test";
    return error.Unsupported;
}

test "a program adds a target to the table without touching the library" {
    const table = shader.target.builtin_targets ++ [_]shader.Target{
        .{ .name = "shout", .family = .glsl, .emit = .{ .text = shout } },
        .{ .name = "tally", .family = .spirv, .emit = .{ .words = tally } },
        .{ .name = "refuse", .family = .hlsl, .emit = .{ .words = refuse } },
    };
    const shout_id = comptime shader.target.idOf(&table, "shout");
    const tally_id = comptime shader.target.idOf(&table, "tally");
    const refuse_id = comptime shader.target.idOf(&table, "refuse");
    try testing.expectEqual(@as(u8, 4), @intFromEnum(shout_id));
    try testing.expectEqual(shader.target.OutputKind.text, table[@intFromEnum(shout_id)].kind());
    try testing.expectEqual(shader.target.OutputKind.words, table[@intFromEnum(tally_id)].kind());

    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    var module = try shader.compileWith(testing.allocator, corpus.sprites, &log.writer, .{
        .table = &table,
        .targets = .of(&.{ .glsl_330, shout_id, tally_id, .spirv_vulkan }),
        .binding = .{ .texture_set = 9 },
    });
    defer module.deinit();

    // Its text, in both stages, and its words.
    try testing.expectEqualStrings("// vertex: 3 attributes\n", module.output(shout_id).text.vertex);
    try testing.expectEqualStrings("// fragment: 3 attributes\n", module.output(shout_id).text.fragment);
    try testing.expectEqualSlices(u32, &.{ 3, 0, 9 }, module.output(tally_id).words.vertex);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 9 }, module.output(tally_id).words.fragment);
    // The shipped rows still work beside it, and the ones not asked for did
    // not run.
    try testing.expect(module.glsl.vertex.len > 0);
    try testing.expect(module.output(.spirv_vulkan).words.vertex.len > 5);
    try testing.expectEqual(std.meta.Tag(shader.Output).none, std.meta.activeTag(module.output(refuse_id)));
    try testing.expectEqual(std.meta.Tag(shader.Output).none, std.meta.activeTag(module.output(.hlsl_50)));

    // A row that cannot do a shader says so, in the log, and the compile
    // fails as a mistake in the source would.
    var failing_log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer failing_log.deinit();
    try testing.expectError(shader.Error.CompileFailed, shader.compileWith(testing.allocator, corpus.sprites, &failing_log.writer, .{
        .table = &table,
        .targets = .of(&.{refuse_id}),
    }));
    try testing.expect(std.mem.indexOf(u8, failing_log.written(), "the refuse target cannot express this shader") != null);
    try testing.expect(std.mem.indexOf(u8, failing_log.written(), "it is just a test") != null);
}

// -------------------------------------------------------------------------
// The validators
// -------------------------------------------------------------------------

test "spirv-val accepts every shader of the corpus, both stages, as Vulkan 1.0" {
    if (toolchain.find(.spirv_val) == null) {
        std.debug.print("\nspirv-val is not installed: skipping\n", .{});
        return error.SkipZigTest;
    }
    for (corpus.all) |entry| {
        try toolchain.checkShader(testing.allocator, entry.name, entry.source, entry.hlsl_valid, .{
            .spirv_cross = false,
            .dxc = false,
        });
    }
}

test "spirv-cross reads every module back as HLSL" {
    if (toolchain.find(.spirv_cross) == null) {
        std.debug.print("\nspirv-cross is not installed: skipping\n", .{});
        return error.SkipZigTest;
    }
    for (corpus.all) |entry| {
        try toolchain.checkShader(testing.allocator, entry.name, entry.source, entry.hlsl_valid, .{
            .spirv_val = false,
            .dxc = false,
        });
    }
}

test "dxc compiles the HLSL the library already wrote, as shader model 6.0 and 5.1" {
    if (toolchain.find(.dxc) == null) {
        std.debug.print("\ndxc is not installed: skipping\n", .{});
        return error.SkipZigTest;
    }
    for (corpus.all) |entry| {
        try toolchain.checkShader(testing.allocator, entry.name, entry.source, entry.hlsl_valid, .{
            .spirv_val = false,
            .spirv_cross = false,
        });
    }
}

// -------------------------------------------------------------------------
// std140 and the Direct3D constant buffer
// -------------------------------------------------------------------------

/// One block that has nothing in it Direct3D packs differently from
/// `std140`, and six that each have one thing: a scalar and then a `vec2` or a
/// `vec3`, or a `mat2` or a `mat3` and then something that fits in the space
/// its last column leaves.
const constant_buffers =
    \\uniform Safe : 0 {
    \\    vec3 b; float c; vec2 d; vec4 e; mat4 f; float g;
    \\    mat3 h; vec3 i; mat2 j; vec4 k; mat3 l; vec2 m; mat2 n; mat4 o; int p;
    \\}
    \\uniform Lone2 : 1 { float a2; vec2 v2; }
    \\uniform Lone3 : 2 { float a3; vec3 v3; }
    \\uniform A : 3 { mat2 r; float s; vec2 t; }
    \\uniform B : 4 { mat3 u; vec2 v; float w; }
    \\uniform C : 5 { mat3 x; float y; vec3 z; }
    \\uniform D : 6 { mat2 aa; vec2 bb; vec3 cc; }
    \\
    \\vertex { position = vec4(1.0); }
    \\
    \\fragment {
    \\    float s0 = b.x + c + d.x + e.x + (f * vec4(1.0)).x + g + (h * vec3(1.0)).x + i.x
    \\        + (j * vec2(1.0)).x + k.x + (l * vec3(1.0)).x + m.x + (n * vec2(1.0)).x
    \\        + (o * vec4(1.0)).x + float(p);
    \\    float s1 = a2 + v2.x + a3 + v3.x;
    \\    float s2 = (r * vec2(1.0)).x + s + t.x + (u * vec3(1.0)).x + v.x + w
    \\        + (x * vec3(1.0)).x + y + z.x + (aa * vec2(1.0)).x + bb.x + cc.x;
    \\    target = vec4(s0, s1, s2, 1.0);
    \\}
;

/// The byte offset `dxc` says a constant buffer's member is at, out of its
/// disassembly listing.
fn d3dOffset(listing: []const u8, block: []const u8, field: []const u8) ?u32 {
    var inside = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r;");
        if (std.mem.startsWith(u8, line, "cbuffer ")) {
            inside = std.mem.eql(u8, std.mem.trim(u8, line["cbuffer ".len..], " "), block);
            continue;
        }
        if (!inside) continue;
        // A member: `column_major float3x3 u;   ; Offset:    0`.
        const offset_at = std.mem.indexOf(u8, raw, "; Offset:") orelse continue;
        const declaration = std.mem.trim(u8, raw[std.mem.indexOfScalar(u8, raw, ';').? + 1 .. offset_at], " \t;");
        if (std.mem.startsWith(u8, declaration, "}")) return null;
        var words = std.mem.tokenizeAny(u8, declaration, " \t;");
        var last: []const u8 = "";
        while (words.next()) |word| last = word;
        if (!std.mem.eql(u8, last, field)) continue;
        const digits = std.mem.trim(u8, raw[offset_at + "; Offset:".len ..], " \t\r");
        const end = std.mem.indexOfAny(u8, digits, " \t") orelse digits.len;
        return std.fmt.parseInt(u32, digits[0..end], 10) catch null;
    }
    return null;
}

test "the Direct3D constant buffer uses the std140 offsets in the reflection" {
    if (toolchain.find(.dxc) == null) {
        std.debug.print("\ndxc is not installed: skipping\n", .{});
        return error.SkipZigTest;
    }
    var module = try compileSpirv(constant_buffers, .{});
    defer module.deinit();
    const listing = try toolchain.dxcListing(testing.allocator, module.hlsl.fragment, "ps_6_0");
    defer testing.allocator.free(listing);

    for (module.blocks) |block| {
        for (block.fields) |field| {
            const there = d3dOffset(listing, block.name, field.name) orelse {
                std.debug.print("\ndxc did not list `{s}.{s}`:\n{s}\n", .{ block.name, field.name, listing });
                return error.TestUnexpectedResult;
            };
            if (there != field.offset) {
                std.debug.print("\n`{s}.{s}`: Direct3D puts it at {d}, but reflection says {d}\n", .{
                    block.name, field.name, there, field.offset,
                });
                return error.TestUnexpectedResult;
            }
        }
    }
}
