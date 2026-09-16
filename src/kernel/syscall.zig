const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");

const paging = arch.paging;
const CallError = paging.MapError || ipc.IpcError || error{ Denied, Invalid };

pub fn handle(task: *process.Process, ticks: u64) void {

    var request = task.context.request();

    invoke(task, ticks, &request) catch |err| {

        request.number = switch (err) {

            error.Denied, error.PermissionDenied => 1,
            error.NoProcess => 3,
            error.Deadlock => 4,
            error.OutOfMemory => 5,
            else => 2,

        };

    };

    task.context.respond(request);

}

fn invoke(task: *process.Process, ticks: u64, frame: *abi.Request) CallError!void {

    const number = frame.number;

    frame.number = 0;

    switch (@as(abi.Call, @enumFromInt(number))) {

        .yield => {

        },
        .exit => root.exited(task, frame.first),
        .send => try ipc.send(root.processes, task, frame.first, frame.second),
        .receive => {

            ipc.receive(root.processes, task);
            frame.* = task.context.request();
            frame.number = 0;

        },
        .write => {

            if (!task.permits(.log, 0, 1)) return error.Denied;
            if (frame.second > 256) return error.Invalid;

            var bytes: [256]u8 = undefined;

            try copyFrom(task, frame.first, bytes[0..frame.second]);
            root.log.output(bytes[0..frame.second]);

        },
        .allocate => {

            const address = try task.vacant();

            _ = try task.space.allocate(address, paging.user | paging.writable | paging.nx);
            task.mapped(address);

            frame.first = address;

        },
        .release => {

            if (frame.first < paging.user_base + 0x10000000 or frame.first >= task.allocation or frame.first % 4096 != 0) return error.Invalid;

            try task.space.unmap(frame.first);
            task.cursor = @min(task.cursor, frame.first);

        },
        .port => {

            if (frame.first > 65535 or frame.second > 1 or frame.third > 255) return error.Invalid;
            if (!task.permits(.port, frame.first, 1)) return error.Denied;

            const port: u16 = @intCast(frame.first);

            if (frame.second == 0) frame.first = arch.cpu.in(port) else arch.cpu.out(port, @intCast(frame.third));

        },
        .map => {

            if (frame.first % 4096 != 0) return error.Invalid;
            if (!task.permits(.mmio, frame.first, 4096)) return error.Denied;

            const address = try task.vacant();

            try task.space.map(address, frame.first, paging.user | paging.writable | paging.nx | paging.uncached | paging.borrowed);
            task.mapped(address);

            frame.first = address;

        },
        .reboot => {

            if (!task.permits(.reboot, 0, 1)) return error.Denied;

            arch.machine.reboot();

        },
        .ticks => frame.first = ticks,
        .identity => frame.first = task.id,
        else => return error.Invalid,

    }

}

fn copyFrom(task: *process.Process, address: u64, bytes: []u8) !void {

    if (address < paging.user_base or address >= paging.user_end or bytes.len > paging.user_end - address) return error.Invalid;

    var offset: usize = 0;

    while (offset < bytes.len) {

        const physical = try task.space.translate(address + offset, false);
        const size = @min(bytes.len - offset, 4096 - (physical & 4095));

        @memcpy(bytes[offset..][0..size], @as([*]const u8, @ptrFromInt(physical))[0..size]);
        offset += size;

    }

}
