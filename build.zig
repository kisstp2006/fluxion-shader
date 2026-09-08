// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fluxion-text: the cursor the lexer reads with, and the line and column
    // a diagnostic is printed at.
    const text = b.dependency("fluxion_text", .{ .target = target, .optimize = optimize });

    // The importable module. Consumers do:
    //   const shader = @import("fluxion_shader");
    const mod = b.addModule("fluxion_shader", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_text", .module = text.module("fluxion_text") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-shader-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-shader",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // The library emits text and stops. Whether that text is a shader a
    // driver will take is a question only a driver can answer, so the
    // examples ask two of them - through `fluxion-rhi`, which is what a
    // program uses this with. All three dependencies are lazy: they are
    // fetched when the examples are wanted and never for a consumer.
    const examples_wanted = b.option(
        bool,
        "examples",
        "Build the examples and their tests (pulls fluxion-rhi, fluxion-platform and fluxion-image)",
    ) orelse (b.pkg_hash.len == 0);
    if (!examples_wanted) return;

    const rhi_dep = b.lazyDependency("fluxion_rhi", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const platform_dep = b.lazyDependency("fluxion_platform", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const image_dep = b.lazyDependency("fluxion_image", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    // A window with or without a GL context in it, and the device on it.
    const window_mod = b.createModule(.{
        .root_source_file = b.path("examples/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_rhi", .module = rhi_dep.module("fluxion_rhi") },
            .{ .name = "fluxion_platform", .module = platform_dep.module("fluxion_platform") },
        },
    });

    // A window needs a windowing system, which a cross-compiled build has no
    // way to reach. On a host with no display the tests skip themselves.
    const host = target.result.os.tag == @import("builtin").os.tag;

    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
        needs_window: bool = false,
        chained_args: []const []const u8 = &.{},
    }{
        .{ .name = "demo", .step = "example", .about = "One shader in, two languages out" },
        .{
            .name = "quad",
            .step = "example-quad",
            .about = "The compiled shader, drawn on whichever backend is asked for",
            .needs_window = true,
            .chained_args = &.{ "--capture", "zig-out/quad.png" },
        },
    };

    const all_examples = b.step("examples", "Build and run every example in turn");
    var previous: ?*std.Build.Step = null;

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_shader", .module = mod },
                .{ .name = "fluxion_rhi", .module = rhi_dep.module("fluxion_rhi") },
                .{ .name = "fluxion_image", .module = image_dep.module("fluxion_image") },
                .{ .name = "window", .module = window_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-shader-{s}", .{example.name}),
            .root_module = example_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        // Anything after `--` goes through: `zig build example-quad -- --backend gl`.
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);

        if (example.needs_window and !host) continue;

        const in_order = b.addRunArtifact(exe);
        in_order.step.dependOn(b.getInstallStep());
        in_order.addArgs(example.chained_args);
        if (previous) |earlier| in_order.step.dependOn(earlier);
        previous = &in_order.step;
        all_examples.dependOn(&in_order.step);

        // The one that draws carries the test that matters: the emitted
        // source, given to a real compiler on each backend.
        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-shader-{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
