const process = @import("process.zig");

const Process = process.Process;
pub const IpcError = error{ PermissionDenied, NoProcess, Deadlock };
var sequence: u64 = 0;

pub fn find(head: ?*Process, id: u64) ?*Process {

    var current = head;

    while (current) |entry| : (current = entry.next) {

        if (entry.id == id and entry.state != .dead) return entry;

    }

    return null;

}

pub fn send(head: ?*Process, sender: *Process, destination: u64, message: u64) IpcError!void {

    if (!sender.permits(.send, destination, 1)) return error.PermissionDenied;

    const receiver = find(head, destination) orelse return error.NoProcess;
    var cursor = receiver;

    while (true) {

        if (cursor == sender) return error.Deadlock;
        if (cursor.state != .sending) break;

        cursor = find(head, cursor.destination) orelse break;

    }

    if (receiver.state == .receiving) {

        deliver(receiver, sender.id, message);

        return;

    }

    sequence +%= 1;
    sender.sequence = sequence;
    sender.destination = destination;
    sender.message = message;
    sender.state = .sending;

}

pub fn receive(head: ?*Process, receiver: *Process) void {

    var first: ?*Process = null;
    var current = head;

    while (current) |sender| : (current = sender.next) {

        if (sender.state != .sending or sender.destination != receiver.id) continue;
        if (first == null or sender.sequence < first.?.sequence) first = sender;

    }

    if (first) |sender| {

        deliver(receiver, sender.id, sender.message);
        sender.state = .ready;
        sender.context.respond(.{

            .number = 0,

        });

    } else {

        receiver.state = .receiving;

    }

}

pub fn cancel(head: ?*Process, id: u64) void {

    var current = head;

    while (current) |sender| : (current = sender.next) {

        if (sender.state != .sending or sender.destination != id) continue;

        sender.state = .ready;
        sender.context.respond(.{

            .number = 3,

        });

    }

}

fn deliver(receiver: *Process, sender: u64, message: u64) void {

    receiver.context.respond(.{

        .number = 0,
        .first = sender,
        .second = message,

    });

    receiver.state = .ready;

}
