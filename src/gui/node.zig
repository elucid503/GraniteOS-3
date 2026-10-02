const std = @import("std");

const canvas = @import("canvas.zig");
const draw = @import("draw.zig");
const font = @import("font.zig");
const style = @import("style.zig");
const text = @import("text.zig");

const Rect = canvas.Rect;
const Point = canvas.Point;
const List = draw.List;
const Style = style.Style;
const Text = text.Text;

const dot = 8;
const pitch = 14;
const caret = 2;

pub const Size = struct {

    width: i32 = 0,
    height: i32 = 0,

};

/// What a node shows: children laid out by its style, one line of text, a text field, or a wrapping text area.
pub const Content = union(enum) {

    box: []const *Node,
    label: []const u8,
    input: *Text,
    area: *Text,

};

/// The nodes a window highlights while drawing.
pub const Marks = struct {

    hover: ?*const Node = null,
    focus: ?*const Node = null,
    pressed: ?*const Node = null,

};

/// One element of a retained UI tree; the app owns every node and its window lays them out.
pub const Node = struct {

    style: Style = .{},
    content: Content = .{

        .box = &.{},

    },

    /// Runs on click, or on Enter or Space while focused; makes the node focusable.
    action: ?*const fn (*Node) void = null,

    /// Free for the app, such as an index into its own data.
    data: usize = 0,

    hidden: bool = false,
    selected: bool = false,

    /// Shown with the `invalid` style until the user edits the node.
    invalid: bool = false,

    /// Where the last layout put the node, in surface coordinates.
    rect: Rect = .{},

    pub fn focusable(self: *const Node) bool {

        return self.shown() and (self.action != null or self.editable());

    }

    pub fn editable(self: *const Node) bool {

        return self.content == .input or self.content == .area;

    }

    /// Visible after the last layout, so no hidden ancestor either.
    pub fn shown(self: *const Node) bool {

        return !self.hidden and self.rect.width > 0 and self.rect.height > 0;

    }

    // ponytail: containers re-measure children at each level, O(nodes x depth); cache sizes if trees grow deep.
    pub fn measure(self: *const Node) Size {

        if (self.hidden) return .{};

        const box = &self.style;
        const face = font.sans();
        var inner = Size{};

        switch (self.content) {

            .box => |children| {

                var count: i32 = 0;

                for (children) |child| {

                    if (child.hidden) continue;

                    const size = child.measure();

                    if (box.direction == .row) {

                        inner.width += size.width;
                        inner.height = @max(inner.height, size.height);

                    } else {

                        inner.width = @max(inner.width, size.width);
                        inner.height += size.height;

                    }

                    count += 1;

                }

                const gaps = box.gap * @max(count - 1, 0);

                if (box.direction == .row) inner.width += gaps else inner.height += gaps;

            },
            .label => |string| inner = .{

                .width = @intFromFloat(@ceil(face.measure(string, box.size / face.units))),
                .height = text.leading(face, box.size),

            },
            .input, .area => inner.height = text.leading(face, box.size),

        }

        return .{

            .width = box.width orelse inner.width + box.padding.left + box.padding.right,
            .height = box.height orelse inner.height + box.padding.top + box.padding.bottom,

        };

    }

    /// Places the node and its children in `area`, growing `damage` by every rectangle that moved.
    pub fn arrange(self: *Node, area: Rect, damage: *Rect) void {

        const target = if (self.hidden) Rect{} else area;

        if (!std.meta.eql(self.rect, target)) {

            damage.* = damage.join(self.rect).join(target);
            self.rect = target;

        }

        const children = switch (self.content) {

            .box => |children| children,
            else => return,

        };

        const box = &self.style;
        const inner = box.padding.shrink(target);
        const row = box.direction == .row;
        const span = if (row) inner.width else inner.height;
        const across = if (row) inner.height else inner.width;
        var used: i32 = 0;
        var grow: i32 = 0;
        var count: i32 = 0;

        for (children) |child| {

            if (child.hidden) continue;

            const size = child.measure();

            used += if (row) size.width else size.height;
            grow += child.style.grow;
            count += 1;

        }

        const free = @max(span - used - box.gap * @max(count - 1, 0), 0);
        var offset: i32 = if (grow != 0) 0 else switch (box.justify) {

            .center => @divTrunc(free, 2),
            .end => free,
            else => 0,

        };

        for (children) |child| {

            if (self.hidden or child.hidden) {

                child.arrange(.{}, damage);
                continue;

            }

            const size = child.measure();
            const fixed = if (row) child.style.height else child.style.width;
            const natural = if (row) size.height else size.width;
            const length = (if (row) size.width else size.height) + if (grow != 0) @divTrunc(free * child.style.grow, grow) else 0;
            const thickness = if (box.items == .stretch and fixed == null) across else @min(natural, across);
            const shift = switch (box.items) {

                .center => @divTrunc(across - thickness, 2),
                .end => across - thickness,
                else => 0,

            };

            child.arrange(if (row) .{

                .x = inner.x + offset,
                .y = inner.y + shift,
                .width = length,
                .height = thickness,

            } else .{

                .x = inner.x + shift,
                .y = inner.y + offset,
                .width = thickness,
                .height = length,

            }, damage);

            offset += length + box.gap;

        }

    }

    /// Records the node and its children inside the list limit; `under` is the colour already behind it.
    pub fn paint(self: *Node, target: *List, marks: Marks, under: u32) void {

        if (!self.shown()) return;
        if (target.limit) |limit| if (limit.intersect(self.rect) == null) return;

        const box = &self.style;
        const colors = box.paint(.{

            .hover = marks.hover == self,
            .selected = self.selected,
            .focus = marks.focus == self,
            .pressed = marks.pressed == self,
            .invalid = self.invalid,

        });
        const fill = colors.background orelse under;
        const color = colors.color orelse box.color;
        const inner = box.padding.shrink(self.rect);

        if (colors.border != null and box.border_width > 0) {

            target.round(self.rect, box.radius, colors.border.?);
            target.round(self.rect.inset(box.border_width), box.radius - box.border_width, fill);

        } else if (colors.background) |background| {

            target.round(self.rect, box.radius, background);

        }

        if (self.content == .box) {

            for (self.content.box) |child| child.paint(target, marks, fill);
            return;

        }

        const limit = target.limit;

        defer target.limit = limit;
        target.limit = if (limit) |outer| outer.intersect(self.rect) else self.rect;
        if (target.limit == null) return;

        switch (self.content) {

            .box => unreachable,
            .label => |string| target.label(string, box.size, inner, color, box.text_align),
            .input => |edit| line(edit, target, box, inner, color, marks.focus == self),
            .area => |edit| lines(edit, target, box, inner, color, marks.focus == self),

        }

    }

    /// The deepest focusable node under `point`.
    pub fn hit(self: *Node, point: Point) ?*Node {

        if (!self.shown() or !self.rect.contains(point)) return null;

        if (self.content == .box) {

            for (self.content.box) |child| {

                if (child.hit(point)) |found| return found;

            }

        }

        return if (self.focusable()) self else null;

    }

    /// Appends the focusable nodes in tree order to `list`, returning how many there are.
    pub fn collect(self: *Node, list: []*Node, count: usize) usize {

        if (!self.shown()) return count;

        var total = count;

        if (self.focusable() and total < list.len) {

            list[total] = self;
            total += 1;

        }

        if (self.content == .box) {

            for (self.content.box) |child| total = child.collect(list, total);

        }

        return total;

    }

};

