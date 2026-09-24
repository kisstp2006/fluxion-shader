// SPDX-License-Identifier: BSL-1.0

//! Fluxion Shader - one shader, in the language of whichever backend asks.
//!
//! A small shading language, read once and written out as many times as there
//! are targets: as GLSL 3.30 core, as GLSL ES 3.00 and as HLSL for shader
//! model 5.0 - which are what [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi)'s
//! OpenGL, WebGL and Direct3D backends take - and, when asked for, as SPIR-V
//! for Vulkan. Beside them come the numbers a pipeline is described with -
//! which location an attribute is at, which slot a block is bound to, where
//! each of its fields starts - so that they are written once, in the shader,
//! and read back rather than repeated.
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
//!     .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
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
//! **The outputs are a table, and so are the builtins.** What a checked tree
//! can be written out as is a list of rows - see `target` - and what a
//! builtin is called in each of them is a row of another - see `builtins`. A
//! new output is a new row of the first, read against a column of the second;
//! neither is a `switch` to find and extend in five files.
//! `compileWith` runs the rows it is asked for and `Module.output` hands back
//! what each wrote, as text or as binary words:
//!
//! ```zig
//! var module = try shader.compileWith(gpa, source, &log.writer, .{
//!     .targets = .of(&.{.spirv_vulkan}),
//! });
//! defer module.deinit();
//! const spirv = module.output(.spirv_vulkan).words; // .vertex, .fragment: []const u32
//! ```
//!
//! **SPIR-V is Vulkan 1.0's.** One module per stage, SPIR-V 1.0, capability
//! `Shader`, entry point `main`, and nothing that needs a later version or an
//! extension. What `spirv` does with an attribute, a varying, a block and a
//! texture is a pure function of its kind and its slot, and is written down in
//! that module.
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
pub const builtins = @import("builtins.zig");
pub const glsl = @import("glsl.zig");
pub const hlsl = @import("hlsl.zig");
pub const spirv = @import("spirv.zig");
pub const target = @import("target.zig");
pub const Diagnostics = @import("diag.zig");

/// What comes out. See `Module`.
pub const Module = @import("Module.zig");

/// Every type the language has. See `ast`.
pub const Type = ast.Type;

/// The functions it brings with it. See `ast` and `builtins`.
pub const Builtin = ast.Builtin;

pub const Attribute = Module.Attribute;
pub const Block = Module.Block;
pub const Field = Module.Field;
pub const Texture = Module.Texture;
pub const Sources = Module.Sources;
pub const Words = Module.Words;
pub const Output = Module.Output;

/// One row of the table of outputs. See `target`.
pub const Target = target.Target;
/// What `compileWith` is asked for: which targets, and how SPIR-V is laid out.
pub const Options = target.Options;
/// Where SPIR-V puts uniform blocks and textures. See `target.BindingLayout`.
pub const BindingLayout = target.BindingLayout;

pub const Error = error{
    /// The source did not compile. Everything wrong with it has been written
    /// to the log by then.
    CompileFailed,
} || Allocator.Error;

/// Read one source and write out six: two stages in each of three languages.
///
/// Every complaint goes to `log`, in the order it was found, each with the
/// line it happened on and a caret under the column. A log that stays empty
/// is the only proof that nothing was wrong.
///
/// This is `compileWith` asked for the three text targets, which is what it
/// always was and what it still costs.
pub fn compile(gpa: Allocator, source: []const u8, log: *std.Io.Writer) Error!Module {
    return compileWith(gpa, source, log, .{});
}

