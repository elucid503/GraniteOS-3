const api = @import("root.zig");

pub const Terminal = struct {

    supervisor: u64,
    endpoint: u64 = 0,

    pub fn request(self: *Terminal, operation: api.protocol.Operation, value: u56) api.ApiError!u64 {

        if (self.endpoint == 0) self.endpoint = try api.lookup(self.supervisor, .serial);

        return api.call(self.endpoint, api.protocol.pack(operation, value)) catch |err| {

            self.endpoint = 0;
            return err;

        };

    }

    pub fn write(self: *Terminal, bytes: []const u8) api.ApiError!void {

        for (bytes) |byte| {

            if (byte == '\n' and try self.request(.write, '\r') != 0) return error.Invalid;
            if (try self.request(.write, byte) != 0) return error.Invalid;

        }

    }

    pub fn read(self: *Terminal) api.ApiError!?u8 {

        const value = try self.request(.read, 0);
        if (value == api.protocol.empty) return null;
        if (value > 255) return error.Invalid;

        return @intCast(value);

    }

};
