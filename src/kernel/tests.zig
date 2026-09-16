const std = @import("std");

const boot = @import("../boot/info.zig");
const memory = @import("memory.zig");
const elf = @import("elf.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const schedule = @import("schedule.zig");
const acpi = @import("../board/pc/acpi.zig");
const permission = @import("permission.zig");
const abi = @import("abi.zig");

test "physical allocator protects firmware state and detects invalid frees" {

    const regions = [_]boot.Region{

        .{

            .base = 0,
            .size = 0x101000,
            .kind = .available,

        },

        .{

            .base = 0x101000,
            .size = 0x3000,
            .kind = .firmware,

        },

        .{

            .base = 0x104000,
            .size = 0x1000,
            .kind = .loader,

        },

        .{

            .base = 0x105000,
            .size = 0x1000,
            .kind = .runtime,

        },

        .{

            .base = 0x106000,
            .size = 0x1000,
            .kind = .acpi,

        },

    };

    var storage: [128]u8 = undefined;
    var frames = try memory.Frames.init(&regions, &storage, 0x101000, 4096);

    try std.testing.expectEqual(3, frames.free_count);

    const first = try frames.alloc();

    try std.testing.expectEqual(0x100000, first);

    const run = try frames.allocRun(2);

    try std.testing.expectEqual(0x102000, run);
    try std.testing.expectError(error.OutOfMemory, frames.alloc());
    try std.testing.expectError(error.InvalidFrame, frames.release(0x101000));
    try std.testing.expectError(error.InvalidFrame, frames.release(0x104000));
    try std.testing.expectError(error.InvalidFrame, frames.release(0x100001));
    try std.testing.expectError(error.InvalidFrame, frames.release(0));
    try frames.release(first);
    try std.testing.expectError(error.DoubleFree, frames.release(first));
    try std.testing.expectEqual(first, try frames.alloc());
    try frames.release(run);
    try frames.release(run + 4096);
    try std.testing.expectEqual(2, frames.free_count);

}

test "physical allocator rejects overlap overflow and insufficient metadata" {

    var storage: [128]u8 = undefined;
    var regions = [_]boot.Region{

        .{

            .base = 0x100000,
            .size = 8192,
            .kind = .available,

        },

        .{

            .base = 0x101000,
            .size = 4096,
            .kind = .available,

        },

    };

    try std.testing.expectError(error.InvalidMap, memory.Frames.init(&regions, &storage, 0, 0));
    try std.testing.expectError(error.InvalidMap, memory.Frames.init(regions[0..1], storage[0..1], 0, 0));
    regions[0].base = 0xfffffffffffff000;
    try std.testing.expectError(error.InvalidMap, memory.Frames.storageSize(regions[0..1]));
    regions[0].base = memory.physical_limit;
    try std.testing.expectError(error.InvalidMap, memory.Frames.storageSize(regions[0..1]));

}

test "physical allocator scans packed states across cursor wrap" {

    for (0..256) |pattern| {

        for (0..12) |cursor| {

            var bits = [_]u8{

                0, @intCast(pattern), 0xaa,

            };

            var frames = memory.Frames{

                .bits = &bits,
                .count = 12,
                .cursor = cursor,

            };

            for (0..4) |index| {

                if ((pattern >> @intCast(index * 2)) & 3 == 1) frames.free_count += 1;

            }

            for (0..12) |offset| {

                const index = (cursor + offset) % 12;

                if (index < 4 or index >= 8 or (pattern >> @intCast((index - 4) * 2)) & 3 != 1) continue;

                try std.testing.expectEqual(index * memory.page_size, try frames.alloc());

            }

            try std.testing.expectEqual(0, frames.free_count);
            try std.testing.expectError(error.OutOfMemory, frames.alloc());

        }

    }

}

fn fixture() [512]u8 {

    var bytes = std.mem.zeroes([512]u8);

    const header = elf.Header{

        .ident = "\x7fELF\x02\x01\x01".* ++ std.mem.zeroes([9]u8),
        .kind = 2,
        .machine = 62,
        .version = 1,
        .entry = 0x8000000000,
        .phoff = 64,
        .shoff = 0,
        .flags = 0,
        .ehsize = 64,
        .phentsize = 56,
        .phnum = 1,
        .shentsize = 0,
        .shnum = 0,
        .shstrndx = 0,

    };

    const segment = elf.Segment{

        .kind = 1,
        .flags = 5,
        .offset = 256,
        .address = 0x8000000000,
        .physical = 0,
        .file_size = 8,
        .memory_size = 4096,
        .alignment = 1,

    };

    @memcpy(bytes[0..64], std.mem.asBytes(&header));
    @memcpy(bytes[64..120], std.mem.asBytes(&segment));

    return bytes;

}

test "ELF validates static executable bounds entry permissions and alignment" {

    var bytes = fixture();
    const image = try elf.Image.parse(&bytes, 0x8000000000, 0x8010000000);

    try std.testing.expectEqual(4096, image.program(0).memory_size);
    try std.testing.expectError(error.InvalidElf, elf.Image.parse(bytes[0..60], 0x8000000000, 0x8010000000));
    bytes[68] = 7;
    try std.testing.expectError(error.InvalidSegment, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));
    bytes = fixture();
    bytes[68] = 4;
    try std.testing.expectError(error.InvalidEntry, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));
    bytes = fixture();
    std.mem.writeInt(u64, bytes[96..104], 0xffffffffffffffff, .little);
    try std.testing.expectError(error.InvalidSegment, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));
    bytes = fixture();
    std.mem.writeInt(u64, bytes[112..120], 4096, .little);
    try std.testing.expectError(error.InvalidSegment, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));
    bytes = fixture();
    bytes[64] = 3;
    try std.testing.expectError(error.InvalidElf, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));

}

