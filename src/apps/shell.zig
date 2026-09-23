const std = @import("std");

const line = @import("line.zig");

const api = @import("api");

const protocol = api.protocol;
pub const panic = api.panic;

const prompt = "obsidian [/]> ";
const Error = api.ApiError || error{Usage};

const Command = struct {

    usage: []const u8,
    description: []const u8,
    run: *const fn ([]const u8) Error!void,

    fn name(self: Command) []const u8 {

        return self.usage[0 .. std.mem.indexOfScalar(u8, self.usage, ' ') orelse self.usage.len];

    }

};

const Group = struct {

    title: []const u8,
    commands: []const Command,

};

const groups = [_]Group{

    .{

        .title = "shell",
        .commands = &.{

            command("help", "List available commands", help),
            command("about", "About GraniteOS 3", about),
            command("clear", "Clear the terminal screen", clear),
            command("echo", "Print some text back", echo),
            command("history", "List recent commands", history),

        },

    },
    .{

        .title = "system",
        .commands = &.{

            command("id", "Print this process' identity", id),
            command("uptime", "Time since boot", uptime),
            command("permissions", "List this process' permissions", permissions),
            command("services", "List running services", services),

        },

    },
    .{

        .title = "services",
        .commands = &.{

            command("ping", "Call the helper service", ping),
            command("crash", "Crash a service (helper, serial)", crash),
            command("restart", "Restart a service (helper, serial)", restart),

        },

    },

};

var terminal: api.Terminal = undefined;
var editor = line.Line{

};

var served: u64 = 0;

pub export fn app_main(_: usize, supervisor: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);
    terminal = .{

        .supervisor = supervisor,

    };

    while (true) {

        terminal.write("\nOBSIDIAN ......... Ready\n\nType 'help' for available commands.\n\n" ++ prompt) catch {

            api.sleep(10);
            continue;

        };

        break;

    }

    while (true) {

        serve();
        const byte = (terminal.read() catch null) orelse {

            api.sleep(1);
            continue;

        };

        handle(byte) catch {

        };

    }

}

fn command(usage: []const u8, description: []const u8, run: *const fn ([]const u8) Error!void) Command {

    return .{

        .usage = usage,
        .description = description,
        .run = run,

    };

}

fn serve() void {

    const request = api.receive(false) catch return;

    served += 1;
    const result = if (protocol.operation(request.second) == .ping) served else protocol.invalid;
    api.reply(request, result) catch {

    };

}

fn handle(byte: u8) api.ApiError!void {

    switch (editor.push(byte)) {

        .none => {

        },
        .echo => try terminal.write(editor.text()[editor.len - 1 ..]),
        .erase => try terminal.write("\x08 \x08"),
        .redraw => try redraw(),
        .bell => try terminal.write("\x07"),
        .complete => try complete(),
        .clear => {

            try terminal.write("\x1b[2J\x1b[H");
            try redraw();

        },
        .cancel => try terminal.write("^C\n" ++ prompt),
        .submit => {

            defer editor.reset();
            try terminal.write("\n");
            execute(std.mem.trim(u8, editor.text(), " "));
            try terminal.write(prompt);

        },

    }

}

fn redraw() api.ApiError!void {

    if (editor.cursor == editor.len) return terminal.print("\r" ++ prompt ++ "{s}\x1b[K", .{editor.text()});

    try terminal.print("\r" ++ prompt ++ "{s}\x1b[K\x1b[{d}D", .{ editor.text(), editor.len - editor.cursor });

}

fn complete() api.ApiError!void {

    const prefix = editor.text()[0..editor.cursor];
    if (std.mem.indexOfScalar(u8, prefix, ' ') != null) return terminal.write("\x07");

    var first: ?[]const u8 = null;
    var shared: usize = 0;
    var matches: usize = 0;

    for (groups) |group| {

        for (group.commands) |entry| {

            const candidate = entry.name();
            if (!std.mem.startsWith(u8, candidate, prefix)) continue;

            if (first) |match| {

                shared = std.mem.indexOfDiff(u8, match[0..shared], candidate) orelse shared;

            } else {

                first = candidate;
                shared = candidate.len;

            }

            matches += 1;

        }

    }

    const match = first orelse return terminal.write("\x07");

    if (matches == 1) {

        _ = editor.insert(match[prefix.len..]);
        _ = editor.insert(" ");
        return redraw();

    }

    if (shared > prefix.len) {

        _ = editor.insert(match[prefix.len..shared]);
        return redraw();

    }

    try terminal.write("\n");
    for (groups) |group| {

        for (group.commands) |entry| {

            if (std.mem.startsWith(u8, entry.name(), prefix)) try terminal.print("{s}  ", .{entry.name()});

        }

    }

    try terminal.write("\n");
    try redraw();

}

