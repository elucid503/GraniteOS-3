const std = @import("std");

const abi = @import("../../kernel/abi.zig");

pub const Frame = extern struct {

    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    r11: u64 = 0,
    r10: u64 = 0,
    r9: u64 = 0,
    r8: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rbp: u64 = 0,
    rdx: u64 = 0,
    rcx: u64 = 0,
    rbx: u64 = 0,
    rax: u64 = 0,

    vector: u64 = 0,
    code: u64 = 0,

    rip: u64 = 0,
    cs: u64 = 0x23,
    flags: u64 = 0x202,
    rsp: u64 = 0,
    ss: u64 = 0x1b,

};

pub const Context = extern struct {

    frame: Frame = .{

    },

    floating: [512]u8 align(16) = std.mem.zeroes([512]u8),

    pub fn request(self: *const Context) abi.Request {

        return .{

            .number = self.frame.rax,
            .first = self.frame.rdi,
            .second = self.frame.rsi,
            .third = self.frame.rdx,

        };

    }

    pub fn respond(self: *Context, request_value: abi.Request) void {

        self.frame.rax = request_value.number;
        self.frame.rdi = request_value.first;
        self.frame.rsi = request_value.second;
        self.frame.rdx = request_value.third;

    }

    pub fn init(entry: usize, stack: usize, argument: usize, kernel: bool) Context {

        var result = Context{

        };

        result.frame.rip = entry;
        result.frame.rsp = stack;
        result.frame.rdi = argument;

        if (kernel) {

            result.frame.cs = 8;
            result.frame.ss = 16;

        }

        result.floating[0] = 0x7f;
        result.floating[1] = 3;
        result.floating[24] = 0x80;
        result.floating[25] = 0x1f;

        return result;

    }

};

comptime {

    if (@sizeOf(Frame) != 176 or @offsetOf(Context, "floating") != 176) @compileError("Interrupt assembly layout");

}

pub extern fn restore(context: *const Context) callconv(.c) noreturn;
