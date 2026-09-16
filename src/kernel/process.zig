const arch = @import("../arch/root.zig");
const elf = @import("elf.zig");
const memory = @import("memory.zig");

const paging = arch.paging;
pub const State = enum {

    ready,
    running,
    sending,
    receiving,
    dead,

};

pub const Right = enum {

    send,
    port,
    mmio,
    reboot,
    log,

};

pub const Capability = struct {

    next: ?*Capability = null,
    right: Right,

    base: u64 = 0,
    size: u64 = 0,

};

pub const Process = struct {

    next: ?*Process = null,
    id: u64,
    state: State = .ready,

    space: paging.Space,
    context: arch.context.Context,

    capabilities: ?*Capability = null,
    destination: u64 = 0,
    sequence: u64 = 0,
    message: u64 = 0,

    home: u32,
    preemptions: usize = 0,

    allocation: usize = paging.user_base + 0x10000000,
    cursor: usize = paging.user_base + 0x10000000,

    pub fn create(kernel: paging.Space, bytes: []const u8, id: u64, argument: usize, home: u32) !*Process {

        const stack_top = paging.user_end - 4096;
        const image = try elf.Image.parse(bytes, paging.user_base, paging.user_base + 0x10000000);

        const address = try kernel.frames.alloc();
        errdefer kernel.frames.release(address) catch @panic("Process ownership");

        const self: *Process = @ptrFromInt(address);
        var space = try paging.Space.process(kernel);
        errdefer space.destroy();

        for (0..image.header.phnum) |index| {

            const segment = image.program(index);

            if (segment.kind != 1 or segment.memory_size == 0) continue;

            var virtual = segment.address & ~@as(u64, 4095);
            const end = segment.address + segment.memory_size;

            while (virtual < end) : (virtual += 4096) {

                const physical = try kernel.frames.alloc();
                errdefer kernel.frames.release(physical) catch @panic("Image page ownership");

                const page: *[4096]u8 = @ptrFromInt(physical);

                @memset(page, 0);

                const first = @max(virtual, segment.address);
                const last = @min(virtual + 4096, segment.address + segment.file_size);

                if (first < last) @memcpy(page[first - virtual .. last - virtual], bytes[segment.offset + first - segment.address .. segment.offset + last - segment.address]);

                const flags: u64 = paging.user | (if (segment.flags & 2 != 0) paging.writable else @as(u64, 0)) | (if (segment.flags & 1 == 0) paging.nx else @as(u64, 0));

                try space.map(@intCast(virtual), physical, flags);

            }

        }

        for (0..4) |index| {

            const physical = try kernel.frames.alloc();
            errdefer kernel.frames.release(physical) catch @panic("Stack ownership");

            @memset(@as(*[4096]u8, @ptrFromInt(physical)), 0);
            try space.map(stack_top - (index + 1) * 4096, physical, paging.user | paging.writable | paging.nx);

        }

        self.* = .{

            .id = id,
            .space = space,
            .context = arch.context.Context.init(image.header.entry, stack_top, argument, false),
            .home = home,

        };

        return self;

    }

    pub fn grant(self: *Process, right: Right, base: u64, size: u64) !void {

        const capability: *Capability = @ptrFromInt(try self.space.frames.alloc());

        capability.* = .{

            .next = self.capabilities,
            .right = right,
            .base = base,
            .size = size,

        };

        self.capabilities = capability;

    }

    pub fn vacant(self: *const Process) memory.MemoryError!usize {

        var address = self.cursor;

        while (address < paging.user_end - 0x100000) : (address += 4096) {

            if (!self.space.present(address)) return address;

        }

        return error.OutOfMemory;

    }

    pub fn mapped(self: *Process, address: usize) void {

        self.cursor = address + 4096;
        self.allocation = @max(self.allocation, self.cursor);

    }

    pub fn permits(self: *const Process, right: Right, base: u64, size: u64) bool {

        var current = self.capabilities;

        while (current) |capability| : (current = capability.next) {

            if (capability.right == right and base >= capability.base and base - capability.base <= capability.size and size <= capability.size - (base - capability.base)) return true;

        }

        return false;

    }

    pub fn destroy(self: *Process) void {

        const frames = self.space.frames;

        self.space.destroy();

        var current = self.capabilities;

        while (current) |capability| {

            current = capability.next;
            frames.release(@intFromPtr(capability)) catch @panic("Capability ownership");

        }

        frames.release(@intFromPtr(self)) catch @panic("Process ownership");

    }

};

comptime {

    if (@sizeOf(Process) > 4096) @compileError("Process exceeds a page");

}