test "ELF rejects page overlaps and program table overflow" {

    var bytes = fixture();

    bytes[56] = 2;
    @memcpy(bytes[120..176], bytes[64..120]);
    try std.testing.expectError(error.OverlappingSegments, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));
    std.mem.writeInt(u64, bytes[32..40], 0xffffffffffffffff, .little);
    try std.testing.expectError(error.InvalidElf, elf.Image.parse(&bytes, 0x8000000000, 0x8010000000));

}

fn task(id: u64) process.Process {

    var value: process.Process = undefined;

    value.next = null;
    value.id = id;
    value.state = .ready;
    value.capabilities = null;
    value.home = 0;
    value.ticket = 0;
    value.deadline = 0;
    value.policy = .{

        .layer = .service,
        .length = abi.permission_count,
        .permissions = .{

            .ipc, .memory, .time, .ports, .mmio, .reboot, .diagnostics, .management

        },

    };

    value.context = .{

    };

    return value;

}

test "permission arrays distinguish services and deny undeclared authority" {

    try std.testing.expectError(error.Denied, permission.Policy.init(.application, &.{

        .ports

    }));
    try std.testing.expectError(error.Denied, permission.Policy.init(.application, &.{

        .management

    }));
    try std.testing.expectError(error.Denied, permission.Policy.init(.application, &.{

        .mmio

    }));
    try std.testing.expectError(error.Denied, permission.Policy.init(.application, &.{

        .reboot

    }));
    try std.testing.expectError(error.Invalid, permission.Policy.init(.service, &.{

        .ipc, .ipc

    }));

    var owner = task(1);
    var grant = process.Capability{

        .right = .port, .base = 0x2f8, .size = 8

    };

    owner.capabilities = &grant;
    owner.policy = try permission.Policy.init(.service, &.{

        .ipc

    });
    try std.testing.expect(!owner.permits(.port, 0x2f8, 1));
    try std.testing.expect(!owner.policy.permits(.memory));
    try std.testing.expect(!owner.policy.permits(.time));
    owner.policy = try permission.Policy.init(.service, &.{

        .ipc, .ports

    });
    try std.testing.expect(owner.permits(.port, 0x2f8, 1));
    try std.testing.expect(!owner.permits(.port, 0x3f8, 1));
    try std.testing.expect(!owner.permits(.port, 0x2ff, 2));
    try std.testing.expectEqualSlices(abi.Permission, &.{

        .ipc, .ports

    }, owner.policy.permissions[0..owner.policy.length]);

}

