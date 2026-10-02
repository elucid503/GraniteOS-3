const std = @import("std");

const font = @import("font.zig");
const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const node = @import("node.zig");
const text = @import("text.zig");

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

test "font kerns letter pairs from its table and measures with them" {

    const face = font.sans();
    const scale = 40 / face.units;

    try std.testing.expect(face.pairs.len > 0);
    try std.testing.expect(face.kerning(face.lookup('A'), face.lookup('V')) < 0);
    try std.testing.expect(face.kerning(face.lookup('T'), face.lookup('o')) < 0);
    try std.testing.expectEqual(0, face.kerning(face.lookup('H'), face.lookup('H')));
    try std.testing.expect(face.measure("AV", scale) < face.measure("A", scale) + face.measure("V", scale));
    try std.testing.expectEqual(face.measure("HH", scale), 2 * face.measure("H", scale));

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

test "flex layout grows, centres, and stretches children and reports what moved" {

    var fixed = node.Node{

        .style = .{

            .width = 40,
            .height = 10,

        },

    };
    var grown = node.Node{

        .style = .{

            .grow = 1,

        },

    };
    var hidden = node.Node{

        .hidden = true,

    };
    var row = node.Node{

        .style = .{

            .direction = .row,
            .gap = 4,
            .items = .center,
            .padding = .all(2),

        },
        .content = .{

            .box = &.{ &fixed, &hidden, &grown },

        },

    };
    var damage = canvas.Rect{};

    row.arrange(.{

        .width = 100,
        .height = 30,

    }, &damage);

    try std.testing.expectEqual(canvas.Rect{ .x = 2, .y = 10, .width = 40, .height = 10 }, fixed.rect);
    try std.testing.expectEqual(canvas.Rect{ .x = 46, .y = 15, .width = 52, .height = 0 }, grown.rect);
    try std.testing.expectEqual(canvas.Rect{}, hidden.rect);
    try std.testing.expectEqual(canvas.Rect{ .width = 100, .height = 30 }, damage);

    var column = node.Node{

        .style = .{

            .justify = .center,

        },
        .content = .{

            .box = &.{&fixed},

        },

    };

    damage = .{};
    column.arrange(.{

        .width = 100,
        .height = 30,

    }, &damage);

    try std.testing.expectEqual(canvas.Rect{ .y = 10, .width = 40, .height = 10 }, fixed.rect);

}

test "text wraps after spaces and moves the caret between wrapped lines" {

    const face = font.sans();
    const width: i32 = @intFromFloat(face.measure("hello ", 20 / face.units) + 1);
    var lines = text.Lines.init(face, "hello world\nx", 20, width);

    try std.testing.expectEqual(text.Line{ .start = 0, .end = 6 }, lines.next().?);
    try std.testing.expectEqual(text.Line{ .start = 6, .end = 11 }, lines.next().?);
    try std.testing.expectEqual(text.Line{ .start = 12, .end = 13 }, lines.next().?);
    try std.testing.expectEqual(null, lines.next());

    var bytes = "hello world\nx".*;
    var edit = text.Text{

        .buffer = &bytes,
        .length = bytes.len,
        .caret = 1,

    };

    try std.testing.expect(edit.vertical(face, 20, width, 1));
    try std.testing.expectEqual(7, edit.caret);
    try std.testing.expect(edit.vertical(face, 20, width, 1));
    try std.testing.expectEqual(13, edit.caret);
    try std.testing.expect(!edit.vertical(face, 20, width, 1));

}

test "recorded commands replay exactly as direct drawing and survive hostile bytes" {

    var bytes: [1024]u8 align(4) = undefined;
    var list = draw.List{

        .bytes = &bytes,
        .width = 32,
        .height = 24,

    };

    list.fill(list.bounds(), 0x202020);
    list.limit = .{

        .x = 2,
        .width = 28,
        .height = 20,

    };
    list.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);
    list.label("Hi", 16, list.bounds(), 0x000000, .center);

    var direct = [_]u32{0} ** (32 * 24);
    var replayed = [_]u32{0} ** (32 * 24);
    var expected = canvas.Canvas{

        .pixels = &direct,
        .width = 32,
        .height = 24,

    };
    var actual = canvas.Canvas{

        .pixels = &replayed,
        .width = 32,
        .height = 24,

    };

    expected.fill(expected.bounds(), 0x202020);
    expected.limit = list.limit;
    expected.round(.{

        .x = -4,
        .y = 2,
        .width = 40,
        .height = 20,

    }, 8, 0xffffff);
    expected.label(font.sans(), "Hi", 16, expected.bounds(), 0x000000, .center);
    draw.replay(&actual, list.commands(), .{}, actual.bounds());

    try std.testing.expectEqualSlices(u32, &direct, &replayed);

    // Truncated, oversized, and garbage commands are skipped rather than trusted.
    var commands = draw.iterate(list.commands()[0 .. list.length - 3]);
    var count: usize = 0;

    while (commands.next()) |_| count += 1;
    try std.testing.expectEqual(2, count);

    @memset(bytes[4..8], 0xff);
    commands = draw.iterate(list.commands());
    try std.testing.expectEqual(null, commands.next());

}

test "UTF-8 text decodes leniently, keeps the caret on whole characters, and draws accented letters" {

    const face = font.sans();
    var characters = font.decode("a\u{e9}\xff");

    try std.testing.expectEqual('a', characters.next().?);
    try std.testing.expectEqual(0xe9, characters.next().?);
    try std.testing.expectEqual(0xfffd, characters.next().?);
    try std.testing.expectEqual(null, characters.next());

    // Accented letters are composites of a base letter and a mark, so they ink more than the plain letter.
    const plain = face.render(face.lookup('e'), 40 / face.units, 0).?;
    var ink: f32 = 0;

    for (plain.coverage) |cell| ink += cell;

    const accented = face.render(face.lookup(0xe9), 40 / face.units, 0).?;
    var accented_ink: f32 = 0;

    for (accented.coverage) |cell| accented_ink += cell;
    try std.testing.expect(accented_ink > ink * 1.05);

    var bytes = "\u{e9}\u{e9}\n\u{e9}\u{e9}".*;
    var edit = text.Text{

        .buffer = &bytes,
        .length = bytes.len,
        .caret = 2,

    };

    try std.testing.expect(edit.vertical(face, 20, 1000, 1));
    try std.testing.expectEqual(7, edit.caret);

}
