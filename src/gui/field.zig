const std = @import("std");

const canvas = @import("canvas.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");

const api = @import("api");

const dot = 8;
const pitch = 14;
const padding = 14;

/// A single-line text input; secret fields show dots and are wiped by `clear`.
pub const Field = struct {

    bytes: [64]u8 = undefined,
    length: usize = 0,
    caret: usize = 0,

    secret: bool = false,

    pub fn text(self: *const Field) []const u8 {

        return self.bytes[0..self.length];

    }

    pub fn clear(self: *Field) void {

        std.crypto.secureZero(u8, &self.bytes);
        self.length = 0;
        self.caret = 0;

    }

    /// Applies an editing key press; true when the text or caret changed.
    pub fn key(self: *Field, event: api.Event) bool {

        if (event.kind != .key or !event.pressed) return false;

        switch (event.key()) {

            .character => {

                if (event.modifiers.control or event.modifiers.alt or event.char < 0x20 or event.char > 0x7e or self.length == self.bytes.len) return false;

                std.mem.copyBackwards(u8, self.bytes[self.caret + 1 .. self.length + 1], self.bytes[self.caret..self.length]);
                self.bytes[self.caret] = @intCast(event.char);
                self.length += 1;
                self.caret += 1;

            },
            .backspace => {

                if (self.caret == 0) return false;

                std.mem.copyForwards(u8, self.bytes[self.caret - 1 .. self.length - 1], self.bytes[self.caret..self.length]);
                self.length -= 1;
                self.caret -= 1;

            },
            .delete => {

                if (self.caret == self.length) return false;

                std.mem.copyForwards(u8, self.bytes[self.caret .. self.length - 1], self.bytes[self.caret + 1 .. self.length]);
                self.length -= 1;

            },
            .left => {

                if (self.caret == 0) return false;
                self.caret -= 1;

            },
            .right => {

                if (self.caret == self.length) return false;
                self.caret += 1;

            },
            .home => self.caret = 0,
            .end => self.caret = self.length,
            else => return false,

        }

        return true;

    }

    pub fn draw(self: *const Field, target: *canvas.Canvas, area: canvas.Rect, placeholder: []const u8, focused: bool, failed: bool) void {

        const face = font.sans();
        const edge: u32 = if (failed) theme.danger else if (focused) theme.accent else theme.field;
        const inner = canvas.Rect{

            .x = area.x + padding,
            .y = area.y,
            .width = area.width - 2 * padding,
            .height = area.height,

        };

        target.round(area, theme.radius, edge);
        target.round(area.inset(theme.border), theme.radius - theme.border, theme.field);

        if (self.length == 0) {

            target.label(face, placeholder, theme.body, inner, theme.muted, .left);

        } else if (self.secret) {

            for (0..@min(self.length, @as(usize, @intCast(@divTrunc(inner.width, pitch))))) |index| {

                target.round(.{

                    .x = inner.x + @as(i32, @intCast(index)) * pitch + 2,
                    .y = inner.y + @divTrunc(inner.height - dot, 2),
                    .width = dot,
                    .height = dot,

                }, dot / 2, theme.text);

            }

        } else {

            target.label(face, self.text(), theme.body, inner, theme.text, .left);

        }

        if (!focused) return;

        const offset: i32 = if (self.secret) @intCast(self.caret * pitch) else @intFromFloat(face.measure(self.bytes[0..self.caret], theme.body / face.units));

        target.fill(.{

            .x = inner.x + offset,
            .y = inner.y + @divTrunc(inner.height - 20, 2),
            .width = 2,
            .height = 20,

        }, theme.accent);

    }

};
