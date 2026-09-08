// SPDX-License-Identifier: BSL-1.0

//! The compiled shader, given to a real driver.
//!
//! One source, compiled once, handed to
//! [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi) as both languages
//! at once - and the pipeline described out of the module's own reflection,
//! so that a location, a slot and a name are never written down twice.
//!
//! Run it with `zig build example-quad`. `-- --backend gl` or `--backend
//! d3d11` picks the API; `-- --capture out.png` draws one frame to a file
//! instead of opening a window.
//!
//! **This is the test that matters.** Everything the library's own suite
//! checks is what the emitted text says; whether a driver will take it is a
//! question only a driver answers, and there are two of them at the bottom
//! of this file, each asked the same shader.

const std = @import("std");
const Io = std.Io;

const shader = @import("fluxion_shader");
const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const windowing = @import("window");
const Window = windowing.Window;

/// A textured quad with a tint and a wave through it: a matrix out of a
/// uniform block, a texture, two varyings, a shared function, and the
/// handful of builtins the two languages spell differently.
const source =
    \\attribute vec2 corner : 0;
    \\
    \\varying vec2 uv;
    \\varying vec4 shade;
    \\
    \\uniform Frame : 0 {
    \\    mat4 projection;
    \\    vec4 rect;
    \\    vec4 tint;
    \\    float time;
    \\}
    \\
    \\texture2d atlas : 0;
    \\
    \\const float amplitude = 0.06;
    \\
    \\// Shared by both stages, so it may touch neither.
    \\float wave(float at, float seconds) {
    \\    return sin(at * 6.2831 + seconds) * amplitude;
    \\}
    \\
    \\vertex {
    \\    uv = corner;
    \\    shade = mix(vec4(1.0), tint, corner.y);
    \\    vec2 world = rect.xy + corner * rect.zw;
    \\    world.y += wave(corner.x, time) * rect.w;
    \\    position = projection * vec4(world, 0.0, 1.0);
    \\}
    \\
    \\fragment {
    \\    vec4 texel = sample(atlas, uv);
    \\    float band = saturate(mod(uv.x * 4.0, 1.0));
    \\    target = texel * shade * (0.75 + 0.25 * band);
    \\}
;

/// What the vertex buffer holds: the four corners of a unit quad, as a strip.
const corners = [_]f32{ 0, 0, 1, 0, 0, 1, 1, 1 };

/// The uniform block, in the layout the shader said it was. `offsetOf` is
/// checked against this below, which is the point of the reflection being
/// there at all.
const Frame = extern struct {
    projection: [16]f32,
    /// Where the quad is, in pixels from the top left: x, y, width, height.
    rect: [4]f32,
    tint: [4]f32,
    time: f32,
    _padding: [3]f32 = @splat(0),
};

/// An orthographic projection: pixels from the top left in, clip space out,
/// for whichever clip space the device has. Written out rather than taken
/// from `fluxion-math`, so this example depends on one library fewer.
fn orthographic(width: f32, height: f32, backend: rhi.Backend) [16]f32 {
    // Depth from -1 to 1 on OpenGL and 0 to 1 on the others, which is the one
    // thing a projection cannot be written without knowing.
    const zero_to_one = backend != .gl;
    var m: [16]f32 = @splat(0);
    m[0] = 2 / width;
    m[5] = -2 / height;
    m[10] = if (zero_to_one) 1 else 2;
    m[12] = -1;
    m[13] = 1;
    m[14] = if (zero_to_one) 0 else -1;
    m[15] = 1;
    return m;
}

/// Sixteen by sixteen: a light square inside a darker border, so that both
/// the sampling and the wrap show.
fn makeAtlas() [16 * 16 * 4]u8 {
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            const edge = x < 2 or y < 2 or x > 13 or y > 13;
            const checker = ((x / 4) + (y / 4)) % 2 == 0;
            const level: u8 = if (edge) 90 else if (checker) 245 else 190;
            const texel = (y * 16 + x) * 4;
            pixels[texel + 0] = level;
            pixels[texel + 1] = level;
            pixels[texel + 2] = level;
            pixels[texel + 3] = 255;
        }
    }
    return pixels;
}

// -------------------------------------------------------------------------
// From a module to a pipeline
// -------------------------------------------------------------------------

