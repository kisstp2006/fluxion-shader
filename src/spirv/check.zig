// SPDX-License-Identifier: BSL-1.0

//! What can be said about a SPIR-V module without a validator.
//!
//! `spirv-val` is the oracle for whether a module means anything, and it is
//! not always installed. This is the part of that which needs nothing but the
//! words: the header, that every instruction's length lands exactly on the
//! end of the stream, that every id is under `Bound` and defined once and
//! never used undefined, that the sections come in the order the
//! specification lays a module out, and that the blocks of every function are
//! the shape a function's blocks are - a label, then instructions, then
//! exactly one terminator, with a merge instruction only ever second to last.
//!
//! It reads the instruction table in `op.zig`, so it can only look at what the
//! emitter can write; an opcode it does not know is a failure and not a skip.
//!
//! Beside `verify` is `uniformBlocks`, which reads the layout decorations
//! back out of a module: what a test needs to hold them to what `sema`
//! computed.

const std = @import("std");
const Allocator = std.mem.Allocator;

const op = @import("op.zig");

pub const Error = error{
    /// The module is not well formed. The log says how.
    Invalid,
} || Allocator.Error;

pub const Instruction = struct {
    op: op.Op,
    /// Every word of it, the first included.
    words: []const u32,
};

/// The instructions of a module after its header, one at a time.
pub const Iterator = struct {
    words: []const u32,
    at: usize = 5,

    pub fn init(words: []const u32) Iterator {
        return .{ .words = words };
    }

    /// The next instruction, or null at the end of the stream. A length that
    /// does not fit is `error.Invalid`, and an opcode this library does not
    /// write is too.
    pub fn next(self: *Iterator) error{Invalid}!?Instruction {
        if (self.at >= self.words.len) return null;
        const first = self.words[self.at];
        const count = first >> 16;
        if (count == 0 or self.at + count > self.words.len) return error.Invalid;
        const opcode = std.enums.fromInt(op.Op, first & 0xffff) orelse return error.Invalid;
        const instruction: Instruction = .{ .op = opcode, .words = self.words[self.at .. self.at + count] };
        self.at += count;
        return instruction;
    }
};

