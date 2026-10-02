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

/// The display service from a client's side: screen size, surfaces, damage, and input events.
pub const Display = struct {

    endpoint: u64 = 0,

    pub fn size(self: *Display) api.ServiceError!Area {

        const value = try self.request(.info, 0, &.{});

        return .{

            .width = @intCast(value & 0xffff),
            .height = @intCast(value >> 16 & 0xffff),

        };

    }

    /// Shows the shared memory `handle` at `area` on screen; returns the surface id.
    pub fn surface(self: *Display, handle: u64, area: Area) api.ServiceError!u64 {

        const endpoint = try self.peer();

        api.lend(handle, endpoint) catch |err| {

            self.endpoint = 0;
            return err;

        };

        var placement = area;

        return self.request(.surface, @intCast(handle), std.mem.asBytes(&placement));

    }

    /// Asks the display to show `area` (surface coordinates) of surface `id` again.
    pub fn damage(self: *Display, id: u64, area: Area) api.ServiceError!void {

        var changed = area;

        _ = try self.request(.damage, @intCast(id), std.mem.asBytes(&changed));

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
