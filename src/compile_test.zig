// SPDX-License-Identifier: BSL-1.0

//! One source in, two languages out, checked line by line.
//!
//! The emitters have no tests of their own, because what they produce is only
//! worth checking whole: a `mul` in the right place is not evidence unless
//! the `*` beside it is in the right place too. So these compile small
//! shaders and read what came out.
//!
//! Whether a driver accepts it is a different question, and only a driver can
//! answer it. That test lives in the examples, where there is a real HLSL
//! compiler and a real OpenGL context to ask.

const std = @import("std");
const testing = std.testing;

const shader = @import("root.zig");
const Module = shader.Module;

/// Compile, or print what went wrong and fail.
fn build(source: []const u8) !Module {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    return shader.compile(testing.allocator, source, &log.writer) catch |err| {
        std.debug.print("\n{s}\n", .{log.written()});
        return err;
    };
}

/// Compile something that should not, and check what it complained about.
fn expectRefused(source: []const u8, wanted: []const u8) !void {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    if (shader.compile(testing.allocator, source, &log.writer)) |*compiled| {
        var mutable = compiled.*;
        mutable.deinit();
        std.debug.print("\nexpected a complaint about `{s}`, got a shader\n", .{wanted});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(shader.Error.CompileFailed, err);
        if (std.mem.indexOf(u8, log.written(), wanted) == null) {
            std.debug.print("\nexpected `{s}` in:\n{s}\n", .{ wanted, log.written() });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\nexpected `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectMissing(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("\ndid not expect `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// The shader the sprite example draws with, which is the one this library
/// exists for: an instanced quad, a texture, and a matrix from a block.
const sprites =
    \\attribute vec2 corner : 0;
    \\attribute vec4 placement : 1;
    \\attribute vec4 tint : 2;
    \\
    \\varying vec2 uv;
    \\varying vec4 colour;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\vertex {
    \\    vec2 world = placement.xy + corner * placement.zw;
    \\    uv = corner;
    \\    colour = tint;
    \\    position = projection * vec4(world, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    target = sample(atlas, uv) * colour;
    \\}
;

test "the sprite shader, as GLSL" {
    var module = try build(sprites);
    defer module.deinit();

    const vertex = module.glsl.vertex;
    try expectContains(vertex, "#version 330 core");
    try expectContains(vertex, "layout(location = 0) in vec2 corner;");
    try expectContains(vertex, "layout(location = 2) in vec4 tint;");
    try expectContains(vertex, "out vec2 uv;");
    try expectContains(vertex, "layout(std140) uniform Frame {");
    try expectContains(vertex, "    mat4 projection;");
    try expectContains(vertex, "uniform sampler2D atlas;");
    try expectContains(vertex, "void main() {");
    try expectContains(vertex, "vec2 world = (placement.xy + (corner * placement.zw));");
    try expectContains(vertex, "gl_Position = (projection * vec4(world, 0.0, 1.0));");

    const fragment = module.glsl.fragment;
    try expectContains(fragment, "in vec2 uv;");
    try expectContains(fragment, "out vec4 fluxion_target;");
    try expectContains(fragment, "fluxion_target = (texture(atlas, uv) * colour);");
    // The vertex stage's inputs are not the fragment stage's.
    try expectMissing(fragment, "in vec2 corner;");
}

test "the sprite shader, as HLSL" {
    var module = try build(sprites);
    defer module.deinit();

    const vertex = module.hlsl.vertex;
    try expectContains(vertex, "cbuffer Frame : register(b0) {");
    try expectContains(vertex, "    float4x4 projection;");
    try expectContains(vertex, "Texture2D atlas : register(t0);");
    try expectContains(vertex, "SamplerState atlas_sampler : register(s0);");
    try expectContains(vertex, "struct FluxionInput {");
    try expectContains(vertex, "    float2 corner : ATTR0;");
    try expectContains(vertex, "    float4 tint : ATTR2;");
    try expectContains(vertex, "struct FluxionVaryings {");
    try expectContains(vertex, "    float4 fluxion_position : SV_POSITION;");
    try expectContains(vertex, "    float2 uv : TEXCOORD0;");
    try expectContains(vertex, "    float4 colour : TEXCOORD1;");
    try expectContains(vertex, "FluxionVaryings main(FluxionInput fluxion_in) {");
    try expectContains(vertex, "float2 world = (fluxion_in.placement.xy + (fluxion_in.corner * fluxion_in.placement.zw));");
    // The one that matters: a matrix times a vector is a call, not a `*`.
    try expectContains(vertex, "fluxion_out.fluxion_position = mul(projection, float4(world, 0.0, 1.0));");
    try expectContains(vertex, "return fluxion_out;");

    const fragment = module.hlsl.fragment;
    try expectContains(fragment, "float4 main(FluxionVaryings fluxion_in) : SV_TARGET {");
    try expectContains(fragment, "fluxion_target = (atlas.Sample(atlas_sampler, fluxion_in.uv) * fluxion_in.colour);");
    try expectContains(fragment, "return fluxion_target;");
    // A fragment shader takes the varyings; it has no input struct of its own.
    try expectMissing(fragment, "struct FluxionInput");
}

test "what the shader said about itself" {
    var module = try build(sprites);
    defer module.deinit();

    try testing.expectEqual(@as(usize, 3), module.attributes.len);
    try testing.expectEqualStrings("placement", module.attributes[1].name);
    try testing.expectEqual(@as(u32, 1), module.attributes[1].location);
    try testing.expectEqual(shader.Type.vec4, module.attributes[1].ty);

    try testing.expectEqual(@as(usize, 1), module.blocks.len);
    const frame = module.block("Frame").?;
    try testing.expectEqual(@as(u32, 0), frame.slot);
    try testing.expectEqual(@as(u32, 64), frame.size);
    try testing.expectEqual(@as(?u32, 0), frame.offsetOf("projection"));

    try testing.expectEqual(@as(usize, 1), module.textures.len);
    try testing.expectEqualStrings("atlas", module.textures[0].name);

    // The two lists a pipeline is described with, in slot order.
    const blocks = (try module.uniformBlockNames()).?;
    try testing.expectEqual(@as(usize, 1), blocks.len);
    try testing.expectEqualStrings("Frame", blocks[0]);
    const textures = (try module.textureNames()).?;
    try testing.expectEqualStrings("atlas", textures[0]);
    // Asked twice, worked out once.
    try testing.expectEqual(blocks.ptr, (try module.uniformBlockNames()).?.ptr);
}

test "a block's fields are laid out where both APIs put them" {
    var module = try build(
        \\uniform Frame : 0 {
        \\    vec3 direction;
        \\    float strength;
        \\    mat4 projection;
        \\    vec2 offset;
        \\}
        \\vertex { position = vec4(direction * strength, offset.x); position = position * projection; }
        \\fragment { target = vec4(1.0); }
    );
    defer module.deinit();

    const frame = module.blocks[0];
    // A vec3 is twelve bytes; a float packs into the four after it rather
    // than starting a register of its own.
    try testing.expectEqual(@as(?u32, 0), frame.offsetOf("direction"));
    try testing.expectEqual(@as(?u32, 12), frame.offsetOf("strength"));
    // A matrix starts a register.
    try testing.expectEqual(@as(?u32, 16), frame.offsetOf("projection"));
    try testing.expectEqual(@as(?u32, 80), frame.offsetOf("offset"));
    // And the whole block is a multiple of sixteen.
    try testing.expectEqual(@as(u32, 96), frame.size);
}

test "a vector filled from one scalar is a cast in HLSL" {
    var module = try build(
        \\vertex { position = vec4(0.5); }
        \\fragment { float grey = float(2) * 0.5; target = vec4(grey); }
    );
    defer module.deinit();

    // GLSL fills a vector from one scalar and HLSL does not, so what comes
    // out there is the cast that broadcasts.
    try expectContains(module.glsl.vertex, "gl_Position = vec4(0.5);");
    try expectContains(module.hlsl.vertex, "fluxion_out.fluxion_position = ((float4)(0.5));");
    try expectContains(module.glsl.fragment, "float grey = (float(2) * 0.5);");
    try expectContains(module.hlsl.fragment, "float grey = (((float)(2)) * 0.5);");
    // And a vector built from parts is still a constructor on both.
    try expectContains(module.hlsl.fragment, "((float4)(grey))");
}

test "an integer where a float belongs comes out as a float" {
    var module = try build(
        \\vertex { position = vec4(1, 2, 3, 1); }
        \\fragment { float half_way = 1; target = vec4(half_way); }
    );
    defer module.deinit();

    try expectContains(module.glsl.vertex, "gl_Position = vec4(1.0, 2.0, 3.0, 1.0);");
    try expectContains(module.hlsl.vertex, "fluxion_out.fluxion_position = float4(1.0, 2.0, 3.0, 1.0);");
    try expectContains(module.glsl.fragment, "float half_way = 1.0;");
    // A whole number used as one stays whole.
    var counter = try build(
        \\vertex { position = vec4(0.0); for (int i = 0; i < 4; i += 1) { position.x += 1.0; } }
        \\fragment { target = vec4(1.0); }
    );
    defer counter.deinit();
    try expectContains(counter.glsl.vertex, "for (int i = 0; (i < 4); i += 1) {");
}

test "the functions that are spelled differently are spelled differently" {
    var module = try build(
        \\varying vec2 uv;
        \\vertex { uv = vec2(0.0); position = vec4(0.0); }
        \\fragment {
        \\    float a = fract(uv.x);
        \\    float b = mix(a, 1.0, 0.5);
        \\    float c = inversesqrt(b);
        \\    float d = saturate(c);
        \\    float e = atan2(uv.y, uv.x);
        \\    float f = atan(uv.x);
        \\    float g = ddx(f) + ddy(f);
        \\    target = vec4(d, e, g, 1.0);
        \\}
    );
    defer module.deinit();

    const gl = module.glsl.fragment;
    try expectContains(gl, "float a = fract(uv.x);");
    try expectContains(gl, "float b = mix(a, 1.0, 0.5);");
    try expectContains(gl, "float c = inversesqrt(b);");
    try expectContains(gl, "float d = clamp(c, 0.0, 1.0);");
    try expectContains(gl, "float e = atan(uv.y, uv.x);");
    try expectContains(gl, "float f = atan(uv.x);");
    try expectContains(gl, "float g = (dFdx(f) + dFdy(f));");

    const hl = module.hlsl.fragment;
    try expectContains(hl, "float a = frac(fluxion_in.uv.x);");
    try expectContains(hl, "float b = lerp(a, 1.0, 0.5);");
    try expectContains(hl, "float c = rsqrt(b);");
    try expectContains(hl, "float d = saturate(c);");
    try expectContains(hl, "float e = atan2(fluxion_in.uv.y, fluxion_in.uv.x);");
    try expectContains(hl, "float f = atan(fluxion_in.uv.x);");
    try expectContains(hl, "float g = (ddx(f) + ddy(f));");
}

test "mod is GLSL's mod on both sides" {
    var module = try build(
        \\vertex { position = vec4(0.0); }
        \\fragment { float t = mod(0.5, 2.0); target = vec4(t); }
    );
    defer module.deinit();

    try expectContains(module.glsl.fragment, "float t = mod(0.5, 2.0);");
    // HLSL's `fmod` takes the sign of the numerator and GLSL's does not, so
    // what comes out is the definition rather than the name.
    try expectContains(module.hlsl.fragment, "float t = ((0.5) - (2.0) * floor((0.5) / (2.0)));");
    try expectMissing(module.hlsl.fragment, "fmod");
}

test "a matrix product is a call and a componentwise one is not" {
    var module = try build(
        \\uniform Frame : 0 { mat4 a; mat4 b; float s; }
        \\vertex {
        \\    mat4 product = a * b;
        \\    mat4 scaled = a * s;
        \\    position = product * vec4(1.0);
        \\    position = scaled * position;
        \\}
        \\fragment { target = vec4(1.0); }
    );
    defer module.deinit();

    const gl = module.glsl.vertex;
    try expectContains(gl, "mat4 product = (a * b);");
    try expectContains(gl, "mat4 scaled = (a * s);");

    const hl = module.hlsl.vertex;
    try expectContains(hl, "float4x4 product = mul(a, b);");
    // A matrix and a lone float is componentwise in both, so it stays a `*`.
    try expectContains(hl, "float4x4 scaled = (a * s);");
    try expectContains(hl, "fluxion_out.fluxion_position = mul(product, ((float4)(1.0)));");
}

test "a user function is emitted into both stages, once each" {
    var module = try build(
        \\uniform Frame : 0 { float gamma; }
        \\vec3 encode(vec3 raw) {
        \\    return pow(raw, vec3(gamma));
        \\}
        \\vertex { position = vec4(encode(vec3(1.0)), 1.0); }
        \\fragment { target = vec4(encode(vec3(0.5)), 1.0); }
    );
    defer module.deinit();

    try expectContains(module.glsl.vertex, "vec3 encode(vec3 raw);");
    try expectContains(module.glsl.vertex, "vec3 encode(vec3 raw) {");
    try expectContains(module.glsl.fragment, "vec3 encode(vec3 raw) {");
    try expectContains(module.hlsl.vertex, "float3 encode(float3 raw) {");
    try expectContains(module.hlsl.fragment, "float3 encode(float3 raw) {");
    try expectContains(module.hlsl.fragment, "return pow(raw, ((float3)(gamma)));");
}

test "the index builtins cost a struct member only where they are used" {
    var module = try build(
        \\vertex {
        \\    float x = float(vertex_index) + float(instance_index);
        \\    position = vec4(x, 0.0, 0.0, 1.0);
        \\}
        \\fragment { target = vec4(1.0); }
    );
    defer module.deinit();

    try expectContains(module.glsl.vertex, "float(gl_VertexID)");
    try expectContains(module.glsl.vertex, "float(gl_InstanceID)");
    try expectContains(module.hlsl.vertex, "uint fluxion_vertex_index : SV_VertexID;");
    try expectContains(module.hlsl.vertex, "uint fluxion_instance_index : SV_InstanceID;");
    try expectContains(module.hlsl.vertex, "((float)(((int)fluxion_in.fluxion_vertex_index)))");

    var without = try build(
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    );
    defer without.deinit();
    try expectMissing(without.hlsl.vertex, "SV_VertexID");
}

test "control flow comes out as control flow" {
    var module = try build(
        \\varying vec2 uv;
        \\vertex { uv = vec2(0.0); position = vec4(0.0); }
        \\fragment {
        \\    float total = 0.0;
        \\    for (int i = 0; i < 4; i += 1) {
        \\        total += 0.25;
        \\    }
        \\    if (total > 0.9) {
        \\        total = 1.0;
        \\    } else if (total > 0.5) {
        \\        total = 0.5;
        \\    } else {
        \\        discard;
        \\    }
        \\    while (total < 0.0) { total += 1.0; }
        \\    target = vec4(total > 0.5 ? 1.0 : 0.0);
        \\}
    );
    defer module.deinit();

    for ([_][:0]const u8{ module.glsl.fragment, module.hlsl.fragment }) |source| {
        try expectContains(source, "for (int i = 0; (i < 4); i += 1) {");
        try expectContains(source, "if ((total > 0.9)) {");
        try expectContains(source, "} else {");
        try expectContains(source, "discard;");
        try expectContains(source, "while ((total < 0.0)) {");
        try expectContains(source, "((total > 0.5) ? 1.0 : 0.0)");
    }
}

// -------------------------------------------------------------------------
// What it refuses
// -------------------------------------------------------------------------

test "a name that is nothing is named" {
    try expectRefused(
        \\vertex { position = vec4(nonsense, 0.0, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "`nonsense` is not anything this shader declared");
}

test "the stages cannot reach into each other" {
    try expectRefused(
        \\attribute vec2 corner : 0;
        \\vertex { position = vec4(corner, 0.0, 1.0); }
        \\fragment { target = vec4(corner, 0.0, 1.0); }
    , "only the vertex stage has");
    try expectRefused(
        \\vertex { position = vec4(1.0); target = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "`target` belongs to the fragment stage");
    try expectRefused(
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(1.0); discard; position = vec4(1.0); }
    , "`position` belongs to the vertex stage");
}

test "a stage that draws nothing says so" {
    try expectRefused(
        \\vertex { float x = 1.0; }
        \\fragment { target = vec4(1.0); }
    , "never writes `position`");
    try expectRefused(
        \\vertex { position = vec4(1.0); }
        \\fragment { float x = 1.0; }
    , "never writes `target`");
    try expectRefused("fragment { target = vec4(1.0); }", "no vertex stage");
    try expectRefused("vertex { position = vec4(1.0); }", "no fragment stage");
}

test "the types have to add up" {
    try expectRefused(
        \\vertex { position = vec3(1.0, 1.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "is vec3, and a vec4 was wanted");
    try expectRefused(
        \\vertex { position = vec4(1.0, 2.0); }
        \\fragment { target = vec4(1.0); }
    , "wants 4 components, and this gives 2");
    try expectRefused(
        \\uniform Frame : 0 { mat4 m; }
        \\vertex { position = m * vec3(1.0, 1.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "multiplies a vec4, not a vec3");
    try expectRefused(
        \\vertex { position = vec4(1.0); }
        \\fragment { float x = 1.0 + true; target = vec4(x); }
    , "needs numbers");
}

test "a swizzle has to be one" {
    try expectRefused(
        \\attribute vec2 corner : 0;
        \\vertex { position = vec4(corner.xyz, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "a vec2 has no `z`");
    try expectRefused(
        \\attribute vec4 corner : 0;
        \\vertex { position = vec4(corner.xg, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "mixes `xyzw` with `rgba`");
    try expectRefused(
        \\uniform Frame : 0 { float t; }
        \\vertex { position = vec4(t.x, 0.0, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "only a vector has parts");
}

test "what cannot be written is not written" {
    try expectRefused(
        \\attribute vec2 corner : 0;
        \\vertex { corner = vec2(1.0); position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "it cannot be written");
    try expectRefused(
        \\uniform Frame : 0 { float t; }
        \\vertex { t = 1.0; position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "a uniform is what the program uploaded");
}

test "a function belongs to neither stage" {
    try expectRefused(
        \\attribute vec2 corner : 0;
        \\vec2 doubled() { return corner * 2.0; }
        \\vertex { position = vec4(doubled(), 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "only the vertex stage has");
    try expectRefused(
        \\varying vec2 uv;
        \\vec2 read() { return uv; }
        \\vertex { uv = vec2(0.0); position = vec4(read(), 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "shared by both stages; pass it in");
}

test "the comparisons that mean two things are refused" {
    try expectRefused(
        \\attribute vec2 corner : 0;
        \\vertex { position = vec4(1.0); if (corner == vec2(0.0)) { position = vec4(0.0); } }
        \\fragment { target = vec4(1.0); }
    , "compares two scalars");
}

test "there is no matrix literal, and the reason is given" {
    try expectRefused(
        \\vertex { mat4 m = mat4(1.0); position = m * vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "GLSL builds one from columns and HLSL from rows");
}

test "a name the emitter uses cannot be taken" {
    try expectRefused(
        \\attribute vec2 input : 0;
        \\vertex { position = vec4(input, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "means something to GLSL or to HLSL");
    try expectRefused(
        \\attribute vec2 fluxion_thing : 0;
        \\vertex { position = vec4(fluxion_thing, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "the emitter's, not yours");
    try expectRefused(
        \\attribute vec2 vec3 : 0;
        \\vertex { position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "is a type");
}

test "two things cannot share a slot, or a name" {
    try expectRefused(
        \\attribute vec2 a : 0;
        \\attribute vec2 b : 0;
        \\vertex { position = vec4(a + b, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "share slot 0");
    try expectRefused(
        \\attribute vec2 a : 0;
        \\varying vec2 a;
        \\vertex { a = vec2(0.0); position = vec4(1.0); }
        \\fragment { target = vec4(1.0); }
    , "declared twice");
}

test "a call has to match what it calls" {
    try expectRefused(
        \\vertex { position = vec4(dot(vec2(1.0)), 0.0, 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "takes 2 arguments, and this passes 1");
    try expectRefused(
        \\vec2 twice(vec2 v) { return v * 2.0; }
        \\vertex { position = vec4(twice(vec2(1.0), 3.0), 0.0, 1.0); }
        \\fragment { target = vec4(1.0); }
    , "takes 1 argument, and this passes 2");
    try expectRefused(
        \\texture2d atlas : 0;
        \\vertex { position = vec4(1.0); }
        \\fragment { target = sample(atlas, 1.0); }
    , "the coordinate is float, and a vec2 was wanted");
}

test "every mistake in a shader is reported, not just the first" {
    var log: std.Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    const result = shader.compile(testing.allocator,
        \\vertex {
        \\    position = missing_one;
        \\    float x = missing_two;
        \\    float y = missing_three;
        \\}
        \\fragment { target = vec4(1.0); }
    , &log.writer);
    try testing.expectError(shader.Error.CompileFailed, result);

    try expectContains(log.written(), "missing_one");
    try expectContains(log.written(), "missing_two");
    try expectContains(log.written(), "missing_three");
    // And each one is on its own line, with a caret under it.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, log.written(), "^"));
}

test "a lexical mistake is a message, not a crash" {
    try expectRefused("vertex { float x = 1.2.3; }", "not a number");
    try expectRefused("vertex { float x = 1 # 2; }", "not part of anything");
    try expectRefused("vertex { /* forever", "reaches the end of the source");
}

test "the shader in the module comment compiles" {
    var module = try build(
        \\attribute vec2 corner : 0;
        \\varying vec2 uv;
        \\uniform Frame : 0 { mat4 projection; }
        \\texture2d atlas : 0;
        \\
        \\vertex {
        \\    uv = corner;
        \\    position = projection * vec4(corner, 0.0, 1.0);
        \\}
        \\
        \\fragment {
        \\    target = sample(atlas, uv);
        \\}
    );
    defer module.deinit();
    try testing.expect(module.glsl.vertex.len > 0);
    try testing.expect(module.hlsl.fragment.len > 0);
}