fn line(edit: *Text, target: *List, box: *const Style, inner: Rect, color: u32, focused: bool) void {

    const face = font.sans();

    if (edit.length == 0) {

        target.label(edit.placeholder, box.size, inner, box.muted, box.text_align);

    } else if (edit.secret) {

        for (0..@min(edit.length, @as(usize, @intCast(@max(@divTrunc(inner.width, pitch), 0))))) |index| {

            target.round(.{

                .x = inner.x + @as(i32, @intCast(index)) * pitch + 2,
                .y = inner.y + @divTrunc(inner.height - dot, 2),
                .width = dot,
                .height = dot,

            }, dot / 2, color);

        }

    } else {

        target.label(edit.text(), box.size, inner, color, .left);

    }

    if (!focused) return;

    const offset: i32 = if (edit.secret) @intCast(edit.caret * pitch) else @intFromFloat(face.measure(edit.buffer[0..edit.caret], box.size / face.units));
    const height = text.leading(face, box.size);

    target.fill(.{

        .x = inner.x + offset,
        .y = inner.y + @divTrunc(inner.height - height, 2),
        .width = caret,
        .height = height,

    }, box.focus.border orelse color);

}

fn lines(edit: *Text, target: *List, box: *const Style, inner: Rect, color: u32, focused: bool) void {

    const face = font.sans();
    const scale = box.size / face.units;
    const height = text.leading(face, box.size);
    const rows: usize = @intCast(@max(@divTrunc(inner.height, height), 1));
    const string = edit.text();

    if (edit.length == 0) {

        target.text(edit.placeholder, box.size, inner.x, inner.y + baseline(face, box.size), box.muted);

    }

    var wrapped = text.Lines.init(face, string, box.size, inner.width);
    var index: usize = 0;

    // Scroll so the caret's line stays in view.
    while (wrapped.next()) |span| : (index += 1) {

        if (!span.holds(string, edit.caret)) continue;

        if (index < edit.top) edit.top = index;
        if (index >= edit.top + rows) edit.top = index + 1 - rows;

        break;

    }

    wrapped = text.Lines.init(face, string, box.size, inner.width);
    index = 0;

    while (wrapped.next()) |span| : (index += 1) {

        if (index < edit.top) continue;
        if (index >= edit.top + rows) break;

        const y = inner.y + @as(i32, @intCast(index - edit.top)) * height;

        target.text(string[span.start..span.end], box.size, inner.x, y + baseline(face, box.size), color);

        if (focused and span.holds(string, edit.caret)) target.fill(.{

            .x = inner.x + @as(i32, @intFromFloat(face.measure(string[span.start..edit.caret], scale))),
            .y = y,
            .width = caret,
            .height = height,

        }, box.focus.border orelse color);

    }

}

fn baseline(face: *const font.Font, size: f32) i32 {

    return @intFromFloat(@as(f32, @floatFromInt(face.ascent)) * size / face.units);

}
