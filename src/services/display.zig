const std = @import("std");

const svga = @import("svga.zig");
const gpu = @import("gpu.zig");

const api = @import("api");
const gui = @import("gui");

const protocol = api.protocol;
const theme = gui.theme;
pub const panic = api.panic;

/// The mode until an administrator picks another, which is then saved in `saved`.
const default = gui.Rect{

    .width = 1280,
    .height = 800,

};

// The desktop is laid out for at least this much room.
const smallest = gui.Rect{

    .width = 640,
    .height = 480,

};

const saved = "/system/display";

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


const Layer = api.display.Layer;

const border = 1;

/// A client's window: drawing commands it shares with us, stacked with the others and fed its input.
const Surface = struct {

    client: u64 = 0,
    memory: api.Shared = undefined,
    area: gui.Rect = .{},

    layer: Layer = .window,
    title: [32]u8 = undefined,
    length: usize = 0,

    /// Which half of the shared buffer holds the presented commands, and how many bytes of them.
    half: u1 = 0,
    size: usize = 0,

    /// Presented at least once; until then nothing of it shows.
    shown: bool = false,

    /// Undelivered input, oldest at `head`.
    events: [128]api.Event = undefined,
    head: usize = 0,
    queued: usize = 0,
    waiting: ?api.Request = null,

    /// Input was dropped because the client stopped reading; logged once.
    behind: bool = false,

    /// The content plus its decorations.
    fn frame(self: *const Surface) gui.Rect {

        if (self.layer != .window) return self.area;

        return outline(self.area);

    }

    // A client may rewrite these bytes at any moment; the reader checks every command, and only this window suffers.
    fn commands(self: *const Surface) []const u8 {

        return self.memory.bytes[@as(usize, self.half) * gui.draw.capacity ..][0..self.size];

    }

};

var settings: *const api.abi.Environment = undefined;
var screen: Screen = undefined;
var back: gui.Canvas = undefined;
var backing: ?api.Shared = null;
var files = api.Files{};

var renderer: ?gpu.Gpu = null;

var surfaces = [_]Surface{.{}} ** 64;


/// Surface indices bottom to top, grouped by layer.
var stack: [surfaces.len]usize = undefined;
var depth: usize = 0;

/// The window keys go to unless an overlay is up.
var focused: ?usize = null;

/// The window following the pointer by its title bar.
var dragging: ?usize = null;

var pointer = gui.Point{};
var buttons: u8 = 0;

var sweep: u64 = 0;

