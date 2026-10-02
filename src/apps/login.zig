const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

const width = 360;
const row_height = 56;
const avatar = 36;
const gap = 6;
const lock = api.Event.Modifiers{

    .shift = true,
    .control = true,

};

const State = enum {

    setup,
    choose,
    locked,
    session,

};

var surface: gui.Surface = undefined;
var accounts = api.Accounts{};
var state = State.choose;
var shown = gui.Rect{};

var names: [8][32]u8 = undefined;
var lengths: [8]usize = undefined;
var count: usize = 0;
var selected: usize = 0;

var name = gui.Field{};
var password = gui.Field{

    .secret = true,

};
var typing_name = false;
var failed = false;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    const screen = while (true) {

        break gui.screen() catch {

            api.sleep(100);
            continue;

        };

    };

    surface = gui.Surface.open(screen) catch api.exit(3);
    surface.canvas.fill(surface.canvas.bounds(), theme.background);
    load();
    refresh();

    while (true) {

        const event = surface.next(500) catch {

            api.sleep(50);
            continue;

        } orelse continue;

        if (react(event)) refresh();

    }

}

/// Reads the account list, retrying while the accounts service is unavailable.
fn load() void {

    count = 0;

    while (count < names.len) {

        const account = accounts.list(@intCast(count)) catch {

            api.sleep(50);
            continue;

        } orelse break;

        lengths[count] = account.name.len;
        @memcpy(names[count][0..account.name.len], account.name);
        count += 1;

    }

    selected = @min(selected, count -| 1);
    state = if (count == 0) .setup else .choose;
    typing_name = state == .setup;
    failed = false;

}

fn react(event: api.Event) bool {

    if (state == .session) {

        if (event.chord(lock, 'l')) state = .locked else if (event.chord(lock, 'q')) logout() else return false;
        return true;

    }

    if (event.kind == .button and event.pressed and event.code == 0) return click(.{

        .x = event.x,
        .y = event.y,

    });

    if (event.kind != .key or !event.pressed) return false;

    switch (event.key()) {

        .enter => {

            if (state == .setup and typing_name) typing_name = false else submit();
            return true;

        },
        .tab => {

            if (state == .setup) typing_name = !typing_name else pick((selected + 1) % count);
            return true;

        },
        .up => if (state == .choose and selected > 0) {

            pick(selected - 1);
            return true;

        },
        .down => if (state == .choose and selected + 1 < count) {

            pick(selected + 1);
            return true;

        },
        else => {

        },

    }

    const field = if (typing_name) &name else &password;
    if (!field.key(event)) return false;

    failed = false;

    return true;

}

fn click(at: gui.Point) bool {

    if (state == .setup) {

        if (fieldArea(0).contains(at)) typing_name = true else if (fieldArea(1).contains(at)) typing_name = false else return false;
        return true;

    }

    if (state != .choose) return false;

    for (0..count) |index| {

        if (!rowArea(index).contains(at)) continue;

        pick(index);
        return true;

    }

    return false;

}

fn pick(index: usize) void {

    if (state != .choose or index == selected) return;

    selected = index;
    password.clear();
    failed = false;

}

fn submit() void {

    defer password.clear();

    if (state == .setup) {

        accounts.create(name.text(), password.text(), true) catch {

            failed = true;
            return;

        };

    }

    const user = if (state == .setup) name.text() else names[selected][0..lengths[selected]];

    _ = accounts.login(user, password.text()) catch {

        failed = true;
        if (state == .setup) load();

        return;

    };

    if (state == .setup) {

        load();

        for (0..count) |index| {

            if (std.mem.eql(u8, names[index][0..lengths[index]], user)) selected = index;

        }

        name.clear();

    }

    state = .session;

}

fn logout() void {

    accounts.logout() catch {

    };
    load();

}

/// Repaints the content and shows the area it covers now or covered before.
fn refresh() void {

    const now = content();
    const dirty = shown.join(now);
    const target = &surface.canvas;

    target.fill(dirty, theme.background);

    switch (state) {

        .setup => {

            name.draw(target, fieldArea(0), "Administrator name", typing_name, failed);
            password.draw(target, fieldArea(1), "Password", !typing_name, false);

        },
        .choose => {

            for (0..count) |index| row(index, rowArea(index), index == selected);
            password.draw(target, fieldArea(0), "Password", true, failed);

        },
        .locked => {

            row(selected, rowArea(0), true);
            password.draw(target, fieldArea(0), "Password", true, failed);

        },
        .session => {

        },

    }

    shown = now;
    surface.damage(dirty) catch {

    };

}

fn row(index: usize, area: gui.Rect, active: bool) void {

    const target = &surface.canvas;
    const face = gui.sans();
    const user = names[index][0..lengths[index]];
    const circle = gui.Rect{

        .x = area.x + 10,
        .y = area.y + @divTrunc(area.height - avatar, 2),
        .width = avatar,
        .height = avatar,

    };

    if (active) target.round(area, theme.radius, theme.selected);
    target.round(circle, avatar / 2, if (active) theme.accent else theme.field);
    target.label(face, &.{std.ascii.toUpper(user[0])}, theme.body, circle, theme.text, .center);
    target.label(face, user, theme.body, .{

        .x = circle.right() + 14,
        .y = area.y,
        .width = area.right() - circle.right() - 14,
        .height = area.height,

    }, theme.text, .left);

}

/// The centred column holding the current state's controls.
fn content() gui.Rect {

    const rows: i32 = switch (state) {

        .choose => @intCast(count),
        .locked => 1,
        else => 0,

    };

    const height = switch (state) {

        .setup => 2 * theme.control + theme.spacing,
        .choose, .locked => rows * row_height + (rows - 1) * gap + 2 * theme.spacing + theme.control,
        .session => 0,

    };

    return surface.canvas.bounds().centered(width, height);

}

fn rowArea(index: usize) gui.Rect {

    const column = content();

    return .{

        .x = column.x,
        .y = column.y + @as(i32, @intCast(index)) * (row_height + gap),
        .width = width,
        .height = row_height,

    };

}

/// Field `index` counted from the top in setup, or the password field otherwise.
fn fieldArea(index: i32) gui.Rect {

    const column = content();
    const top = if (state == .setup) column.y + index * (theme.control + theme.spacing) else column.bottom() - theme.control;

    return .{

        .x = column.x,
        .y = top,
        .width = width,
        .height = theme.control,

    };

}
