pub inline fn out(port: u16, value: u8) void {

    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{

            .memory = true,

        });

}

pub inline fn in(port: u16) u8 {

    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{

            .memory = true,

        });

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

    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> usize),
    );
    return flags & (1 << 9) != 0;

}

pub fn stackPointer() usize {

    return asm volatile ("movq %%rsp, %[stack]"
        : [stack] "=r" (-> usize),
    );

}

pub extern fn enter(info: *const anyopaque, stack_top: usize, entry: *const fn (*const anyopaque) callconv(.c) noreturn) callconv(.c) noreturn;
