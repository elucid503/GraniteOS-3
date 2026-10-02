const canvas = @import("canvas.zig");
const font = @import("font.zig");
const node = @import("node.zig");
const surface = @import("surface.zig");
const theme = @import("theme.zig");

const api = @import("api");

const Node = node.Node;
const Rect = canvas.Rect;

pub const Layer = api.display.Layer;

pub const Options = struct {

    title: []const u8 = "",
    layer: Layer = .window,

    /// Content size, centred on screen; null fills the screen.
    width: ?i32 = null,
    height: ?i32 = null,

};

/// A surface showing a node tree: lays it out, repaints what changed, and routes input to its nodes.
pub const Window = struct {

    surface: surface.Surface,
    root: *Node,

    /// Covers the whole screen, so it follows the screen's size.
    fullscreen: bool,

    focused: ?*Node = null,
    hovered: ?*Node = null,
    pressed: ?*Node = null,

    damage: Rect = .{},

    /// Waits for the display, then opens a window showing `root`.
    pub fn open(root: *Node, options: Options) !Window {

        const screen = while (true) {

            break surface.screen() catch {

                api.sleep(100);
                continue;

            };

        };

        const width = options.width orelse screen.width;
        const height = options.height orelse screen.height;
        var area = screen.centered(width, height);

        if (options.layer == .window) area.y += @divTrunc(theme.title, 2);

        var window = Window{

            .surface = try surface.Surface.open(api.display.Spec.init(.{

                .x = area.x,
                .y = area.y,
                .width = width,
                .height = height,

            }, options.layer, options.title)),
            .root = root,
            .fullscreen = options.width == null and options.height == null,

        };

        window.refresh();

        return window;

    }

    /// Repaints what changed, then waits up to `timeout` ticks for input; returns events no node handled.
    pub fn next(self: *Window, timeout: u64) ?api.Event {

        self.update();

        const waited = self.surface.next(timeout) catch null;

        // A restarted display lost our window, so the next update shows it afresh.
        if (!self.surface.attached) {

            self.refresh();
            api.sleep(50);

        }

        const event = waited orelse return null;

        if (event.kind == .resize and self.fullscreen) self.fill(event.x, event.y);

        if (!self.dispatch(event)) return event;

        self.update();

        return null;

    }

    /// Schedules a full repaint, after changes too broad to invalidate node by node.
    pub fn refresh(self: *Window) void {

        self.damage = self.surface.list.bounds();

    }

    /// Schedules `target` to repaint, after changing it in a way that keeps its size.
    pub fn invalidate(self: *Window, target: *const Node) void {

        self.damage = self.damage.join(target.rect);

    }

    /// Swaps in a new tree.
    pub fn show(self: *Window, root: *Node) void {

        self.root = root;
        self.focused = null;
        self.hovered = null;
        self.pressed = null;
        self.refresh();

    }

    pub fn focus(self: *Window, target: ?*Node) void {

        if (self.focused == target) return;
        if (self.focused) |old| self.invalidate(old);
        if (target) |new| self.invalidate(new);

        self.focused = target;

    }

    /// Restacks the window, such as a lock screen dropping below other windows once unlocked.
    pub fn stack(self: *Window, layer: Layer) void {

        var spec = self.surface.spec;
        if (spec.layer == layer) return;

        spec.layer = layer;
        self.surface.place(spec) catch {

        };

    }

    /// Grows or shrinks to a `width` by `height` screen.
    fn fill(self: *Window, width: i16, height: i16) void {

        var spec = self.surface.spec;

        spec.area = .{

            .width = width,
            .height = height,

        };
        self.surface.place(spec) catch {

        };
        self.refresh();

    }

    fn update(self: *Window) void {

        const bounds = self.surface.list.bounds();
        const target = &self.surface.list;

        self.root.arrange(bounds, &self.damage);

        for ([_]*?*Node{ &self.focused, &self.hovered, &self.pressed }) |mark| {

            if (mark.*) |marked| if (!marked.shown()) {

                mark.* = null;

            };

        }

        if (self.damage.intersect(bounds) == null) return;

        // The GPU redraws a whole window cheaply, so every change re-records the tree.
        const background = self.root.style.background orelse theme.background;

        self.damage = .{};
        target.reset();
        target.fill(bounds, background);
        self.root.paint(target, .{

            .hover = self.hovered,
            .focus = self.focused,
            .pressed = self.pressed,

        }, background);
        self.surface.present() catch self.refresh();

    }

    fn dispatch(self: *Window, event: api.Event) bool {

        const at = canvas.Point{

            .x = event.x,
            .y = event.y,

        };

        switch (event.kind) {

            .pointer => {

                const target = self.root.hit(at);

                if (target != self.hovered) {

                    if (self.hovered) |old| self.invalidate(old);
                    if (target) |new| self.invalidate(new);
                    self.hovered = target;

                }

                return true;

            },
            .button => {

                if (event.code != 0) return false;

                const target = self.root.hit(at);

                if (event.pressed) {

                    self.pressed = target;

                    const new = target orelse return false;

                    self.invalidate(new);
                    // Like most desktops, clicking a button does not steal focus from the field being typed in.
                    if (new.editable()) self.focus(new);

                    return true;

                }

                const was = self.pressed orelse return false;

                self.pressed = null;
                self.invalidate(was);
                if (was == target) activate(was);

                return true;

            },
            .key => return self.key(event),
            else => return false,

        }

    }

    fn key(self: *Window, event: api.Event) bool {

        if (!event.pressed) return false;

        if (event.key() == .tab and !event.modifiers.control and !event.modifiers.alt) {

            self.cycle(event.modifiers.shift);
            return true;

        }

        const target = self.focused orelse return false;

        switch (target.content) {

            .input, .area => |edit| {

                const multiline = target.content == .area;
                const vertical = multiline and (event.key() == .up or event.key() == .down);

                if (event.key() == .enter and !multiline) {

                    if (target.action == null) return false;
                    activate(target);

                    return true;

                }

                const changed = if (vertical) edit.vertical(font.sans(), target.style.size, target.style.padding.shrink(target.rect).width, if (event.key() == .up) -1 else 1) else edit.key(event, multiline);
                if (!changed) return false;

                target.invalid = false;
                self.invalidate(target);

                return true;

            },
            else => {

                const press = event.key() == .enter or (event.key() == .character and event.char == ' ');
                if (target.action == null or !press) return false;

                activate(target);

                return true;

            },

        }

    }

    /// Moves focus to the next focusable node, or the previous one when `backwards`.
    fn cycle(self: *Window, backwards: bool) void {

        var list: [64]*Node = undefined;
        const count = self.root.collect(&list, 0);
        if (count == 0) return;

        const current = for (list[0..count], 0..) |entry, index| {

            if (entry == self.focused) break index;

        } else if (backwards) 0 else count - 1;

        self.focus(list[if (backwards) (current + count - 1) % count else (current + 1) % count]);

    }

};

fn activate(target: *Node) void {

    if (target.action) |action| action(target);

}
