const std = @import("std");

pub const abi = @import("abi");
pub const protocol = @import("protocol.zig");
pub const Terminal = @import("terminal.zig").Terminal;
pub const Request = abi.Request;
pub const ApiError = error{ Denied, Invalid, Missing, Deadlock, Exhausted, Timeout, Busy };
var environment: ?*const abi.Environment = null;

extern fn invoke(request: *Request) callconv(.c) void;

pub const panic = std.debug.FullPanic(fatal);

pub fn start(context: *const abi.Environment, expected: abi.Layer) void {

    if (context.version != 1 or context.length > abi.permission_count or context.layer != expected) exit(97);
    environment = context;

}

pub fn permissions() []const abi.Permission {

    const context = environment orelse exit(97);

    return context.permissions[0..context.length];

}

pub fn permits(permission: abi.Permission) bool {

    for (permissions()) |entry| {

        if (entry == permission) return true;

    }

    return false;

}

pub fn raw(number: abi.Call, first: u64, second: u64, third: u64) Request {

    var request = Request{

        .number = @intFromEnum(number),
        .first = first,
        .second = second,
        .third = third,

    };

    invoke(&request);

    return request;

}

pub fn checked(request: Request) ApiError!Request {

    return switch (request.number) {

        0 => request,
        1 => error.Denied,
        3 => error.Missing,
        4 => error.Deadlock,
        5 => error.Exhausted,
        6 => error.Timeout,
        7 => error.Busy,
        else => error.Invalid,

    };

}

/// A timeout or disconnect does not guarantee the peer performed no work.
pub fn call(peer: u64, message: u64) ApiError!u64 {

    return (try checked(raw(.call, peer, message, 100))).first;

}

pub fn receive(block: bool) ApiError!Request {

    return try checked(raw(.receive, if (block) 0 else 1, 0, 0));

}

pub fn reply(request: Request, message: u64) ApiError!void {

    _ = try checked(raw(.reply, request.first, request.third, message));

}

pub fn lookup(supervisor: u64, image: abi.Image) ApiError!u64 {

    const id = try call(supervisor, protocol.pack(.lookup, @intCast(@intFromEnum(image))));
    if (id == 0 or id == protocol.invalid) return error.Missing;

    return id;

}

pub fn sleep(duration: u64) void {

    _ = raw(.sleep, duration, 0, 0);

}

pub fn ticks() u64 {

    return raw(.ticks, 0, 0, 0).first;

}

pub fn identity() u64 {

    return raw(.identity, 0, 0, 0).first;

}

pub fn log(bytes: []const u8) void {

    _ = raw(.write, @intFromPtr(bytes.ptr), bytes.len, 0);

}

pub fn exit(status: u64) noreturn {

    _ = raw(.exit, status, 0, 0);

    while (true) asm volatile ("ud2");

}

fn fatal(_: []const u8, _: ?usize) noreturn {

    exit(98);

}
