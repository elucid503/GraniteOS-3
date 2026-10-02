const std = @import("std");

const policy = @import("policy.zig");

const api = @import("api");
const options = @import("options");

const protocol = api.protocol;
pub const panic = api.panic;
var entries = [_]policy.Entry{.{}} ** @typeInfo(api.abi.Image).@"enum".fields.len;

/// An app launched for a session, stopped when the session ends.
const App = struct {

    id: u64 = 0,
    session: u64 = 0,
    ending: bool = false,

};

/// Apps a session may launch by name.
const registry = [_]struct { name: []const u8, image: api.abi.Image }{

    .{ .name = "notes", .image = .notes },

};

var apps = [_]App{.{}} ** 32;

/// Apps from before a supervisor restart have no known session, so they are stopped.
var orphans = false;

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
        orphans = true;
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

    reap();

    for ([_]api.abi.Image{

        .serial, .helper, .storage, .files, .accounts, .install, .input, .display, .shell, .client, .login

    }) |image| {

        const index = @intFromEnum(image);
        const entry = &entries[index];

        if (index == @intFromEnum(api.abi.Image.client) and (!options.self_test or test_finished)) continue;

        if (entry.id != 0 and api.raw(.inspect, entry.id, 0, 0).number != 0) {

            // A lock screen that died must not leave its session's windows unguarded.
            if (image == .login) end(entry.id);
            entry.failed(now);
            api.log("services: process lost; restart scheduled\n");
            if (entry.offline) api.log("services: restart limit reached\n");

        }

        if (!entry.ready(now)) continue;
        if ((image == .shell or image == .client) and (!entries[0].available or !entries[2].available)) continue;
        if (image == .login and !entries[@intFromEnum(api.abi.Image.display)].available) continue;

        const child = api.raw(.spawn, index, entry.retries, 0);

        if (child.number != 0) {

            entry.failed(now);
            continue;

        }

        entry.id = child.first;
        if (!application(image)) {

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

/// Forgets apps that exited and stops those whose session ended; a stop on a running app is retried next pass.
fn reap() void {

    for (&apps) |*app| {

        if (app.id == 0) continue;

        if (api.raw(.inspect, app.id, 0, 0).number != 0) {

            app.* = .{};
            continue;

        }

        if (app.ending) _ = api.raw(.stop, app.id, 0, 0);

    }

    if (!orphans) return;

    orphans = for (registry) |entry| {

        const child = api.raw(.inspect, 0, @intFromEnum(entry.image), 0);

        if (child.number == 0) {

            _ = api.raw(.stop, child.first, 0, 0);
            break true;

        }

    } else false;

}

fn launch(request: api.Request) u64 {

    const session = owner(request.first) orelse return protocol.denied;
    var name: [32]u8 = undefined;

    if (request.fourth > name.len) return protocol.invalid;
    api.fetch(request, 0, name[0..request.fourth]) catch return protocol.invalid;

    const image = for (registry) |entry| {

        if (std.mem.eql(u8, entry.name, name[0..request.fourth])) break entry.image;

    } else return protocol.missing;

    const app = for (&apps) |*app| {

        if (app.id == 0) break app;

    } else return protocol.full;

    const id = api.spawn(image, request) catch |err| return if (err == error.Denied) protocol.denied else protocol.invalid;

    app.* = .{

        .id = id,
        .session = session,

    };

    return 0;

}

/// The session `id` belongs to: the login process's own, or that of the app it launched.
fn owner(id: u64) ?u64 {

    if (id != 0 and id == entries[@intFromEnum(api.abi.Image.login)].id) return id;

    for (apps) |app| {

        if (app.id == id and !app.ending) return app.session;

    }

    return null;

}

fn end(session: u64) void {

    for (&apps) |*app| {

        if (app.id != 0 and app.session == session) app.ending = true;

    }

}

/// Applications never answer `hello` and may not be crashed or restarted on request.
fn application(image: api.abi.Image) bool {

    return image == .shell or image == .client or image == .login or image == .notes;

}

fn handle(request: api.Request) u64 {

    const operation = protocol.operation(request.second);
    const value = protocol.value(request.second);
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

            if (!api.sender(request).admin and (!options.self_test or request.first != client)) return protocol.invalid;
            if (value >= entries.len or application(@enumFromInt(value))) return protocol.invalid;

            const peer = entries[value].id;

            if (peer == 0) return 0;
            if (operation == .restart) return if (api.raw(.stop, peer, 0, 0).number == 0) 0 else protocol.invalid;

            _ = api.call(peer, protocol.pack(.crash, 0)) catch |err| {

                return if (err == error.Missing) 0 else protocol.invalid;

            };

            return protocol.invalid;

        },

        .power => {

            if (api.sender(request).user == api.abi.nobody.user) return protocol.denied;

            const result = api.raw(if (value == 1) .shutdown else .reboot, 0, 0, 0);

            return if (result.number == 0) 0 else protocol.invalid;

        },

        .passed, .failed => {

            if (!options.self_test or request.first != client or test_finished) return protocol.invalid;
            test_finished = true;
            api.log(if (operation == .passed) "services: recovery and application APIs passed\n" else "services: acceptance failed\n");

            return 0;

        },

        .launch => return launch(request),

        .end => {

            if (request.first != entries[@intFromEnum(api.abi.Image.login)].id) return protocol.denied;
            end(request.first);

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
