const api = @import("api");
const options = @import("options");

const protocol = api.protocol;
pub const panic = api.panic;

pub export fn app_main(_: usize, _: usize, environment: *const api.abi.Environment) callconv(.c) noreturn {

    api.start(environment, .service);

    if (!api.permits(.ipc) or api.permits(.ports) or api.permits(.management) or api.permits(.memory) or api.permits(.time)) api.exit(2);
    if (api.raw(.allocate, 0, 0, 0).number != 1 or api.raw(.ticks, 0, 0, 0).number != 1) api.exit(2);

    while (true) {

        const request = api.receive(true) catch continue;

        const result: u64 = switch (protocol.operation(request.second)) {

            .hello => protocol.version,
            .ping => @as(u64, protocol.value(request.second)) + 1,
            .crash => if (request.first == api.raw(.owner, 0, 0, 0).first or options.self_test) fault() else protocol.invalid,
            .stall => if (options.self_test) continue else protocol.invalid,

            else => protocol.invalid,

        };

        api.reply(request, result) catch {

        };

    }

}

fn fault() noreturn {

    asm volatile ("ud2");
    api.exit(1);

}
