const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;
var supervisor: u64 = 0;

pub export fn app_main(_: usize, parent: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    var forged = environment.*;
    forged.layer = .service;
    forged.length = api.abi.permission_count;
    forged.permissions = .{

        .ipc, .memory, .time, .ports, .mmio, .reboot, .diagnostics, .management

    };

    api.start(&forged, .service);
    if (api.raw(.port, 0x2f8, 0, 0).number != 1 or api.raw(.spawn, 0, 0, 0).number != 1) api.exit(3);
    api.start(environment, .application);
    supervisor = parent;
    run() catch {

        _ = api.call(supervisor, protocol.pack(.failed, 0)) catch {

        };

        api.exit(1);

    };

    _ = api.call(supervisor, protocol.pack(.passed, 0)) catch api.exit(2);
    api.exit(0);

}

fn run() !void {

    try expect(api.permissions().len == 3);
    try expect(api.permits(.ipc) and api.permits(.memory) and api.permits(.time));
    try expect(!api.permits(.ports) and !api.permits(.management));
    try expect(try api.call(supervisor, protocol.pack(.hello, 0)) == protocol.version);
    try expect(api.raw(.port, 0x2f8, 0, 0).number == 1);
    try expect(api.raw(.port, 0x3f8, 1, 0).number == 1);
    try expect(api.raw(.map, 0xfee00000, 0, 0).number == 1);
    try expect(api.raw(.spawn, 0, 0, 0).number == 1);
    try expect(api.raw(.connect, api.identity(), supervisor, 0).number == 1);
    try expect(api.raw(.inspect, supervisor, 0, 0).number == 1);
    try expect(api.raw(.stop, supervisor, 0, 0).number == 1);
    try expect(api.raw(.write, 0, 0, 0).number == 1);
    try expect(api.raw(.reboot, 0, 0, 0).number == 1);

    const allocation = try api.checked(api.raw(.allocate, 0, 0, 0));
    const page: *volatile u64 = @ptrFromInt(allocation.first);
    page.* = 0x123456789abcdef0;

    const helper = try discover(.helper, 0);
    const shell = try discover(.shell, 0);
    const serial = try discover(.serial, 0);
    try expect(try api.call(helper, protocol.pack(.ping, 41)) == 42);
    try expect(try api.call(helper, protocol.pack(.ping, ~@as(u56, 0))) == @as(u64, 1) << 56);
    if (api.call(helper, protocol.pack(.stall, 0))) |_| {

        return error.ExpectedTimeout;

    } else |err| {

        try expect(err == error.Timeout);

    }

    try expect(try api.call(helper, protocol.pack(.ping, 41)) == 42);
    const counter = try api.call(shell, protocol.pack(.ping, 0));

    if (api.call(helper, protocol.pack(.crash, 0))) |_| {

        return error.ExpectedDisconnect;

    } else |err| {

        try expect(err == error.Missing);

    }

    const replacement = try discover(.helper, helper);
    try expect(try api.call(replacement, protocol.pack(.ping, 100)) == 101);
    try expect(api.raw(.call, helper, protocol.pack(.ping, 0), 100).number == 1);
    try expect(try api.lookup(supervisor, .shell) == shell);
    try expect(try api.call(shell, protocol.pack(.ping, 0)) == counter + 1);
    try expect(page.* == 0x123456789abcdef0);
    try expect(try api.call(supervisor, protocol.pack(.restart, @intFromEnum(api.abi.Image.helper))) == 0);
    const stopped_replacement = try discover(.helper, replacement);
    try expect(try api.call(stopped_replacement, protocol.pack(.ping, 41)) == 42);

    try expect(try api.call(supervisor, protocol.pack(.crash, @intFromEnum(api.abi.Image.serial))) == 0);
    const replacement_serial = try discover(.serial, serial);
    try expect(try api.call(replacement_serial, protocol.pack(.hello, 0)) == protocol.version);
    try expect(try api.call(shell, protocol.pack(.ping, 0)) == counter + 2);
    try expect(try api.lookup(supervisor, .shell) == shell);
    try expect(page.* == 0x123456789abcdef0);
    _ = try api.checked(api.raw(.release, allocation.first, 0, 0));

    if (api.call(supervisor, protocol.pack(.relaunch, 0))) |_| {

        return error.ExpectedSupervisorDisconnect;

    } else |err| {

        try expect(err == error.Missing);

    }

    try expect(try discover(.shell, 0) == shell);
    try expect(try api.lookup(supervisor, .helper) == stopped_replacement);
    try expect(try api.lookup(supervisor, .serial) == replacement_serial);
    try expect(try api.call(shell, protocol.pack(.ping, 0)) == counter + 3);
    try expect(try api.call(stopped_replacement, protocol.pack(.ping, 41)) == 42);

}

fn discover(image: api.abi.Image, old: u64) !u64 {

    const deadline = api.ticks() + 500;

    while (api.ticks() < deadline) {

        const id = api.lookup(supervisor, image) catch {

            api.sleep(1);
            continue;

        };

        if (id != old) return id;
        api.sleep(1);

    }

    return error.DiscoveryTimeout;

}

fn expect(condition: bool) !void {

    if (!condition) return error.AcceptanceFailed;

}
