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
    try std.testing.expectEqual(.character, input.push('a'));
    try std.testing.expectEqual(.character, input.push('b'));
    try std.testing.expectEqual(.erase, input.push(127));
    try std.testing.expectEqualStrings("a", input.bytes[0..input.len]);
    try std.testing.expectEqual(.submit, input.push('\r'));
    try std.testing.expectEqual(.none, input.push('\n'));
    try std.testing.expectEqual(.cancel, input.push(3));
    try std.testing.expectEqual(0, input.len);

    for (0..input.bytes.len) |_| try std.testing.expectEqual(.character, input.push('x'));

    try std.testing.expectEqual(.full, input.push('x'));
    try std.testing.expectEqual(256, input.len);
    try std.testing.expectEqual(.erase, input.push(8));
    try std.testing.expectEqual(.character, input.push('y'));

}

test "service protocol preserves operation and payload boundaries" {

    const value = std.math.maxInt(u56);
    const message = protocol.pack(.ping, value);

    try std.testing.expectEqual(.ping, protocol.operation(message));
    try std.testing.expectEqual(value, protocol.value(message));
    try std.testing.expectEqual(@as(protocol.Operation, @enumFromInt(255)), protocol.operation(255));

}
