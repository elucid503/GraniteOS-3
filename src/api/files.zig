const std = @import("std");

const api = @import("root.zig");

const protocol = api.protocol;
pub const FileError = api.ServiceError;

pub const Kind = enum(u8) {

    file = 1,
    directory = 2,
    _,

};

pub const Entry = struct {

    kind: Kind,
    size: u64,
    mode: u16,
    owner: u32,
    name: []const u8,

};

pub const Usage = struct {

    total: u64,
    free: u64,

};

/// Paths are absolute; every call resolves them afresh, so a restarted files service needs no reopening.
pub const Files = struct {

    endpoint: u64 = 0,
    window: [4096]u8 = undefined,

    pub fn create(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.create, 0, path, 0);

    }

    pub fn directory(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.directory, 0, path, 0);

    }

    pub fn remove(self: *Files, path: []const u8) FileError!void {

        _ = try self.request(.remove, 0, path, 0);

    }

    /// Sets permission bits; only system services may pass an `owner` other than null.
    pub fn change(self: *Files, path: []const u8, mode: u16, owner: ?u32) FileError!void {

        _ = try self.request(.change, @as(u56, owner orelse api.abi.nobody.user) << 16 | mode, path, 0);

    }

    /// Reads up to `limit` bytes at `offset`; the bytes live in `window` until the next call.
    pub fn read(self: *Files, path: []const u8, offset: u56, limit: usize) FileError![]const u8 {

        const count = try self.request(.read, offset, path, @max(limit, path.len + 1) - path.len - 1);

        return self.window[0..count];

    }

    pub fn write(self: *Files, path: []const u8, offset: u56, bytes: []const u8) FileError!void {

        if (path.len + 1 + bytes.len > self.window.len) return error.Invalid;
        @memcpy(self.window[path.len + 1 ..][0..bytes.len], bytes);

        if (try self.request(.write, offset, path, bytes.len) != bytes.len) return error.Invalid;

    }

    /// Lists entries from `index` onward into `out`, returning how many fit in one reply.
    pub fn list(self: *Files, path: []const u8, index: u56, out: []Entry) FileError!usize {

        const count = try self.request(.list, index, path, self.window.len - path.len - 1);
        var offset: usize = 0;

        for (0..@min(count, out.len)) |entry| {

            const length = self.window[offset + 15];

            out[entry] = .{

                .kind = @enumFromInt(self.window[offset]),
                .size = std.mem.readInt(u64, self.window[offset + 1 ..][0..8], .little),
                .mode = std.mem.readInt(u16, self.window[offset + 9 ..][0..2], .little),
                .owner = std.mem.readInt(u32, self.window[offset + 11 ..][0..4], .little),
                .name = self.window[offset + 16 ..][0..length],

            };
            offset += 16 + length;

        }

        return @min(count, out.len);

    }

    pub fn usage(self: *Files) FileError!Usage {

        _ = try self.request(.volume, 0, "", 15);

        return .{

            .total = std.mem.readInt(u64, self.window[0..8], .little),
            .free = std.mem.readInt(u64, self.window[8..16], .little),

        };

    }

    /// Sends `path` and a NUL, followed by `payload` bytes already placed in the window.
    fn request(self: *Files, operation: protocol.Operation, value: u56, path: []const u8, payload: usize) FileError!u64 {

        if (path.len + 1 + payload > self.window.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.Invalid;

        @memcpy(self.window[0..path.len], path);
        self.window[path.len] = 0;

        return api.query(&self.endpoint, .files, protocol.pack(operation, value), self.window[0 .. path.len + 1 + payload]);

    }

};
