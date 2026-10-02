pub const canvas = @import("canvas.zig");
pub const Canvas = canvas.Canvas;
pub const Rect = canvas.Rect;
pub const Point = canvas.Point;

pub const draw = @import("draw.zig");

pub const font = @import("font.zig");
pub const Font = font.Font;
pub const sans = @import("font.zig").sans;
pub const theme = @import("theme.zig");

pub const style = @import("style.zig");
pub const Style = style.Style;
pub const Paint = style.Paint;
pub const Edges = style.Edges;

pub const Node = @import("node.zig").Node;
pub const Text = @import("text.zig").Text;

pub const Surface = @import("surface.zig").Surface;
pub const screen = @import("surface.zig").screen;
pub const Window = @import("window.zig").Window;
pub const Layer = @import("window.zig").Layer;

/// A container laying out `children` as `look` says.
pub fn box(look: Style, children: []const *Node) Node {

    return .{

        .style = look,
        .content = .{

            .box = children,

        },

    };

}

pub fn label(string: []const u8, look: Style) Node {

    return .{

        .style = look,
        .content = .{

            .label = string,

        },

    };

}

pub fn button(string: []const u8, action: *const fn (*Node) void) Node {

    var result = label(string, theme.button);

    result.action = action;

    return result;

}

pub fn input(edit: *Text) Node {

    return .{

        .style = theme.input,
        .content = .{

            .input = edit,

        },

    };

}

/// A multi-line text field that wraps and scrolls.
pub fn area(edit: *Text) Node {

    return .{

        .style = theme.area,
        .content = .{

            .area = edit,

        },

    };

}
