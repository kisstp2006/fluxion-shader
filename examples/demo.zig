// SPDX-License-Identifier: BSL-1.0

//! One shader in, three languages out, printed side by side.
//!
//! Run it with `zig build example`. It needs no window, no driver and no
//! graphics card: the whole of this library is text in and text out, and this
//! is that, with the reflection underneath so the numbers a pipeline is
//! described with can be seen coming from the same place.
//!
//! `-- --stage fragment` prints the other stage; `-- --refuse` shows what a
//! mistake looks like on the way out.

const std = @import("std");
const Io = std.Io;

const shader = @import("fluxion_shader");

const source =
    \\// Everything a sprite batch needs, and one thing more so that the
    \\// interesting cases show up in both languages.
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

const broken =
    \\attribute vec2 corner : 0;
    \\
    \\vertex {
    \\    position = vec4(corner, 0.0);
    \\    uv = corner;
    \\}
    \\
    \\fragment {
    \\    target = corner.z;
    \\}
;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    const gpa = init.gpa;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var stage: []const u8 = "vertex";
    var refuse = false;
    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        if (std.mem.eql(u8, arguments[i], "--stage") and i + 1 < arguments.len) {
            i += 1;
            stage = arguments[i];
        } else if (std.mem.eql(u8, arguments[i], "--refuse")) {
            refuse = true;
        } else {
            try out.print("unknown argument `{s}`\n", .{arguments[i]});
            try out.flush();
            return error.UnknownArgument;
        }
    }

    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();

    if (refuse) {
        try out.writeAll("--- a shader with three mistakes in it ---\n\n");
        try printSource(out, broken);
        _ = shader.compile(gpa, broken, &log.writer) catch {
            try out.writeAll("\n--- and what it was told ---\n\n");
            try out.writeAll(log.written());
            return out.flush();
        };
        try out.writeAll("\nit compiled, which it should not have\n");
        return out.flush();
    }

    var module = shader.compile(gpa, source, &log.writer) catch |err| {
        try out.print("{s}\n", .{log.written()});
        return err;
    };
    defer module.deinit();

    const wanted_vertex = std.mem.eql(u8, stage, "vertex");
    try out.print("--- the source, {s} stage and all ---\n\n", .{stage});
    try printSource(out, source);

    try out.writeAll("\n--- as GLSL 3.30 core ---\n\n");
    try printSource(out, if (wanted_vertex) module.glsl.vertex else module.glsl.fragment);

    // Only the head, because the rest is the text above: the test suite holds
    // the two GLSLs to being the same below it.
    const es = if (wanted_vertex) module.glsl_es.vertex else module.glsl_es.fragment;
    const es_head = shader.glsl.Dialect.es.header();
    try out.writeAll("\n--- as GLSL ES 3.00, for WebGL 2 ---\n\n");
    try printSource(out, std.mem.trimEnd(u8, es[0..es_head.len], "\n"));
    try out.writeAll("\n    // ...and from here on, the GLSL above, line for line.\n");

    try out.writeAll("\n--- as HLSL, shader model 5.0 ---\n\n");
    try printSource(out, if (wanted_vertex) module.hlsl.vertex else module.hlsl.fragment);

    try out.writeAll("\n--- and what the shader said about itself ---\n\n");
    for (module.attributes) |a| {
        try out.print("    attribute  {s: <12} {t: <10} location {d}, ATTR{d}\n", .{
            a.name, a.ty, a.location, a.location,
        });
    }
    for (module.blocks) |b| {
        try out.print("    block      {s: <12} slot {d}, {d} bytes\n", .{ b.name, b.slot, b.size });
        for (b.fields) |field| {
            try out.print("                 {s: <10} {t: <10} at byte {d}\n", .{ field.name, field.ty, field.offset });
        }
    }
    for (module.textures) |t| {
        try out.print("    texture    {s: <12} slot {d}, t{d} and s{d}\n", .{ t.name, t.slot, t.slot, t.slot });
    }

    try out.writeAll(
        \\
        \\Those numbers are what a pipeline is described with, and they were
        \\written once - in the shader. `uniformBlockNames` and `textureNames`
        \\hand back the two lists a `PipelineDesc` wants, in slot order.
        \\
    );
    try out.flush();
}

fn printSource(w: *Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try w.writeByte('\n');
            continue;
        }
        try w.print("    {s}\n", .{line});
    }
}

test "the shader in this example is one the library accepts" {
    var log: Io.Writer.Allocating = .init(std.testing.allocator);
    defer log.deinit();
    var module = shader.compile(std.testing.allocator, source, &log.writer) catch |err| {
        std.debug.print("\n{s}\n", .{log.written()});
        return err;
    };
    defer module.deinit();
    try std.testing.expectEqual(@as(usize, 3), module.attributes.len);
}

test "the broken one is refused, once per mistake" {
    var log: Io.Writer.Allocating = .init(std.testing.allocator);
    defer log.deinit();
    try std.testing.expectError(
        shader.Error.CompileFailed,
        shader.compile(std.testing.allocator, broken, &log.writer),
    );
    // Three: the vec3 given to `position`, the undeclared `uv`, and the
    // attribute the fragment stage cannot see. One per mistake - a name that
    // resolved to nothing does not then produce a second complaint about the
    // type it did not get.
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, log.written(), "^"));
}
