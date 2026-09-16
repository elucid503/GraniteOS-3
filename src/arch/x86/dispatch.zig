const arch = @import("../root.zig");
const root = @import("../../kernel/root.zig");
const calls = @import("../../kernel/syscall.zig");
const check = @import("../../kernel/check.zig");
const schedule = @import("../../kernel/schedule.zig");

const options = @import("options");

const machine = arch.machine;

pub export fn dispatch(frame: *const arch.context.Frame, floating: *const [512]u8) callconv(.c) *const arch.context.Context {

    const active_root = asm volatile ("mov %%cr3, %[value]" // Read the active page-table address.
        : [value] "=r" (-> usize),
    );

    if (root.failed.load(.acquire)) arch.cpu.halt();

    if (frame.vector < 32 and (frame.cs & 3 == 0 or frame.vector == 2 or frame.vector == 8 or frame.vector == 18)) {

        root.beginFailure();
        dump(frame, active_root);

        root.reportFailure("Kernel exception", frame.rip);

    }

    const core = machine.local();

    while (root.lock.swap(true, .acquire)) arch.cpu.relax();

    arch.paging.activate(machine.kernel.root);

    if (core.current) |task| {

        task.context.frame = frame.*;
        task.context.floating = floating.*;
        task.state = .ready;

        if (frame.vector == 32) {

            task.preemptions += 1;
            core.preemptions += 1;

        } else if (frame.vector == 128) {

            calls.handle(task, core.ticks);

        } else if (frame.vector < 32) {

            root.log.decimal("isolated fault process", task.id);
            dump(frame, active_root);

            if (options.self_test) check.faulted(task, frame);

            task.state = .dead;

        }

    } else {

        core.idle.frame = frame.*;
        core.idle.floating = floating.*;

    }

    if (frame.vector == 32) core.ticks += 1;
    if (frame.vector >= 32 and frame.vector != 128 and frame.vector != 255) machine.apic.write(0xb0, 0);

    core.current = null;
    root.reap();

    const selected = schedule.choose(root.processes, core.id, core.last_id);
    var result: *const arch.context.Context = &core.idle;

    if (selected) |task| {

        task.state = .running;
        core.current = task;
        core.last_id = task.id;
        core.switches += 1;

        arch.paging.activate(task.space.root);
        result = &task.context;

    }

    if (options.self_test) check.verify();
    root.lock.store(false, .release);

    return result;

}

fn dump(frame: *const arch.context.Frame, active_root: usize) void {

    root.log.decimal("cpu", machine.apic.id());
    root.log.hex("vector", frame.vector);
    root.log.hex("error code", frame.code);

    root.log.hex("rip", frame.rip);
    root.log.hex("rsp", frame.rsp);
    root.log.hex("cr2", asm volatile ("mov %%cr2, %[value]" // Read the faulting memory address.
        : [value] "=r" (-> usize),
    ));

    root.log.hex("rax", frame.rax);
    root.log.hex("rbx", frame.rbx);
    root.log.hex("rcx", frame.rcx);
    root.log.hex("rdx", frame.rdx);
    root.log.hex("rsi", frame.rsi);
    root.log.hex("rdi", frame.rdi);
    root.log.hex("rbp", frame.rbp);
    root.log.hex("r8", frame.r8);
    root.log.hex("r9", frame.r9);
    root.log.hex("r10", frame.r10);
    root.log.hex("r11", frame.r11);
    root.log.hex("r12", frame.r12);
    root.log.hex("r13", frame.r13);
    root.log.hex("r14", frame.r14);
    root.log.hex("r15", frame.r15);

    root.log.hex("rflags", frame.flags);
    root.log.hex("cr3", active_root);

}
