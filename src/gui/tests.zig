const std = @import("std");

const font = @import("font.zig");
const canvas = @import("canvas.zig");

test "font rasterizes every printable ASCII glyph with solid stems and open counters" {

    const face = font.sans();

    for ('!'..'~' + 1) |code| {

        const glyph = face.lookup(@intCast(code));

        try std.testing.expect(glyph != 0);
        try std.testing.expect(face.render(glyph, 40 / face.units, 0.5) != null);

    }

    try std.testing.expectEqual(null, face.render(face.lookup(' '), 40 / face.units, 0));

    const letter = face.render(face.lookup('H'), 64 / face.units, 0).?;
    const center = letter.width / 2;

    for (letter.coverage) |cell| try std.testing.expect(cell >= 0 and cell <= 1);
    try std.testing.expect(letter.coverage[letter.height / 4 * letter.width + center] < 0.01);
    try std.testing.expect(letter.coverage[letter.height / 2 * letter.width + center] > 0.99);
    try std.testing.expect(std.mem.indexOfScalar(f32, letter.coverage[letter.height / 4 * letter.width ..][0..letter.width], 1) != null);
    try std.testing.expect(letter.top < -40 and letter.top > -50);

}

test "canvas clips fills, rounds corners, and blits only the overlap" {

    var pixels = [_]u32{0} ** (32 * 24);
    var target = canvas.Canvas{

        .pixels = &pixels,
        .width = 32,
        .height = 24,

    };

    target.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);

    try std.testing.expectEqual(0xffffff, pixels[12 * 32 + 16]);
    try std.testing.expectEqual(0, pixels[0]);
    try std.testing.expect(pixels[2 * 32 + 31] != 0xffffff);

    var small = [_]u32{0x123456} ** (4 * 4);
    const source = canvas.Canvas{

        .pixels = &small,
        .width = 4,
        .height = 4,

    };

    target.blit(&source, .{

        .x = 30,
        .y = -2,

    }, target.bounds());

    try std.testing.expectEqual(0x123456, pixels[0 * 32 + 30]);
    try std.testing.expectEqual(0x123456, pixels[1 * 32 + 31]);
    try std.testing.expect(pixels[2 * 32 + 30] != 0x123456);

    target.fill(target.bounds(), 0xffffff);
    target.label(font.sans(), "Hi", 16, target.bounds(), 0x000000, .center);

    try std.testing.expect(std.mem.indexOfScalar(u32, &pixels, 0x000000) != null);

}
