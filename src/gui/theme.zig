//! The flat dark look shared by every surface.

const style = @import("style.zig");

const Style = style.Style;
const Edges = style.Edges;

pub const background = 0x141518;
pub const raised = 0x1d1e22;
pub const field = 0x25262b;
pub const selected = 0x2f3137;

pub const text = 0xe9eaec;
pub const muted = 0x8b8e96;
pub const accent = 0x5a8dee;
pub const danger = 0xe5534b;

pub const radius = 10;
pub const border = 2;
pub const spacing = 12;

pub const body: f32 = 17;
pub const small: f32 = 15;

/// Height of single-line controls such as fields and rows.
pub const control = 46;

pub const title = 32;

/// Base styles for the stock widgets; tweak them per node with `Style.with`.
pub const panel = Style{

    .padding = .all(spacing),
    .gap = spacing,

    .background = raised,
    .radius = radius,

};

pub const button = Style{

    .height = control,
    .padding = .axes(0, 18),

    .background = field,
    .border = field,
    .border_width = border,
    .radius = radius,
    .text_align = .center,

    .hover = .{

        .background = selected,
        .border = selected,

    },
    .focus = .{

        .border = accent,

    },
    .pressed = .{

        .background = accent,
        .border = accent,

    },

};

pub const input = Style{

    .height = control,
    .padding = .axes(0, 14),

    .background = field,
    .border = field,
    .border_width = border,
    .radius = radius,

    .focus = .{

        .border = accent,

    },
    .invalid = .{

        .border = danger,

    },

};

pub const area = input.with(.{

    .height = 5 * control,
    .padding = Edges.all(12),

});

/// A selectable line in a list, such as an account.
pub const item = Style{

    .height = 56,
    .padding = .axes(0, 10),
    .direction = .row,
    .gap = 14,
    .items = .center,

    .radius = radius,

    .hover = .{

        .background = raised,

    },
    .selected = .{

        .background = selected,

    },

};

pub const bar = Style{

    .height = 44,
    .padding = .axes(4, spacing),
    .direction = .row,
    .gap = spacing / 2,
    .items = .center,

    .background = raised,

};
