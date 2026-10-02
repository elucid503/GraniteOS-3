const std = @import("std");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const data = 0x60;
const control = 0x64;

var packet: [3]u8 = undefined;
var received: usize = 0;
var moved_x: i32 = 0;
var moved_y: i32 = 0;
var buttons: u8 = 0;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ports) or api.permits(.mmio) or api.permits(.management)) api.exit(2);

    // Polled, so both controller interrupts stay off; the keyboard port stays disabled until keyboard support.
    command(0xad);
    command(0xa7);

    for (0..16) |_| {

        if (input(control) & 1 == 0) break;
        _ = input(data);

    }

    command(0x20);
    const configuration = receive() orelse api.exit(3);

    command(0x60);
    send(configuration & ~@as(u8, 3));
    command(0xa8);

    if (!mouse(0xf6) or !mouse(0xf4)) api.exit(3);
    api.log("input: ready\n");

    while (true) {

        const request = api.receive(true) catch continue;
        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .read => motion(),
            .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
            else => protocol.invalid,

        };

        api.reply(request, result) catch {

        };

    }

}

/// Drains pending mouse packets and returns the motion since the last read: x and y as i16, then the button bits.
fn motion() u64 {

    for (0..64) |_| {

        const status = input(control);
        if (status & 1 == 0) break;

        const byte = input(data);

        // Keyboard bytes are dropped; a first byte without bit 3 means the stream lost sync.
        if (status & 0x20 == 0 or received == 0 and byte & 8 == 0) continue;

        packet[received] = byte;
        received += 1;
        if (received < 3) continue;

        received = 0;
        if (packet[0] & 0xc0 != 0) continue;

        moved_x += @as(i32, packet[1]) - (@as(i32, packet[0] & 0x10) << 4);
        moved_y += @as(i32, packet[2]) - (@as(i32, packet[0] & 0x20) << 3);
        buttons = packet[0] & 7;

    }

    const x: i16 = @intCast(std.math.clamp(moved_x, -32768, 32767));
    const y: i16 = @intCast(std.math.clamp(moved_y, -32768, 32767));

    moved_x = 0;
    moved_y = 0;

    return @as(u64, @as(u16, @bitCast(x))) | @as(u64, @as(u16, @bitCast(y))) << 16 | @as(u64, buttons) << 32;

}

fn mouse(byte: u8) bool {

    command(0xd4);
    send(byte);

    return receive() == 0xfa;

}

fn command(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(control, byte);

}

fn send(byte: u8) void {

    if (!wait(2, 0)) api.exit(3);
    output(data, byte);

}

fn receive() ?u8 {

    return if (wait(1, 1)) input(data) else null;

}

fn wait(mask: u8, value: u8) bool {

    const deadline = api.ticks() + 10;

    while (input(control) & mask != value) {

        if (api.ticks() >= deadline) return false;
        _ = api.raw(.yield, 0, 0, 0);

    }

    return true;

}

fn input(port: u16) u8 {

    const result = api.raw(.port, port, 0, 0);
    if (result.number != 0) api.exit(1);

    return @intCast(result.first);

}

fn output(port: u16, byte: u8) void {

    if (api.raw(.port, port, 1, byte).number != 0) api.exit(1);

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
