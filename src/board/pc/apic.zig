const cpu = @import("../../arch/x86/cpu.zig");

pub var base: usize = 0xfee00000;
pub var timer_count: u32 = 0;
pub var tsc_per_ms: u64 = 0;

pub fn read(offset: usize) u32 {

    return @as(*volatile u32, @ptrFromInt(base + offset)).*;

}

pub fn write(offset: usize, value: u32) void {

    @as(*volatile u32, @ptrFromInt(base + offset)).* = value;
    _ = read(0x20);

}

pub fn id() u32 {

    return read(0x20) >> 24;

}

pub fn init() void {

    const msr = cpu.readMsr(0x1b);

    if (msr & 0x400 != 0) @panic("x2APIC firmware mode unsupported");
    cpu.writeMsr(0x1b, base | (msr & 0x100) | 0x800);

    write(0x80, 0);
    write(0xf0, 0x1ff);

    write(0x320, 1 << 16);
    write(0x350, 1 << 16);
    write(0x360, 1 << 16);
    write(0x370, 1 << 16);

    write(0x280, 0);
    write(0xb0, 0);

}

pub fn calibrate() void {

    cpu.out(0x21, 0xff);
    cpu.out(0xa1, 0xff);

    const speaker = cpu.in(0x61);

    cpu.out(0x61, speaker & ~@as(u8, 3));
    cpu.out(0x43, 0xb0);
    cpu.out(0x42, 0x9c);
    cpu.out(0x42, 0x2e);

    write(0x3e0, 3);
    write(0x380, 0xffffffff);

    const start = cpu.ticks();

    cpu.out(0x61, (speaker & ~@as(u8, 2)) | 1);

    var attempts: usize = 0;

    while (cpu.in(0x61) & 0x20 == 0) : (attempts += 1) {

        if (attempts == 100000000) @panic("PIT calibration timeout");
        cpu.relax();

    }

    tsc_per_ms = (cpu.ticks() - start) / 10;
    timer_count = 0xffffffff - read(0x390);

    cpu.out(0x61, speaker);

    if (timer_count < 100 or tsc_per_ms == 0) @panic("Invalid timer calibration");

}

pub fn timer() void {

    write(0x3e0, 3);
    write(0x320, 32 | (1 << 17));
    write(0x380, timer_count);

}

pub fn delay(milliseconds: u64) void {

    const start = cpu.ticks();

    while (cpu.ticks() -% start < milliseconds * tsc_per_ms) cpu.relax();

}

pub fn send(target: u32, command: u32) void {

    const start = cpu.ticks();

    while (read(0x300) & (1 << 12) != 0) {

        if (cpu.ticks() -% start > tsc_per_ms * 1000) @panic("APIC delivery timeout");
        cpu.relax();

    }

    write(0x310, target << 24);
    write(0x300, command);

}

pub fn stopOthers() void {

    write(0x300, 0xc0400);

}