test "RPC authenticates one-shot replies and cancels both phases on peer death" {

    var client = task(1);
    var server = task(2);
    var stranger = task(3);
    var grant = process.Capability{

        .right = .send,
        .base = 2,
        .size = 1,

    };

    client.next = &server;
    server.next = &stranger;
    client.capabilities = &grant;

    try ipc.call(&client, &client, 2, 41, 100);
    try std.testing.expectEqual(.sending, client.state);
    try std.testing.expect(ipc.poll(&client, &server));
    const ticket = server.context.request().third;

    try std.testing.expectEqual(.replying, client.state);
    try std.testing.expectError(error.InvalidReply, ipc.reply(&client, &stranger, 1, ticket, 42));
    try std.testing.expectError(error.InvalidReply, ipc.reply(&client, &server, 1, ticket + 1, 42));
    try ipc.reply(&client, &server, 1, ticket, 42);
    try std.testing.expectEqual(42, client.context.request().first);
    try std.testing.expectError(error.InvalidReply, ipc.reply(&client, &server, 1, ticket, 42));

    ipc.receive(&client, &server);
    try ipc.call(&client, &client, 2, 43, 100);
    try std.testing.expectEqual(.replying, client.state);
    try std.testing.expectError(error.InvalidReply, ipc.reply(&client, &server, 1, ticket, 42));
    ipc.cancel(&client, 2);
    try std.testing.expectEqual(.ready, client.state);
    try std.testing.expectEqual(3, client.context.request().number);

    try ipc.call(&client, &client, 2, 44, 100);
    ipc.cancel(&client, 2);
    try std.testing.expectEqual(.ready, client.state);
    try std.testing.expectEqual(3, client.context.request().number);

}

test "RPC deadlines release queued and delivered calls without reviving stale replies" {

    var client = task(1);
    var server = task(2);
    var grant = process.Capability{

        .right = .send,
        .base = 1,
        .size = 2,

    };

    client.next = &server;
    client.capabilities = &grant;
    server.capabilities = &grant;
    try ipc.call(&client, &client, 2, 1, 10);
    ipc.expire(&client, 9);
    try std.testing.expectEqual(.sending, client.state);
    ipc.expire(&client, 10);
    try std.testing.expectEqual(6, client.context.request().number);
    try std.testing.expect(!ipc.poll(&client, &server));

    ipc.receive(&client, &server);
    try ipc.call(&client, &client, 2, 1, 20);
    const ticket = server.context.request().third;

    try std.testing.expectError(error.Deadlock, ipc.call(&client, &server, 1, 2, 20));
    ipc.expire(&client, 20);
    try std.testing.expectEqual(6, client.context.request().number);
    try std.testing.expectError(error.InvalidReply, ipc.reply(&client, &server, 1, ticket, 0));

}

test "capabilities reject wrong types overflow and boundary crossings" {

    var owner = task(1);
    var capability = process.Capability{

        .right = .port,
        .base = 0x3f8,
        .size = 8,

    };

    owner.capabilities = &capability;
    try std.testing.expect(owner.permits(.port, 0x3ff, 1));
    try std.testing.expect(!owner.permits(.port, 0x3ff, 2));
    try std.testing.expect(!owner.permits(.port, 0x3f7, 1));
    try std.testing.expect(!owner.permits(.port, 0x400, 1));
    try std.testing.expect(!owner.permits(.mmio, 0x3f8, 1));
    try std.testing.expect(!owner.permits(.port, 0xffffffffffffffff, 2));
    try std.testing.expect(!owner.permits(.port, 0x3f8, 0xffffffffffffffff));

}

