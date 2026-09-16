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
    call = 12,
    reply = 13,
    spawn = 14,
    inspect = 15,
    connect = 16,
    sleep = 17,
    stop = 18,
    owner = 19,
    _,

};

pub const Status = enum(u64) {

    success = 0,
    denied = 1,
    invalid = 2,
    missing = 3,
    deadlock = 4,
    exhausted = 5,
    timeout = 6,
    busy = 7,

};

pub const Image = enum(u64) {

    serial,
    shell,
    helper,
    client,

};

pub const Layer = enum(u64) {

    application,
    service,

};

pub const Permission = enum(u32) {

    ipc,
    memory,
    time,
    ports,
    mmio,
    reboot,
    diagnostics,
    management,

};

pub const permission_count = @typeInfo(Permission).@"enum".fields.len;

pub const Environment = extern struct {

    version: u64 = 1,
    layer: Layer,
    length: u64,
    permissions: [permission_count]Permission,

};