/// The one mapping a program has to write: this language's types against the
/// vertex formats the renderer knows. Nothing else about the pipeline is
/// repeated - the locations, the slots and the names all come from the
/// module.
fn vertexFormat(ty: shader.Type) !rhi.VertexFormat {
    return switch (ty) {
        .float => .float,
        .vec2 => .float2,
        .vec3 => .float3,
        .vec4 => .float4,
        .int => .int,
        else => error.NotAVertexFormat,
    };
}

const Built = struct {
    module: shader.Module,
    pipeline: rhi.Pipeline,

    fn deinit(self: *Built) void {
        self.module.deinit();
        self.* = undefined;
    }
};

/// Compile the shader and describe a pipeline out of what it says about
/// itself. Tightly packed attributes in one buffer, in declaration order.
fn build(gpa: std.mem.Allocator, device: *rhi.Device, log: *Io.Writer) !Built {
    var module = try shader.compile(gpa, source, log);
    errdefer module.deinit();

    const handle = try device.createShader(.{
        .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
        .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
        .label = "quad",
    });

    var attributes: [8]rhi.VertexAttribute = undefined;
    var stride: u32 = 0;
    for (module.attributes, 0..) |a, i| {
        const format = try vertexFormat(a.ty);
        attributes[i] = .{ .location = a.location, .format = format, .offset = stride };
        stride += format.size();
    }

    const pipeline = try device.createPipeline(.{
        .shader = handle,
        .attributes = attributes[0..module.attributes.len],
        .buffers = &.{.{ .stride = stride }},
        .topology = .triangle_strip,
        .blend = .alpha,
        // The two lists the shader itself wrote down.
        .uniform_blocks = (try module.uniformBlockNames()) orelse return error.SlotsHaveHoles,
        .textures = (try module.textureNames()) orelse return error.SlotsHaveHoles,
        .label = "quad",
    });

    return .{ .module = module, .pipeline = pipeline };
}

/// One frame into `target`, `width` by `height`.
fn draw(
    device: *rhi.Device,
    built: Built,
    target: rhi.RenderTarget,
    width: u32,
    height: u32,
    seconds: f32,
    frame_buffer: rhi.Buffer,
    vertices: rhi.Buffer,
    atlas: rhi.Texture,
    sampler: rhi.Sampler,
) !void {
    // The quad covers the middle seventy per cent of the window, in pixels
    // from the top left corner.
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const frame: Frame = .{
        .projection = orthographic(w, h, device.backendTag()),
        .rect = .{ w * 0.15, h * 0.15, w * 0.7, h * 0.7 },
        .tint = .{ 0.35, 0.75, 1.0, 1.0 },
        .time = seconds,
    };
    try device.updateBuffer(frame_buffer, 0, std.mem.asBytes(&frame));

    const cmd = device.begin();
    try cmd.beginPass(.{ .color = .{ .target = target, .clear_color = .{ 0.07, 0.08, 0.11, 1 } } });
    try cmd.setPipeline(built.pipeline);
    try cmd.setVertexBuffer(0, vertices, 0);
    try cmd.setUniformBuffer(0, frame_buffer);
    try cmd.setTexture(0, atlas, sampler);
    try cmd.draw(.{ .vertex_count = 4 });
    try cmd.endPass();
    try device.submit();
}

const Scene = struct {
    built: Built,
    frame: rhi.Buffer,
    vertices: rhi.Buffer,
    atlas: rhi.Texture,
    sampler: rhi.Sampler,

    fn init(gpa: std.mem.Allocator, device: *rhi.Device, log: *Io.Writer) !Scene {
        var built = try build(gpa, device, log);
        errdefer built.deinit();

        const frame = module_frame: {
            const block = built.module.block("Frame") orelse return error.NoFrameBlock;
            break :module_frame try device.createBuffer(.{ .kind = .uniform, .size = block.size });
        };
        const texels = makeAtlas();
        return .{
            .built = built,
            .frame = frame,
            .vertices = try device.createBuffer(.{
                .kind = .vertex,
                .size = @sizeOf(@TypeOf(corners)),
                .data = std.mem.asBytes(&corners),
            }),
            .atlas = try device.createTexture(.{ .width = 16, .height = 16, .data = &texels }),
            .sampler = try device.createSampler(.nearest),
        };
    }

    fn render(self: *Scene, device: *rhi.Device, target: rhi.RenderTarget, width: u32, height: u32, seconds: f32) !void {
        try draw(device, self.built, target, width, height, seconds, self.frame, self.vertices, self.atlas, self.sampler);
    }

    fn deinit(self: *Scene) void {
        self.built.deinit();
        self.* = undefined;
    }
};

