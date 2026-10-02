const arch = @import("../arch/root.zig");
const root = @import("root.zig");
const process = @import("process.zig");
const ipc = @import("ipc.zig");

const paging = arch.paging;
pub const SharedError = error{ Denied, Invalid, Exhausted, NoProcess };

const Holder = struct {

    id: u64 = 0,
    address: usize = 0,

};

/// Physically contiguous memory mapped into every holder; freed once the last holder lets go.
const Region = struct {

    physical: usize = 0,
    pages: usize = 0,
    generation: u64 = 0,

    holders: [4]Holder = [_]Holder{.{}} ** 4,

};

pub const Mapping = struct {

    handle: u64,
    address: usize,
    physical: usize,
    pages: usize,

};

// ponytail: fixed table of 64 regions with 4 holders each; grow when more surfaces or sharers appear.
var regions = [_]Region{.{}} ** 64;

pub fn create(task: *process.Process, pages: u64) !Mapping {

    // 256 MiB bounds a single allocation.
    if (pages == 0 or pages > 0x10000) return error.Invalid;

    const index = for (regions, 0..) |region, slot| {

        if (region.pages == 0) break slot;

    } else return error.Exhausted;

    // ponytail: one contiguous run per region; switch to page lists once fragmentation makes large runs fail.
    const physical = try root.frames.allocRun(pages);
    errdefer release(physical, pages);

    @memset(@as([*]u8, @ptrFromInt(physical))[0 .. pages * 4096], 0);

    const region = &regions[index];

    region.* = .{

        .physical = physical,
        .pages = pages,
        .generation = region.generation +% 1,

    };
    errdefer region.pages = 0;

    return describe(region, index, try map(task, region));

}

/// Lets process `target` attach the region; only a current holder may lend it.
pub fn lend(task: *process.Process, handle: u64, target: u64) !void {

    const region = try find(handle);
    if (holder(region, task.id) == null) return error.Denied;

    const borrower = ipc.find(root.processes, target) orelse return error.NoProcess;
    if (!borrower.permits(.region, handle, 1)) try borrower.grant(.region, handle, 1);

}

pub fn attach(task: *process.Process, handle: u64) !Mapping {

    const region = try find(handle);

    if (!task.permits(.region, handle, 1)) return error.Denied;
    if (holder(region, task.id) != null) return error.Invalid;

    return describe(region, handle & 0xff, try map(task, region));

}

pub fn detach(task: *process.Process, handle: u64) !void {

    const region = try find(handle);
    const slot = holder(region, task.id) orelse return error.Denied;

    // Pages stay owned by the region, so unmapping never frees them.
    for (0..region.pages) |page| task.space.unmap(slot.address + page * 4096) catch {

    };

    slot.* = .{};
    settle(region);

}

/// Drops every hold of a reaped process.
pub fn departed(id: u64) void {

    for (&regions) |*region| {

        if (region.pages == 0) continue;

        for (&region.holders) |*slot| {

            if (slot.id == id) slot.* = .{};

        }

        settle(region);

    }

}

fn map(task: *process.Process, region: *Region) !usize {

    const slot = holder(region, 0) orelse return error.Exhausted;
    const address = try task.reserve(region.pages);

    for (0..region.pages) |page| {

        task.space.map(address + page * 4096, region.physical + page * 4096, paging.user | paging.writable | paging.nx | paging.borrowed) catch |err| {

            for (0..page) |mapped| task.space.unmap(address + mapped * 4096) catch {

            };

            return err;

        };

    }

    task.mapped(address + (region.pages - 1) * 4096);
    slot.* = .{

        .id = task.id,
        .address = address,

    };

    return address;

}

fn describe(region: *const Region, index: u64, address: usize) Mapping {

    return .{

        .handle = region.generation << 8 | index,
        .address = address,
        .physical = region.physical,
        .pages = region.pages,

    };

}

fn find(handle: u64) !*Region {

    const index = handle & 0xff;
    if (index >= regions.len) return error.Invalid;

    const region = &regions[index];
    if (region.pages == 0 or region.generation != handle >> 8) return error.Invalid;

    return region;

}

fn holder(region: *Region, id: u64) ?*Holder {

    for (&region.holders) |*slot| {

        if (slot.id == id) return slot;

    }

    return null;

}

fn settle(region: *Region) void {

    for (region.holders) |slot| {

        if (slot.id != 0) return;

    }

    release(region.physical, region.pages);
    region.pages = 0;

}

fn release(physical: usize, pages: usize) void {

    for (0..pages) |page| root.frames.release(physical + page * 4096) catch @panic("Shared page ownership");

}
