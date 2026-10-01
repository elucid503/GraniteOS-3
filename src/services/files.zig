const std = @import("std");

const volume = @import("volume.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const path_limit = 1024;

const Disk = struct {

    index: u8,

    pub fn read(self: Disk, lba: u64, bytes: []u8) volume.Error!void {

        try transfer(.read, self.index, lba, bytes);

    }

    pub fn write(self: Disk, lba: u64, bytes: []const u8) volume.Error!void {

        try transfer(.write, self.index, lba, @constCast(bytes));

    }

    pub fn flush(self: Disk) volume.Error!void {

        if (try request(.flush, self.index, chunk[0..0]) != 0) return error.Device;

    }

};

var storage: u64 = 0;
var mounted: volume.Volume(Disk) = undefined;
var ready = false;

var path: [path_limit + 1]u8 = undefined;
var chunk: [volume.block_size]u8 = undefined;
var sector: [512]u8 = undefined;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.ipc) or api.permits(.ports) or api.permits(.management) or api.permits(.dma)) api.exit(2);

    while (true) {

        const message = api.receive(true) catch continue;

        api.reply(message, handle(message)) catch {

        };

    }

}

fn handle(message: api.Request) u64 {

    const operation = protocol.operation(message.second);
    const value = protocol.value(message.second);

    switch (operation) {

        .hello => return protocol.version,
        .crash => return if (message.first == api.raw(.owner, 0, 0, 0).first) fault() else protocol.invalid,
        .list, .read, .write, .create, .directory, .remove, .volume => {

        },
        else => return protocol.invalid,

    }

    // Mounting waits for the first request, so the supervisor's handshake never waits on storage.
    if (!ready) mount() catch |err| return code(err);

    if (operation == .volume) {

        const usage = mounted.usage();
        const bytes = std.mem.toBytes([2]u64{ usage.total, usage.free });

        api.store(message, 0, &bytes) catch return protocol.invalid;

        return 0;

    }

    const window = message.fourth;
    const size = @min(window, path.len);

    api.fetch(message, 0, path[0..size]) catch return protocol.invalid;

    const length = std.mem.indexOfScalar(u8, path[0..size], 0) orelse return protocol.invalid;
    const name = path[0..length];

    return serve(message, operation, value, name, window - length - 1) catch |err| code(err);

}

fn serve(message: api.Request, operation: protocol.Operation, value: u56, name: []const u8, payload: u64) (volume.Error || api.ApiError)!u64 {

    switch (operation) {

        .create => try mounted.create(name, .file),
        .directory => try mounted.create(name, .directory),
        .remove => try mounted.remove(name),
        .read => {

            var done: u64 = 0;

            while (done < message.fourth) {

                const count = try mounted.read(name, value + done, chunk[0..@min(chunk.len, message.fourth - done)]);
                if (count == 0) break;

                try api.store(message, done, chunk[0..count]);
                done += count;

            }

            return done;

        },
        .write => {

            const start = name.len + 1;
            var done: u64 = 0;

            while (done < payload) {

                const count = @min(chunk.len, payload - done);

                try api.fetch(message, start + done, chunk[0..count]);
                try mounted.write(name, value + done, chunk[0..count]);
                done += count;

            }

            return done;

        },
        .list => {

            // Records are kind, size, name length, then the name.
            var done: u64 = 0;
            var index: u64 = value;

            while (try mounted.entry(name, index)) |entry| : (index += 1) {

                const record = 10 + entry.name.len;
                if (done + record > message.fourth) break;

                chunk[0] = @intFromEnum(entry.kind);
                std.mem.writeInt(u64, chunk[1..9], entry.size, .little);
                chunk[9] = @intCast(entry.name.len);
                @memcpy(chunk[10..record], entry.name);

                try api.store(message, done, chunk[0..record]);
                done += record;

            }

            return index - value;

        },
        else => return protocol.invalid,

    }

    return 0;

}

fn mount() volume.Error!void {

    var index: u8 = 0;

    while (index < 32) : (index += 1) {

        const sectors = try request(.info, index, chunk[0..0]);
        if (sectors == 0 or sectors == protocol.invalid) break;

        const disk = Disk{

            .index = index,

        };

        const range = try volume.find(disk, &sector, sectors) orelse continue;
        const formatted = try mounted.mount(disk, range);

        ready = true;
        api.log(if (formatted) "files: volume formatted\n" else "files: volume mounted\n");

        return;

    }

    return error.Missing;

}

fn transfer(operation: protocol.Operation, index: u8, lba: u64, bytes: []u8) volume.Error!void {

    if (lba >> 48 != 0) return error.Invalid;
    if (try request(operation, @as(u56, index) << 48 | @as(u56, @intCast(lba)), bytes) != 0) return error.Device;

}

fn request(operation: protocol.Operation, value: u56, window: []u8) volume.Error!u64 {

    for (0..2) |_| {

        if (storage == 0) storage = api.lookup(0, .storage) catch return error.Device;

        return api.exchange(storage, protocol.pack(operation, value), window) catch |err| {

            storage = 0;
            if (err == error.Missing or err == error.Denied) continue;

            return error.Device;

        };

    }

    return error.Device;

}

fn code(err: anyerror) u64 {

    return switch (err) {

        error.Missing => protocol.missing,
        error.Exists => protocol.exists,
        error.Full => protocol.full,
        error.Busy => protocol.busy,
        else => protocol.invalid,

    };

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
