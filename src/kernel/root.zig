const boot = @import("../boot/info.zig");
const Log = @import("../debug/log.zig").Log;

pub fn start(info: *const boot.Info, log: Log) void {

    if (info.version != 1 or info.memory.len == 0) @panic("Invalid boot information");

    log.line("start");
    log.decimal("regions", info.memory.len);
    log.hex("image", info.image.base);
    log.hex("stack", info.stack.base);

    if (info.acpi_rsdp) |address| {

        log.hex("acpi", address);

    } else {

        log.line("acpi unavailable");

    }

    if (info.framebuffer) |framebuffer| {

        const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
        const rows = @min(framebuffer.height, 24);

        for (0..rows) |y| {

            for (0..framebuffer.width) |x| {

                pixels[y * framebuffer.stride + x] = framebuffer.green_mask;

            }

        }

        log.line("framebuffer ready");

    } else {

        log.line("framebuffer unavailable");

    }

    log.line("ready");

}
