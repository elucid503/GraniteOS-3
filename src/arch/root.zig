const builtin = @import("builtin");

pub const cpu = switch (builtin.cpu.arch) {

    .x86_64 => @import("x86/cpu.zig"),
    else => @compileError("Unsupported boot architecture"),

};
