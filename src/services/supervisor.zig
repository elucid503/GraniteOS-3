const policy = @import("policy.zig");

const api = @import("api");
const options = @import("options");

const protocol = api.protocol;
pub const panic = api.panic;
var entries = [_]policy.Entry{ .{ }, .{ }, .{ }, .{ } };

var started = false;
var test_finished = false;

pub export fn app_main(restored: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);
    if (!api.permits(.management) or api.permits(.ports)) api.exit(2);

    if (restored != 0) {

        for (&entries, 0..) |*entry, index| {

            const child = api.raw(.inspect, 0, index, 0);
            if (child.number != 0) continue;

            entry.id = child.first;
            entry.retries = @intCast(@min(child.second, 3));
            entry.available = true;

        }

        test_finished = entries[@intFromEnum(api.abi.Image.client)].id == 0;
        api.log("services: supervisor recovered; children adopted\n");

    }

    while (true) {

        maintain();
        const request = api.receive(false) catch {

            api.sleep(1);
            continue;

        };

        const result = handle(request);
        api.reply(request, result) catch {

        };

    }

}

fn maintain() void {

    const now = api.ticks();

    for ([_]api.abi.Image{

        .serial, .helper, .shell, .client

    }) |image| {

        const index = @intFromEnum(image);
        const entry = &entries[index];

        if (index == @intFromEnum(api.abi.Image.client) and (!options.self_test or test_finished)) continue;

        if (entry.id != 0 and api.raw(.inspect, entry.id, 0, 0).number != 0) {

            entry.failed(now);
            api.log("services: process lost; restart scheduled\n");
            if (entry.offline) api.log("services: restart limit reached\n");

        }

        if (!entry.ready(now)) continue;
        if ((image == .shell or image == .client) and (!entries[0].available or !entries[2].available)) continue;

        const child = api.raw(.spawn, index, entry.retries, 0);

        if (child.number != 0) {

            entry.failed(now);
            continue;

        }

        entry.id = child.first;
        if (image == .serial or image == .helper) {

            const version = api.call(entry.id, protocol.pack(.hello, 0)) catch protocol.invalid;
            if (version != protocol.version) {

                _ = api.raw(.stop, entry.id, 0, 0);
                entry.failed(api.ticks());
                api.log("services: startup failed\n");
                continue;

            }

        }

        entry.available = true;
        if (entry.retries != 0) api.log("services: process restarted\n");

        if (!started and entries[0].available and entries[1].available and entries[2].available) {

            started = true;
            api.log("services: ready\n");

        }

    }

}

fn handle(request: api.Request) u64 {

    const operation = protocol.operation(request.second);
    const value = protocol.value(request.second);
    const shell = entries[@intFromEnum(api.abi.Image.shell)].id;
    const client = entries[@intFromEnum(api.abi.Image.client)].id;

    switch (operation) {

        .hello => return protocol.version,

        .lookup => {

            if (value >= entries.len) return protocol.invalid;
            if (!entries[value].available) return 0;
            const peer = entries[value].id;
            if (peer == 0) return 0;
            if (api.raw(.connect, request.first, peer, 0).number != 0) return 0;

            return peer;

        },

        .crash, .restart => {

            if (request.first != shell and (!options.self_test or request.first != client)) return protocol.invalid;
            if (value != @intFromEnum(api.abi.Image.helper) and value != @intFromEnum(api.abi.Image.serial)) return protocol.invalid;

            const peer = entries[value].id;

            if (peer == 0) return 0;
            if (operation == .restart) return if (api.raw(.stop, peer, 0, 0).number == 0) 0 else protocol.invalid;

            _ = api.call(peer, protocol.pack(.crash, 0)) catch |err| {

                return if (err == error.Missing) 0 else protocol.invalid;

            };

            return protocol.invalid;

        },

        .passed, .failed => {

            if (!options.self_test or request.first != client or test_finished) return protocol.invalid;
            test_finished = true;
            api.log(if (operation == .passed) "services: recovery and application APIs passed\n" else "services: acceptance failed\n");

            return 0;

        },

        .relaunch => {

            if (!options.self_test or request.first != client) return protocol.invalid;
            asm volatile ("ud2");
            api.exit(1);

        },

        else => return protocol.invalid,

    }

}
