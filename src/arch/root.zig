const builtin = @import("builtin");

pub const cpu = switch (builtin.cpu.arch) {

    .x86_64 => @import("x86/cpu.zig"),
    else => @compileError("Unsupported boot architecture"),

};

pub const paging = @import("x86/paging.zig");
pub const context = @import("x86/context.zig");
pub const machine = @import("x86/machine.zig");
