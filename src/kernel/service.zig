const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");
const abi = @import("abi.zig");

var supervisor: u64 = 0;
var restarting = false;
var attempts: u8 = 0;
var due: u64 = 0;

pub fn start() !void {

    const task = try root.spawn(@embedFile("supervisor"), @intFromBool(supervisor != 0), root.primary);
    errdefer task.state = .dead;

    try task.configure(.service, &.{

        .ipc, .time, .management, .diagnostics

    });
    try task.grant(.manage, 0, 1);
    try task.grant(.log, 0, 1);

    var current = root.processes;

    while (current) |child| : (current = child.next) {

        if (child.owner != supervisor or child.image == null or child.state == .dead) continue;
        try child.grant(.send, task.id, 1);
        try task.grant(.send, child.id, 1);

    }

    // Publish ownership only after every replacement capability exists.
    current = root.processes;

    while (current) |child| : (current = child.next) {

        if (child.owner == supervisor and child.image != null) child.owner = task.id;

    }

    supervisor = task.id;
    restarting = false;
    root.log.line("supervisor started");

}

pub fn endpoint(owner: u64) ipc.IpcError!u64 {

    if (owner == 0 or owner != supervisor) return error.PermissionDenied;
    if (restarting or ipc.find(root.processes, supervisor) == null) return error.NoProcess;

    return supervisor;

}

pub fn departed(id: u64) void {

    if (id != supervisor) return;
    restarting = true;
    due = root.ticks +| 10;

}

pub fn maintain() void {

    if (!restarting or attempts == 3 or root.ticks < due) return;
    attempts += 1;
    start() catch {

        due = root.ticks +| 100;
        root.log.line("supervisor recovery failed");

    };

}

pub fn spawn(owner: *process.Process, image: abi.Image, argument: u64) !u64 {

    const bytes = switch (image) {

        .serial => @embedFile("serial"),
        .shell => @embedFile("shell"),
        .helper => @embedFile("helper"),
        .client => @embedFile("client"),

    };

    const task = try root.spawn(bytes, argument, owner.home);
    errdefer task.state = .dead;

    task.owner = owner.id;
    task.image = image;
    task.generation = argument;
    task.context.frame.rsi = 0;
    switch (image) {

        .serial => try task.configure(.service, &.{

            .ipc, .time, .ports

        }),
        .helper => try task.configure(.service, &.{

            .ipc

        }),
        .shell, .client => {

        },

    }

    try task.grant(.send, owner.id, 1);
    if (image == .serial) try task.grant(.port, 0x2f8, 8);
    try owner.grant(.send, task.id, 1);

    return task.id;

}

pub fn inspect(owner: *process.Process, image: abi.Image) ?*process.Process {

    var current = root.processes;

    while (current) |task| : (current = task.next) {

        if (task.owner == owner.id and task.image == image and task.state != .dead) return task;

    }

    return null;

}

pub fn connect(owner: *process.Process, source: u64, destination: u64) !void {

    const sender = ipc.find(root.processes, source) orelse return error.NoProcess;
    const receiver = ipc.find(root.processes, destination) orelse return error.NoProcess;

    if (sender.owner != owner.id or receiver.owner != owner.id) return error.Denied;
    if (!sender.permits(.send, destination, 1)) try sender.grant(.send, destination, 1);

}

pub fn revoke(id: u64) void {

    var current = root.processes;

    while (current) |task| : (current = task.next) {

        var link = &task.capabilities;

        while (link.*) |grant| {

            if (grant.right != .send or grant.base != id or grant.size != 1) {

                link = &grant.next;
                continue;

            }

            link.* = grant.next;
            root.frames.release(@intFromPtr(grant)) catch @panic("Capability ownership");

        }

    }

}
