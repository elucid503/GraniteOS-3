const std = @import("std");

const svga = @import("svga.zig");
const gpu = @import("gpu.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

// ponytail: fixed 1280x800 on VMware; follow the host window or a settings choice later.
const mode = gui.Rect{

    .width = 1280,
    .height = 800,

};

const arrow = [_]*const [12]u8{

    "X...........",
    "XX..........",
    "XOX.........",
    "XOOX........",
    "XOOOX.......",
    "XOOOOX......",
    "XOOOOOX.....",
    "XOOOOOOX....",
    "XOOOOOOOX...",
    "XOOOOOOOOX..",
    "XOOOOOOOOOX.",
    "XOOOOOOXXXXX",
    "XOOOXOOX....",
    "XOOX.XOOX...",
    "XOX..XOOX...",
    "XX....XOOX..",
    "X.....XOOX..",
    ".......XX...",

};

/// The boot framebuffer, drawn by the CPU with a software pointer.
const Frame = struct {

    pixels: [*]u32,
    stride: usize,

    /// Bit positions of red, green, and blue.
    shifts: [3]u5,

    fn present(self: *Frame, source: *const gui.Canvas, area: gui.Rect) void {

        const visible = area.intersect(source.bounds()) orelse return;
        var line: [256]u32 = undefined;
        var y: usize = @intCast(visible.y);

        while (y < visible.bottom()) : (y += 1) {

            var x: usize = @intCast(visible.x);

            // Composing in RAM writes each device pixel once, so the pointer never flickers.
            while (x < visible.right()) {

                const row = line[0..@min(line.len, @as(usize, @intCast(visible.right())) - x)];

                for (row, source.pixels[y * source.width + x ..][0..row.len]) |*pixel, color| pixel.* = self.convert(color);
                self.overlay(row, x, y);
                @memcpy(self.pixels[y * self.stride + x ..][0..row.len], row);
                x += row.len;

            }

        }

    }

    fn overlay(self: *Frame, row: []u32, x: usize, y: usize) void {

        const line = @as(i64, @intCast(y)) - pointer.y;
        if (line < 0 or line >= arrow.len) return;

        for (arrow[@intCast(line)], 0..) |shape, column| {

            const offset = pointer.x + @as(i64, @intCast(column)) - @as(i64, @intCast(x));
            if (shape == '.' or offset < 0 or offset >= row.len) continue;

            row[@intCast(offset)] = self.convert(if (shape == 'X') 0x000000 else 0xffffff);

        }

    }

    fn convert(self: *const Frame, color: u32) u32 {

        return (color >> 16 & 0xff) << self.shifts[0] | (color >> 8 & 0xff) << self.shifts[1] | (color & 0xff) << self.shifts[2];

    }

};

const Screen = union(enum) {

    svga: svga.Device,
    frame: Frame,

};

/// Pixels a client shares with us, stacked with the others and fed its input.
const Surface = struct {

    client: u64 = 0,
    memory: api.Shared = undefined,
    canvas: gui.Canvas = undefined,
    area: gui.Rect = .{},

    events: [32]api.Event = undefined,
    queued: usize = 0,
    waiting: ?api.Request = null,

};

var screen: Screen = undefined;
var back: gui.Canvas = undefined;

var renderer: ?gpu.Gpu = null;

var surfaces = [_]Surface{.{}} ** 8;

comptime {

    if (surfaces.len > gpu.layers) @compileError("The GPU frame holds fewer layers than surfaces");

}
var stack: [surfaces.len]usize = undefined;
var depth: usize = 0;

var pointer = gui.Point{};
var buttons: u8 = 0;

var sweep: u64 = 0;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, geometry: usize, shifts: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.memory) or api.permits(.management)) api.exit(2);

    const size = select(environment, base, geometry, shifts);
    const count: usize = @intCast(size.width * size.height);
    const pages = (count * 4 + 4095) / 4096;
    const memory = api.share(pages) catch api.exit(3);

    back = .{

        .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
        .width = @intCast(size.width),
        .height = @intCast(size.height),

    };
    pointer = .{

        .x = @divTrunc(size.width, 2),
        .y = @divTrunc(size.height, 2),

    };

    switch (screen) {

        .svga => |*device| {

            if (!device.bind(memory.bytes, @intCast(size.width * 4))) api.exit(3);

            var image: [arrow.len * arrow[0].len]u32 = undefined;

            for (arrow, 0..) |row, y| {

                for (row, 0..) |shape, x| image[y * row.len + x] = switch (shape) {

                    'X' => 0xff000000,
                    'O' => 0xffffffff,
                    else => 0,

                };

            }

            device.shape(&image, arrow[0].len, arrow.len, .{});
            device.point(pointer);

            renderer = gpu.Gpu.init(device, @intCast(size.width), @intCast(size.height));

            api.log(if (renderer != null) "display: ready (svga, 3D on)\n" else if (device.accelerated) "display: ready (svga, 3D failed)\n" else "display: ready (svga, 3D off)\n");

        },
        .frame => api.log("display: ready (framebuffer)\n"),

    }

    compose(back.bounds());

    while (true) {

        const request = api.receive(true) catch continue;

        if (handle(request)) |result| api.reply(request, result) catch {

        };

        // ponytail: exited clients are pruned on the next request; add a timer if an idle screen must drop them.
        if (api.ticks() >= sweep) prune();

    }

}

