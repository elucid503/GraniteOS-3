pub const Request = extern struct {

    number: u64,
    first: u64 = 0,
    second: u64 = 0,
    third: u64 = 0,

};

pub const Call = enum(u64) {

    yield = 0,
    exit = 1,
    send = 2,
    receive = 3,
    write = 4,
    allocate = 5,
    release = 6,
    port = 7,
    map = 8,
    reboot = 9,
    ticks = 10,
    identity = 11,
    _,

};

pub const Status = enum(u64) {

    success = 0,
    denied = 1,
    invalid = 2,
    missing = 3,
    deadlock = 4,
    exhausted = 5,

};
