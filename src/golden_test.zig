// SPDX-License-Identifier: BSL-1.0

//! The text the emitters wrote before the builtin table existed, as hashes.
//!
//! Moving every builtin's spelling out of a `switch` and into a row has to
//! change nothing about what comes out, and "the existing tests still pass"
//! only proves that for what they happen to look at. So this holds the whole
//! of it: for every shader in `corpus.zig`, a hash of each of the six sources
//! - two stages in each of GLSL 3.30, GLSL ES 3.00 and HLSL 5.0 - taken from
//! the emitters as they were before, and compared with what they write now.
//!
//! If one of these fails on purpose - an emitter really is meant to write
//! something different - regenerate the hashes; do not loosen the test.

const std = @import("std");
const testing = std.testing;

const shader = @import("root.zig");
const corpus = @import("corpus.zig");

const Golden = struct {
    name: []const u8,
    /// GLSL vertex and fragment, ES vertex and fragment, HLSL vertex and
    /// fragment; Wyhash with seed zero over the source text.
    hashes: [6]u64,
};

const golden = [_]Golden{
    .{ .name = "sprites", .hashes = .{ 0xd4e03ffe421adc5e, 0xefa948e96e4150ae, 0x8a6089921a74d52e, 0xae8b9208d8e36de6, 0x4f44adee88a3bfb3, 0xf8f1438e91268ca7 } },
    .{ .name = "everything", .hashes = .{ 0x606f5c49ccc985d0, 0xdefe1bd3a15b2086, 0xd6942e9c2e5a576e, 0x27d3419a69dfea01, 0x9eae933a95e56d15, 0xe1bb4e97a937eece } },
    .{ .name = "demo", .hashes = .{ 0x9ab1563243e888e4, 0x700ea4897cf6eb30, 0x79ce2f4ec181f73d, 0x8ef708fb06a827d1, 0x77d5e3cef6269014, 0xccf98741c288951e } },
    .{ .name = "quad", .hashes = .{ 0x831896dddba449f8, 0x70c97a23eed888c3, 0x62ba87e4293f640, 0xe04e2455b3c1a39f, 0x17b347fb28132e12, 0x530aa6e021267347 } },
    .{ .name = "kitchen sink", .hashes = .{ 0xfa98ab061642773, 0x501dd15d98929718, 0x328d09b9b0966d, 0x1f88e4d9722c8668, 0x9bfb2a09c213cb72, 0x5d669120ce304da0 } },
    .{ .name = "many varyings", .hashes = .{ 0xfb9aa6a88907766d, 0xd46da5e3bb7bcb2b, 0x975bf3616c06a68d, 0x68f9f328cbedf6c3, 0xa2a8406aa7167442, 0xd9285d7f78f2e610 } },
    .{ .name = "loops and discard", .hashes = .{ 0xe64520f00eefbcd4, 0xdc73ae29eaa0f94d, 0x9b38fe2952325c03, 0x478de792ff0a7822, 0x2ac1975f5607170e, 0xbc8742f274729bac } },
    .{ .name = "matrix block", .hashes = .{ 0x122831074d707e7f, 0x486509ff24f55937, 0x2b6b35386fcd2fb0, 0xd4a8108465094eb0, 0x75824c1b25cfa885, 0x530dc857dffedab1 } },
    .{ .name = "index builtins", .hashes = .{ 0xce918fd5ca8fd160, 0xdfb2d4651d4901be, 0xc87569ec4c5f6566, 0x427716d8853c291f, 0x5b6d38e5acadf932, 0x75d3bb985c5600ed } },
    .{ .name = "promotions", .hashes = .{ 0xf29fb240ab884eb3, 0x1e41eeca1454edf, 0x6f1c998c4cbfde55, 0xb1d0cfbbfcd656c7, 0xce5acd071e148912, 0xd0d9f765b2654ad1 } },
    .{ .name = "swizzle assignment", .hashes = .{ 0x1cf15b463263a35f, 0x4b76c7879a38bcf1, 0x1d508b36b90cd340, 0x3b16b32a0adc0db2, 0x1c9454a197642e6f, 0x86379d418dce099c } },
    .{ .name = "selects and constants", .hashes = .{ 0x6ca50683d51bb854, 0x2d240828a4863c7, 0xcf7e791ff4c547b7, 0xa11b725d13d58a3, 0xb68153495cde5b9b, 0xb20ad94d982c4bb0 } },
};

test "the text emitters write what they wrote before the builtin table" {
    try testing.expectEqual(corpus.pinned, golden.len);
    var changed = false;
    for (corpus.all[0..corpus.pinned], golden) |entry, expected| {
        try testing.expectEqualStrings(entry.name, expected.name);

        var log: std.Io.Writer.Allocating = .init(testing.allocator);
        defer log.deinit();
        var module = shader.compile(testing.allocator, entry.source, &log.writer) catch |err| {
            std.debug.print("\n{s}: {s}\n", .{ entry.name, log.written() });
            return err;
        };
        defer module.deinit();

        const texts = [_][:0]const u8{
            module.glsl.vertex,    module.glsl.fragment,
            module.glsl_es.vertex, module.glsl_es.fragment,
            module.hlsl.vertex,    module.hlsl.fragment,
        };
        for (texts, expected.hashes, 0..) |text, hash, which| {
            const actual = std.hash.Wyhash.hash(0, text);
            if (actual != hash) {
                std.debug.print("\nthe text of `{s}` changed (source {d} of 6, hash 0x{x}):\n{s}\n", .{ entry.name, which, actual, text });
                changed = true;
            }
        }
    }
    if (changed) return error.TestUnexpectedResult;
}
