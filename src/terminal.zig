const std = @import("std");
const testing = std.testing;
const GapBuffer = @import("gap_buffer.zig").GapBuffer;
const Allocator = std.mem.Allocator;
const unicode = std.unicode;
const assert = std.debug.assert;

/// Type of cursor to use.
///
/// More information: https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h4-Functions-using-CSI-_-ordered-by-the-final-character-lparen-s-rparen:CSI-Ps-SP-q.1D81
const CursorMode = enum(u4) {
    blinkingBlock = 1,
    steadyBlock = 2,
    blinkingUnderline = 3,
    steadyUnderline = 4,
    blinkingBar = 5,
    steadyBar = 6,
};

const EditMode = enum(u2) {
    normal,
    insert,
    visual,
};

const TerminalOptions = struct {
    filepath: []const u8,
};

pub const Terminal = struct {
    const Self = @This();
    const tabIndentation = 4;
    const spaces = " " ** tabIndentation;
    const lineInitialCapacity = 10;

    /// The current line the cursor is on
    y: usize = 0,
    /// The current character a cursor is on
    x: usize = 0,
    /// The current byte the cursor is on
    byteX: usize = 0,
    content: GapBuffer(GapBuffer(u8)),
    allocator: Allocator,
    options: ?TerminalOptions,
    mode: EditMode = EditMode.normal,

    pub fn init(allocator: std.mem.Allocator, options: ?TerminalOptions) Allocator.Error!Self {
        var buffer = try GapBuffer(GapBuffer(u8)).initCapacity(allocator, 1000);
        const line = try GapBuffer(u8).initCapacity(allocator, lineInitialCapacity);
        try buffer.insert(line);
        return Self{
            .content = buffer,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: Self) void {
        var iterator = self.content.iterator();
        while (iterator.next()) |line| {
            line.deinit();
        }
        self.content.deinit();
    }

    fn computeBytePosition(self: Self, gap: GapBuffer(u8), charX: usize) !usize {
        var byteX: usize = 0;
        if (gap.len > 0) {
            const owned = try gap.getOwnedSlice();
            defer self.allocator.free(owned);
            var iter = (try unicode.Utf8View.init(owned)).iterator();
            var i: usize = 0;
            while (iter.nextCodepointSlice()) |ch| : (i += 1) {
                if (i >= charX) break;
                byteX += ch.len;
            }
        }
        return byteX;
    }

    fn jump(self: *Self, y: usize, x: usize) !void {
        self.content.jump(y + 1);
        var line = self.content.getLeft();
        line.jump(x);
        self.y = y;
        self.x = x;
        self.byteX = try self.computeBytePosition(line.*, self.x);
    }

    /// Inserts a slice of characters at the current cursor position.
    /// Does not handle different character types. `addChars` should
    /// be used for that.
    fn insertSlice(self: *Self, chars: []const u8) !void {
        try self.content.get(self.y).insertSlice(chars);
        self.x += try unicode.utf8CountCodepoints(chars);
        self.byteX += chars.len;
    }

    fn insertNewline(self: *Self) !void {
        const oldLineLength = self.content.getLeft().len;
        try self.content.insert(try GapBuffer(u8).initCapacity(self.allocator, lineInitialCapacity));
        if (self.byteX < oldLineLength) {
            const newLine = self.content.getLeft();
            const oldLine = self.content.get(self.y);
            try newLine.insertSlice(oldLine.buffer.items[self.byteX..oldLineLength]);
            oldLine.deleteAllRight();
        }
        self.y += 1;
        self.x = 0;
        self.byteX = 0;
    }

    /// Takes an unfiltered input of characters and inserts them at
    /// the current cursor position. Handles special characters like
    /// newlines and tabs.
    fn addChars(self: *Self, chars: []const u8) !void {
        var start: usize = 0;
        var pos: usize = 0;
        for (chars, 0..) |c, i| {
            switch (c) {
                '\n' => {
                    if (start < i) {
                        try self.insertSlice(chars[start..i]);
                    }
                    try self.insertNewline();
                    start = i + 1;
                    pos = 0;
                },
                '\t' => {
                    if (start < i) {
                        try self.insertSlice(chars[start..i]);
                    }
                    const spacesToAdd = 4 - pos % 4;
                    try self.insertSlice(spaces[0..spacesToAdd]);
                    pos += spacesToAdd + i - start;
                    start = i + 1;
                },
                else => {},
            }
        }
        if (start < chars.len) {
            try self.insertSlice(chars[start..]);
        }
    }
};

test "init" {
    var term = try Terminal.init(testing.allocator, null);
    defer term.deinit();
    try testing.expectEqual(@as(usize, 0), term.x);
    try testing.expectEqual(@as(usize, 0), term.y);
    try testing.expectEqual(@as(usize, 1), term.content.len);
    try testing.expectEqual(@as(usize, 0), term.content.buffer.items[0].len);
}

test "init with failing allocator" {
    const terminal = Terminal.init(testing.failing_allocator, null);
    try testing.expectError(std.mem.Allocator.Error.OutOfMemory, terminal);
}

test "computeBytePosition" {
    const a = testing.allocator;
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        const gap = GapBuffer(u8).init(a);
        try testing.expectEqual(@as(usize, 0), try term.computeBytePosition(gap, 0));
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        var gap = GapBuffer(u8).init(a);
        defer gap.deinit();
        try gap.insertSlice("äääää");
        try testing.expectEqual(@as(usize, 10), try term.computeBytePosition(gap, 5));
    }
}

