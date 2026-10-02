const std = @import("std");

const font = @import("font.zig");

const api = @import("api");

/// Editable UTF-8 text in caller-owned `buffer`; the caret always sits between characters; secret text shows dots and is wiped by `clear`.
pub const Text = struct {

    buffer: []u8,
    length: usize = 0,
    caret: usize = 0,

    placeholder: []const u8 = "",
    secret: bool = false,

    /// First visible line of multi-line text.
    top: usize = 0,

    pub fn text(self: *const Text) []const u8 {

        return self.buffer[0..self.length];

    }

    pub fn clear(self: *Text) void {

        std.crypto.secureZero(u8, self.buffer);
        self.length = 0;
        self.caret = 0;
        self.top = 0;

    }

    pub fn set(self: *Text, string: []const u8) void {

        self.clear();
        self.length = @min(string.len, self.buffer.len);
        @memcpy(self.buffer[0..self.length], string[0..self.length]);
        self.caret = self.length;

    }

    /// Applies an editing key press; true when the text or caret changed.
    pub fn key(self: *Text, event: api.Event, multiline: bool) bool {

        if (event.kind != .key or !event.pressed) return false;

        switch (event.key()) {

            .character => {

                if (event.modifiers.control or event.modifiers.alt or event.char < 0x20 or event.char == 0x7f) return false;
                return self.insert(event.char);

            },
            .enter => return multiline and self.insert('\n'),
            .backspace => {

                if (self.caret == 0) return false;

                const end = self.caret;

                self.caret = self.before(self.caret);
                self.remove(end - self.caret);

            },
            .delete => {

                if (self.caret == self.length) return false;
                self.remove(self.after(self.caret) - self.caret);

            },
            .left => {

                if (self.caret == 0) return false;
                self.caret = self.before(self.caret);

            },
            .right => {

                if (self.caret == self.length) return false;
                self.caret = self.after(self.caret);

            },
            .home => self.caret = if (multiline) self.start(self.caret) else 0,
            .end => self.caret = if (multiline) std.mem.indexOfScalarPos(u8, self.text(), self.caret, '\n') orelse self.length else self.length,
            else => return false,

        }

        return true;

    }

    /// Moves the caret `delta` wrapped lines, keeping its horizontal position; false at the first or last line.
    pub fn vertical(self: *Text, face: *const font.Font, size: f32, width: i32, delta: i32) bool {

        const scale = size / face.units;
        const string = self.text();
        var lines = Lines.init(face, string, size, width);
        var previous: ?Line = null;

        while (lines.next()) |line| {

            if (!line.holds(string, self.caret)) {

                previous = line;
                continue;

            }

            const target = (if (delta < 0) previous else lines.next()) orelse return false;
            const x = face.measure(string[line.start..self.caret], scale);
            var best = target.start;

            for (target.start..target.end + 1) |position| {

                if (position < string.len and inner(string[position])) continue;
                if (@abs(face.measure(string[target.start..position], scale) - x) < @abs(face.measure(string[target.start..best], scale) - x)) best = position;

            }

            self.caret = best;

            return true;

        }

        return false;

    }

    fn insert(self: *Text, char: u21) bool {

        var bytes: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(char, &bytes) catch return false;

        if (self.length + count > self.buffer.len) return false;

        std.mem.copyBackwards(u8, self.buffer[self.caret + count .. self.length + count], self.buffer[self.caret..self.length]);
        @memcpy(self.buffer[self.caret..][0..count], bytes[0..count]);
        self.length += count;
        self.caret += count;

        return true;

    }

    /// Removes `count` bytes at the caret.
    fn remove(self: *Text, count: usize) void {

        std.mem.copyForwards(u8, self.buffer[self.caret .. self.length - count], self.buffer[self.caret + count .. self.length]);
        self.length -= count;
        @memset(self.buffer[self.length..][0..count], 0);

    }

    /// Where the character before `at` starts.
    fn before(self: *const Text, at: usize) usize {

        var index = at - 1;

        while (index > 0 and inner(self.buffer[index])) index -= 1;

        return index;

    }

    /// Where the character after `at` starts.
    fn after(self: *const Text, at: usize) usize {

        var index = at + 1;

        while (index < self.length and inner(self.buffer[index])) index += 1;

        return index;

    }

    fn start(self: *const Text, from: usize) usize {

        const newline = std.mem.lastIndexOfScalar(u8, self.buffer[0..from], '\n') orelse return 0;

        return newline + 1;

    }

};

/// One wrapped line as a byte range; a hard break's newline is not included.
pub const Line = struct {

    start: usize,
    end: usize,

    /// Whether `caret` sits on this line; a caret at a soft break belongs to the next one.
    pub fn holds(self: Line, string: []const u8, caret: usize) bool {

        if (caret < self.start or caret > self.end) return false;

        return caret < self.end or caret == string.len or string[caret] == '\n';

    }

};

/// Splits `string` into lines no wider than `width` pixels, breaking after spaces where possible.
pub const Lines = struct {

    face: *const font.Font,
    string: []const u8,
    scale: f32,
    width: f32,
    index: usize = 0,

    pub fn init(face: *const font.Font, string: []const u8, size: f32, width: i32) Lines {

        return .{

            .face = face,
            .string = string,
            .scale = size / face.units,
            .width = @floatFromInt(@max(width, 1)),

        };

    }

    pub fn next(self: *Lines) ?Line {

        if (self.index > self.string.len) return null;

        const begin = self.index;
        const stop = std.mem.indexOfScalarPos(u8, self.string, begin, '\n') orelse self.string.len;
        var span: f32 = 0;
        var previous: u16 = 0;
        var space: ?usize = null;
        var characters = font.Characters{

            .bytes = self.string[0..stop],
            .index = begin,

        };

        while (characters.index < stop) {

            const position = characters.index;
            const char = characters.next().?;
            const glyph = self.face.lookup(char);

            span += (self.face.kerning(previous, glyph) + self.face.advance(glyph)) * self.scale;
            previous = glyph;

            if (span > self.width and position > begin) {

                const end = space orelse position;

                self.index = end;
                return .{

                    .start = begin,
                    .end = end,

                };

            }

            if (char == ' ') space = characters.index;

        }

        self.index = stop + 1;

        return .{

            .start = begin,
            .end = stop,

        };

    }

};

/// Pixel height of one line of text at `size`.
pub fn leading(face: *const font.Font, size: f32) i32 {

    const span: f32 = @floatFromInt(@as(i32, face.ascent) + @as(i32, @abs(face.descent)));

    return @intFromFloat(@ceil(span * size / face.units));

}

/// Whether `byte` continues a UTF-8 sequence rather than starting a character.
fn inner(byte: u8) bool {

    return byte & 0xc0 == 0x80;

}
