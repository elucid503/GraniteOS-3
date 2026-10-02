const canvas = @import("canvas.zig");
const draw = @import("draw.zig");

const api = @import("api");

/// A window's drawing commands, rendered by the display; re-attached automatically if the display restarts.
pub const Surface = struct {

    /// Records into the half of the buffer the display is not showing.
    list: draw.List,
    spec: api.display.Spec,
    memory: api.Shared,
    half: u1 = 0,

    display: api.Display = .{},
    id: u64 = 0,
    attached: bool = false,

    /// Allocates the command buffer for `spec`; nothing shows until the first `present`.
    pub fn open(spec: api.display.Spec) !Surface {

        const memory = try api.share(2 * draw.capacity / 4096);

        return .{

            .list = .{

                .bytes = memory.bytes[0..draw.capacity],
                .width = spec.area.width,
                .height = spec.area.height,

            },
            .spec = spec,
            .memory = memory,

        };

    }

    /// Shows what the list recorded, then starts a fresh list in the other half.
    pub fn present(self: *Surface) !void {

        for (0..2) |_| {

            if (!self.attached) {

                self.id = try self.display.surface(self.memory.handle, self.spec);
                self.attached = true;

            }

            self.display.present(self.id, self.half, self.list.length) catch |err| {

                if (err != error.Missing and err != error.Denied) return err;
                self.attached = false;
                continue;

            };

            self.half +%= 1;
            self.list.bytes = self.memory.bytes[@as(usize, self.half) * draw.capacity ..][0..draw.capacity];
            self.list.reset();

            return;

        }

        return error.Missing;

    }

    /// Moves, resizes, restacks, or retitles the surface.
    pub fn place(self: *Surface, spec: api.display.Spec) !void {

        self.spec = spec;
        self.list.width = spec.area.width;
        self.list.height = spec.area.height;
        if (!self.attached) return;

        self.display.place(self.id, spec) catch |err| {

            if (err != error.Missing and err != error.Denied) return err;
            self.attached = false;

        };

    }

    /// Waits up to `timeout` ticks for input; null when none arrived.
    pub fn next(self: *Surface, timeout: u64) !?api.Event {

        if (!self.attached) return error.Missing;

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
