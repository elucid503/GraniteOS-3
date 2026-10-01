const cpu = @import("../../arch/x86/cpu.zig");

pub const Bar = struct {

    base: u64,
    size: u64,

};

/// Finds the first function of `class` (class, subclass, interface) and enables its memory decoding and bus mastering.
pub fn find(class: u24, index: u3) ?Bar {

    // ponytail: brute-force scan of every bus; walk bridges if boot time matters.
    for (0..256) |bus| {

        for (0..32) |device| {

            const first = address(bus, device, 0);
            if (read(first, 0) & 0xffff == 0xffff) continue;

            const functions: usize = if (read(first, 0x0c) & 0x800000 != 0) 8 else 1;

            for (0..functions) |function| {

                const at = address(bus, device, function);
                if (read(at, 0) & 0xffff == 0xffff or read(at, 8) >> 8 != class) continue;

                return bar(at, index);

            }

        }

    }

    return null;

}

fn bar(at: u32, index: u3) ?Bar {

    const offset = 0x10 + @as(u8, index) * 4;
    const command = read(at, 4) & 0xffff;
    const original = read(at, offset);

    if (original & 7 != 0 or original & ~@as(u32, 0xf) == 0) return null;

    // Sizing a BAR while it decodes would briefly move the device.
    write(at, 4, command & ~@as(u32, 2));
    write(at, offset, 0xffffffff);

    const size = ~(read(at, offset) & ~@as(u32, 0xf)) +% 1;

    write(at, offset, original);
    write(at, 4, command | 0x406);
    if (size == 0) return null;

    return .{

        .base = original & ~@as(u32, 0xf),
        .size = size,

    };

}

fn address(bus: usize, device: usize, function: usize) u32 {

    return @intCast(0x80000000 | bus << 16 | device << 11 | function << 8);

}

fn read(at: u32, offset: u8) u32 {

    cpu.out32(0xcf8, at | offset);

    return cpu.in32(0xcfc);

}

fn write(at: u32, offset: u8, value: u32) void {

    cpu.out32(0xcf8, at | offset);
    cpu.out32(0xcfc, value);

}
