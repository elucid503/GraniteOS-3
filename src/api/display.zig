const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;

/// A pixel rectangle as it travels between clients and the display.
pub const Area = extern struct {

    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

};

/// Where a surface stacks; the window manager decorates and lets users move `window` surfaces.
pub const Layer = enum(u8) {

    background,
    window,
    overlay,
    _,

};

/// How a surface asks to be shown: `area` is its content in screen coordinates.
pub const Spec = extern struct {

    area: Area = .{},
    layer: Layer = .window,
    length: u8 = 0,
    title: [32]u8 = undefined,

    pub fn init(area: Area, layer: Layer, title: []const u8) Spec {

        var spec = Spec{

            .area = area,
            .layer = layer,
            .length = @intCast(@min(title.len, 32)),

        };

        @memcpy(spec.title[0..spec.length], title[0..spec.length]);

        return spec;

    }

    pub fn name(self: *const Spec) []const u8 {

        return self.title[0..@min(self.length, self.title.len)];

    }

};

/// The display service from a client's side: screen size, surfaces, their drawing, and input events.
pub const Display = struct {

    endpoint: u64 = 0,

    pub fn size(self: *Display) api.ServiceError!Area {

        const value = try self.request(.info, 0, &.{});

        return .{

            .width = @intCast(value & 0xffff),
            .height = @intCast(value >> 16 & 0xffff),

        };

    }

    /// Shows the shared memory `handle` as `spec` describes; returns the surface id.
    pub fn surface(self: *Display, handle: u64, spec: Spec) api.ServiceError!u64 {

        const endpoint = try self.peer();

        api.lend(handle, endpoint) catch |err| {

            self.endpoint = 0;
            return err;

        };

        var placement = spec;

        return self.request(.surface, @intCast(handle), std.mem.asBytes(&placement));

    }

    /// Moves, resizes, restacks, or retitles surface `id`.
    pub fn place(self: *Display, id: u64, spec: Spec) api.ServiceError!void {

        var placement = spec;

        _ = try self.request(.place, @intCast(id), std.mem.asBytes(&placement));

    }

    /// Switches the screen to `width` by `height` and remembers it; administrators only.
    pub fn mode(self: *Display, width: u16, height: u16) api.ServiceError!void {

        _ = try self.request(.mode, @as(u56, height) << 16 | width, &.{});

    }

    /// Shows the first `length` bytes of commands in buffer half `half` of surface `id`.
    pub fn present(self: *Display, id: u64, half: u1, length: usize) api.ServiceError!void {

        if (id > 0xff or length > 0xffff_ffff) return error.Invalid;

        _ = try self.request(.present, @intCast(id | @as(u64, half) << 8 | @as(u64, length) << 9), &.{});

    }

    /// Waits up to `timeout` ticks for the next input event of surface `id`.
    pub fn wait(self: *Display, id: u64, timeout: u64) api.ServiceError!?api.Event {

        const endpoint = try self.peer();
        const result = api.checked(api.raw(.call, endpoint, protocol.pack(.wait, @intCast(id)), timeout)) catch |err| {

            if (err == error.Timeout) return null;
            self.endpoint = 0;

            return err;

        };

        if (result.first == protocol.invalid) return error.Invalid;

        return @bitCast(result.first);

    }

    fn peer(self: *Display) api.ApiError!u64 {

        if (self.endpoint == 0) self.endpoint = try api.lookup(0, .display);

        return self.endpoint;

    }

    fn request(self: *Display, operation: protocol.Operation, value: u56, window: []u8) api.ServiceError!u64 {

        const endpoint = try self.peer();
        const result = api.exchange(endpoint, protocol.pack(operation, value), window) catch |err| {

            self.endpoint = 0;
            return err;

        };

        return switch (result) {

            protocol.invalid => error.Invalid,
            protocol.denied => error.Denied,
            protocol.full => error.Full,
            else => result,

        };

    }

};