test "IPC rendezvous preserves sender identity and wakes blocked peers" {

    var sender = task(1);
    var receiver = task(2);

    sender.next = &receiver;

    var grant = process.Capability{

        .right = .send,
        .base = 2,
        .size = 1,

    };

    sender.capabilities = &grant;
    try ipc.send(&sender, &sender, 2, 123);
    try std.testing.expectEqual(.sending, sender.state);
    ipc.receive(&sender, &receiver);
    try std.testing.expectEqual(.ready, sender.state);
    try std.testing.expectEqual(1, receiver.context.request().first);
    try std.testing.expectEqual(123, receiver.context.request().second);
    ipc.receive(&sender, &receiver);
    try std.testing.expectEqual(.receiving, receiver.state);
    try ipc.send(&sender, &sender, 2, 456);
    try std.testing.expectEqual(.ready, receiver.state);
    try std.testing.expectEqual(456, receiver.context.request().second);
    try std.testing.expectError(error.PermissionDenied, ipc.send(&sender, &receiver, 1, 0));
    try ipc.send(&sender, &sender, 2, 789);
    receiver.state = .dead;
    ipc.cancel(&sender, 2);
    try std.testing.expectEqual(.ready, sender.state);
    try std.testing.expectEqual(3, sender.context.request().number);
    try std.testing.expectError(error.NoProcess, ipc.send(&sender, &sender, 2, 0));

}

test "IPC rejects wait cycles and serves senders in arrival order" {

    var first = task(1);
    var second = task(2);
    var receiver = task(3);

    first.next = &second;
    second.next = &receiver;

    var grant = process.Capability{

        .right = .send,
        .base = 1,
        .size = 3,

    };

    first.capabilities = &grant;
    second.capabilities = &grant;
    receiver.capabilities = &grant;
    try std.testing.expectError(error.Deadlock, ipc.send(&first, &first, 1, 0));
    try ipc.send(&first, &first, 2, 1);
    try std.testing.expectError(error.Deadlock, ipc.send(&first, &second, 1, 2));
    ipc.receive(&first, &second);
    try ipc.send(&first, &second, 3, 20);
    try ipc.send(&first, &first, 3, 10);
    ipc.receive(&first, &receiver);
    try std.testing.expectEqual(20, receiver.context.request().second);
    ipc.receive(&first, &receiver);
    try std.testing.expectEqual(10, receiver.context.request().second);

}

test "scheduler rotates ready processes without running blocked or foreign tasks" {

    var first = task(1);
    var second = task(2);
    var third = task(3);

    first.next = &second;
    second.next = &third;
    try std.testing.expectEqual(&second, schedule.choose(&first, 0, 1).?);
    try std.testing.expectEqual(&first, schedule.choose(&first, 0, 3).?);
    first.state = .receiving;
    second.home = 1;
    try std.testing.expectEqual(&third, schedule.choose(&first, 0, 3).?);
    third.state = .running;
    try std.testing.expectEqual(null, schedule.choose(&first, 0, 0));
    try std.testing.expectEqual(&second, schedule.choose(&first, 1, 0).?);

}

test "MADT parser rejects nonadvancing truncated and corrupted records" {

    var bytes = std.mem.zeroes([52]u8);
    @memcpy(bytes[0..4], "APIC");
    std.mem.writeInt(u32, bytes[4..8], bytes.len, .little);
    bytes[45] = 8;
    fixChecksum(&bytes);
    try acpi.validateMadt(&bytes);
    bytes[45] = 0;
    fixChecksum(&bytes);
    try std.testing.expectError(error.InvalidAcpi, acpi.validateMadt(&bytes));
    bytes[45] = 9;
    fixChecksum(&bytes);
    try std.testing.expectError(error.InvalidAcpi, acpi.validateMadt(&bytes));
    bytes[45] = 8;
    fixChecksum(&bytes);
    bytes[10] = 1;
    try std.testing.expectError(error.InvalidAcpi, acpi.validateMadt(&bytes));

}

fn fixChecksum(bytes: []u8) void {

    bytes[9] = 0;

    var sum: u8 = 0;

    for (bytes) |byte| sum +%= byte;
    bytes[9] = 0 -% sum;

}
