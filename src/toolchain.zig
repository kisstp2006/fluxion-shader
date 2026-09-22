// SPDX-License-Identifier: BSL-1.0

//! The programs the tests ask, when they are installed.
//!
//! What an emitter writes is only worth as much as what reads it, and the
//! things that read SPIR-V and HLSL are installed with the Vulkan SDK:
//! `spirv-val`, which says whether a module is valid for a Vulkan 1.0
//! environment; `spirv-cross`, a second and independent reader that turns a
//! module back into GLSL, HLSL and MSL; and `dxc`, which compiles HLSL for
//! shader model 6 - the toolchain the Direct3D 12 backend and a DXIL cooker
//! sit on. None of them is a dependency: a machine without them runs the rest
//! of the suite, and the tests that need them report **skipped**, visibly,
//! rather than passing.
//!
//! Each tool is looked for in the same three places, in this order: on
//! `PATH`, in `%VULKAN_SDK%\Bin`, and in the SDK's default install directory.
//! It is found by running it, since running it is the only way to know it can
//! run.
//!
//! Only tests use this file; nothing in the library imports it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;

const shader = @import("root.zig");

pub const Tool = enum {
    spirv_val,
    spirv_cross,
    dxc,

    fn stem(self: Tool) []const u8 {
        return switch (self) {
            .spirv_val => "spirv-val",
            .spirv_cross => "spirv-cross",
            .dxc => "dxc",
        };
    }
};

/// Where the SDK this was written against puts its programs, for a machine on
/// which neither `PATH` nor `VULKAN_SDK` says.
const default_sdk_bin = "C:\\VulkanSDK\\1.4.350.0\\Bin";

const tool_count = @typeInfo(Tool).@"enum".fields.len;

// Found once per run, and kept for the life of the process. The strings are
// not the testing allocator's, which would call them leaks.
var searched: [tool_count]bool = @splat(false);
var located: [tool_count]?[]const u8 = @splat(null);

/// What to run for `tool`, or null if it is nowhere.
pub fn find(tool: Tool) ?[]const u8 {
    const slot = @intFromEnum(tool);
    if (searched[slot]) return located[slot];
    searched[slot] = true;

    const keep = std.heap.page_allocator;
    const exe = if (builtin.os.tag == .windows) ".exe" else "";
    const bare = std.fmt.allocPrint(keep, "{s}{s}", .{ tool.stem(), exe }) catch return null;

    var candidates: [3]?[]const u8 = .{ bare, null, null };
    if (testing.environ.getAlloc(keep, "VULKAN_SDK")) |sdk| {
        candidates[1] = std.fmt.allocPrint(keep, "{s}{c}Bin{c}{s}{s}", .{
            sdk, std.fs.path.sep, std.fs.path.sep, tool.stem(), exe,
        }) catch null;
    } else |_| {}
    if (builtin.os.tag == .windows) {
        candidates[2] = std.fmt.allocPrint(keep, "{s}\\{s}{s}", .{ default_sdk_bin, tool.stem(), exe }) catch null;
    }

    for (candidates) |candidate| {
        const path = candidate orelse continue;
        if (runs(path)) {
            located[slot] = path;
            return path;
        }
    }
    return null;
}

