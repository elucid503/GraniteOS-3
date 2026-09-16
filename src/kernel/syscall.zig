const std = @import("std");

const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");
const service = @import("service.zig");

const paging = arch.paging;
const CallError = paging.MapError || ipc.IpcError || @import("elf.zig").LoadError || error{ Denied, Invalid, Busy, ProcessIdsExhausted, InvalidProcessor };

pub fn handle(task: *process.Process, ticks: u64) void {

    var request = task.context.request();

    invoke(task, ticks, &request) catch |err| {

        request.number = switch (err) {

            error.Denied, error.PermissionDenied => 1,
            error.NoProcess => 3,
            error.Deadlock => 4,
            error.OutOfMemory, error.Exhausted, error.ProcessIdsExhausted => 5,
            error.Busy => 7,
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

            if (!task.policy.permits(.ipc)) return error.Denied;
            if (frame.first > 1) return error.Invalid;
            if (frame.first == 1) {

                if (!ipc.poll(root.processes, task)) return error.NoProcess;

            } else ipc.receive(root.processes, task);
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

            if (!task.policy.permits(.memory)) return error.Denied;
            const address = try task.vacant();

            _ = try task.space.allocate(address, paging.user | paging.writable | paging.nx);
            task.mapped(address);

            frame.first = address;

        },
        .release => {

            if (!task.policy.permits(.memory)) return error.Denied;
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
        .ticks => {

            if (!task.policy.permits(.time)) return error.Denied;
            frame.first = ticks;

        },
        .identity => frame.first = task.id,
        .owner => frame.first = task.owner,
        .call => {

            if (frame.third == 0 or frame.third > 6000 or ticks > ~@as(u64, 0) - frame.third) return error.Invalid;
            const destination = if (frame.first == 0) try service.endpoint(task.owner) else frame.first;
            try ipc.call(root.processes, task, destination, frame.second, ticks + frame.third);

        },
        .reply => {

            if (!task.policy.permits(.ipc)) return error.Denied;
            try ipc.reply(root.processes, task, frame.first, frame.second, frame.third);

        },
        .sleep => {

            if (!task.policy.permits(.time)) return error.Denied;
            if (frame.first == 0 or frame.first > 6000 or ticks > ~@as(u64, 0) - frame.first) return error.Invalid;
            task.deadline = ticks + frame.first;
            task.state = .sleeping;

        },
        .spawn => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            const image = std.enums.fromInt(abi.Image, frame.first) orelse return error.Invalid;
            frame.first = try service.spawn(task, image, frame.second);

        },
        .inspect => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            if (frame.first == 0) {

                const image = std.enums.fromInt(abi.Image, frame.second) orelse return error.Invalid;
                const child = service.inspect(task, image) orelse return error.NoProcess;
                frame.first = child.id;
                frame.second = child.generation;
                return;

            }

            const child = ipc.find(root.processes, frame.first) orelse return error.NoProcess;
            if (child.owner != task.id) return error.Denied;
            frame.first = child.id;

        },
        .connect => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            try service.connect(task, frame.first, frame.second);

        },
        .stop => {

            if (!task.permits(.manage, 0, 1)) return error.Denied;
            const child = ipc.find(root.processes, frame.first) orelse return error.NoProcess;
            if (child.owner != task.id) return error.Denied;
            if (child.state == .running) return error.Busy;
            child.state = .dead;

        },
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