/// Read one source and write out whichever targets `options` names.
///
/// The default `Options` is the three text targets and is `compile`. SPIR-V
/// is a row of the same table, asked for by id:
///
/// ```zig
/// var module = try shader.compileWith(gpa, source, &log, .{
///     .targets = .of(&.{.spirv_vulkan}),
/// });
/// defer module.deinit();
/// const words = module.output(.spirv_vulkan).words; // .vertex, .fragment
/// ```
///
/// A target whose emitter cannot express the shader - SPIR-V has no
/// recursion, for one - fails the compile with a line in the log naming the
/// target and why, exactly as a mistake in the source would.
pub fn compileWith(
    gpa: Allocator,
    source: []const u8,
    log: *std.Io.Writer,
    options: Options,
) Error!Module {
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

    // The table has to start with the shipped rows: `Module.glsl` and the
    // other two are read out of them by position.
    std.debug.assert(options.table.len <= target.Set.capacity);
    std.debug.assert(options.table.len >= target.builtin_targets.len);
    for (target.builtin_targets, options.table[0..target.builtin_targets.len]) |shipped, given| {
        std.debug.assert(std.mem.eql(u8, shipped.name, given.name));
    }

    // Every allocation happens before the arena is handed over, because
    // handing it over copies the bookkeeping that says what to free.
    const outputs = try keep.alloc(Module.Output, options.table.len);
    @memset(outputs, .none);
    for (options.table, outputs, 0..) |row, *slot, index| {
        if (!options.targets.contains(@enumFromInt(index))) continue;
        switch (row.emit) {
            .text => |emitter| slot.* = .{ .text = .{
                .vertex = try emitText(keep, emitter, &program, .vertex),
                .fragment = try emitText(keep, emitter, &program, .fragment),
            } },
            .words => |emitter| {
                const vertex = try emitWords(work, keep, emitter, row.name, &program, .vertex, options, log);
                const fragment = try emitWords(work, keep, emitter, row.name, &program, .fragment, options, log);
                slot.* = .{ .words = .{ .vertex = vertex, .fragment = fragment } };
            },
        }
    }
    const attributes = try attributesOf(keep, &program);
    const blocks = try blocksOf(keep, &program);
    const textures = try texturesOf(keep, &program);

    return .{
        .arena = owned,
        .glsl = textOf(outputs, .glsl_330),
        .glsl_es = textOf(outputs, .glsl_es_300),
        .hlsl = textOf(outputs, .hlsl_50),
        .outputs = outputs,
        .binding = options.binding,
        .attributes = attributes,
        .blocks = blocks,
        .textures = textures,
    };
}

/// What a text target wrote, or two empty sources when it was not asked for.
fn textOf(outputs: []const Module.Output, id: target.Id) Module.Sources {
    switch (outputs[@intFromEnum(id)]) {
        .text => |sources| return sources,
        else => return .{ .vertex = "", .fragment = "" },
    }
}

fn emitText(
    keep: Allocator,
    emitter: Target.TextFn,
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

/// One stage from a words emitter. The emitter works in `work`, which is
/// thrown away, and what it returns is copied into `keep`: its scratch space
/// is not the module's.
fn emitWords(
    work: Allocator,
    keep: Allocator,
    emitter: Target.WordsFn,
    name: []const u8,
    program: *const ast.Program,
    stage: sema.Where,
    options: Options,
    log: *std.Io.Writer,
) Error![]const u32 {
    var request: target.Request = .{
        .program = program,
        .stage = stage,
        .binding = options.binding,
        .debug_names = options.debug_names,
    };
    const words = emitter(work, &request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            // Not a complaint about a line of the source, so no caret: it is
            // about what the target can say.
            log.print("the {s} target cannot express this shader ({t} stage): {s}\n", .{
                name, stage, request.reason,
            }) catch {};
            return error.CompileFailed;
        },
    };
    return keep.dupe(u32, words);
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
                .default = if (field.default != null) try keep.dupe(f32, field.default_values) else null,
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
    _ = builtins;
    _ = glsl;
    _ = hlsl;
    _ = spirv;
    _ = target;
    _ = Diagnostics;
    _ = Module;
    _ = @import("spirv/op.zig");
    _ = @import("compile_test.zig");
    _ = @import("golden_test.zig");
    _ = @import("spirv/Builder.zig");
    _ = @import("spirv/check.zig");
    _ = @import("spirv_test.zig");
}