fn execute(text: []const u8) void {

    if (text.len == 0) return;

    const split = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const name = text[0..split];
    const argument = std.mem.trim(u8, text[split..], " ");

    for (groups) |group| {

        for (group.commands) |entry| {

            if (!std.mem.eql(u8, entry.name(), name)) continue;

            const takes = entry.name().len != entry.usage.len;
            const result = if (!takes and argument.len != 0) error.Usage else entry.run(argument);

            result catch |err| {

                if (err == error.Usage) terminal.print("usage: {s}\n", .{entry.usage}) catch {

                };

            };

            return;

        }

    }

    terminal.print("obsidian: {s}: command not found\n", .{name}) catch {

    };

}

fn help(_: []const u8) Error!void {

    try terminal.write("\nGraniteOS 3 - Available Commands\n\n");

    for (groups) |group| {

        try terminal.print("{s}\n", .{group.title});
        for (group.commands) |entry| try terminal.print("  {s:<16}{s}\n", .{ entry.usage, entry.description });
        try terminal.write("\n");

    }

}

fn about(_: []const u8) Error!void {

    try terminal.write(
        \\
        \\   ______                 _ __       ____  _____    _____
        \\  / ____/________ _____  (_) /____  / __ \/ ___/   |__  /
        \\ / / __/ ___/ __ `/ __ \/ / __/ _ \/ / / /\__ \     /_ <
        \\/ /_/ / /  / /_/ / / / / / /_/  __/ /_/ /___/ /   ___/ /
        \\\____/_/   \__,_/_/ /_/_/\__/\___/\____//____/   /____/
        \\
        \\A practical, everyday operating system written in Zig.
        \\
        \\Features:
        \\  - x86_64 UEFI boot
        \\  - Preemptive multicore scheduling
        \\  - Isolated processes with kernel-enforced permissions
        \\  - Supervised services with crash recovery
        \\  - Serial terminal and OBSIDIAN shell
        \\
        \\Type 'help' to see available commands.
        \\
        \\
    );

}

fn clear(_: []const u8) Error!void {

    try terminal.write("\x1b[2J\x1b[H");

}

fn echo(argument: []const u8) Error!void {

    try terminal.print("{s}\n", .{argument});

}

fn history(_: []const u8) Error!void {

    var step = @min(editor.total, editor.history.len);

    while (step > 0) : (step -= 1) {

        try terminal.print("  {d:>3}  {s}\n", .{ editor.total - step + 1, editor.recalled(step).? });

    }

}

fn id(_: []const u8) Error!void {

    try terminal.print("{d}\n", .{api.identity()});

}

fn uptime(_: []const u8) Error!void {

    const ticks = api.ticks();
    try terminal.print("{d}.{d:0>2} seconds\n", .{ ticks / 100, ticks % 100 });

}

fn permissions(_: []const u8) Error!void {

    for (api.permissions()) |permission| try terminal.print("{s}\n", .{@tagName(permission)});

}

fn services(_: []const u8) Error!void {

    for ([_]api.abi.Image{ .serial, .helper, .shell }) |image| {

        const peer = api.lookup(terminal.supervisor, image) catch {

            try terminal.print("  {s:<10}unavailable\n", .{@tagName(image)});
            continue;

        };

        try terminal.print("  {s:<10}{d}\n", .{ @tagName(image), peer });

    }

}

fn ping(_: []const u8) Error!void {

    const helper = api.lookup(terminal.supervisor, .helper) catch return terminal.write("ping: helper unavailable\n");
    const value = api.call(helper, protocol.pack(.ping, 41)) catch return terminal.write("ping: helper disconnected\n");

    try terminal.print("{d}\n", .{value});

}

fn crash(argument: []const u8) Error!void {

    try control(.crash, argument);

}

fn restart(argument: []const u8) Error!void {

    try control(.restart, argument);

}

fn control(operation: protocol.Operation, argument: []const u8) Error!void {

    const image = std.meta.stringToEnum(api.abi.Image, argument) orelse return error.Usage;
    if (image != .helper and image != .serial) return error.Usage;

    const result = try api.call(terminal.supervisor, protocol.pack(operation, @intCast(@intFromEnum(image))));
    try terminal.print("{s}: {s}\n", .{ argument, if (result == 0) "stopped; supervisor will recover it" else "request denied" });

}
