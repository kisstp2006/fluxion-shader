// SPDX-License-Identifier: BSL-1.0

//! Fluxion Shader - one shader, in the language of whichever backend asks.
//!
//! A small shading language, read once and written out twice: as GLSL 3.30
//! core and as HLSL for shader model 5.0, which are what
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi)'s two backends
//! take. Beside them come the numbers a pipeline is described with - which
//! location an attribute is at, which slot a block is bound to, where each of
//! its fields starts - so that they are written once, in the shader, and read
//! back rather than repeated.
//!
//! ```zig
//! const shader = @import("fluxion_shader");
//!
//! var log: std.Io.Writer.Allocating = .init(gpa);
//! defer log.deinit();
//!
//! var module = shader.compile(gpa, source, &log.writer) catch {
//!     std.debug.print("{s}\n", .{log.written()});
//!     return error.ShaderFailed;
//! };
//! defer module.deinit();
//!
//! const handle = try device.createShader(.{
//!     .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
//!     .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
//! });
//! ```
//!
//! And the source it read:
//!
//! ```
//! attribute vec2 corner : 0;
//! varying vec2 uv;
//! uniform Frame : 0 { mat4 projection; }
//! texture2d atlas : 0;
//!
//! vertex {
//!     uv = corner;
//!     position = projection * vec4(corner, 0.0, 1.0);
//! }
//!
//! fragment {
//!     target = sample(atlas, uv);
//! }
//! ```
//!
//! **It is a compiler, not a translator.** The source is parsed, checked and
//! emitted, so a mistake is a message with a line and a column on it rather
//! than something a driver says later in a language the author did not write.
//!
//! **It does not have everything.** No arrays, no structs, no integer
//! vectors, no matrix literals, no compute stage. Most of those are left out
//! for one reason: they are where GLSL and HLSL stop agreeing, and a library
//! that emitted both from one description would be promising something it
//! could not keep. The README names each one and why.
//!
//! Nothing here allocates except through the allocator handed to `compile`,
//! and nothing here talks to a driver.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ast = @import("ast.zig");
pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");
pub const sema = @import("sema.zig");
pub const glsl = @import("glsl.zig");
pub const hlsl = @import("hlsl.zig");
pub const Diagnostics = @import("diag.zig");

/// What comes out. See `Module`.
pub const Module = @import("Module.zig");

/// Every type the language has. See `ast`.
pub const Type = ast.Type;

/// The functions it brings with it. See `ast`.
pub const Builtin = ast.Builtin;

pub const Attribute = Module.Attribute;
pub const Block = Module.Block;
pub const Field = Module.Field;
pub const Texture = Module.Texture;
pub const Sources = Module.Sources;

pub const Error = error{
    /// The source did not compile. Everything wrong with it has been written
    /// to the log by then.
    CompileFailed,
} || Allocator.Error;

/// Read one source and write out four.
///
/// Every complaint goes to `log`, in the order it was found, each with the
/// line it happened on and a caret under the column. A log that stays empty
/// is the only proof that nothing was wrong.
pub fn compile(gpa: Allocator, source: []const u8, log: *std.Io.Writer) Error!Module {
    // Two arenas: one for the tokens and the tree, which nothing outside
    // this call ever sees, and one for what comes back.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var owned: std.heap.ArenaAllocator = .init(gpa);
    errdefer owned.deinit();

    const work = scratch.allocator();
    const keep = owned.allocator();
    var diagnostics: Diagnostics = .init(source, log);

    var failure: lex.Failure = undefined;
    const tokens = lex.tokenize(work, source, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostics.report(failure.offset, "{s}", .{switch (failure.err) {
                error.UnexpectedByte => "this is not part of anything the language has",
                error.MalformedNumber => "this is not a number",
                error.UnterminatedComment => "this comment reaches the end of the source",
            }});
            return error.CompileFailed;
        },
    };

    var program = parse.parse(work, tokens, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.CompileFailed,
    };

    sema.check(work, &program, &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CheckFailed => return error.CompileFailed,
    };

    // Every allocation happens before the arena is handed over, because
    // handing it over copies the bookkeeping that says what to free.
    const sources: struct { Module.Sources, Module.Sources } = .{
        .{
            .vertex = try emit(keep, glsl.emit, &program, .vertex),
            .fragment = try emit(keep, glsl.emit, &program, .fragment),
        },
        .{
            .vertex = try emit(keep, hlsl.emit, &program, .vertex),
            .fragment = try emit(keep, hlsl.emit, &program, .fragment),
        },
    };
    const attributes = try attributesOf(keep, &program);
    const blocks = try blocksOf(keep, &program);
    const textures = try texturesOf(keep, &program);

    return .{
        .arena = owned,
        .glsl = sources[0],
        .hlsl = sources[1],
        .attributes = attributes,
        .blocks = blocks,
        .textures = textures,
    };
}

const EmitFn = fn (*const ast.Program, sema.Where, *std.Io.Writer) std.Io.Writer.Error!void;

fn emit(
    keep: Allocator,
    comptime emitter: EmitFn,
    program: *const ast.Program,
    stage: sema.Where,
) Allocator.Error![:0]const u8 {
    var out: std.Io.Writer.Allocating = .init(keep);
    // The writer is over an arena, so the only thing that can go wrong is
    // running out of memory, and that has its own name.
    emitter(program, stage, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSliceSentinel(0);
}

fn attributesOf(keep: Allocator, program: *const ast.Program) Allocator.Error![]const Module.Attribute {
    const out = try keep.alloc(Module.Attribute, program.attributes.len);
    for (program.attributes, out) |a, *entry| {
        entry.* = .{ .name = try keep.dupe(u8, a.name), .ty = a.ty, .location = a.location };
    }
    return out;
}

fn blocksOf(keep: Allocator, program: *const ast.Program) Allocator.Error![]const Module.Block {
    const out = try keep.alloc(Module.Block, program.blocks.len);
    for (program.blocks, out) |b, *entry| {
        const fields = try keep.alloc(Module.Field, b.fields.len);
        for (b.fields, fields) |field, *copy| {
            copy.* = .{
                .name = try keep.dupe(u8, field.name),
                .ty = field.ty,
                .offset = field.byte_offset,
            };
        }
        entry.* = .{
            .name = try keep.dupe(u8, b.name),
            .slot = b.slot,
            .size = b.size,
            .fields = fields,
        };
    }
    return out;
}

fn texturesOf(keep: Allocator, program: *const ast.Program) Allocator.Error![]const Module.Texture {
    const out = try keep.alloc(Module.Texture, program.textures.len);
    for (program.textures, out) |t, *entry| {
        entry.* = .{ .name = try keep.dupe(u8, t.name), .slot = t.slot };
    }
    return out;
}

test {
    _ = ast;
    _ = lex;
    _ = parse;
    _ = sema;
    _ = glsl;
    _ = hlsl;
    _ = Diagnostics;
    _ = Module;
    _ = @import("compile_test.zig");
}
