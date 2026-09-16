pub inline fn out(port: u16, value: u8) void {

    asm volatile ("outb %[value], %[port]" : : [value] "{al}" (value), [port] "{dx}" (port), : .{ .memory = true, });

}

pub inline fn in(port: u16) u8 {

    return asm volatile ("inb %[port], %[value]" : [value] "={al}" (-> u8), : [port] "{dx}" (port), : .{ .memory = true, });

}

pub fn halt() noreturn {

    asm volatile ("cli" ::: .{

        .memory = true,

    });

    while (true) {

        asm volatile ("hlt");

    }

}

pub fn interruptsEnabled() bool {

    const flags = asm volatile ("pushfq; popq %[flags]" : [flags] "=r" (-> usize), );
    return flags & (1 << 9) != 0;

}

pub fn stackPointer() usize {

    return asm volatile ("movq %%rsp, %[stack]" : [stack] "=r" (-> usize), );

}

pub extern fn enter(info: *const anyopaque, stack_top: usize, entry: *const fn (*const anyopaque) callconv(.c) noreturn) callconv(.c) noreturn;

pub fn readMsr(index: u32) u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [index] "{ecx}" (index),
    );

    return (@as(u64, high) << 32) | low;

}

pub fn writeMsr(index: u32, value: u64) void {

    asm volatile ("wrmsr" : : [index] "{ecx}" (index), [low] "{eax}" (@as(u32, @truncate(value))), [high] "{edx}" (@as(u32, @truncate(value >> 32))), : .{

        .memory = true,

    });

}

pub fn relax() void {

    asm volatile ("pause");

}

pub fn disable() void {

    asm volatile ("cli" ::: .{

        .memory = true,

    });

}

pub fn ticks() u64 {

    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdtsc" : [low] "={eax}" (low), [high] "={edx}" (high), );

    return (@as(u64, high) << 32) | low;

}

pub fn features() void {

    const cr0 = asm volatile ("mov %%cr0, %[value]" : [value] "=r" (-> usize), );

    asm volatile ("mov %[value], %%cr0" : : [value] "r" ((cr0 & ~@as(usize, 12)) | 0x10002), : .{ .memory = true, });

    const cr4 = asm volatile ("mov %%cr4, %[value]"
        : [value] "=r" (-> usize),
    );

    // FXSAVE owns the complete enabled user floating-point state.
    asm volatile ("mov %[value], %%cr4" : : [value] "r" ((cr4 | 0x600) & ~@as(usize, 0x70000)), : .{ .memory = true, });

    writeMsr(0xc0000080, readMsr(0xc0000080) | (1 << 11));
    if (readMsr(0x277) != 0x0007040600070406) @panic("Unsupported firmware PAT layout");

    asm volatile ("fninit");
    const mxcsr: u32 = 0x1f80;

    asm volatile ("ldmxcsr (%[value])" : : [value] "r" (&mxcsr), : .{ .memory = true, });

}
