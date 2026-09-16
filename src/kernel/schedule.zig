const Process = @import("process.zig").Process;

pub fn choose(head: ?*Process, home: u32, previous: u64) ?*Process {

    var next: ?*Process = null;
    var first: ?*Process = null;
    var current = head;

    while (current) |task| : (current = task.next) {

        if (task.state != .ready or task.home != home) continue;
        if (first == null or task.id < first.?.id) first = task;
        if (task.id > previous and (next == null or task.id < next.?.id)) next = task;

    }

    return next orelse first;

}