fn select(environment: *const api.abi.Environment, base: usize, geometry: usize, shifts: usize) gui.Rect {

    if (svga.Device.init(&environment.bars, @intCast(mode.width), @intCast(mode.height))) |device| {

        screen = .{

            .svga = device,

        };

        return mode;

    }

    if (base == 0) api.exit(3);

    const height = geometry >> 16 & 0xffff;
    const stride = geometry >> 32;
    const pixels = api.map(base, stride * height * 4) catch api.exit(3);

    screen = .{

        .frame = .{

            .pixels = @ptrCast(@alignCast(pixels)),
            .stride = stride,
            .shifts = .{ @intCast(shifts & 0xff), @intCast(shifts >> 8 & 0xff), @intCast(shifts >> 16 & 0xff) },

        },

    };

    return .{

        .width = @intCast(geometry & 0xffff),
        .height = @intCast(height),

    };

}

/// Returns the reply, or null when the request waits for input.
fn handle(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .info => back.width | back.height << 16,
        .surface => attach(request, value),
        .damage => damage(request, value),
        .wait => wait(request, value),
        .input => input(request),
        .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
        else => protocol.invalid,

    };

}

fn attach(request: api.Request, region: u64) u64 {

    const area = fetch(request) orelse return protocol.invalid;
    if (area.width <= 0 or area.height <= 0 or area.width > 8192 or area.height > 8192) return protocol.invalid;

    const index = for (surfaces, 0..) |surface, slot| {

        if (surface.client == 0) break slot;

    } else return protocol.full;

    const memory = api.attach(region) catch return protocol.denied;
    const count: usize = @intCast(area.width * area.height);

    if (memory.bytes.len < count * 4) {

        api.detach(memory.handle);
        return protocol.invalid;

    }

    if (renderer) |*device| {

        if (!device.adopt(@intCast(index), memory.bytes, @intCast(area.width), @intCast(area.height))) {

            api.detach(memory.handle);
            return protocol.full;

        }

    }

    surfaces[index] = .{

        .client = request.first,
        .memory = memory,
        .canvas = .{

            .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
            .width = @intCast(area.width),
            .height = @intCast(area.height),

        },
        .area = area,

    };
    stack[depth] = index;
    depth += 1;

    return index;

}

fn damage(request: api.Request, id: u64) u64 {

    const surface = owned(request, id) orelse return protocol.invalid;
    const area = fetch(request) orelse return protocol.invalid;
    const changed = area.intersect(surface.canvas.bounds()) orelse return 0;

    if (renderer) |*device| device.upload(@intCast(id), changed);

    compose(.{

        .x = changed.x + surface.area.x,
        .y = changed.y + surface.area.y,
        .width = changed.width,
        .height = changed.height,

    });

    return 0;

}

fn wait(request: api.Request, id: u64) ?u64 {

    const surface = owned(request, id) orelse return protocol.invalid;

    surface.waiting = request;
    deliver(surface);

    return null;

}

/// Redraws `area` of the screen from the surface stack, bottom to top.
fn compose(area: gui.Rect) void {

    const visible = area.intersect(back.bounds()) orelse return;

    if (renderer) |*device| {

        var layers: [surfaces.len]gpu.Layer = undefined;

        for (stack[0..depth], 0..) |index, slot| layers[slot] = .{

            .index = @intCast(index),
            .area = surfaces[index].area,

        };

        return device.compose(visible, layers[0..depth]);

    }

    switch (screen) {

        .svga => |*device| device.idle(),
        .frame => {

        },

    }

    back.fill(visible, theme.background);

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];

        back.blit(&surface.canvas, .{

            .x = surface.area.x,
            .y = surface.area.y,

        }, visible);

    }

    switch (screen) {

        .svga => |*device| device.present(visible),
        .frame => |*frame| frame.present(&back, visible),

    }

}

/// Takes the events the input service lends in its window and hands them to surfaces.
fn input(request: api.Request) u64 {

    // Only services run as the system, so clients cannot forge another surface's input.
    if (api.sender(request).user != api.abi.system.user) return protocol.denied;

    var events: [64]api.Event = undefined;
    const count = @min(request.fourth / @sizeOf(api.Event), events.len);

    api.fetch(request, 0, std.mem.sliceAsBytes(events[0..count])) catch return protocol.invalid;
    for (events[0..count]) |event| route(event);

    for (&surfaces) |*surface| {

        if (surface.client != 0) deliver(surface);

    }

    return 0;

}

