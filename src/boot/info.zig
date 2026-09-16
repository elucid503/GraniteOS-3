pub const MemoryKind = enum {

    reserved,
    available,
    loader,
    firmware,
    runtime,
    acpi,
    persistent,
    mmio,
    unusable,

};

pub const Region = struct {

    base: u64,
    size: u64,
    kind: MemoryKind,

};

pub const Framebuffer = struct {

    base: u64,
    size: u64,
    width: u32,
    height: u32,
    stride: u32,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,

};

pub const Info = struct {

    version: u32 = 2,
    memory: []const Region,
    image: Region,
    stack: Region,
    framebuffer: ?Framebuffer,
    acpi_rsdp: ?u64,
    trampoline: u64 = 0,

};
