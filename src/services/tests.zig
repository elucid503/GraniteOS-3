const std = @import("std");

const policy = @import("policy.zig");
const line = @import("../apps/line.zig");
const protocol = @import("../api/protocol.zig");
const volume = @import("volume.zig");

test "restart policy backs off and stops after three replacements" {

    var entry = policy.Entry{

    };

    try std.testing.expect(entry.ready(0));

    entry.id = 42;

    try std.testing.expect(!entry.ready(100));
    entry.failed(100);

    try std.testing.expectEqual(0, entry.id);
    try std.testing.expect(!entry.ready(109));
    try std.testing.expect(entry.ready(110));
    entry.failed(110);

    try std.testing.expect(!entry.ready(129));
    try std.testing.expect(entry.ready(130));
    entry.failed(130);

    try std.testing.expect(!entry.ready(169));
    try std.testing.expect(entry.ready(170));
    entry.failed(170);

    try std.testing.expect(entry.offline);
    try std.testing.expect(!entry.ready(std.math.maxInt(u64)));

}

test "terminal editing handles CRLF erase cancel and full input" {

    var input = line.Line{

    };

    try std.testing.expectEqual(.none, input.push(8));
    try std.testing.expectEqual(.echo, input.push('a'));
    try std.testing.expectEqual(.echo, input.push('b'));
    try std.testing.expectEqual(.erase, input.push(127));
    try std.testing.expectEqualStrings("a", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    try std.testing.expectEqual(.none, input.push('\n'));
    input.reset();

    try std.testing.expectEqual(.cancel, input.push(3));
    try std.testing.expectEqual(0, input.len);

    for (0..input.bytes.len) |_| try std.testing.expectEqual(.echo, input.push('x'));

    try std.testing.expectEqual(.bell, input.push('x'));
    try std.testing.expectEqual(256, input.len);
    try std.testing.expectEqual(.erase, input.push(8));
    try std.testing.expectEqual(.echo, input.push('y'));

}

test "terminal editing moves the cursor and recalls history" {

    var input = line.Line{

    };

    for ("echo hed") |byte| _ = input.push(byte);
    for ("\x1b[D") |byte| _ = input.push(byte);

    try std.testing.expectEqual(.redraw, input.push('l'));
    try std.testing.expectEqualStrings("echo held", input.text());

    for ("\x1b[1~") |byte| _ = input.push(byte);
    for ("\x1b[3~") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("cho held", input.text());
    try std.testing.expectEqual(.redraw, input.push(5));
    try std.testing.expectEqual(.redraw, input.push(23));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.submit, input.push('\r'));
    input.reset();

    for ("id\rid\r") |byte| {

        if (input.push(byte) == .submit) input.reset();

    }

    try std.testing.expectEqual(2, input.total);
    _ = input.push('x');
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("id", input.text());
    try std.testing.expectEqual(.redraw, input.push(16));
    try std.testing.expectEqualStrings("cho ", input.text());
    try std.testing.expectEqual(.bell, input.push(16));
    for ("\x1b[B\x1b[B") |byte| _ = input.push(byte);

    try std.testing.expectEqualStrings("x", input.text());
    try std.testing.expectEqual(.none, input.push(14));

}

test "service protocol preserves operation and payload boundaries" {

    const value = std.math.maxInt(u56);
    const message = protocol.pack(.ping, value);

    try std.testing.expectEqual(.ping, protocol.operation(message));
    try std.testing.expectEqual(value, protocol.value(message));
    try std.testing.expectEqual(@as(protocol.Operation, @enumFromInt(255)), protocol.operation(255));

}

const Memory = struct {

    bytes: []u8,

    pub fn read(self: Memory, lba: u64, out: []u8) volume.Error!void {

        if (lba * 512 + out.len > self.bytes.len) return error.Device;
        @memcpy(out, self.bytes[lba * 512 ..][0..out.len]);

    }

    pub fn write(self: Memory, lba: u64, bytes: []const u8) volume.Error!void {

        if (lba * 512 + bytes.len > self.bytes.len) return error.Device;
        @memcpy(self.bytes[lba * 512 ..][0..bytes.len], bytes);

    }

    pub fn flush(_: Memory) volume.Error!void {

    }

};