/// Check a module. Everything wrong with it that can be told without running
/// it is written to `log`, and `error.Invalid` says there was something.
pub fn verify(gpa: Allocator, words: []const u32, log: *std.Io.Writer) Error!void {
    var problems: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (words.len < 5) {
        log.print("a module is at least a five-word header, and this is {d} words\n", .{words.len}) catch {};
        return error.Invalid;
    }
    if (words[0] != op.magic) {
        log.print("the first word is 0x{x}, not the magic number 0x{x}\n", .{ words[0], op.magic }) catch {};
        problems += 1;
    }
    if (words[1] != op.version_1_0) {
        log.print("the version is 0x{x}; this library writes SPIR-V 1.0, 0x{x}\n", .{ words[1], op.version_1_0 }) catch {};
        problems += 1;
    }
    if (words[4] != 0) {
        log.print("the schema word is {d}, and the only one there is is 0\n", .{words[4]}) catch {};
        problems += 1;
    }
    const bound = words[3];
    if (bound == 0 or bound > 1 << 24) {
        log.print("the bound {d} is not a bound\n", .{bound}) catch {};
        return error.Invalid;
    }

    const defined = try a.alloc(bool, bound);
    const used = try a.alloc(bool, bound);
    @memset(defined, false);
    @memset(used, false);
    var highest: u32 = 0;

    var iterator: Iterator = .init(words);
    var index: usize = 0;
    var section: op.Section = .capabilities;
    var in_function = false;
    // Where in a function's blocks the last instruction left things.
    var in_block = false;
    var first_block = false;
    var variables_allowed = false;
    var previous: ?op.Op = null;

    while (true) : (index += 1) {
        const instruction = iterator.next() catch {
            log.print("instruction {d}: its length or its opcode is not one this library writes\n", .{index}) catch {};
            return error.Invalid;
        } orelse break;

        const info = op.info(instruction.op);
        const w = instruction.words;
        var at: usize = 1;

        // The sections come in the order the specification says. A variable
        // is in the types section at module scope and in a function inside
        // one, and a function is the last section there is.
        const this_section: op.Section = if (in_function) .functions else op.section(instruction.op);
        if (@intFromEnum(this_section) < @intFromEnum(section)) {
            log.print("instruction {d} ({t}): a {t} instruction after {t} ones\n", .{
                index, instruction.op, this_section, section,
            }) catch {};
            problems += 1;
        }
        section = @enumFromInt(@max(@intFromEnum(section), @intFromEnum(this_section)));

        if (info.has_type) {
            if (!markUsed(w[at], bound, used, log, index)) problems += 1;
            at += 1;
        }
        if (info.has_result) {
            const id = w[at];
            if (id == 0 or id >= bound) {
                log.print("instruction {d} ({t}): defines id {d}, which is not under the bound {d}\n", .{ index, instruction.op, id, bound }) catch {};
                problems += 1;
            } else if (defined[id]) {
                log.print("instruction {d} ({t}): defines id {d} a second time\n", .{ index, instruction.op, id }) catch {};
                problems += 1;
            } else {
                defined[id] = true;
                highest = @max(highest, id);
            }
            at += 1;
        }

        for (info.operands, 0..) |kind, operand_index| {
            switch (kind) {
                .id => {
                    if (at >= w.len) {
                        log.print("instruction {d} ({t}): operand {d} is missing\n", .{ index, instruction.op, operand_index }) catch {};
                        problems += 1;
                        break;
                    }
                    if (!markUsed(w[at], bound, used, log, index)) problems += 1;
                    at += 1;
                },
                .lit => {
                    if (at >= w.len) {
                        log.print("instruction {d} ({t}): operand {d} is missing\n", .{ index, instruction.op, operand_index }) catch {};
                        problems += 1;
                        break;
                    }
                    at += 1;
                },
                .str => {
                    // Words up to and including the one with a zero byte.
                    var terminated = false;
                    while (at < w.len and !terminated) : (at += 1) {
                        for (0..4) |byte| {
                            if ((w[at] >> @intCast(byte * 8)) & 0xff == 0) terminated = true;
                        }
                    }
                    if (!terminated) {
                        log.print("instruction {d} ({t}): a string that never ends\n", .{ index, instruction.op }) catch {};
                        problems += 1;
                    }
                },
                .ids => {
                    while (at < w.len) : (at += 1) {
                        if (!markUsed(w[at], bound, used, log, index)) problems += 1;
                    }
                },
                .lits => at = w.len,
            }
        }
        if (at != w.len) {
            log.print("instruction {d} ({t}): {d} words long, and what it says takes {d}\n", .{ index, instruction.op, w.len, at }) catch {};
            problems += 1;
        }

        // The blocks of a function.
        switch (instruction.op) {
            .function => {
                if (in_function) {
                    log.print("instruction {d}: a function inside a function\n", .{index}) catch {};
                    problems += 1;
                }
                in_function = true;
                in_block = false;
                first_block = true;
            },
            .function_end => {
                if (in_block) {
                    log.print("instruction {d}: the function ends inside a block that has no terminator\n", .{index}) catch {};
                    problems += 1;
                }
                in_function = false;
            },
            .label => {
                if (in_block) {
                    log.print("instruction {d}: a block starts before the last one ended\n", .{index}) catch {};
                    problems += 1;
                }
                in_block = true;
                variables_allowed = first_block;
                first_block = false;
            },
            else => if (in_function) {
                switch (instruction.op) {
                    .function_parameter => {},
                    else => {
                        if (!in_block) {
                            log.print("instruction {d} ({t}): outside any block\n", .{ index, instruction.op }) catch {};
                            problems += 1;
                        }
                        if (instruction.op == .variable) {
                            if (!variables_allowed) {
                                log.print("instruction {d}: a variable that is not at the start of the entry block\n", .{index}) catch {};
                                problems += 1;
                            }
                        } else {
                            variables_allowed = false;
                        }
                        if (isTerminator(instruction.op)) in_block = false;
                    },
                }
            },
        }

        // A merge instruction is the one before the branch that ends its
        // block, and is followed by exactly that.
        if (previous) |before| {
            if ((before == .selection_merge or before == .loop_merge) and
                instruction.op != .branch and instruction.op != .branch_conditional)
            {
                log.print("instruction {d} ({t}): follows a merge instruction and is not a branch\n", .{ index, instruction.op }) catch {};
                problems += 1;
            }
        }
        previous = instruction.op;
    }

    for (used, defined, 0..) |is_used, is_defined, id| {
        if (is_used and !is_defined) {
            log.print("id {d} is used and never defined\n", .{id}) catch {};
            problems += 1;
        }
    }
    if (bound != highest + 1) {
        log.print("the bound is {d}, and the highest id defined is {d}; it should be one more\n", .{ bound, highest }) catch {};
        problems += 1;
    }
    if (in_function) {
        log.print("the module ends inside a function\n", .{}) catch {};
        problems += 1;
    }

    if (problems > 0) return error.Invalid;
}

fn isTerminator(opcode: op.Op) bool {
    return switch (opcode) {
        .branch, .branch_conditional, .@"return", .return_value, .kill, .@"unreachable" => true,
        else => false,
    };
}

fn markUsed(id: u32, bound: u32, used: []bool, log: *std.Io.Writer, index: usize) bool {
    if (id == 0 or id >= bound) {
        log.print("instruction {d}: uses id {d}, which is not under the bound {d}\n", .{ index, id, bound }) catch {};
        return false;
    }
    used[id] = true;
    return true;
}

