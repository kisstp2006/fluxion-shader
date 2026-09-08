// SPDX-License-Identifier: BSL-1.0

//! Where a complaint goes, and what it looks like when it gets there.
//!
//! One shape for everything the compiler has to say, because a program that
//! prints `module.log()` should not have to tell a parse error from a type
//! error to lay it out:
//!
//! ```
//! 7:24: cannot assign a vec3 to `position`, which is a vec4
//!     position = vec3(world, 0.0);
//!                ^
//! ```
//!
//! The line and the column come from `fluxion-text`'s `Parser.locationAt`,
//! which scans from the start of the file - once per message, and never in
//! the loop that does the work.

const std = @import("std");
const text = @import("fluxion_text");

const Diagnostics = @This();

source: []const u8,
log: *std.Io.Writer,
/// How many messages have been written. Zero at the end is the only proof
/// that nothing went wrong.
count: usize = 0,

pub fn init(source: []const u8, log: *std.Io.Writer) Diagnostics {
    return .{ .source = source, .log = log };
}

/// One message, at the byte the trouble started on, with the line under it
/// and a caret at the column.
pub fn report(
    self: *Diagnostics,
    offset: u32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.count += 1;
    // A writer that has run out of room has nothing more to say, and losing a
    // diagnostic is not a reason to fail a compile that was already failing.
    self.write(offset, fmt, args) catch {};
}

fn write(self: *Diagnostics, offset: u32, comptime fmt: []const u8, args: anytype) !void {
    var parser: text.Parser = .init(self.source);
    const at = parser.locationAt(offset);
    if (self.count > 1) try self.log.writeByte('\n');
    try self.log.print("{f}: ", .{at});
    try self.log.print(fmt, args);
    try self.log.writeByte('\n');

    // The line itself, and a caret under the column. Tabs go through as
    // spaces so the caret lands where the reader's eye does.
    const line = lineAt(self.source, offset);
    try self.log.writeAll("    ");
    for (line.bytes) |c| try self.log.writeByte(if (c == '\t') ' ' else c);
    try self.log.writeAll("\n    ");
    var column: usize = 1;
    while (column < at.column) : (column += 1) try self.log.writeByte(' ');
    try self.log.writeByte('^');
    try self.log.writeByte('\n');
}

/// The line `offset` falls on, without its terminator.
fn lineAt(source: []const u8, offset: u32) struct { bytes: []const u8 } {
    const at = @min(offset, source.len);
    const start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |nl| nl + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
    return .{ .bytes = std.mem.trimEnd(u8, source[start..end], "\r") };
}

/// Did anything go wrong?
pub fn failed(self: *const Diagnostics) bool {
    return self.count > 0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a message points at the line and the column it happened on" {
    const source =
        \\vertex {
        \\    position = nonsense;
        \\}
    ;
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var diagnostics: Diagnostics = .init(source, &writer);

    // The `n` of `nonsense`, which is on line 2.
    const offset: u32 = @intCast(std.mem.indexOf(u8, source, "nonsense").?);
    diagnostics.report(offset, "`{s}` is not anything this shader declared", .{"nonsense"});

    try testing.expect(diagnostics.failed());
    try testing.expectEqualStrings(
        \\2:16: `nonsense` is not anything this shader declared
        \\        position = nonsense;
        \\                   ^
        \\
    , writer.buffered());
}

test "a second message is separated from the first" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var diagnostics: Diagnostics = .init("a\nb\n", &writer);
    diagnostics.report(0, "first", .{});
    diagnostics.report(2, "second", .{});
    try testing.expectEqual(@as(usize, 2), diagnostics.count);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "1:1: first") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "2:1: second") != null);
}

test "nothing said is nothing wrong" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var diagnostics: Diagnostics = .init("", &writer);
    try testing.expect(!diagnostics.failed());
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "a writer with no room left loses the message rather than the compile" {
    // Eight bytes is not enough for any message, and reporting has to carry
    // on regardless: the compile is failing either way, and a lost line is
    // better than a crash on the way to saying so.
    var buffer: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var diagnostics: Diagnostics = .init("hello", &writer);
    diagnostics.report(0, "a message far longer than the room for it", .{});
    try testing.expect(diagnostics.failed());
}
