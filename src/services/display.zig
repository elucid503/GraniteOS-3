const std = @import("std");

const canvas = @import("canvas.zig");
const font = @import("font.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const label = "Hello from GraniteOS 3";

var scene: canvas.Canvas = undefined;
var frame: [*]u32 = undefined;
var stride: usize = 0;
var pointer: canvas.Point = undefined;

var input: u64 = 0;
var retry: u64 = 0;
var greeted = false;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, geometry: usize, shifts: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.mmio) or !api.permits(.memory) or api.permits(.ports) or api.permits(.management)) api.exit(2);

    const width = geometry & 0xffff;
    const height = geometry >> 16 & 0xffff;

    stride = geometry >> 32;
    frame = @ptrFromInt(pages(.map, base, stride * height * 4));
    scene = .{

        .pixels = @as([*]u32, @ptrFromInt(pages(.allocate, 0, width * height * 4)))[0 .. width * height],
        .width = width,
        .height = height,

        .shifts = .{ @intCast(shifts & 0xff), @intCast(shifts >> 8 & 0xff), @intCast(shifts >> 16 & 0xff) },

    };
    pointer = .{

        .x = @intCast(width / 2),
        .y = @intCast(height / 2),

    };

    paint();
    scene.present(frame, stride, .{

        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),

    }, pointer);
    api.log("display: ready\n");

    while (true) {

        const request = api.receive(false) catch {

            // The supervisor blocks on our first reply, so asking it for input any sooner would deadlock.
            if (greeted) track();
            api.sleep(1);
            continue;

        };

        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
            else => protocol.invalid,

        };

        api.reply(request, result) catch {

        };
        greeted = true;

    }

}

fn paint() void {

    const face = font.Font.init(@embedFile("fonts/NimbusSans-Regular.ttf")) catch api.exit(3);
    const scale = 32 / face.units;
    const span: i32 = @intFromFloat(@ceil(face.measure(label, scale)));
    const box = canvas.Rect{

        .x = @divTrunc(@as(i32, @intCast(scene.width)) - span - 96, 2),
        .y = @divTrunc(@as(i32, @intCast(scene.height)) - 120, 2),
        .width = span + 96,
        .height = 120,

    };

    scene.fill(.{

        .x = 0,
        .y = 0,
        .width = @intCast(scene.width),
        .height = @intCast(scene.height),

    }, 0x1f2933);
    scene.fill(.{

        .x = box.x - 1,
        .y = box.y - 1,
        .width = box.width + 2,
        .height = box.height + 2,

    }, 0x52606d);
    scene.fill(box, 0xf5f7fa);

    const baseline = box.y + @divTrunc(box.height + @as(i32, @intFromFloat(@as(f32, @floatFromInt(face.ascent + face.descent)) * scale)), 2);

    scene.text(&face, label, scale, @floatFromInt(box.x + 48), baseline, 0x1f2933);

}

/// Moves the pointer by the motion since the last poll, re-presenting only the two areas it covered.
fn track() void {

    if (input == 0) {

        if (api.ticks() < retry) return;
        retry = api.ticks() + 100;
        input = api.lookup(0, .input) catch return;

    }

    const motion = api.call(input, protocol.pack(.read, 0)) catch {

        input = 0;
        return;

    };

    const dx: i16 = @bitCast(@as(u16, @truncate(motion)));
    const dy: i16 = @bitCast(@as(u16, @truncate(motion >> 16)));

    if (motion == protocol.invalid or dx == 0 and dy == 0) return;

    const previous = pointer;

    pointer = .{

        .x = std.math.clamp(pointer.x + dx, 0, @as(i32, @intCast(scene.width)) - 1),
        .y = std.math.clamp(pointer.y - dy, 0, @as(i32, @intCast(scene.height)) - 1),

    };
    scene.present(frame, stride, canvas.cursor(previous), pointer);
    scene.present(frame, stride, canvas.cursor(pointer), pointer);

}

/// Maps `size` bytes as consecutive pages starting at `base`, through `.map` (device memory) or `.allocate` (fresh RAM).
fn pages(call: api.abi.Call, base: usize, size: usize) usize {

    const page = base & ~@as(usize, 4095);
    const first = (api.checked(api.raw(call, page, 0, 0)) catch api.exit(3)).first;
    var offset: usize = 4096;

    while (offset < base + size - page) : (offset += 4096) {

        const next = api.checked(api.raw(call, page + offset, 0, 0)) catch api.exit(3);
        if (next.first != first + offset) api.exit(3);

    }

    return first + base % 4096;

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
