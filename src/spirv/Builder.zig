// SPDX-License-Identifier: BSL-1.0

//! The mechanical half of writing SPIR-V: ids, sections, and things that are
//! only ever written once.
//!
//! A module is a header and then instructions in a fixed order of kinds -
//! capabilities, the extended-instruction import, the memory model, entry
//! points, execution modes, debug names, decorations, then every type,
//! constant and module-scope variable, then the functions. The emitter
//! produces them in whatever order is convenient, and this keeps one buffer
//! per kind so that `finish` can lay them out in the order the specification
//! wants, and gives every id from one counter so that the header's `Bound` is
//! simply the next one.
//!
//! **Types and constants are interned.** `intern` takes an instruction and
//! returns the id it already has if an identical one was written, so a
//! `float` is one `OpTypeFloat` however many places ask for one, and asking
//! for a type that needs another asks for that first - which is also what
//! puts every definition before its use, without anybody sorting them.
//!
//! Everything here allocates from one arena owned by the builder and freed by
//! `deinit`; `finish` returns the module in memory the caller chose.

const std = @import("std");
const Allocator = std.mem.Allocator;

const op = @import("op.zig");

const Builder = @This();

pub const Words = std.ArrayList(u32);

arena: std.heap.ArenaAllocator,
/// The next id to hand out. Ids start at one; zero is not an id.
next_id: u32 = 1,

/// One buffer per part of a module that has its own place in the order.
entry_points: Words = .empty,
execution_modes: Words = .empty,
debug: Words = .empty,
annotations: Words = .empty,
/// Types, constants and module-scope variables, in the order they were first
/// wanted - which is an order in which every one comes after what it uses.
globals: Words = .empty,
functions: Words = .empty,

/// The id of `GLSL.std.450`, or zero until something is lowered to it. Imported
/// only when used, so a shader with no builtin in it has no import.
std450: u32 = 0,