// -------------------------------------------------------------------------
// Reading the layout back
// -------------------------------------------------------------------------

/// A uniform block as a module declares it: which descriptor it is, and
/// where every member is and how it is laid out.
pub const BlockLayout = struct {
    set: u32,
    binding: u32,
    members: []const Member,

    pub const Member = struct {
        offset: u32,
        col_major: bool = false,
        matrix_stride: ?u32 = null,
    };
};

/// Every `Uniform` variable of a module whose type is a decorated `Block`
/// struct, in the order the variables are declared, with the layout
/// decorations of its members. Allocated from `a`, which is meant to be an
/// arena.
pub fn uniformBlocks(a: Allocator, words: []const u32) Error![]const BlockLayout {
    const Struct = struct {
        members: std.ArrayList(BlockLayout.Member) = .empty,
        is_block: bool = false,
    };
    var structs: std.AutoHashMapUnmanaged(u32, Struct) = .empty;
    var pointers: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var sets: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var bindings: std.AutoHashMapUnmanaged(u32, u32) = .empty;

    // The first pass finds the structs and how many members each has, so that
    // the second can fill them in whatever order the decorations came.
    var iterator: Iterator = .init(words);
    while (try iterator.next()) |instruction| {
        const w = instruction.words;
        switch (instruction.op) {
            .type_struct => {
                const member_count = w.len - 2;
                var entry: Struct = .{};
                try entry.members.appendNTimes(a, .{ .offset = 0 }, member_count);
                try structs.put(a, w[1], entry);
            },
            .type_pointer => try pointers.put(a, w[1], w[3]),
            else => {},
        }
    }

    iterator = .init(words);
    while (try iterator.next()) |instruction| {
        const w = instruction.words;
        switch (instruction.op) {
            .decorate => switch (@as(op.Decoration, @enumFromInt(w[2]))) {
                .block => if (structs.getPtr(w[1])) |entry| {
                    entry.is_block = true;
                },
                .descriptor_set => try sets.put(a, w[1], w[3]),
                .binding => try bindings.put(a, w[1], w[3]),
                else => {},
            },
            .member_decorate => if (structs.getPtr(w[1])) |entry| {
                const member = &entry.members.items[w[2]];
                switch (@as(op.Decoration, @enumFromInt(w[3]))) {
                    .offset => member.offset = w[4],
                    .col_major => member.col_major = true,
                    .matrix_stride => member.matrix_stride = w[4],
                    else => {},
                }
            },
            else => {},
        }
    }

    var out: std.ArrayList(BlockLayout) = .empty;
    iterator = .init(words);
    while (try iterator.next()) |instruction| {
        const w = instruction.words;
        if (instruction.op != .variable) continue;
        if (w[3] != @intFromEnum(op.StorageClass.uniform)) continue;
        const pointee = pointers.get(w[1]) orelse continue;
        const entry = structs.get(pointee) orelse continue;
        if (!entry.is_block) continue;
        try out.append(a, .{
            .set = sets.get(w[2]) orelse return error.Invalid,
            .binding = bindings.get(w[2]) orelse return error.Invalid,
            .members = entry.members.items,
        });
    }
    return out.items;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "a header alone is not a module, and a module that lies about its length is refused" {
    var buffer: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    const header = [_]u32{ op.magic, op.version_1_0, 0, 1, 0 };
    // A header and nothing else has a bound of one and no ids, which is
    // consistent: an empty module.
    try verify(testing.allocator, &header, &log);

    // An instruction that says it is longer than the stream.
    const truncated = header ++ [_]u32{ 3 << 16 | 17, 1 };
    try testing.expectError(error.Invalid, verify(testing.allocator, &truncated, &log));
    // And one that is too short for what it is.
    const short = header ++ [_]u32{1 << 16 | 17};
    try testing.expectError(error.Invalid, verify(testing.allocator, &short, &log));
}

test "an id that is used and never defined is found" {
    var buffer: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    // OpCapability Shader, then OpName %1 "x" with nothing defining %1.
    const words = [_]u32{
        op.magic,     op.version_1_0, 0,           2, 0,
        2 << 16 | 17, 1,              3 << 16 | 5, 1, 'x',
    };
    try testing.expectError(error.Invalid, verify(testing.allocator, &words, &log));
    try testing.expect(std.mem.indexOf(u8, log.buffered(), "never defined") != null);
}

test "sections out of order are found" {
    var buffer: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buffer);
    // OpMemoryModel before OpCapability.
    const words = [_]u32{
        op.magic,     op.version_1_0, 0, 1,            0,
        3 << 16 | 14, 0,              1, 2 << 16 | 17, 1,
    };
    try testing.expectError(error.Invalid, verify(testing.allocator, &words, &log));
    try testing.expect(std.mem.indexOf(u8, log.buffered(), "after") != null);
}