/// Does this start? Every one of the three prints its version and stops.
fn runs(path: []const u8) bool {
    var child = std.process.spawn(testing.io, .{
        .argv = &.{ path, "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return false;
    _ = child.wait(testing.io) catch return false;
    return true;
}

/// One run of one tool.
pub const Job = struct {
    tool: Tool,
    /// Everything after the program's own name.
    args: []const []const u8,
};

pub const Outcome = struct {
    /// It ran and returned zero.
    ok: bool,
    /// What it printed, both streams, in memory of the caller's.
    log: []u8,
};

/// Run every job at once and wait for all of them. A tool takes tens of
/// milliseconds to start and a suite asks dozens of questions, so they are
/// asked together: each writes to a file of its own in `dir`, which is read
/// back afterwards, and nothing waits on a pipe.
pub fn runAll(gpa: std.mem.Allocator, dir: Io.Dir, jobs: []const Job) ![]Outcome {
    const io = testing.io;
    const children = try gpa.alloc(?std.process.Child, jobs.len);
    defer gpa.free(children);
    @memset(children, null);
    const outcomes = try gpa.alloc(Outcome, jobs.len);
    errdefer gpa.free(outcomes);

    var argv_arena: std.heap.ArenaAllocator = .init(gpa);
    defer argv_arena.deinit();

    for (jobs, 0..) |job, index| {
        var name: [32]u8 = undefined;
        const log_name = try std.fmt.bufPrint(&name, "tool-{d}.log", .{index});
        const log_file = try dir.createFile(io, log_name, .{});
        defer log_file.close(io);

        const path = find(job.tool) orelse return error.ToolMissing;
        const argv = try argv_arena.allocator().alloc([]const u8, job.args.len + 1);
        argv[0] = path;
        @memcpy(argv[1..], job.args);
        children[index] = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
            .create_no_window = true,
        });
    }

    for (children, outcomes, 0..) |*child, *outcome, index| {
        const term = try child.*.?.wait(io);
        var name: [32]u8 = undefined;
        const log_name = try std.fmt.bufPrint(&name, "tool-{d}.log", .{index});
        outcome.* = .{
            .ok = switch (term) {
                .exited => |code| code == 0,
                else => false,
            },
            .log = try dir.readFileAlloc(io, log_name, gpa, .limited(1 << 20)),
        };
    }
    return outcomes;
}

fn freeOutcomes(gpa: std.mem.Allocator, outcomes: []Outcome) void {
    for (outcomes) |outcome| gpa.free(outcome.log);
    gpa.free(outcomes);
}

/// Which questions to ask about a shader. Each one is only asked when its
/// tool is installed.
pub const Want = struct {
    spirv_val: bool = true,
    spirv_cross: bool = true,
    dxc: bool = true,

    fn bits(self: Want) u64 {
        return @as(u64, @intFromBool(self.spirv_val)) | @as(u64, @intFromBool(self.spirv_cross)) << 1 |
            @as(u64, @intFromBool(self.dxc)) << 2;
    }
};

/// A source that has been through every tool already, so that a shader the
/// suite compiles a dozen times is asked about once.
var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;

/// Hold one shader to everything that can be asked about it.
///
/// Structurally, always: the header, the lengths, the ids, the sections and
/// the blocks of both SPIR-V modules, which needs no tool. And then, for each
/// tool that is installed: `spirv-val` on both stages under
/// `--target-env vulkan1.0`; `spirv-cross` turning both back into HLSL, into Vulkan GLSL and into MSL; and
/// `dxc` compiling the HLSL of both stages as shader model 6.0 and as 5.1,
/// entry point `main`. Anything a tool rejects fails with what it said.
///
/// `hlsl_valid` is false for a shader that is fine in the language and that
/// Direct3D cannot say at all - the corpus lists why.
pub fn checkShader(
    gpa: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    hlsl_valid: bool,
    want: Want,
) !void {
    const key = std.hash.Wyhash.hash(want.bits() << 1 | @intFromBool(hlsl_valid), source);
    const keep = std.heap.page_allocator;
    if (seen.contains(key)) return;
    try seen.put(keep, key, {});

    var log: Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var module = shader.compileWith(gpa, source, &log.writer, .{
        .targets = .of(&.{ .hlsl_50, .spirv_vulkan }),
    }) catch |err| {
        std.debug.print("\n`{s}` did not compile to SPIR-V: {s}\n{s}\n", .{ name, @errorName(err), log.written() });
        return err;
    };
    defer module.deinit();
    const words = module.output(.spirv_vulkan).words;

    // The structure, which needs no tool.
    inline for (.{ .{ "vertex", words.vertex }, .{ "fragment", words.fragment } }) |stage| {
        var problems: Io.Writer.Allocating = .init(gpa);
        defer problems.deinit();
        shader.spirv.check.verify(gpa, stage[1], &problems.writer) catch |err| {
            std.debug.print("\nthe {s} module of `{s}` is malformed:\n{s}\n", .{ stage[0], name, problems.written() });
            return err;
        };
    }

    const run_val = want.spirv_val and find(.spirv_val) != null;
    const run_cross = want.spirv_cross and find(.spirv_cross) != null;
    const run_dxc = want.dxc and hlsl_valid and find(.dxc) != null;
    if (!run_val and !run_cross and !run_dxc) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(gpa);
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Where each file is, as the tools are told it.
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);

    const stages = [_]struct { label: []const u8, words: []const u32, hlsl: []const u8, sm6: []const u8, sm51: []const u8 }{
        .{ .label = "vertex", .words = words.vertex, .hlsl = module.hlsl.vertex, .sm6 = "vs_6_0", .sm51 = "vs_5_1" },
        .{ .label = "fragment", .words = words.fragment, .hlsl = module.hlsl.fragment, .sm6 = "ps_6_0", .sm51 = "ps_5_1" },
    };
    for (stages) |stage| {
        const spv_name = try std.fmt.allocPrint(a, "{s}.spv", .{stage.label});
        try tmp.dir.writeFile(io, .{ .sub_path = spv_name, .data = std.mem.sliceAsBytes(stage.words) });
        const spv_path = try std.fs.path.join(a, &.{ root, spv_name });

        if (run_val) {
            try jobs.append(gpa, .{ .tool = .spirv_val, .args = try dupeArgs(a, &.{ "--target-env", "vulkan1.0", spv_path }) });
            try labels.append(gpa, try std.fmt.allocPrint(a, "spirv-val on the {s} module", .{stage.label}));
        }
        if (run_cross) {
            // Three independent writers of three languages: if they can all
            // read it, it is a module and not merely something `spirv-val`
            // let through.
            const modes = [_][]const []const u8{
                &.{ "--hlsl", "--shader-model", "50" },
                &.{"--vulkan-semantics"},
                &.{"--msl"},
            };
            for (modes) |mode| {
                const args = try a.alloc([]const u8, mode.len + 1);
                args[0] = spv_path;
                @memcpy(args[1..], mode);
                try jobs.append(gpa, .{ .tool = .spirv_cross, .args = args });
                try labels.append(gpa, try std.fmt.allocPrint(a, "spirv-cross {s} on the {s} module", .{ mode[0], stage.label }));
            }
        }
        if (run_dxc) {
            const hlsl_name = try std.fmt.allocPrint(a, "{s}.hlsl", .{stage.label});
            try tmp.dir.writeFile(io, .{ .sub_path = hlsl_name, .data = stage.hlsl });
            const hlsl_path = try std.fs.path.join(a, &.{ root, hlsl_name });
            for ([_][]const u8{ stage.sm6, stage.sm51 }) |profile| {
                const out_name = try std.fmt.allocPrint(a, "{s}-{s}.bin", .{ stage.label, profile });
                const out_path = try std.fs.path.join(a, &.{ root, out_name });
                try jobs.append(gpa, .{ .tool = .dxc, .args = try dupeArgs(a, &.{ "-T", profile, "-E", "main", hlsl_path, "-Fo", out_path }) });
                try labels.append(gpa, try std.fmt.allocPrint(a, "dxc -T {s} on the {s} HLSL", .{ profile, stage.label }));
            }
        }
    }

    const outcomes = try runAll(gpa, tmp.dir, jobs.items);
    defer freeOutcomes(gpa, outcomes);
    var failed = false;
    for (outcomes, labels.items) |outcome, label| {
        if (outcome.ok) continue;
        failed = true;
        std.debug.print("\n`{s}`: {s} said no:\n{s}\n", .{ name, label, outcome.log });
    }
    if (failed) return error.ToolRejected;
}

fn dupeArgs(a: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    return a.dupe([]const u8, args);
}

/// What `dxc` prints for one HLSL source when it is not asked to write a
/// file: the disassembly, which begins with the layout of every constant
/// buffer it kept - each member and the byte offset Direct3D put it at.
/// Owned by the caller. Null-free: it fails with `error.ToolRejected` when the
/// source does not compile.
pub fn dxcListing(gpa: std.mem.Allocator, hlsl: []const u8, profile: []const u8) ![]u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "listing.hlsl", .data = hlsl });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const path = try std.fs.path.join(arena.allocator(), &.{
        try tmp.dir.realPathFileAlloc(io, ".", arena.allocator()), "listing.hlsl",
    });

    const outcomes = try runAll(gpa, tmp.dir, &.{.{
        .tool = .dxc,
        .args = &.{ "-T", profile, "-E", "main", path },
    }});
    defer gpa.free(outcomes);
    errdefer gpa.free(outcomes[0].log);
    if (!outcomes[0].ok) {
        std.debug.print("\ndxc -T {s} said no:\n{s}\n", .{ profile, outcomes[0].log });
        return error.ToolRejected;
    }
    return outcomes[0].log;
}
