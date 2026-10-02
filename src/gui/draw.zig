const std = @import("std");

const canvas = @import("canvas.zig");
const font = @import("font.zig");

const Rect = canvas.Rect;
const Point = canvas.Point;

/// Bytes in each of the two halves of a surface's command buffer.
pub const capacity = 64 * 1024;

// Coordinates past this are refused, so no arithmetic on them can overflow.
const reach = 1 << 20;

const Kind = enum(u32) {

    shape,
    text,
    _,

};

/// Starts every command: its kind, its size in bytes including this header, and the area it may touch.
const Header = extern struct {

    kind: Kind,
    size: u32,
    clip: [4]i32,

};

const Shape = extern struct {

    header: Header,
    area: [4]i32,
    color: u32,
    radius: i32,

};

/// Followed by `length` bytes of text, padded to four.
const Run = extern struct {

    header: Header,
    x: i32,
    baseline: i32,
    color: u32,
    size: f32,
    length: u32,

};

pub const Command = union(enum) {

    shape: struct {

        clip: Rect,
        area: Rect,
        color: u32,
        radius: i32,

    },
    text: struct {

        clip: Rect,
        x: i32,
        baseline: i32,
        color: u32,
        size: f32,
        string: []const u8,

    },

};

/// Records drawing as commands for the display to render; mirrors `Canvas` so the same code draws either.
pub const List = struct {

    bytes: []u8,
    length: usize = 0,
    width: i32,
    height: i32,

    /// Drawing outside this, when set, is discarded.
    limit: ?Rect = null,

    pub fn reset(self: *List) void {

        self.length = 0;
        self.limit = null;

    }

    pub fn commands(self: *const List) []const u8 {

        return self.bytes[0..self.length];

    }

    pub fn bounds(self: *const List) Rect {

        return .{

            .width = self.width,
            .height = self.height,

        };

    }

    pub fn fill(self: *List, area: Rect, color: u32) void {

        self.round(area, 0, color);

    }

    /// Fills `area` with anti-aliased corners of `radius` pixels.
    pub fn round(self: *List, area: Rect, radius: i32, color: u32) void {

        const clip = self.visible(area) orelse return;

        self.append(std.mem.asBytes(&Shape{

            .header = header(.shape, @sizeOf(Shape), clip),
            .area = wire(area),
            .color = color,
            .radius = radius,

        }), "");

    }

    /// Draws UTF-8 `string` at `size` pixels with its baseline starting at (`x`, `baseline`).
    pub fn text(self: *List, string: []const u8, size: f32, x: i32, baseline: i32, color: u32) void {

        if (string.len == 0) return;

        const clip = self.visible(self.bounds()) orelse return;

        self.append(std.mem.asBytes(&Run{

            .header = header(.text, @intCast(@sizeOf(Run) + std.mem.alignForward(usize, string.len, 4)), clip),
            .x = x,
            .baseline = baseline,
            .color = color,
            .size = size,
            .length = @intCast(string.len),

        }), string);

    }

    /// Draws `string` vertically centred in `area`.
    pub fn label(self: *List, string: []const u8, size: f32, area: Rect, color: u32, alignment: canvas.Alignment) void {

        const start = canvas.anchor(font.sans(), string, size, area, alignment);

        self.text(string, size, start.x, start.y, color);

    }

    fn visible(self: *const List, area: Rect) ?Rect {

        const window = (self.limit orelse self.bounds()).intersect(self.bounds()) orelse return null;

        return area.intersect(window);

    }

    // ponytail: a full list drops later commands; grow `capacity` if real windows hit it.
    fn append(self: *List, fixed: []const u8, string: []const u8) void {

        const size = fixed.len + std.mem.alignForward(usize, string.len, 4);
        if (self.length + size > self.bytes.len) return;

        @memcpy(self.bytes[self.length..][0..fixed.len], fixed);
        @memcpy(self.bytes[self.length + fixed.len ..][0..string.len], string);
        @memset(self.bytes[self.length + fixed.len + string.len ..][0 .. size - fixed.len - string.len], 0);
        self.length += size;

    }

};

/// Reads commands another process wrote, refusing any that are malformed or out of reach.
pub const Iterator = struct {

    bytes: []const u8,
    offset: usize = 0,

    pub fn next(self: *Iterator) ?Command {

        while (self.offset + @sizeOf(Header) <= self.bytes.len) {

            const start = self.offset;
            const top = std.mem.bytesToValue(Header, self.bytes[start..][0..@sizeOf(Header)]);

            if (top.size < @sizeOf(Header) or top.size % 4 != 0 or top.size > self.bytes.len - start) return null;
            self.offset += top.size;

            const body = self.bytes[start..][0..top.size];
            const clip = rect(top.clip) orelse continue;

            switch (top.kind) {

                .shape => {

                    if (body.len < @sizeOf(Shape)) continue;

                    const shape = std.mem.bytesToValue(Shape, body[0..@sizeOf(Shape)]);

                    return .{

                        .shape = .{

                            .clip = clip,
                            .area = rect(shape.area) orelse continue,
                            .color = shape.color,
                            .radius = std.math.clamp(shape.radius, 0, reach),

                        },

                    };

                },
                .text => {

                    if (body.len < @sizeOf(Run)) continue;

                    const run = std.mem.bytesToValue(Run, body[0..@sizeOf(Run)]);

                    if (run.length > body.len - @sizeOf(Run) or !near(run.x) or !near(run.baseline)) continue;
                    if (!(run.size >= 4 and run.size <= 128)) continue;

                    return .{

                        .text = .{

                            .clip = clip,
                            .x = run.x,
                            .baseline = run.baseline,
                            .color = run.color,
                            .size = run.size,
                            .string = body[@sizeOf(Run)..][0..run.length],

                        },

                    };

                },
                _ => continue,

            }

        }

        return null;

    }

};

pub fn iterate(bytes: []const u8) Iterator {

    return .{

        .bytes = bytes,

    };

}

/// Draws `bytes` of commands on the CPU, shifted by `origin` and kept inside `limit`.
pub fn replay(target: *canvas.Canvas, bytes: []const u8, origin: Point, limit: Rect) void {

    const previous = target.limit;
    var commands = iterate(bytes);

    defer target.limit = previous;

    while (commands.next()) |command| {

        switch (command) {

            .shape => |shape| {

                target.limit = limit.intersect(move(shape.clip, origin)) orelse continue;
                target.round(move(shape.area, origin), shape.radius, shape.color);

            },
            .text => |run| {

                target.limit = limit.intersect(move(run.clip, origin)) orelse continue;
                target.text(font.sans(), run.string, run.size, run.x + origin.x, run.baseline + origin.y, run.color);

            },

        }

    }

}

pub fn move(area: Rect, by: Point) Rect {

    return .{

        .x = area.x + by.x,
        .y = area.y + by.y,
        .width = area.width,
        .height = area.height,

    };

}

fn header(kind: Kind, size: u32, clip: Rect) Header {

    return .{

        .kind = kind,
        .size = size,
        .clip = wire(clip),

    };

}

fn wire(area: Rect) [4]i32 {

    return .{ area.x, area.y, area.width, area.height };

}

fn rect(values: [4]i32) ?Rect {

    for (values) |value| {

        if (!near(value)) return null;

    }

    if (values[2] <= 0 or values[3] <= 0) return null;

    return .{

        .x = values[0],
        .y = values[1],
        .width = values[2],
        .height = values[3],

    };

}

fn near(value: i32) bool {

    return value > -reach and value < reach;

}
