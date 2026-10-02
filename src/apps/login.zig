const std = @import("std");

const api = @import("api");
const gui = @import("gui");

const theme = gui.theme;
pub const panic = api.panic;

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

const avatar = gui.Style{

    .width = 36,
    .height = 36,

    .background = theme.field,
    .radius = 18,
    .text_align = .center,

    .selected = .{

        .background = theme.accent,

    },

};

var window: gui.Window = undefined;
var accounts = api.Accounts{};
var state = State.choose;

var names: [8][32]u8 = undefined;
var lengths: [8]usize = undefined;
var initials: [8]u8 = undefined;
var count: usize = 0;
var selected: usize = 0;

var name_bytes: [64]u8 = undefined;
var name_text = gui.Text{

    .buffer = &name_bytes,
    .placeholder = "Administrator name",

};
var password_bytes: [64]u8 = undefined;
var password_text = gui.Text{

    .buffer = &password_bytes,
    .placeholder = "Password",
    .secret = true,

};

var name = gui.input(&name_text);
var password = gui.input(&password_text);

var avatars: [8]gui.Node = undefined;
var labels: [8]gui.Node = undefined;
var rows: [8]gui.Node = undefined;
var parts: [8][2]*gui.Node = undefined;
var list: [8]*gui.Node = undefined;

var users = gui.box(.{

    .gap = 6,

}, &list);
var column = gui.box(.{

    .width = 360,
    .gap = 2 * theme.spacing,

}, &.{ &name, &users, &password });
var greeter = gui.box(.{

    .justify = .center,
    .items = .center,

}, &.{&column});

var who = gui.label("", .{

    .grow = 1,

});
var notes_button = gui.button("Notes", &openNotes);
var lock_button = gui.button("Lock", &lockScreen);
var logout_button = gui.button("Log out", &logout);
var bar = gui.box(theme.bar, &.{ &notes_button, &who, &lock_button, &logout_button });
var desktop = gui.box(.{

}, &.{&bar});

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    for (&rows, 0..) |*row, index| {

        avatars[index] = gui.label("", avatar);
        labels[index] = gui.label("", .{

            .grow = 1,

        });
        parts[index] = .{ &avatars[index], &labels[index] };
        row.* = gui.box(theme.item, &parts[index]);
        row.data = index;
        list[index] = row;

    }

    name.action = &advance;
    password.action = &submit;

    window = gui.Window.open(&greeter, .{

        .layer = .overlay,

    }) catch api.exit(3);
    load();
    sync();

    while (true) {

        const event = window.next(500) orelse continue;

        react(event);

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
    name.invalid = false;
    password.invalid = false;

}

/// Shows the tree for the current state.
fn sync() void {

    name.hidden = state != .setup;
    users.hidden = state == .setup;

    for (&rows, 0..) |*row, index| {

        row.hidden = index >= count or (state == .locked and index != selected);
        row.selected = index == selected;
        row.action = if (state == .choose) &pick else null;
        avatars[index].selected = row.selected;

        if (index < count) {

            labels[index].content.label = names[index][0..lengths[index]];
            initials[index] = std.ascii.toUpper(names[index][0]);
            avatars[index].content.label = initials[index .. index + 1];

        }

    }

    if (count != 0) who.content.label = names[selected][0..lengths[selected]];

    window.show(if (state == .session) &desktop else &greeter);
    window.focus(if (state == .session) null else if (state == .setup and name_text.length == 0) &name else &password);
    window.stack(if (state == .session) .background else .overlay);

}

fn react(event: api.Event) void {

    if (state == .session) {

        if (event.chord(lock, 'l')) lockScreen(&bar) else if (event.chord(lock, 'q')) logout(&bar);
        return;

    }

    if (state != .choose or event.kind != .key or !event.pressed) return;

    switch (event.key()) {

        .up => if (selected > 0) select(selected - 1),
        .down => if (selected + 1 < count) select(selected + 1),
        else => {

        },

    }

}

fn pick(row: *gui.Node) void {

    select(row.data);

}

fn select(index: usize) void {

    if (index == selected) return;

    selected = index;
    password_text.clear();
    password.invalid = false;
    sync();

}

fn advance(_: *gui.Node) void {

    window.focus(&password);

}

fn submit(_: *gui.Node) void {

    defer sync();
    defer password_text.clear();

    if (state == .setup) {

        accounts.create(name_text.text(), password_text.text(), true) catch {

            name.invalid = true;
            return;

        };

    }

    const user = if (state == .setup) name_text.text() else names[selected][0..lengths[selected]];

    _ = accounts.login(user, password_text.text()) catch {

        if (state == .setup) load();
        password.invalid = true;

        return;

    };

    if (state == .setup) {

        load();

        for (0..count) |index| {

            if (std.mem.eql(u8, names[index][0..lengths[index]], user)) selected = index;

        }

        name_text.clear();

    }

    state = .session;

}

fn lockScreen(_: *gui.Node) void {

    state = .locked;
    sync();

}

fn openNotes(_: *gui.Node) void {

    api.launch("notes") catch {

    };

}

fn logout(_: *gui.Node) void {

    api.end() catch {

    };
    accounts.logout() catch {

    };
    load();
    sync();

}
