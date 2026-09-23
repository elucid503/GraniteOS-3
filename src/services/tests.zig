const std = @import("std");

const policy = @import("policy.zig");
const line = @import("../apps/line.zig");
const protocol = @import("../api/protocol.zig");

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