fn route(event: api.Event) void {

    switch (event.kind) {

        .key => if (depth != 0) queue(&surfaces[stack[depth - 1]], event),
        .motion => {

            if (event.x != 0 or event.y != 0) move(event.x, event.y);

            const target = under(pointer);
            const changed = buttons ^ event.code;

            if (target) |surface| queue(surface, local(surface, .{

                .kind = .pointer,
                .code = event.code,

            }));

            for (0..3) |button| {

                if (changed >> @intCast(button) & 1 == 0) continue;

                const pressed = event.code >> @intCast(button) & 1 != 0;
                const surface = target orelse continue;

                if (pressed and button == 0) raise(surface);
                queue(surface, local(surface, .{

                    .kind = .button,
                    .pressed = pressed,
                    .code = @intCast(button),

                }));

            }

            buttons = event.code;

        },
        else => {

        },

    }

}

fn move(dx: i16, dy: i16) void {

    const previous = pointer;

    pointer = .{

        .x = std.math.clamp(pointer.x + dx, 0, @as(i32, @intCast(back.width)) - 1),
        .y = std.math.clamp(pointer.y + dy, 0, @as(i32, @intCast(back.height)) - 1),

    };

    switch (screen) {

        .svga => |*device| device.point(pointer),
        .frame => |*frame| {

            frame.present(&back, footprint(previous));
            frame.present(&back, footprint(pointer));

        },

    }

}

fn queue(surface: *Surface, event: api.Event) void {

    // Only the latest position matters, so consecutive moves collapse.
    if (event.kind == .pointer and surface.queued != 0 and surface.events[surface.queued - 1].kind == .pointer) {

        surface.events[surface.queued - 1] = event;
        return;

    }

    if (surface.queued == surface.events.len) return;

    surface.events[surface.queued] = event;
    surface.queued += 1;

}

fn deliver(surface: *Surface) void {

    const request = surface.waiting orelse return;
    if (surface.queued == 0) return;

    surface.waiting = null;

    // A timed-out wait keeps its event for the next one.
    api.reply(request, @bitCast(surface.events[0])) catch |err| {

        if (err == error.Missing) close(surface);
        return;

    };

    std.mem.copyForwards(api.Event, surface.events[0 .. surface.queued - 1], surface.events[1..surface.queued]);
    surface.queued -= 1;

}

fn raise(surface: *Surface) void {

    const index = (@intFromPtr(surface) - @intFromPtr(&surfaces)) / @sizeOf(Surface);
    const position = std.mem.indexOfScalar(usize, stack[0..depth], index) orelse return;

    if (position == depth - 1) return;

    std.mem.copyForwards(usize, stack[position .. depth - 1], stack[position + 1 .. depth]);
    stack[depth - 1] = index;
    compose(surface.area);

}

fn close(surface: *Surface) void {

    const index = (@intFromPtr(surface) - @intFromPtr(&surfaces)) / @sizeOf(Surface);
    const position = std.mem.indexOfScalar(usize, stack[0..depth], index) orelse return;
    const area = surface.area;

    std.mem.copyForwards(usize, stack[position .. depth - 1], stack[position + 1 .. depth]);
    depth -= 1;
    if (renderer) |*device| device.release(@intCast(index));
    api.detach(surface.memory.handle);
    surface.* = .{};
    compose(area);

}

/// Drops the surfaces of clients that exited.
fn prune() void {

    sweep = api.ticks() + 100;

    for (&surfaces) |*surface| {

        if (surface.client != 0 and !api.alive(surface.client)) close(surface);

    }

}

fn under(at: gui.Point) ?*Surface {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.area.contains(at)) return surface;

    }

    return null;

}

fn owned(request: api.Request, id: u64) ?*Surface {

    if (id >= surfaces.len) return null;

    const surface = &surfaces[id];

    return if (surface.client != 0 and surface.client == request.first) surface else null;

}

fn local(surface: *const Surface, event: api.Event) api.Event {

    var result = event;

    result.x = @intCast(pointer.x - surface.area.x);
    result.y = @intCast(pointer.y - surface.area.y);

    return result;

}

fn fetch(request: api.Request) ?gui.Rect {

    var area = api.display.Area{};

    api.fetch(request, 0, std.mem.asBytes(&area)) catch return null;

    return .{

        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = area.height,

    };

}

fn footprint(at: gui.Point) gui.Rect {

    return .{

        .x = at.x,
        .y = at.y,
        .width = arrow[0].len,
        .height = arrow.len,

    };

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
