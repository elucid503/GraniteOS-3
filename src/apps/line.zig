const std = @import("std");

pub const capacity = 256;
const history_limit = 16;

pub const Event = enum {

    none,
    echo,
    erase,
    redraw,
    bell,
    submit,
    cancel,
    complete,
    clear,

};

const Escape = enum {

    none,
    start,
    sequence,

};

pub const Line = struct {

    bytes: [capacity]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    carriage: bool = false,
    escape: Escape = .none,
    parameter: u8 = 0,

    history: [history_limit][capacity]u8 = undefined,
    lengths: [history_limit]usize = undefined,
    total: usize = 0,
    back: usize = 0,

    draft: [capacity]u8 = undefined,
    draft_len: usize = 0,

    pub fn text(self: *const Line) []const u8 {

        return self.bytes[0..self.len];

    }

    pub fn reset(self: *Line) void {

        self.len = 0;
        self.cursor = 0;
        self.back = 0;

    }

    /// Returns the command `step` entries back from the newest, or null past the oldest.
    pub fn recalled(self: *const Line, step: usize) ?[]const u8 {

        if (step == 0 or step > @min(self.total, history_limit)) return null;
        const slot = (self.total - step) % history_limit;

        return self.history[slot][0..self.lengths[slot]];

    }

    pub fn push(self: *Line, byte: u8) Event {

        const previous = self.carriage;
        self.carriage = byte == '\r';

        switch (self.escape) {

            .none => {

            },
            .start => {

                self.escape = if (byte == '[' or byte == 'O') .sequence else .none;
                self.parameter = 0;
                return .none;

            },
            .sequence => {

                if (byte >= '0' and byte <= '9') self.parameter = byte;
                if ((byte >= '0' and byte <= '9') or byte == ';') return .none;

                self.escape = .none;
                return self.key(if (byte == '~') self.parameter else byte);

            },

        }

        return switch (byte) {

            '\n' => if (previous) .none else self.submit(),
            '\r' => self.submit(),
            0x1b => {

                self.escape = .start;
                return .none;

            },
            1 => self.move(0),
            2 => self.key('D'),
            3 => {

                self.reset();
                return .cancel;

            },
            5 => self.move(self.len),
            6 => self.key('C'),
            8, 127 => self.erase(),
            '\t' => .complete,
            11 => self.remove(self.cursor, self.len),
            12 => .clear,
            14 => self.key('B'),
            16 => self.key('A'),
            21 => self.remove(0, self.cursor),
            23 => self.remove(self.wordStart(), self.cursor),
            ' '...'~' => self.insert(&.{byte}),
            else => .none,

        };

    }

    pub fn insert(self: *Line, bytes: []const u8) Event {

        if (bytes.len > self.bytes.len - self.len) return .bell;

        const appending = self.cursor == self.len;
        std.mem.copyBackwards(u8, self.bytes[self.cursor + bytes.len .. self.len + bytes.len], self.bytes[self.cursor..self.len]);
        @memcpy(self.bytes[self.cursor .. self.cursor + bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
        self.back = 0;

        return if (appending and bytes.len == 1) .echo else .redraw;

    }

    fn key(self: *Line, code: u8) Event {

        return switch (code) {

            'A' => self.recall(self.back + 1),
            'B' => if (self.back == 0) .none else self.recall(self.back - 1),
            'C' => if (self.cursor < self.len) self.move(self.cursor + 1) else .none,
            'D' => if (self.cursor > 0) self.move(self.cursor - 1) else .none,
            'H', '1', '7' => self.move(0),
            'F', '4', '8' => self.move(self.len),
            '3' => self.remove(self.cursor, @min(self.cursor + 1, self.len)),
            else => .none,

        };

    }

    fn submit(self: *Line) Event {

        const newest = self.recalled(1);
        const repeated = newest != null and std.mem.eql(u8, newest.?, self.text());

        if (self.len != 0 and !repeated) {

            const slot = self.total % history_limit;
            @memcpy(self.history[slot][0..self.len], self.text());
            self.lengths[slot] = self.len;
            self.total += 1;

        }

        return .submit;

    }

    fn recall(self: *Line, step: usize) Event {

        const source = if (step == 0) self.draft[0..self.draft_len] else self.recalled(step) orelse return .bell;

        if (self.back == 0) {

            @memcpy(self.draft[0..self.len], self.text());
            self.draft_len = self.len;

        }

        @memcpy(self.bytes[0..source.len], source);
        self.len = source.len;
        self.cursor = source.len;
        self.back = step;

        return .redraw;

    }

    fn move(self: *Line, position: usize) Event {

        if (position == self.cursor) return .none;
        self.cursor = position;

        return .redraw;

    }

    fn erase(self: *Line) Event {

        if (self.cursor == 0) return .none;
        const trailing = self.cursor == self.len;
        _ = self.remove(self.cursor - 1, self.cursor);

        return if (trailing) .erase else .redraw;

    }

    fn remove(self: *Line, start: usize, end: usize) Event {

        if (start == end) return .none;

        std.mem.copyForwards(u8, self.bytes[start .. self.len - (end - start)], self.bytes[end..self.len]);
        self.len -= end - start;
        self.cursor = start;
        self.back = 0;

        return .redraw;

    }

    fn wordStart(self: *const Line) usize {

        var index = self.cursor;

        while (index > 0 and self.bytes[index - 1] == ' ') index -= 1;
        while (index > 0 and self.bytes[index - 1] != ' ') index -= 1;

        return index;

    }

};
