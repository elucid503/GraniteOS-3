const cpu = @import("../../arch/x86/cpu.zig");

const port: u16 = 0x3f8;
var present = false;

pub fn init() void {

    cpu.out(port + 1, 0);
    cpu.out(port + 3, 0x80);
    cpu.out(port, 1);
    cpu.out(port + 1, 0);
    cpu.out(port + 3, 3);
    cpu.out(port + 2, 0xc7);
    cpu.out(port + 4, 3);
    cpu.out(port + 7, 0x5a);
    present = cpu.in(port + 7) == 0x5a and cpu.in(port + 5) != 0xff;

}

pub fn write(bytes: []const u8) void {

    if (!present) return;

    for (bytes) |byte| {

        if (byte == '\n') send('\r'); // nice to allow us to not have to manually add carriage returns to our strings
        send(byte);

    }

}

fn send(byte: u8) void {

    if (!present) return;

    for (0..100_000) |_| {

        if (cpu.in(port + 5) & 0x20 != 0) {

            cpu.out(port, byte);

            return;

        }

        asm volatile ("pause");

    }

    present = false;

}
