const std = @import("std");

const font = @import("font.zig");

pub const Point = struct {

    x: i32 = 0,
    y: i32 = 0,

};

pub const Rect = struct {

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    pub fn right(self: Rect) i32 {

        return self.x + self.width;

    }

    pub fn bottom(self: Rect) i32 {

        return self.y + self.height;

    }

    pub fn contains(self: Rect, point: Point) bool {

        return point.x >= self.x and point.y >= self.y and point.x < self.right() and point.y < self.bottom();

    }

    pub fn intersect(self: Rect, other: Rect) ?Rect {

        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right_edge = @min(self.right(), other.right());
        const bottom_edge = @min(self.bottom(), other.bottom());

        if (left >= right_edge or top >= bottom_edge) return null;

        return .{

            .x = left,
            .y = top,
            .width = right_edge - left,
            .height = bottom_edge - top,

        };

    }

    /// The smallest rectangle covering both.
    pub fn join(self: Rect, other: Rect) Rect {

        if (self.width <= 0 or self.height <= 0) return other;
        if (other.width <= 0 or other.height <= 0) return self;

        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);

        return .{

            .x = left,
            .y = top,
            .width = @max(self.right(), other.right()) - left,
            .height = @max(self.bottom(), other.bottom()) - top,

        };

    }

    pub fn inset(self: Rect, amount: i32) Rect {

        return .{

            .x = self.x + amount,
            .y = self.y + amount,
            .width = self.width - 2 * amount,
            .height = self.height - 2 * amount,

        };

    }

    /// A `width` by `height` rectangle centered within this one.
    pub fn centered(self: Rect, width: i32, height: i32) Rect {

        return .{

            .x = self.x + @divTrunc(self.width - width, 2),
            .y = self.y + @divTrunc(self.height - height, 2),
            .width = width,
            .height = height,

        };

    }

};

pub const Alignment = enum {

    left,
    center,

};

const Bounds = struct {

    left: usize,
    top: usize,
    right: usize,
    bottom: usize,

};

/// Pixels as 0x00RRGGBB, row after row.
pub const Canvas = struct {

    pixels: []u32,
    width: usize,
    height: usize,

    pub fn bounds(self: *const Canvas) Rect {

        return .{

            .width = @intCast(self.width),
            .height = @intCast(self.height),

        };

    }

    pub fn fill(self: *Canvas, area: Rect, color: u32) void {

        const clipped = self.clip(area) orelse return;

        for (clipped.top..clipped.bottom) |y| @memset(self.pixels[y * self.width ..][clipped.left..clipped.right], color);

    }

    /// Fills `area` with anti-aliased corners of `radius` pixels.
    pub fn round(self: *Canvas, area: Rect, radius: i32, color: u32) void {

        const limit = @min(radius, @divTrunc(@min(area.width, area.height), 2));
        if (limit <= 0) return self.fill(area, color);

        const clipped = self.clip(area) orelse return;
        const r: f32 = @floatFromInt(limit);
        const left: f32 = @floatFromInt(area.x);
        const top: f32 = @floatFromInt(area.y);
        const right: f32 = @floatFromInt(area.right());
        const bottom: f32 = @floatFromInt(area.bottom());

        for (clipped.top..clipped.bottom) |y| {

            const row = self.pixels[y * self.width ..];
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dy = fy - std.math.clamp(fy, top + r, bottom - r);

            // Rows between the corners are solid.
            if (dy == 0) {

                @memset(row[clipped.left..clipped.right], color);
                continue;

            }

            for (clipped.left..clipped.right) |x| {

                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const dx = fx - std.math.clamp(fx, left + r, right - r);

                blend(&row[x], color, r - @sqrt(dx * dx + dy * dy) + 0.5);

            }

        }

    }

    /// Draws ASCII `string` at `size` pixels with its baseline starting at (`x`, `baseline`).
    pub fn text(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, x: i32, baseline: i32, color: u32) void {

        const scale = size / face.units;
        var pen: f32 = @floatFromInt(x);
        var previous: u16 = 0;

        for (string) |char| {

            const glyph = face.lookup(char);

            pen += face.kerning(previous, glyph) * scale;
            previous = glyph;

            if (face.render(glyph, scale, pen - @floor(pen))) |bitmap| {

                const left = @as(i32, @intFromFloat(@floor(pen))) + bitmap.left;
                const top = baseline + bitmap.top;

                for (0..bitmap.height) |row| {

                    for (0..bitmap.width) |column| {

                        const point = Point{

                            .x = left + @as(i32, @intCast(column)),
                            .y = top + @as(i32, @intCast(row)),

                        };

                        if (self.bounds().contains(point)) blend(self.at(point), color, bitmap.coverage[row * bitmap.width + column]);

                    }

                }

            }

            pen += face.advance(glyph) * scale;

        }

    }

    /// Draws `string` vertically centered in `area`.
    pub fn label(self: *Canvas, face: *const font.Font, string: []const u8, size: f32, area: Rect, color: u32, alignment: Alignment) void {

        const scale = size / face.units;
        const span: i32 = @intFromFloat(@ceil(face.measure(string, scale)));
        const height: i32 = @intFromFloat(@as(f32, @floatFromInt(face.ascent + face.descent)) * scale);
        const x = switch (alignment) {

            .left => area.x,
            .center => area.x + @divTrunc(area.width - span, 2),

        };

        self.text(face, string, size, x, area.y + @divTrunc(area.height + height, 2), color);

    }

    /// Copies `source`, placed with its corner at `origin`, wherever it overlaps `area`.
    pub fn blit(self: *Canvas, source: *const Canvas, origin: Point, area: Rect) void {

        const placed = Rect{

            .x = origin.x,
            .y = origin.y,
            .width = @intCast(source.width),
            .height = @intCast(source.height),

        };

        const visible = area.intersect(placed) orelse return;
        const clipped = self.clip(visible) orelse return;
        const span = clipped.right - clipped.left;
        const column: usize = @intCast(@as(i64, @intCast(clipped.left)) - origin.x);

        for (clipped.top..clipped.bottom) |y| {

            const row: usize = @intCast(@as(i64, @intCast(y)) - origin.y);

            @memcpy(self.pixels[y * self.width + clipped.left ..][0..span], source.pixels[row * source.width + column ..][0..span]);

        }

    }

    fn at(self: *Canvas, point: Point) *u32 {

        return &self.pixels[@as(usize, @intCast(point.y)) * self.width + @as(usize, @intCast(point.x))];

    }

    fn clip(self: *const Canvas, area: Rect) ?Bounds {

        const visible = area.intersect(self.bounds()) orelse return null;

        return .{

            .left = @intCast(visible.x),
            .top = @intCast(visible.y),
            .right = @intCast(visible.right()),
            .bottom = @intCast(visible.bottom()),

        };

    }

};

fn blend(pixel: *u32, color: u32, alpha: f32) void {

    if (alpha <= 0) return;
    if (alpha >= 1) {

        pixel.* = color;
        return;

    }

    var result: u32 = 0;

    for ([_]u5{ 0, 8, 16 }) |shift| {

        const under: f32 = @floatFromInt(pixel.* >> shift & 0xff);
        const over: f32 = @floatFromInt(color >> shift & 0xff);

        result |= @as(u32, @intFromFloat(under + (over - under) * alpha + 0.5)) << shift;

    }

    pixel.* = result;

}
