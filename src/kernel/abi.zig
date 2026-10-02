pub const Request = extern struct {

    number: u64,
    first: u64 = 0,
    second: u64 = 0,
    third: u64 = 0,
    fourth: u64 = 0,
    fifth: u64 = 0,

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
    dma = 20,
    fetch = 21,
    store = 22,
    shutdown = 23,
    assign = 24,
    variable = 25,
    share = 26,
    lend = 27,
    attach = 28,
    detach = 29,
    alive = 30,
    physical = 31,
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
    storage,
    files,
    accounts,
    install,
    display,
    input,
    login,
    notes,

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
    power,
    diagnostics,
    management,
    dma,
    accounts,
    firmware,

};

/// Who a process acts for; the kernel attaches the sender's identity to every message as `fifth`.
pub const Identity = packed struct(u64) {

    user: u32,
    admin: bool = false,
    reserved: u31 = 0,

};

pub const system = Identity{

    .user = 0,

};

pub const nobody = Identity{

    .user = 0xffffffff,

};

pub const permission_count = @typeInfo(Permission).@"enum".fields.len;

/// A PCI base address range granted to a driver service.
pub const Bar = extern struct {

    base: u64 = 0,
    size: u64 = 0,
    ports: bool = false,

};

pub const Environment = extern struct {

    version: u64 = 1,
    layer: Layer,
    length: u64,
    permissions: [permission_count]Permission,

    /// The PCI function a driver service was granted, by BAR index; unused entries are empty.
    bars: [6]Bar = [_]Bar{.{}} ** 6,

};
