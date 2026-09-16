const std = @import("std");

const boot = @import("../info.zig");

const uefi = std.os.uefi;

const Descriptor = uefi.tables.MemoryDescriptor;
const Services = uefi.tables.BootServices;

const MapError = error{ InvalidMemoryMap, MemoryMapUnstable, MemoryMapReadFailed, ExitBootServicesFailed };

pub const Map = struct {

    buffer: []align(8) u8,
    regions: []boot.Region,

    size: usize = 0,
    stride: usize = 0,

    version: u32 = 0,

    key: uefi.tables.MemoryMapKey = @enumFromInt(0),

    pub fn allocate(services: *Services) !Map {

        var size: usize = 0;
        var stride: usize = 0;

        var version: u32 = 0;

        var key: uefi.tables.MemoryMapKey = @enumFromInt(0);

        const status = services._getMemoryMap(&size, null, &key, &stride, &version);

        if (status != .buffer_too_small or stride < @sizeOf(Descriptor) or size == 0) return MapError.InvalidMemoryMap;

        // Spare descriptors cover allocations and exit callbacks without allocating on retry.
        const capacity = try std.math.add(usize, size, try std.math.mul(usize, stride, 32));
        const buffer = try services.allocatePool(.loader_data, capacity);

        const region_count = capacity / @sizeOf(Descriptor);
        const region_bytes = try services.allocatePool(.loader_data, try std.math.mul(usize, region_count, @sizeOf(boot.Region)));

        return .{

            .buffer = buffer,
            .regions = @as([*]boot.Region, @ptrCast(@alignCast(region_bytes.ptr)))[0..region_count],

        };

    }

    pub fn read(self: *Map, services: *Services) MapError!uefi.Status {

        self.size = self.buffer.len;

        const status = services._getMemoryMap(&self.size, self.buffer.ptr, &self.key, &self.stride, &self.version);

        if (status == .buffer_too_small) return status;
        if (status != .success) return MapError.MemoryMapReadFailed;

        if (self.size > self.buffer.len) return MapError.InvalidMemoryMap;

        try validate(self.buffer[0..self.size], self.stride, self.version);

        return .success;

    }

    pub fn finish(self: *Map, services: *Services, handle: uefi.Handle, attempted: *bool) MapError![]const boot.Region {

        for (0..8) |_| {

            if (try self.read(services) != .success) return MapError.MemoryMapUnstable;

            attempted.* = true;

            const status = services._exitBootServices(handle, self.key);

            if (status == .success) return try convert(self.buffer[0..self.size], self.stride, self.version, self.regions);
            if (status != .invalid_parameter) return MapError.ExitBootServicesFailed;

        }

        return MapError.MemoryMapUnstable;

    }

};

fn validate(bytes: []const u8, stride: usize, version: u32) MapError!void {

    if (version != 1 or stride < @sizeOf(Descriptor) or bytes.len == 0 or bytes.len % stride != 0) return MapError.InvalidMemoryMap;

}

pub fn convert(bytes: []const u8, stride: usize, version: u32, regions: []boot.Region) MapError![]const boot.Region {

    try validate(bytes, stride, version);

    const count = bytes.len / stride;

    if (count > regions.len) return MapError.InvalidMemoryMap;

    for (0..count) |index| {

        const offset = index * stride;
        const descriptor = std.mem.bytesToValue(Descriptor, bytes[offset..][0..@sizeOf(Descriptor)]);
        const size = std.math.mul(u64, descriptor.number_of_pages, 4096) catch return MapError.InvalidMemoryMap;

        _ = std.math.add(u64, descriptor.physical_start, size) catch return MapError.InvalidMemoryMap;
        if (descriptor.physical_start % 4096 != 0) return MapError.InvalidMemoryMap;

        const kind: boot.MemoryKind = if (descriptor.attribute.memory_runtime) .runtime else switch (descriptor.type) {

            .conventional_memory => .available,
            .loader_code, .loader_data => .loader,
            .boot_services_code, .boot_services_data => .firmware,
            .runtime_services_code, .runtime_services_data => .runtime,
            .acpi_reclaim_memory => .acpi,
            .persistent_memory => .persistent,
            .memory_mapped_io, .memory_mapped_io_port_space => .mmio,
            .unusable_memory => .unusable,
            else => .reserved,

        };

        regions[index] = .{

            .base = descriptor.physical_start,
            .size = size,
            .kind = kind,

        };

    }

    return regions[0..count];

}
