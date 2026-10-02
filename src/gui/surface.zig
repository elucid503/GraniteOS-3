const std = @import("std");

const canvas = @import("canvas.zig");

const api = @import("api");

/// Client-drawn pixels shown by the display; re-attached automatically if the display restarts.
pub const Surface = struct {

    canvas: canvas.Canvas,
    area: canvas.Rect,
    memory: api.Shared,

    display: api.Display = .{},
    id: u64 = 0,
    attached: bool = false,

    /// Allocates pixels for `area` in screen coordinates; nothing shows until the first `damage`.
    pub fn open(area: canvas.Rect) !Surface {

        const count: usize = @intCast(area.width * area.height);
        const memory = try api.share((count * 4 + 4095) / 4096);

        return .{

            .canvas = .{

                .pixels = std.mem.bytesAsSlice(u32, memory.bytes[0 .. count * 4]),
                .width = @intCast(area.width),
                .height = @intCast(area.height),

            },
            .area = area,
            .memory = memory,

        };

    }

    /// Shows `rect` of the canvas again; the first call after (re)attaching shows everything.
    pub fn damage(self: *Surface, rect: canvas.Rect) !void {

        for (0..2) |_| {

            const changed = if (self.attached) rect else self.canvas.bounds();

            if (!self.attached) {

                self.id = try self.display.surface(self.memory.handle, wire(self.area));
                self.attached = true;

            }

            self.display.damage(self.id, wire(changed)) catch |err| {

                if (err != error.Missing and err != error.Denied) return err;
                self.attached = false;
                continue;

            };

            return;

        }

        return error.Missing;

    }

    /// Waits up to `timeout` ticks for input; null when none arrived.
    pub fn next(self: *Surface, timeout: u64) !?api.Event {

        if (!self.attached) try self.damage(self.canvas.bounds());

        return self.display.wait(self.id, timeout) catch |err| {

            if (err != error.Missing and err != error.Denied) return err;
            self.attached = false;

            return null;

        };

    }

};

/// The screen's size, from the display service.
pub fn screen() !canvas.Rect {

    var display = api.Display{};
    const size = try display.size();

    return .{

        .width = size.width,
        .height = size.height,

    };

}

fn wire(rect: canvas.Rect) api.display.Area {

    return .{

        .x = rect.x,
        .y = rect.y,
        .width = rect.width,
        .height = rect.height,

    };

}