interned: std.HashMapUnmanaged([]const u32, u32, KeyContext, 80) = .empty,

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: []const u32) u64 {
        return std.hash.Wyhash.hash(0x5350_4952_56, std.mem.sliceAsBytes(key));
    }

    pub fn eql(_: KeyContext, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

pub fn init(gpa: Allocator) Builder {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(self: *Builder) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn allocator(self: *Builder) Allocator {
    return self.arena.allocator();
}

/// A new id.
pub fn newId(self: *Builder) u32 {
    const id = self.next_id;
    self.next_id += 1;
    return id;
}

/// Append one instruction to `section`: the opcode and its length in the
/// first word, then `operands` exactly as they are.
pub fn emit(self: *Builder, section: *Words, opcode: op.Op, operands: []const u32) Allocator.Error!void {
    const a = self.allocator();
    try section.ensureUnusedCapacity(a, operands.len + 1);
    section.appendAssumeCapacity(@as(u32, @intCast(operands.len + 1)) << 16 | @intFromEnum(opcode));
    section.appendSliceAssumeCapacity(operands);
}

/// An instruction that has a result type and a result id: the result gets a
/// fresh id, which is returned. `operands` are what follows the two.
pub fn emitResult(
    self: *Builder,
    section: *Words,
    opcode: op.Op,
    result_type: u32,
    operands: []const u32,
) Allocator.Error!u32 {
    const id = self.newId();
    const a = self.allocator();
    try section.ensureUnusedCapacity(a, operands.len + 3);
    section.appendAssumeCapacity(@as(u32, @intCast(operands.len + 3)) << 16 | @intFromEnum(opcode));
    section.appendAssumeCapacity(result_type);
    section.appendAssumeCapacity(id);
    section.appendSliceAssumeCapacity(operands);
    return id;
}

/// An instruction that has a result id and no result type, which is what
/// every type declaration and `OpLabel` is.
pub fn emitDeclaration(
    self: *Builder,
    section: *Words,
    opcode: op.Op,
    operands: []const u32,
) Allocator.Error!u32 {
    const id = self.newId();
    const a = self.allocator();
    try section.ensureUnusedCapacity(a, operands.len + 2);
    section.appendAssumeCapacity(@as(u32, @intCast(operands.len + 2)) << 16 | @intFromEnum(opcode));
    section.appendAssumeCapacity(id);
    section.appendSliceAssumeCapacity(operands);
    return id;
}

/// The id of this type or constant, written the first time it is asked for.
///
/// `operands` is what follows the result id - and, for a constant, what
/// follows the result type, which `op.info` says is the first of them.
pub fn intern(self: *Builder, opcode: op.Op, operands: []const u32) Allocator.Error!u32 {
    const a = self.allocator();
    const key = try a.alloc(u32, operands.len + 1);
    key[0] = @intFromEnum(opcode);
    @memcpy(key[1..], operands);

    const found = try self.interned.getOrPut(a, key);
    if (found.found_existing) {
        a.free(key);
        return found.value_ptr.*;
    }

    // What the row says is the first operand is the result type, and the
    // result id goes between it and the rest.
    const id = self.newId();
    const has_type = op.info(opcode).has_type;
    const head: usize = if (has_type) 1 else 0;
    try self.globals.ensureUnusedCapacity(a, operands.len + 2);
    self.globals.appendAssumeCapacity(@as(u32, @intCast(operands.len + 2)) << 16 | @intFromEnum(opcode));
    self.globals.appendSliceAssumeCapacity(operands[0..head]);
    self.globals.appendAssumeCapacity(id);
    self.globals.appendSliceAssumeCapacity(operands[head..]);
    found.value_ptr.* = id;
    return id;
}

/// The words that spell `text`: its bytes, a terminator, and zeros up to a
/// word.
pub fn appendString(self: *Builder, list: *Words, text: []const u8) Allocator.Error!void {
    const a = self.allocator();
    const count = op.stringWords(text.len);
    try list.ensureUnusedCapacity(a, count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var word: u32 = 0;
        for (0..4) |byte| {
            const at = i * 4 + byte;
            if (at < text.len) word |= @as(u32, text[at]) << @intCast(byte * 8);
        }
        list.appendAssumeCapacity(word);
    }
}

/// `OpName` for an id, when names are wanted.
pub fn name(self: *Builder, id: u32, text: []const u8) Allocator.Error!void {
    var words: Words = .empty;
    const a = self.allocator();
    try words.append(a, id);
    try self.appendString(&words, text);
    try self.emit(&self.debug, .name, words.items);
}

pub fn memberName(self: *Builder, struct_id: u32, member: u32, text: []const u8) Allocator.Error!void {
    var words: Words = .empty;
    const a = self.allocator();
    try words.append(a, struct_id);
    try words.append(a, member);
    try self.appendString(&words, text);
    try self.emit(&self.debug, .member_name, words.items);
}

/// `OpDecorate` with a literal argument, or none.
pub fn decorate(self: *Builder, target: u32, decoration: op.Decoration, args: []const u32) Allocator.Error!void {
    var words: [8]u32 = undefined;
    words[0] = target;
    words[1] = @intFromEnum(decoration);
    @memcpy(words[2 .. 2 + args.len], args);
    try self.emit(&self.annotations, .decorate, words[0 .. 2 + args.len]);
}

pub fn decorateMember(
    self: *Builder,
    struct_id: u32,
    member: u32,
    decoration: op.Decoration,
    args: []const u32,
) Allocator.Error!void {
    var words: [8]u32 = undefined;
    words[0] = struct_id;
    words[1] = member;
    words[2] = @intFromEnum(decoration);
    @memcpy(words[3 .. 3 + args.len], args);
    try self.emit(&self.annotations, .member_decorate, words[0 .. 3 + args.len]);
}

/// The id of the extended instruction set, imported on first use.
pub fn glslStd450(self: *Builder) u32 {
    if (self.std450 == 0) self.std450 = self.newId();
    return self.std450;
}

/// Lay the module out in the order the specification wants and return it,
/// allocated from `out`. The header's `Bound` is one past the last id
/// handed out.
pub fn finish(self: *Builder, out: Allocator) Allocator.Error![]u32 {
    // The parts that are the same in every module are written here rather
    // than kept as sections.
    var head: Words = .empty;
    const a = self.allocator();
    try self.emit(&head, .capability, &.{@intFromEnum(op.Capability.shader)});
    if (self.std450 != 0) {
        var import: Words = .empty;
        try import.append(a, self.std450);
        try self.appendString(&import, op.std450_name);
        try self.emit(&head, .ext_inst_import, import.items);
    }
    try self.emit(&head, .memory_model, &.{
        @intFromEnum(op.AddressingModel.logical),
        @intFromEnum(op.MemoryModel.glsl450),
    });

    const sections = [_][]const u32{
        head.items,
        self.entry_points.items,
        self.execution_modes.items,
        self.debug.items,
        self.annotations.items,
        self.globals.items,
        self.functions.items,
    };
    var total: usize = 5;
    for (sections) |section| total += section.len;

    const words = try out.alloc(u32, total);
    words[0] = op.magic;
    words[1] = op.version_1_0;
    // The generator: zero is "unknown", which is honest. A number is
    // registered with Khronos, and this library has not asked for one.
    words[2] = 0;
    words[3] = self.next_id;
    words[4] = 0;
    var at: usize = 5;
    for (sections) |section| {
        @memcpy(words[at .. at + section.len], section);
        at += section.len;
    }
    return words;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a type asked for twice is written once" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    const float = try b.intern(.type_float, &.{32});
    const again = try b.intern(.type_float, &.{32});
    const wide = try b.intern(.type_float, &.{64});
    try testing.expectEqual(float, again);
    try testing.expect(float != wide);

    // A constant is its type and its value, and the type comes first in the
    // operands but the result id goes in front of the value.
    const one = try b.intern(.constant, &.{ float, @as(u32, @bitCast(@as(f32, 1.0))) });
    try testing.expectEqual(one, try b.intern(.constant, &.{ float, @as(u32, @bitCast(@as(f32, 1.0))) }));
    const words = b.globals.items;
    // OpTypeFloat %1 32; OpTypeFloat %2 64; OpConstant %1 %3 1.0
    try testing.expectEqualSlices(u32, &.{
        3 << 16 | 22,                      float, 32,
        3 << 16 | 22,                      wide,  64,
        4 << 16 | 43,                      float, one,
        @as(u32, @bitCast(@as(f32, 1.0))),
    }, words);
}

test "strings are packed four bytes to a word, with a terminator" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();

    var words: Words = .empty;
    try b.appendString(&words, "main");
    // Four bytes and a terminator is two words.
    try testing.expectEqualSlices(u32, &.{ 0x6e69616d, 0 }, words.items);

    words.clearRetainingCapacity();
    try b.appendString(&words, "abc");
    try testing.expectEqualSlices(u32, &.{0x00636261}, words.items);
}

test "a module has the header, and a bound past the last id" {
    var b: Builder = .init(testing.allocator);
    defer b.deinit();
    _ = try b.intern(.type_void, &.{});

    const words = try b.finish(testing.allocator);
    defer testing.allocator.free(words);
    try testing.expectEqual(op.magic, words[0]);
    try testing.expectEqual(op.version_1_0, words[1]);
    try testing.expectEqual(@as(u32, 2), words[3]);
    // OpCapability Shader, OpMemoryModel Logical GLSL450, OpTypeVoid.
    try testing.expectEqual(@as(u32, 2 << 16 | 17), words[5]);
}