test "volume persists fragmented files and directories and reclaims every block" {

    const allocator = std.testing.allocator;
    const disk = Memory{

        .bytes = try allocator.alloc(u8, 8 << 20),

    };
    defer allocator.free(disk.bytes);
    @memset(disk.bytes, 0);

    var sector: [512]u8 = undefined;
    const capacity = disk.bytes.len / 512;

    try std.testing.expectEqual(null, try volume.find(disk, &sector, capacity));
    @memcpy(disk.bytes[512..520], "EFI PART");
    std.mem.writeInt(u64, disk.bytes[512 + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 80 ..][0..4], 8, .little);
    std.mem.writeInt(u32, disk.bytes[512 + 84 ..][0..4], 128, .little);

    const record = disk.bytes[1024 + 5 * 128 ..][0..128];

    @memcpy(record[0..16], &volume.partition);
    std.mem.writeInt(u64, record[32..40], 64, .little);
    std.mem.writeInt(u64, record[40..48], capacity - 1, .little);

    const range = (try volume.find(disk, &sector, capacity)).?;

    try std.testing.expectEqual(64, range.first);

    const mounted = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(mounted);

    try std.testing.expect(try mounted.mount(disk, range));
    const initial = mounted.usage();

    try mounted.create("/docs", .directory);
    try mounted.create("/docs/note", .file);
    try mounted.write("/docs/note", 0, "hello");
    try std.testing.expectError(error.Exists, mounted.create("/docs", .directory));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/note/child", .file));
    try std.testing.expectError(error.Missing, mounted.write("/nowhere", 0, "x"));
    try std.testing.expectError(error.Invalid, mounted.create("/docs/..", .file));

    try mounted.create("/a", .file);
    try mounted.create("/b", .file);

    var block: [volume.block_size]u8 = undefined;

    // Interleaving two files defeats contiguous growth, forcing continuation extent pages.
    for (0..600) |index| {

        @memset(&block, @truncate(index));
        try mounted.write("/a", index * block.len, &block);
        @memset(&block, @truncate(index +% 128));
        try mounted.write("/b", index * block.len, &block);

    }

    try mounted.write("/docs/note", 10000, "!");

    const again = try allocator.create(volume.Volume(Memory));
    defer allocator.destroy(again);

    try std.testing.expect(!try again.mount(disk, range));

    var out: [volume.block_size]u8 = undefined;

    try std.testing.expectEqual(out.len, try again.read("/docs/note", 0, &out));
    try std.testing.expectEqualStrings("hello", out[0..5]);
    try std.testing.expect(std.mem.allEqual(u8, out[5..], 0));
    try std.testing.expectEqual(11, try again.read("/docs/note", 9990, &out));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 10 ++ [_]u8{'!'}), out[0..11]);
    try std.testing.expectEqual(0, try again.read("/docs/note", 10001, &out));

    for ([_]usize{ 0, 253, 254, 255, 598 }) |index| {

        try std.testing.expectEqual(200, try again.read("/a", index * block.len + 4000, out[0..200]));
        try std.testing.expectEqual(@as(u8, @truncate(index)), out[0]);
        try std.testing.expectEqual(@as(u8, @truncate(index + 1)), out[199]);

    }

    try std.testing.expectEqual(10001, (try again.entry("/docs", 0)).?.size);
    try std.testing.expectEqualStrings("b", (try again.entry("/", 2)).?.name);
    try std.testing.expectEqual(null, try again.entry("/", 3));

    try std.testing.expectError(error.Busy, again.remove("/docs"));
    try again.remove("/a");
    try again.create("/b", .file);
    try std.testing.expectEqual(0, try again.read("/b", 0, &out));
    try again.remove("/docs/note");
    try again.remove("/docs");
    try again.remove("/b");
    try std.testing.expectEqual(null, try again.entry("/", 0));
    try std.testing.expectEqual(initial.free, again.usage().free);

}