// -------------------------------------------------------------------------
// The program
// -------------------------------------------------------------------------

const Options = struct {
    backend: rhi.Backend,
    width: u32 = 640,
    height: u32 = 480,
    frames: ?u32 = null,
    capture: ?[]const u8 = null,
    at: f32 = 0.4,
    software: bool = false,

    fn fromArguments(init: std.process.Init, arena: std.mem.Allocator) !Options {
        var self: Options = .{ .backend = windowing.defaultBackend() };
        const arguments = try init.minimal.args.toSlice(arena);
        var i: usize = 1;
        while (i < arguments.len) : (i += 1) {
            const argument = arguments[i];
            const value = if (i + 1 < arguments.len) arguments[i + 1] else null;
            if (std.mem.eql(u8, argument, "--backend")) {
                self.backend = windowing.parseBackend(value orelse return error.MissingValue) orelse return error.UnknownBackend;
                i += 1;
            } else if (std.mem.eql(u8, argument, "--frames")) {
                self.frames = try std.fmt.parseInt(u32, value orelse return error.MissingValue, 10);
                i += 1;
            } else if (std.mem.eql(u8, argument, "--capture")) {
                self.capture = value orelse return error.MissingValue;
                i += 1;
            } else if (std.mem.eql(u8, argument, "--at")) {
                self.at = try std.fmt.parseFloat(f32, value orelse return error.MissingValue);
                i += 1;
            } else if (std.mem.eql(u8, argument, "--software")) {
                self.software = true;
            } else {
                return error.UnknownArgument;
            }
        }
        return self;
    }
};

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;
    const gpa = init.gpa;

    const options = try Options.fromArguments(init, init.arena.allocator());

    var window = Window.open(.{
        .backend = options.backend,
        .title = "Fluxion Shader - one source, either driver",
        .width = options.width,
        .height = options.height,
        .visible = options.capture == null,
    }) catch |err| {
        try out.print("no window for {t}: {t}\n", .{ options.backend, err });
        try out.flush();
        return err;
    };
    defer window.close();

    var device = window.openDevice(gpa, .{ .software = options.software }) catch |err| {
        try out.print("no {t} device on this machine: {t}\n", .{ options.backend, err });
        try out.flush();
        return err;
    };
    defer device.deinit();
    try out.print("{f}\n", .{device.info()});

    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();

    var scene = Scene.init(gpa, &device, &log.writer) catch |err| {
        // Either this library refused the source, or the driver refused what
        // it emitted. Both are worth reading in full.
        if (log.written().len > 0) try out.print("{s}\n", .{log.written()});
        if (device.diagnostics().len > 0) try out.print("{s}\n", .{device.diagnostics()});
        return err;
    };
    defer scene.deinit();
    try out.writeAll("one shader, compiled once, accepted by this driver\n");

    if (options.capture) |path| {
        const target = try device.createTexture(.{
            .width = options.width,
            .height = options.height,
            .usage = .{ .render_target = true },
        });
        try scene.render(&device, .{ .texture = target }, options.width, options.height, options.at);
        const pixels = try device.readTexture(target, gpa);
        defer gpa.free(pixels);
        try image.png.writeFile(gpa, init.io, path, .{
            .width = options.width,
            .height = options.height,
            .pixels = pixels,
            .row_pitch = @as(usize, options.width) * 4,
        }, .{});
        try out.print("wrote {s}, {d} by {d}, at {d:.2} seconds\n", .{ path, options.width, options.height, options.at });
        return out.flush();
    }

    const surface = try window.createSurface(&device);
    try out.writeAll("escape or close the window to quit\n");
    try out.flush();

    const started = Io.Timestamp.now(init.io, .awake).nanoseconds;
    var frames: u32 = 0;
    while (window.pump()) {
        if (window.minimised()) continue;
        if (window.takeResize()) try device.resizeSurface(surface, window.width, window.height);

        const now = Io.Timestamp.now(init.io, .awake).nanoseconds;
        const seconds = @as(f32, @floatFromInt(now - started)) / std.time.ns_per_s;
        try scene.render(&device, .{ .surface = surface }, window.width, window.height, seconds);
        try device.present(surface);

        frames += 1;
        if (options.frames) |limit| if (frames >= limit) break;
    }
    try out.print("{d} frames\n", .{frames});
    try out.flush();
}

// -------------------------------------------------------------------------
// Tests: the same source, given to each driver this machine has
// -------------------------------------------------------------------------

const testing = std.testing;

