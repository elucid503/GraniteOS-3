const std = @import("std");

const font = @import("font.zig");

pub const Point = struct {

    x: i32,
    y: i32,

};

/// A pixel rectangle; it may extend past the canvas and is clipped on use.
pub const Rect = struct {

    x: i32,
    y: i32,
    width: i32,
    height: i32,

};

const Bounds = struct {

    left: usize,
    top: usize,
    right: usize,
    bottom: usize,

};

const arrow = [_]*const [12]u8{

    "X...........",
    "XX..........",
    "XOX.........",
    "XOOX........",
    "XOOOX.......",
    "XOOOOX......",
    "XOOOOOX.....",
    "XOOOOOOX....",
    "XOOOOOOOX...",
    "XOOOOOOOOX..",
    "XOOOOOOOOOX.",
    "XOOOOOOXXXXX",
    "XOOOXOOX....",
    "XOOX.XOOX...",
    "XOX..XOOX...",
    "XX....XOOX..",
    "X.....XOOX..",
    ".......XX...",

};

/// The pointer's footprint when its tip sits at `pointer`.
pub fn cursor(pointer: Point) Rect {

    return .{

        .x = pointer.x,
        .y = pointer.y,
        .width = arrow[0].len,
        .height = arrow.len,

    };

}

/// The composed scene in device pixel format; damaged areas are copied out rather than redrawn.
pub const Canvas = struct {

    pixels: []u32,
    width: usize,
    height: usize,

    /// Bit positions of the red, green, and blue bytes.
    shifts: [3]u5,

    /// Converts 0xRRGGBB to the device pixel format.
    pub fn color(self: *const Canvas, rgb: u32) u32 {

        var pixel: u32 = 0;

        for (self.shifts, 0..) |shift, index| pixel |= channel(rgb, index) << shift;

        return pixel;

    }

    pub fn fill(self: *Canvas, area: Rect, rgb: u32) void {

        const bounds = self.clip(area) orelse return;
        const pixel = self.color(rgb);

        for (bounds.top..bounds.bottom) |y| @memset(self.pixels[y * self.width ..][bounds.left..bounds.right], pixel);

    }

    /// Draws ASCII `string` with its baseline starting at (`x`, `baseline`).
    pub fn text(self: *Canvas, face: *const font.Font, string: []const u8, scale: f32, x: f32, baseline: i32, rgb: u32) void {

        var pen = x;

        for (string) |char| {

            const glyph = face.lookup(char);

            if (face.render(glyph, scale, pen - @floor(pen))) |bitmap| {

                const left = @as(i32, @intFromFloat(@floor(pen))) + bitmap.left;
                const top = baseline + bitmap.top;

                for (0..bitmap.height) |row| {

                    for (0..bitmap.width) |column| self.blend(left + @as(i32, @intCast(column)), top + @as(i32, @intCast(row)), rgb, bitmap.coverage[row * bitmap.width + column]);

                }

            }

            pen += face.advance(glyph) * scale;

        }

    }

    /// Copies `area` of the scene to `frame` with the pointer drawn over it.
    pub fn present(self: *const Canvas, frame: [*]u32, stride: usize, area: Rect, pointer: Point) void {

        const bounds = self.clip(area) orelse return;
        var line: [256]u32 = undefined;

        for (bounds.top..bounds.bottom) |y| {

            var x = bounds.left;

            // Composing in RAM writes each device pixel once, so the pointer never flickers.
            while (x < bounds.right) {

                const row = line[0..@min(line.len, bounds.right - x)];

                @memcpy(row, self.pixels[y * self.width + x ..][0..row.len]);
                self.overlay(row, x, y, pointer);
                @memcpy(frame[y * stride + x ..][0..row.len], row);
                x += row.len;

            }

        }

    }

    fn overlay(self: *const Canvas, row: []u32, x: usize, y: usize, pointer: Point) void {

        const line = @as(i64, @intCast(y)) - pointer.y;
        if (line < 0 or line >= arrow.len) return;

        for (arrow[@intCast(line)], 0..) |shape, column| {

            const offset = pointer.x + @as(i64, @intCast(column)) - @as(i64, @intCast(x));
            if (shape == '.' or offset < 0 or offset >= row.len) continue;

            row[@intCast(offset)] = self.color(if (shape == 'X') 0x000000 else 0xffffff);

        }

    }

    fn blend(self: *Canvas, x: i32, y: i32, rgb: u32, alpha: f32) void {

        if (alpha == 0 or x < 0 or y < 0 or x >= self.width or y >= self.height) return;

        const pixel = &self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))];
        var result: u32 = 0;

        for (self.shifts, 0..) |shift, index| {

            const under: f32 = @floatFromInt(pixel.* >> shift & 0xff);
            const over: f32 = @floatFromInt(channel(rgb, index));

            result |= @as(u32, @intFromFloat(under + (over - under) * alpha + 0.5)) << shift;

        }

        pixel.* = result;

    }

    fn clip(self: *const Canvas, area: Rect) ?Bounds {

        const width: i32 = @intCast(self.width);
        const height: i32 = @intCast(self.height);
        const left = std.math.clamp(area.x, 0, width);
        const top = std.math.clamp(area.y, 0, height);
        const right = std.math.clamp(area.x +| area.width, 0, width);
        const bottom = std.math.clamp(area.y +| area.height, 0, height);

        if (left >= right or top >= bottom) return null;

        return .{

            .left = @intCast(left),
            .top = @intCast(top),
            .right = @intCast(right),
            .bottom = @intCast(bottom),

        };

    }

};

fn channel(rgb: u32, index: usize) u32 {

    return rgb >> @intCast(16 - index * 8) & 0xff;

}