test "jump" {
    {
        var term = try Terminal.init(testing.allocator, null);
        defer term.deinit();
        try term.jump(0, 0);
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 0), term.x);
    }
    {
        var term = try Terminal.init(testing.allocator, null);
        defer term.deinit();
        try term.addChars("hello\nthere\ngeneral\nkenobi");
        try term.jump(3, 4);
        try testing.expectEqual(@as(usize, 3), term.y);
        try testing.expectEqual(@as(usize, 4), term.x);
        const line = term.content.getLeft().*;
        try testing.expectEqual(@as(u8, 'o'), line.getLeft().*);
        try testing.expectEqual(@as(u8, 'b'), line.getRight().*);
    }
}

test "insertSlice" {
    const a = testing.allocator;
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.insertSlice("asdf");
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 4), term.x);
        try testing.expectEqual(@as(usize, 4), term.byteX);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.insertSlice("äüＳ");
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 3), term.x);
        try testing.expectEqual(@as(usize, 7), term.byteX);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.insertSlice("2345");
        try term.jump(0, 0);
        try term.insertSlice("01");
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 2), term.x);
        try testing.expectEqual(@as(usize, 2), term.byteX);
        const line = try term.content.get(0).getOwnedSlice();
        defer a.free(line);
        try testing.expectEqualSlices(u8, "012345", line);
    }
}

test "insertNewline" {
    const a = testing.allocator;
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.insertSlice("a");
        try term.insertNewline();
        try testing.expectEqual(@as(usize, 1), term.y);
        try testing.expectEqual(@as(usize, 0), term.x);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.insertSlice("abcd");
        try term.jump(0, 2);
        try term.insertNewline();
        try testing.expectEqual(@as(usize, 2), term.content.len);
        const firstLine = try term.content.get(0).getOwnedSlice();
        defer a.free(firstLine);
        const secondLine = try term.content.get(1).getOwnedSlice();
        defer a.free(secondLine);
        try testing.expectEqual(@as(usize, 1), term.y);
        try testing.expectEqual(@as(usize, 0), term.x);
        try testing.expectEqualSlices(u8, "ab", firstLine);
        try testing.expectEqualSlices(u8, "cd", secondLine);
    }
}

test "addChars" {
    const a = testing.allocator;
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.addChars("hello");
        const owned = try term.content.get(0).getOwnedSlice();
        defer a.free(owned);
        try testing.expectEqual(@as(usize, 1), term.content.len);
        try testing.expectEqual(@as(usize, 5), owned.len);
        try testing.expectEqualSlices(u8, "hello", owned);
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 5), term.x);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.addChars("Hello there\nGeneral Kenobi");
        const firstLine = try term.content.get(0).getOwnedSlice();
        const secondLine = try term.content.get(1).getOwnedSlice();
        defer a.free(firstLine);
        defer a.free(secondLine);
        try testing.expectEqual(@as(usize, 2), term.content.len);
        try testing.expectEqual(@as(usize, 11), firstLine.len);
        try testing.expectEqual(@as(usize, 14), secondLine.len);
        try testing.expectEqualSlices(u8, "Hello there", firstLine);
        try testing.expectEqualSlices(u8, "General Kenobi", secondLine);
        try testing.expectEqual(@as(usize, 1), term.y);
        try testing.expectEqual(@as(usize, 14), term.x);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.addChars("\tdef foo()");
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 13), term.x);
        try testing.expectEqual(@as(usize, 13), term.byteX);
    }
    {
        var term = try Terminal.init(a, null);
        defer term.deinit();
        try term.addChars("\tdef\t\tfoo()");
        try testing.expectEqual(@as(usize, 0), term.y);
        try testing.expectEqual(@as(usize, 17), term.x);
        try testing.expectEqual(@as(usize, 17), term.byteX);
    }
}
