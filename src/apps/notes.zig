const api = @import("api");
const gui = @import("gui");

pub const panic = api.panic;

var bytes: [4096]u8 = undefined;
var text = gui.Text{

    .buffer = &bytes,
    .placeholder = "Write something...",

};

var page = gui.area(&text);
var root = gui.box(.{

    .padding = .all(gui.theme.spacing),

}, &.{&page});

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .application);

    page.style = gui.theme.area.with(.{

        .height = null,
        .grow = 1,

    });

    var window = gui.Window.open(&root, .{

        .title = "Notes",
        .width = 560,
        .height = 380,

    }) catch api.exit(3);

    window.focus(&page);

    while (true) {

        const event = window.next(500) orelse continue;

        if (event.kind == .close) api.exit(0);

    }

}
