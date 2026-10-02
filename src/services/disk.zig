const volume = @import("volume.zig");

const api = @import("api");

const protocol = api.protocol;

var storage: u64 = 0;

/// A storage-service disk addressed in 512-byte sectors.
pub const Disk = struct {

    index: u8,

    pub fn read(self: Disk, lba: u64, bytes: []u8) volume.Error!void {

        try transfer(.read, self.index, lba, bytes);

    }

    pub fn write(self: Disk, lba: u64, bytes: []const u8) volume.Error!void {

        try transfer(.write, self.index, lba, @constCast(bytes));

    }

    pub fn flush(self: Disk) volume.Error!void {

        _ = try request(.flush, self.index, &.{});

    }

};

/// Returns the sector count of disk `index`, or zero past the last disk.
pub fn sectors(index: u8) volume.Error!u64 {

    return request(.info, index, &.{});

}

fn transfer(operation: protocol.Operation, index: u8, lba: u64, bytes: []u8) volume.Error!void {

    var done: usize = 0;

    // The storage service moves at most 64 KiB per request.
    while (done < bytes.len) {

        const size = @min(bytes.len - done, 0x10000);
        const sector = lba + done / 512;

        if (sector >> 48 != 0) return error.Invalid;
        _ = try request(operation, @as(u56, index) << 48 | @as(u56, @intCast(sector)), bytes[done..][0..size]);
        done += size;

    }

}

fn request(operation: protocol.Operation, value: u56, window: []u8) volume.Error!u64 {

    return api.query(&storage, .storage, protocol.pack(operation, value), window) catch error.Device;

}