/// Compile the shader, hand it to a real driver, draw with it, and look at
/// what came out.
fn drawOn(backend: rhi.Backend, gpa: std.mem.Allocator) ![]u8 {
    var fixture = try windowing.TestDevice.open(backend);
    defer fixture.close();
    var device = &fixture.device;

    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();

    var scene = Scene.init(gpa, device, &log.writer) catch |err| {
        std.debug.print("\n{s}\n{s}\n", .{ log.written(), device.diagnostics() });
        return err;
    };
    defer scene.deinit();

    const target = try device.createTexture(.{
        .width = 64,
        .height = 64,
        .usage = .{ .render_target = true },
    });
    try scene.render(device, .{ .texture = target }, 64, 64, 0.0);
    return device.readTexture(target, gpa);
}

fn pixelAt(pixels: []const u8, x: usize, y: usize) [4]u8 {
    return pixels[(y * 64 + x) * 4 ..][0..4].*;
}

fn isBackground(p: [4]u8) bool {
    return p[0] < 30 and p[1] < 30 and p[2] < 40;
}

fn checkFrame(pixels: []const u8) !void {
    // Something was drawn: the middle is not the background.
    try testing.expect(!isBackground(pixelAt(pixels, 32, 32)));
    // The quad does not cover everything, so a corner still is.
    try testing.expect(isBackground(pixelAt(pixels, 1, 62)));
    // And the tint runs down the quad rather than across it: `shade` mixes
    // towards the tint with `corner.y`, and the projection puts y downwards,
    // so the bottom of the quad is bluer than the top. Getting the clip
    // space or the origin wrong turns this around.
    const upper = pixelAt(pixels, 32, 14);
    const lower = pixelAt(pixels, 32, 50);
    try testing.expect(!isBackground(upper) and !isBackground(lower));
    const upper_blueness = @as(i32, upper[2]) - @as(i32, upper[0]);
    const lower_blueness = @as(i32, lower[2]) - @as(i32, lower[0]);
    try testing.expect(lower_blueness > upper_blueness + 20);
}

test "the emitted HLSL is what Direct3D takes" {
    const pixels = try drawOn(.d3d11, testing.allocator);
    defer testing.allocator.free(pixels);
    try checkFrame(pixels);
}

test "the emitted GLSL is what OpenGL takes" {
    const pixels = try drawOn(.gl, testing.allocator);
    defer testing.allocator.free(pixels);
    try checkFrame(pixels);
}

test "and the two drivers drew the same picture" {
    const a = drawOn(.d3d11, testing.allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(a);
    const b = drawOn(.gl, testing.allocator) catch |err| switch (err) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(b);

    // Not pixel-identical: two rasterisers round an edge differently, and
    // two shader compilers are entitled to reassociate a multiply. The
    // picture is the same.
    var agree: usize = 0;
    var total: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 4) {
        total += 1;
        var close = true;
        for (0..3) |channel| {
            if (@abs(@as(i32, a[i + channel]) - @as(i32, b[i + channel])) > 8) close = false;
        }
        if (close) agree += 1;
    }
    try testing.expect(agree * 100 / total >= 97);
}

test "the reflection matches the struct the program uploads" {
    var log: Io.Writer.Allocating = .init(testing.allocator);
    defer log.deinit();
    var module = shader.compile(testing.allocator, source, &log.writer) catch |err| {
        std.debug.print("\n{s}\n", .{log.written()});
        return err;
    };
    defer module.deinit();

    // The whole point of the reflection: this is checked rather than assumed,
    // and a field moved in the shader is caught here rather than drawn wrong.
    const frame = module.block("Frame").?;
    try testing.expectEqual(@as(?u32, @offsetOf(Frame, "projection")), frame.offsetOf("projection"));
    try testing.expectEqual(@as(?u32, @offsetOf(Frame, "rect")), frame.offsetOf("rect"));
    try testing.expectEqual(@as(?u32, @offsetOf(Frame, "tint")), frame.offsetOf("tint"));
    try testing.expectEqual(@as(?u32, @offsetOf(Frame, "time")), frame.offsetOf("time"));
    try testing.expectEqual(@as(u32, @sizeOf(Frame)), frame.size);

    // And the vertex buffer this example fills matches what the shader reads.
    var stride: u32 = 0;
    for (module.attributes) |a| stride += (try vertexFormat(a.ty)).size();
    try testing.expectEqual(@as(u32, @sizeOf([2]f32)), stride);
}
