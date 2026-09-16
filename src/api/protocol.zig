pub const version = 1;
pub const invalid = ~@as(u64, 0);
pub const empty = invalid - 1;

pub const Operation = enum(u8) {

    hello,
    lookup,
    ping,
    crash,
    write,
    read,
    passed,
    failed,
    stall,
    restart,
    relaunch,
    _,

};

pub fn pack(kind: Operation, payload: u56) u64 {

    return @as(u64, payload) << 8 | @intFromEnum(kind);

}

pub fn operation(message: u64) Operation {

    return @enumFromInt(@as(u8, @truncate(message)));

}

pub fn value(message: u64) u56 {

    return @intCast(message >> 8);

}
