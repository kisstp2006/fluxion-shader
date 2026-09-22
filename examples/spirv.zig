// SPDX-License-Identifier: BSL-1.0

//! One shader in, SPIR-V out, written to files a person can open.
//!
//! Run it with `zig build example-spirv`. It needs no window, no driver and no
//! graphics card: the library writes the words, this writes them to
//! `zig-out/demo.vert.spv` and `zig-out/demo.frag.spv`, and says which
//! descriptor each block and texture of the shader ended up as - which is the
//! part a Vulkan pipeline layout is made from.
//!
//! `-- --stage fragment` writes one stage and not the other (`vertex`,
//! `fragment`, or `both`, which is the default). To read what came out, with
//! the Vulkan SDK installed:
//!
//! ```
//! spirv-dis zig-out/demo.frag.spv       # the module as text
//! spirv-val --target-env vulkan1.0 zig-out/demo.frag.spv
//! spirv-cross --hlsl --shader-model 50 zig-out/demo.frag.spv
//! ```
//!
//! The names are in the file because this example asks for them
//! (`debug_names`). A program that ships its shaders leaves that off, which is
//! the default.

const std = @import("std");
const Io = std.Io;

const shader = @import("fluxion_shader");

const source =
    \\// Everything a sprite batch needs, and a little more so that the
    \\// interesting cases show up: a matrix from a block, a texture, two
    \\// varyings, a function both stages share, and builtins that lower to
    \\// GLSL.std.450 instructions.
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\attribute vec4 tint : 2;
    \\
    \\varying vec2 uv;
    \\varying vec4 colour;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    float time;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\const float wobble = 0.02;
    \\
    \\// Shared by both stages, so it may touch neither.
    \\vec2 sway(vec2 at, float seconds) {
    \\    return at + vec2(sin(seconds) * wobble, 0.0);
    \\}
    \\
    \\vertex {
    \\    vec2 world = placement.xy + corner * placement.zw;
    \\    uv = corner;
    \\    colour = tint;
    \\    position = projection * vec4(sway(world, time), 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(atlas, uv);
    \\    float edge = saturate(mod(time, 1.0));
    \\    target = mix(texel, texel * colour, edge);
    \\}
;

const Stages = enum { vertex, fragment, both };

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    const gpa = init.gpa;
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var wanted: Stages = .both;
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        if (std.mem.eql(u8, arguments[i], "--stage") and i + 1 < arguments.len) {
            i += 1;
            wanted = std.meta.stringToEnum(Stages, arguments[i]) orelse {
                try out.print("unknown stage `{s}`; it is `vertex`, `fragment` or `both`\n", .{arguments[i]});
                try out.flush();
                return error.UnknownStage;
            };
        } else {
            try out.print("unknown argument `{s}`\n", .{arguments[i]});
            try out.flush();
            return error.UnknownArgument;
        }
    }

    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var module = shader.compileWith(gpa, source, &log.writer, .{
        .targets = .of(&.{.spirv_vulkan}),
        .debug_names = true,
    }) catch |err| {
        try out.print("{s}\n", .{log.written()});
        try out.flush();
        return err;
    };
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;

    var dir = try Io.Dir.cwd().createDirPathOpen(io, "zig-out", .{});
    defer dir.close(io);

    if (wanted != .fragment) try write(out, io, dir, "demo.vert.spv", words.vertexBytes());
    if (wanted != .vertex) try write(out, io, dir, "demo.frag.spv", words.fragmentBytes());

    try out.writeAll("\nwhat the pipeline layout is made from:\n\n");
    for (module.attributes) |a| {
        try out.print("    attribute  {s: <12} {t: <6}  Location {d}\n", .{ a.name, a.ty, a.location });
    }
    for (module.blocks) |b| {
        try out.print("    block      {s: <12} {d} bytes  DescriptorSet {d}, Binding {d}, Uniform\n", .{
            b.name, b.size, module.binding.uniform_set, b.slot,
        });
    }
    for (module.textures) |t| {
        try out.print("    texture    {s: <12} {s: <8}  DescriptorSet {d}, Binding {d}, combined image sampler\n", .{
            t.name, "", module.binding.texture_set, t.slot,
        });
    }
    try out.writeAll(
        \\
        \\A resource's binding is its kind and its slot and nothing else: the
        \\uniform blocks are one descriptor set and the textures another, each
        \\numbered by the slot the shader gave it, so the two slot spaces of the
        \\RHI - setUniformBuffer(slot) and setTexture(slot) - are the two sets.
        \\
        \\Read a module with `spirv-dis zig-out/demo.frag.spv`.
        \\
    );
    try out.flush();
}

fn write(out: *Io.Writer, io: Io, dir: Io.Dir, name: []const u8, bytes: []align(4) const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    try out.print("wrote zig-out/{s}: {d} words, {d} bytes\n", .{ name, bytes.len / 4, bytes.len });
}

test "the shader in this example compiles to SPIR-V, both stages, under the header a driver wants" {
    var log: Io.Writer.Allocating = .init(std.testing.allocator);
    defer log.deinit();
    var module = shader.compileWith(std.testing.allocator, source, &log.writer, .{
        .targets = .of(&.{.spirv_vulkan}),
    }) catch |err| {
        std.debug.print("\n{s}\n", .{log.written()});
        return err;
    };
    defer module.deinit();

    const words = module.output(.spirv_vulkan).words;
    for ([_][]const u32{ words.vertex, words.fragment }) |stage| {
        try std.testing.expectEqual(@as(u32, 0x07230203), stage[0]);
        try std.testing.expectEqual(@as(u32, 0x00010000), stage[1]);
    }
    // What a driver's create-shader call is given.
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(words.vertexBytes().ptr) % 4);
    try std.testing.expectEqual(words.vertex.len * 4, words.vertexBytes().len);
    // The descriptor a person reads off it.
    try std.testing.expectEqual(@as(u32, 0), module.binding.uniform_set);
    try std.testing.expectEqual(@as(u32, 1), module.binding.texture_set);
}