pub export fn app_main(_: usize, base: usize, environment: *const api.abi.Environment, geometry: usize, shifts: usize) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.memory) or api.permits(.management)) api.exit(2);

    settings = environment;

    // The supervisor waits on our handshake, so answer it before asking the files service for the saved mode.
    greet();

    const wanted = load() orelse default;

    if (!open(wanted) and !open(default)) framebuffer(base, geometry, shifts);

    pointer = .{

        .x = @divTrunc(@as(i32, @intCast(back.width)), 2),
        .y = @divTrunc(@as(i32, @intCast(back.height)), 2),

    };

    switch (screen) {

        .svga => |*device| {

            device.point(pointer);
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

/// Answers the supervisor's `hello`; nothing else should arrive before it.
fn greet() void {

    while (true) {

        const request = api.receive(true) catch continue;
        const hello = protocol.operation(request.second) == .hello;

        api.reply(request, if (hello) protocol.version else protocol.invalid) catch {

        };

        if (hello) return;

    }

}

/// Takes over the SVGA adapter at `size`, drawing on its GPU when it has one; false when the adapter cannot show it.
fn open(size: gui.Rect) bool {

    const width: u32 = @intCast(size.width);
    const height: u32 = @intCast(size.height);
    const device = svga.Device.init(&settings.bars, width, height) orelse return false;

    screen = .{

        .svga = device,

    };

    const memory = api.share((width * height * 4 + 4095) / 4096) catch return false;

    if (!screen.svga.bind(memory.bytes, width * 4)) {

        api.detach(memory.handle);
        return false;

    }

    adopt(memory, size);

    var image: [arrow.len * arrow[0].len]u32 = undefined;

    for (arrow, 0..) |row, y| {

        for (row, 0..) |shape, x| image[y * row.len + x] = switch (shape) {

            'X' => 0xff000000,
            'O' => 0xffffffff,
            else => 0,

        };

    }

    screen.svga.shape(&image, arrow[0].len, arrow.len, .{});
    screen.svga.point(pointer);

    if (renderer) |*old| old.release();
    renderer = gpu.Gpu.init(&screen.svga, width, height);

    return true;

}

/// Falls back to the boot framebuffer, drawn by the CPU at whatever mode the firmware left.
fn framebuffer(base: usize, geometry: usize, shifts: usize) void {

    if (base == 0) api.exit(3);

    const height = geometry >> 16 & 0xffff;
    const stride = geometry >> 32;
    const pixels = api.map(base, stride * height * 4) catch api.exit(3);
    const size = gui.Rect{

        .width = @intCast(geometry & 0xffff),
        .height = @intCast(height),

    };

    screen = .{

        .frame = .{

            .pixels = @ptrCast(@alignCast(pixels)),
            .stride = stride,
            .shifts = .{ @intCast(shifts & 0xff), @intCast(shifts >> 8 & 0xff), @intCast(shifts >> 16 & 0xff) },

        },

    };

    adopt(api.share((@as(usize, @intCast(size.width * size.height)) * 4 + 4095) / 4096) catch api.exit(3), size);

}

/// Makes `memory` the CPU's copy of a `size` screen, freeing the last one.
fn adopt(memory: api.Shared, size: gui.Rect) void {

    if (backing) |old| api.detach(old.handle);

    const count: usize = @intCast(size.width * size.height);

    backing = memory;
    back = .{

        .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
        .width = @intCast(size.width),
        .height = @intCast(size.height),

    };

}

/// Switches to a `width` by `height` mode for an administrator, then tells every window.
fn mode(request: api.Request, value: u64) u64 {

    if (!api.sender(request).admin) return protocol.denied;
    if (screen != .svga) return protocol.invalid;

    const size = gui.Rect{

        .width = @intCast(value & 0xffff),
        .height = @intCast(value >> 16 & 0xffff),

    };
    const previous = back.bounds();

    if (size.width < smallest.width or size.height < smallest.height or !screen.svga.fits(@intCast(size.width), @intCast(size.height))) return protocol.invalid;
    if (!open(size) and !open(previous)) api.exit(3);
    if (back.width != size.width or back.height != size.height) return protocol.invalid;

    settle();
    compose(back.bounds());
    save(size);

    return 0;

}

/// Keeps the pointer and every title bar on the new screen, and tells clients its size.
fn settle() void {

    const width: i32 = @intCast(back.width);
    const height: i32 = @intCast(back.height);

    pointer = .{

        .x = @min(pointer.x, width - 1),
        .y = @min(pointer.y, height - 1),

    };

    for (&surfaces) |*surface| {

        if (surface.client == 0) continue;

        if (surface.layer == .window) {

            surface.area.x = std.math.clamp(surface.area.x, theme.title - surface.area.width, width - theme.title);
            surface.area.y = std.math.clamp(surface.area.y, theme.title, height - border);

        }

        queue(surface, .{

            .kind = .resize,
            .x = @intCast(width),
            .y = @intCast(height),

        });
        deliver(surface);

    }

}

fn load() ?gui.Rect {

    const bytes = files.read(saved, 0, 4) catch return null;
    if (bytes.len != 4) return null;

    const value = std.mem.readInt(u32, bytes[0..4], .little);
    const size = gui.Rect{

        .width = @intCast(value & 0xffff),
        .height = @intCast(value >> 16),

    };

    return if (size.width >= smallest.width and size.height >= smallest.height) size else null;

}

fn save(size: gui.Rect) void {

    const value: u32 = @intCast(size.width | size.height << 16);

    files.directory("/system") catch {

    };
    files.create(saved) catch {

    };
    files.write(saved, 0, &std.mem.toBytes(std.mem.nativeToLittle(u32, value))) catch api.log("display: could not save the mode\n");

}

/// Returns the reply, or null when the request waits for input.
fn handle(request: api.Request) ?u64 {

    const value = protocol.value(request.second);

    return switch (protocol.operation(request.second)) {

        .hello => protocol.version,
        .info => back.width | back.height << 16,
        .surface => attach(request, value),
        .place => place(request, value),
        .mode => mode(request, value),
        .present => present(request, value),
        .wait => wait(request, value),
        .input => input(request),
        .crash => if (request.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
        else => protocol.invalid,

    };

}

fn attach(request: api.Request, region: u64) u64 {

    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    const area = rect(spec.area);

    if (area.width <= 0 or area.height <= 0 or area.width > 8192 or area.height > 8192) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;

    const index = for (&surfaces, 0..) |*surface, slot| {

        if (surface.client == 0) break slot;

    } else return protocol.full;

    const memory = api.attach(region) catch return protocol.denied;

    if (memory.bytes.len < 2 * gui.draw.capacity) {

        api.detach(memory.handle);
        return protocol.invalid;

    }

    const surface = &surfaces[index];

    surface.* = .{

        .client = request.first,
        .memory = memory,
        .area = area,
        .layer = spec.layer,

    };
    name(surface, spec);
    insert(index);
    if (spec.layer != .background) focus(index);

    return index;

}

/// Moves, resizes, restacks, or retitles a surface; decorations cannot come or go, so neither can the window layer.
fn place(request: api.Request, id: u64) u64 {

    const surface = owned(request, id) orelse return protocol.invalid;
    const spec = fetch(request, api.display.Spec) orelse return protocol.invalid;
    const area = rect(spec.area);

    if (area.width <= 0 or area.height <= 0 or area.width > 8192 or area.height > 8192) return protocol.invalid;
    if ((spec.layer == .window) != (surface.layer == .window)) return protocol.invalid;
    if (!allowed(request.first, spec.layer)) return protocol.denied;

    const before = surface.frame();
    const index: usize = @intCast(id);

    surface.area = area;
    surface.layer = spec.layer;
    name(surface, spec);
    remove(index);
    insert(index);
    if (spec.layer == .overlay) focus(index);
    compose(before.join(surface.frame()));

    return 0;

}

/// Shows the commands a client finished writing into one half of its buffer.
fn present(request: api.Request, value: u64) u64 {

    const surface = owned(request, value & 0xff) orelse return protocol.invalid;
    const length = value >> 9;

    if (length > gui.draw.capacity) return protocol.invalid;

    surface.half = @intCast(value >> 8 & 1);
    surface.size = length;
    surface.shown = true;
    compose(surface.frame());

    return 0;

}

fn wait(request: api.Request, id: u64) ?u64 {

    const surface = owned(request, id) orelse return protocol.invalid;

    surface.waiting = request;
    deliver(surface);

    return null;

}

/// Redraws `area` of the screen from the surface stack, bottom to top, on the GPU when there is one.
fn compose(area: gui.Rect) void {

    const visible = area.intersect(back.bounds()) orelse return;

    if (renderer) |*device| {

        device.begin(visible);

        for (stack[0..depth]) |index| {

            const surface = &surfaces[index];
            if (!surface.shown) continue;

            var bytes: [512]u8 align(4) = undefined;
            const chrome = trim(index, &bytes);

            if (surface.frame().intersect(visible)) |limit| device.render(chrome.commands(), corner(surface.frame()), limit);
            if (surface.area.intersect(visible)) |limit| device.render(surface.commands(), corner(surface.area), limit);

        }

        return device.finish(visible);

    }

    switch (screen) {

        .svga => |*device| device.idle(),
        .frame => {

        },

    }

    back.fill(visible, theme.background);

    for (stack[0..depth]) |index| {

        const surface = &surfaces[index];
        if (!surface.shown) continue;

        var bytes: [512]u8 align(4) = undefined;
        const chrome = trim(index, &bytes);

        if (surface.frame().intersect(visible)) |limit| gui.draw.replay(&back, chrome.commands(), corner(surface.frame()), limit);
        if (surface.area.intersect(visible)) |limit| gui.draw.replay(&back, surface.commands(), corner(surface.area), limit);

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

        .key => if (keyboard()) |surface| queue(surface, event),
        .motion => {

            if (event.x != 0 or event.y != 0) {

                const previous = pointer;

                move(event.x, event.y);
                if (dragging) |index| drag(index, pointer.x - previous.x, pointer.y - previous.y);

            }

            const target = under(pointer);
            const changed = buttons ^ event.code;

            if (target) |surface| if (dragging == null) queue(surface, local(surface, .{

                .kind = .pointer,
                .code = event.code,

            }));

            for (0..3) |button| {

                if (changed >> @intCast(button) & 1 == 0) continue;

                const pressed = event.code >> @intCast(button) & 1 != 0;

                if (button == 0 and !pressed and dragging != null) {

                    dragging = null;
                    continue;

                }

                const surface = target orelse continue;

                if (button == 0 and pressed) {

                    const index = which(surface);

                    raise(index);
                    focus(index);

                    if (!surface.area.contains(pointer)) {

                        if (closer(surface).contains(pointer)) queue(surface, .{

                            .kind = .close,

                        }) else dragging = index;

                        continue;

                    }

                }

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

/// Moves a window with the pointer, keeping its title bar on screen.
fn drag(index: usize, dx: i32, dy: i32) void {

    const surface = &surfaces[index];
    const before = surface.frame();

    surface.area.x += dx;
    surface.area.y = std.math.clamp(surface.area.y + dy, theme.title, @as(i32, @intCast(back.height)) - border);
    compose(before.join(surface.frame()));

}

/// Where keys go: an overlay above everything, else the focused window.
fn keyboard() ?*Surface {

    if (depth == 0) return null;

    const top = &surfaces[stack[depth - 1]];
    if (top.layer == .overlay) return top;

    const index = focused orelse return top;

    return &surfaces[index];

}

fn queue(surface: *Surface, event: api.Event) void {

    const capacity = surface.events.len;

    // Only the latest position matters, so consecutive moves collapse.
    if (event.kind == .pointer and surface.queued != 0) {

        const last = &surface.events[(surface.head + surface.queued - 1) % capacity];

        if (last.kind == .pointer) {

            last.* = event;
            return;

        }

    }

    // A client this far behind has stopped reading; its oldest input goes first.
    if (surface.queued == capacity) {

        if (!surface.behind) api.log("display: a window stopped reading input; dropping its oldest\n");
        surface.behind = true;
        surface.head = (surface.head + 1) % capacity;
        surface.queued -= 1;

    }

    surface.events[(surface.head + surface.queued) % capacity] = event;
    surface.queued += 1;

}

fn deliver(surface: *Surface) void {

    const request = surface.waiting orelse return;
    if (surface.queued == 0) return;

    surface.waiting = null;

    // A timed-out wait keeps its event for the next one.
    api.reply(request, @bitCast(surface.events[surface.head])) catch |err| {

        if (err == error.Missing) close(surface);
        return;

    };

    surface.head = (surface.head + 1) % surface.events.len;
    surface.queued -= 1;

}

/// Puts surface `index` on top of the others in its layer.
fn insert(index: usize) void {

    const layer = @intFromEnum(surfaces[index].layer);
    var position = depth;

    while (position > 0 and @intFromEnum(surfaces[stack[position - 1]].layer) > layer) position -= 1;

    std.mem.copyBackwards(usize, stack[position + 1 .. depth + 1], stack[position..depth]);
    stack[position] = index;
    depth += 1;

}

fn remove(index: usize) void {

    const position = std.mem.indexOfScalar(usize, stack[0..depth], index) orelse return;

    std.mem.copyForwards(usize, stack[position .. depth - 1], stack[position + 1 .. depth]);
    depth -= 1;

}

fn raise(index: usize) void {

    if (stack[depth - 1] == index) return;

    remove(index);
    insert(index);
    compose(surfaces[index].frame());

}

/// Sends keys to surface `index` and repaints the title bars that changed.
fn focus(index: ?usize) void {

    const previous = focused;
    if (previous == index) return;

    focused = index;

    for ([_]?usize{ previous, index }) |entry| {

        const changed = entry orelse continue;

        if (surfaces[changed].layer == .window) compose(surfaces[changed].frame());

    }

}

fn close(surface: *Surface) void {

    const index = which(surface);
    const area = surface.frame();

    remove(index);
    if (dragging == index) dragging = null;

    api.detach(surface.memory.handle);
    surface.* = .{};

    if (focused == index) {

        focused = null;
        focus(if (depth != 0 and surfaces[stack[depth - 1]].layer != .background) stack[depth - 1] else null);

    }

    compose(area);

}

/// Drops the surfaces of clients that exited.
fn prune() void {

    sweep = api.ticks() + 100;

    for (&surfaces) |*surface| {

        if (surface.client != 0 and !api.alive(surface.client)) close(surface);

    }

}

/// Records the title bar and border of window `index` in frame coordinates; empty for other layers.
fn trim(index: usize, bytes: []u8) gui.draw.List {

    const surface = &surfaces[index];
    const frame = surface.frame();
    var list = gui.draw.List{

        .bytes = bytes,
        .width = frame.width,
        .height = frame.height,

    };

    if (surface.layer != .window) return list;

    const active = focused == index;
    const bar = gui.Rect{

        .width = frame.width,
        .height = theme.title,

    };
    const dot = closer(surface);
    const spot = gui.Rect{

        .x = dot.x - frame.x,
        .y = dot.y - frame.y,
        .width = dot.width,
        .height = dot.height,

    };

    list.fill(list.bounds(), theme.selected);
    list.fill(bar, if (active) theme.selected else theme.raised);
    list.label(surface.title[0..surface.length], theme.small, bar, if (active) theme.text else theme.muted, .center);
    list.round(spot.centered(12, 12), 6, if (active) theme.danger else theme.muted);

    return list;

}

fn name(surface: *Surface, spec: api.display.Spec) void {

    const title = spec.name();

    surface.length = title.len;
    @memcpy(surface.title[0..title.len], title);

}

/// The close control at the right of a window's title bar.
fn closer(surface: *const Surface) gui.Rect {

    const frame = surface.frame();

    return .{

        .x = frame.right() - theme.title,
        .y = frame.y,
        .width = theme.title,
        .height = theme.title,

    };

}

fn outline(area: gui.Rect) gui.Rect {

    return .{

        .x = area.x - border,
        .y = area.y - theme.title,
        .width = area.width + 2 * border,
        .height = area.height + theme.title + border,

    };

}

/// Background and overlay surfaces cover other windows, so only one client, the session, may hold them.
fn allowed(client: u64, layer: Layer) bool {

    switch (layer) {

        .window => return true,
        .background, .overlay => {

        },
        _ => return false,

    }

    for (&surfaces) |*surface| {

        if (surface.client != 0 and surface.client != client and surface.layer != .window) return false;

    }

    return true;

}

fn under(at: gui.Point) ?*Surface {

    var position = depth;

    while (position > 0) {

        position -= 1;

        const surface = &surfaces[stack[position]];
        if (surface.frame().contains(at)) return surface;

    }

    return null;

}

fn owned(request: api.Request, id: u64) ?*Surface {

    if (id >= surfaces.len) return null;

    const surface = &surfaces[id];

    return if (surface.client != 0 and surface.client == request.first) surface else null;

}

fn which(surface: *const Surface) usize {

    return (@intFromPtr(surface) - @intFromPtr(&surfaces)) / @sizeOf(Surface);

}

fn local(surface: *const Surface, event: api.Event) api.Event {

    var result = event;

    result.x = @intCast(pointer.x - surface.area.x);
    result.y = @intCast(pointer.y - surface.area.y);

    return result;

}

fn fetch(request: api.Request, comptime T: type) ?T {

    var value = T{};

    api.fetch(request, 0, std.mem.asBytes(&value)) catch return null;

    return value;

}

fn rect(area: api.display.Area) gui.Rect {

    return .{

        .x = area.x,
        .y = area.y,
        .width = area.width,
        .height = area.height,

    };

}

fn corner(area: gui.Rect) gui.Point {

    return .{

        .x = area.x,
        .y = area.y,

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
