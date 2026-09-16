const std = @import("std");

const line = @import("line.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

pub export fn app_main(_: usize, supervisor: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    var terminal = api.Terminal{

        .supervisor = supervisor

    };

    var input = line.Line{

    };

    var counter: u64 = 0;

    while (true) {

        terminal.write("GraniteOS serial terminal\nType help for commands.\ngranite> ") catch {

            api.sleep(10);
            continue;

        };

        break;

    }

    while (true) {

        if (api.receive(false)) |request| {

            counter += 1;
            const result = if (protocol.operation(request.second) == .ping) counter else protocol.invalid;
            api.reply(request, result) catch {

            };

        } else |_| {

        }

        const byte = terminal.read() catch {

            api.sleep(1);
            continue;

        } orelse {

            api.sleep(1);
            continue;

        };

        switch (input.push(byte)) {

            .none => {

            },
            .character => terminal.write(&.{

                byte

            }) catch {

            },
            .erase => terminal.write("\x08 \x08") catch {

            },
            .full => terminal.write("\x07") catch {

            },
            .cancel => terminal.write("^C\ngranite> ") catch {

            },
            .submit => {

                terminal.write("\n") catch {

                };

                execute(&terminal, std.mem.trim(u8, input.bytes[0..input.len], " ")) catch {

                };

                input.len = 0;
                terminal.write("granite> ") catch {

                };

            },

        }

    }

}

fn execute(terminal: *api.Terminal, command: []const u8) api.ApiError!void {

    if (command.len == 0) return;

    if (std.mem.eql(u8, command, "help")) {

        try terminal.write("help | echo TEXT | id | ticks | permissions | services | ping | crash helper | restart helper | clear\n");

    } else if (std.mem.eql(u8, command, "echo") or std.mem.startsWith(u8, command, "echo ")) {

        if (command.len > 4) try terminal.write(command[5..]);
        try terminal.write("\n");

    } else if (std.mem.eql(u8, command, "id")) {

        try decimal(terminal, api.identity());

    } else if (std.mem.eql(u8, command, "ticks")) {

        try decimal(terminal, api.ticks());

    } else if (std.mem.eql(u8, command, "permissions")) {

        for (api.permissions()) |permission| {

            try terminal.write(@tagName(permission));
            try terminal.write("\n");

        }

    } else if (std.mem.eql(u8, command, "services")) {

        for ([_]api.abi.Image{

            .serial, .helper, .shell

        }) |kind| {

            try terminal.write(@tagName(kind));
            try terminal.write(": ");
            const id = api.lookup(terminal.supervisor, kind) catch {

                try terminal.write("unavailable\n");
                continue;

            };

            try decimal(terminal, id);

        }

    } else if (std.mem.eql(u8, command, "ping")) {

        const helper = api.lookup(terminal.supervisor, .helper) catch {

            try terminal.write("helper unavailable\n");
            return;

        };

        const value = api.call(helper, protocol.pack(.ping, 41)) catch {

            try terminal.write("helper disconnected\n");
            return;

        };

        try decimal(terminal, value);

    } else if (std.mem.eql(u8, command, "crash helper") or std.mem.eql(u8, command, "restart helper")) {

        const operation: protocol.Operation = if (command[0] == 'c') .crash else .restart;
        const result = try api.call(terminal.supervisor, protocol.pack(operation, @intFromEnum(api.abi.Image.helper)));
        try terminal.write(if (result == 0) "helper stopped; supervisor will recover it\n" else "request denied\n");

    } else if (std.mem.eql(u8, command, "clear")) {

        try terminal.write("\x1b[2J\x1b[H");

    } else try terminal.write("unknown command\n");

}

fn decimal(terminal: *api.Terminal, value: u64) api.ApiError!void {

    var buffer: [21]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}\n", .{

        value

    }) catch return error.Invalid;

    try terminal.write(text);

}
