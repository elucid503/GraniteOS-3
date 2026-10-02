const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;

pub const Account = struct {

    name: []const u8,
    identity: api.abi.Identity,

};

/// Fields travel as NUL-terminated strings; a successful login re-identifies the calling process.
pub const Accounts = struct {

    endpoint: u64 = 0,
    window: [512]u8 = undefined,

    pub fn login(self: *Accounts, name: []const u8, secret: []const u8) api.ServiceError!api.abi.Identity {

        return @bitCast(try self.request(.login, 0, &.{ name, secret }));

    }

    pub fn logout(self: *Accounts) api.ServiceError!void {

        _ = try self.request(.logout, 0, &.{});

    }

    pub fn create(self: *Accounts, name: []const u8, secret: []const u8, admin: bool) api.ServiceError!void {

        _ = try self.request(.create, @intFromBool(admin), &.{ name, secret });

    }

    pub fn remove(self: *Accounts, name: []const u8) api.ServiceError!void {

        _ = try self.request(.remove, 0, &.{name});

    }

    /// Changing your own password needs `current`; administrators may reset others without it.
    pub fn password(self: *Accounts, name: []const u8, new: []const u8, current: []const u8) api.ServiceError!void {

        _ = try self.request(.password, 0, &.{ name, new, current });

    }

    /// Describes account `index`, or null past the last; the name lives in `window` until the next call.
    pub fn list(self: *Accounts, index: u56) api.ServiceError!?Account {

        const identity: api.abi.Identity = @bitCast(self.request(.list, index, &.{}) catch |err| {

            return if (err == error.Missing) null else err;

        });

        return .{

            .name = std.mem.sliceTo(&self.window, 0),
            .identity = identity,

        };

    }

    fn request(self: *Accounts, operation: protocol.Operation, value: u56, fields: []const []const u8) api.ServiceError!u64 {

        @memset(&self.window, 0);

        var length: usize = 0;

        for (fields) |field| {

            if (length + field.len + 1 > self.window.len or std.mem.indexOfScalar(u8, field, 0) != null) return error.Invalid;

            @memcpy(self.window[length..][0..field.len], field);
            length += field.len + 1;

        }

        defer if (operation != .list) @memset(&self.window, 0);

        return api.query(&self.endpoint, .accounts, protocol.pack(operation, value), &self.window);

    }

};
