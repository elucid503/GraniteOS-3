const std = @import("std");

const boot = @import("../../boot/info.zig");

pub const AcpiError = error{ MissingAcpi, InvalidAcpi, MissingMadt, UnsupportedApic };
pub const Acpi = struct {

    regions: []const boot.Region,
    root: []const u8,
    stride: usize,

    pub fn init(info: *const boot.Info) AcpiError!Acpi {

        const address = info.acpi_rsdp orelse return error.MissingAcpi;
        const rsdp = try mapped(info.memory, address, 20);

        if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ") or !checksum(rsdp)) return error.InvalidAcpi;

        var root_address: u64 = read(u32, rsdp, 16);
        var stride: usize = 4;

        if (rsdp[15] >= 2) {

            const extended = try mapped(info.memory, address, 36);
            const length = read(u32, extended, 20);

            if (length < 36 or length > 4096 or !checksum(try mapped(info.memory, address, length))) return error.InvalidAcpi;

            const xsdt = read(u64, extended, 24);

            if (xsdt != 0) {

                root_address = xsdt;
                stride = 8;

            }

        }

        const root = try table(info.memory, root_address);

        if (!std.mem.eql(u8, root[0..4], if (stride == 8) "XSDT" else "RSDT") or (root.len - 36) % stride != 0) return error.InvalidAcpi;

        return .{

            .regions = info.memory,
            .root = root,
            .stride = stride,

        };

    }

    pub fn find(self: Acpi, signature: *const [4]u8) AcpiError!?[]const u8 {

        var offset: usize = 36;

        while (offset < self.root.len) : (offset += self.stride) {

            const address = if (self.stride == 8) read(u64, self.root, offset) else read(u32, self.root, offset);
            const data = try table(self.regions, address);

            if (std.mem.eql(u8, data[0..4], signature)) return data;

        }

        return null;

    }

};

pub fn validateMadt(bytes: []const u8) AcpiError!void {

    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "APIC") or read(u32, bytes, 4) != bytes.len or !checksum(bytes)) return error.InvalidAcpi;

    var offset: usize = 44;

    while (offset < bytes.len) {

        if (bytes.len - offset < 2) return error.InvalidAcpi;

        const size = bytes[offset + 1];

        if (size < 2 or size > bytes.len - offset) return error.InvalidAcpi;
        if ((bytes[offset] == 0 and size != 8) or (bytes[offset] == 5 and size != 12) or (bytes[offset] == 9 and size != 16)) return error.InvalidAcpi;

        offset += size;

    }

}

fn mapped(regions: []const boot.Region, address: u64, size: usize) AcpiError![]const u8 {

    if (address == 0) return error.InvalidAcpi;

    for (regions) |region| {

        if (region.kind == .mmio or region.kind == .unusable or region.kind == .reserved) continue;
        if (address >= region.base and address - region.base <= region.size and size <= region.size - (address - region.base)) return @as([*]const u8, @ptrFromInt(address))[0..size];

    }

    return error.InvalidAcpi;

}

fn table(regions: []const boot.Region, address: u64) AcpiError![]const u8 {

    const header = try mapped(regions, address, 36);
    const length = read(u32, header, 4);

    if (length < 36 or length > 1024 * 1024) return error.InvalidAcpi;

    const bytes = try mapped(regions, address, length);

    if (!checksum(bytes)) return error.InvalidAcpi;

    return bytes;

}

pub fn checksum(bytes: []const u8) bool {

    var sum: u8 = 0;

    for (bytes) |byte| sum +%= byte;

    return sum == 0;

}

pub fn read(comptime T: type, bytes: []const u8, offset: usize) T {

    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);

}
