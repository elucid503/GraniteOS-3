const std = @import("std");

const boot = @import("../info.zig");
const memory = @import("map.zig");
const graphics = @import("graphics.zig");
const Log = @import("../../debug/log.zig").Log;

const uefi = std.os.uefi;
const LoaderError = error{ MissingBootServices, MissingLoadedImage, MemoryMapUnstable };
var exit_attempted = false;

pub fn prepare(log: Log) !*const boot.Info {

    const table = uefi.system_table;
    const services = table.boot_services orelse return LoaderError.MissingBootServices;

    try services.setWatchdogTimer(0, 0, null);
    console("\r\nGraniteOS 3\r\nPreparing firmware handoff.\r\nA green band at the top confirms boot completed.\r\nSerial diagnostics: COM1, 115200 8N1.\r\n");

    const loaded = try services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) orelse return LoaderError.MissingLoadedImage;
    const info_bytes = try services.allocatePool(.loader_data, @sizeOf(boot.Info));
    const info: *boot.Info = @ptrCast(@alignCast(info_bytes.ptr));
    const stack = try services.allocatePages(.any, .loader_data, 16);
    const trampoline = try services.allocatePages(.{

        .max_address = @ptrFromInt(0xff000),

    }, .loader_data, 1);

    info.* = .{

        .memory = &.{ },

        .image = .{

            .base = @intFromPtr(loaded.image_base),
            .size = loaded.image_size,
            .kind = .loader,

        },
        .stack = .{

            .base = @intFromPtr(stack.ptr),
            .size = stack.len * 4096,
            .kind = .loader,

        },
        .framebuffer = try graphics.capture(services),
        .acpi_rsdp = findAcpi(table),
        .trampoline = @intFromPtr(trampoline.ptr),

    };

    var map = try memory.Map.allocate(services);

    for (0..8) |_| {

        if (try map.read(services) == .success) break;

        try services.freePool(map.buffer.ptr);
        try services.freePool(@ptrCast(map.regions.ptr));

        map = try memory.Map.allocate(services);

    } else return LoaderError.MemoryMapUnstable;

    log.line("exit firmware");
    info.memory = try map.finish(services, uefi.handle, &exit_attempted);
    log.line("firmware released");

    return info;

}

fn findAcpi(table: *uefi.tables.SystemTable) ?u64 {

    const Configuration = uefi.tables.ConfigurationTable;
    var legacy: ?u64 = null;

    for (table.configuration_table[0..table.number_of_table_entries]) |entry| {

        if (entry.vendor_guid.eql(Configuration.acpi_20_table_guid)) return @intFromPtr(entry.vendor_table);
        if (entry.vendor_guid.eql(Configuration.acpi_10_table_guid)) legacy = @intFromPtr(entry.vendor_table);

    }

    return legacy;

}

fn console(comptime message: []const u8) void {

    if (uefi.system_table.con_out) |output| {

        _ = output.outputString(std.unicode.utf8ToUtf16LeStringLiteral(message)) catch return;

    }

}

pub fn reportFailure(name: []const u8) void {

    if (exit_attempted) return;

    console("\r\nBOOT FAILED: ");

    if (uefi.system_table.con_out) |output| {

        for (name) |byte| {

            const character = [_:0]u16{

                byte,

            };

            _ = output.outputString(&character) catch return;

        }

    }

    console("\r\nSee serial diagnostics. Reset to return to firmware.\r\n");

}
