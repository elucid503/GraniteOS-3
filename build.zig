const std = @import("std");

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{

    });

    const options = b.addOptions();

    options.addOption(bool, "panic_test", b.option(bool, "panic-test", "Exercise kernel diagnostics and hardware reboot") orelse false);
    const self_test = b.option(bool, "self-test", "Run the embedded kernel acceptance workload") orelse true;
    options.addOption(bool, "self_test", self_test);
    options.addOption(bool, "guard_test", b.option(bool, "guard-test", "Exercise double-fault diagnostics on a guarded kernel stack") orelse false);
    const service_options = b.addOptions();

    service_options.addOption(bool, "self_test", b.option(bool, "service-test", "Exercise service recovery and application APIs") orelse self_test);

    const application = b.addExecutable(.{

        .name = "probe",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{

            .root_source_file = b.path("src/user/main.zig"),
            .target = b.resolveTargetQuery(.{

                .cpu_arch = .x86_64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .baseline,

            }),
            .optimize = optimize,
            .red_zone = false,
            .stack_check = false,
            .stack_protector = false,
            .code_model = .large,

        }),

    });

    application.root_module.addAssemblyFile(b.path("src/user/asm/entry.S"));
    application.root_module.addAnonymousImport("abi", .{

        .root_source_file = b.path("src/kernel/abi.zig"),

    });

    application.setLinkerScript(b.path("src/user/asm/link.ld"));
    b.installArtifact(application);

    const target = b.resolveTargetQuery(.{

        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
        .cpu_model = .baseline,

    });

    const module = b.createModule(.{

        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,

    });

    const boot = b.addExecutable(.{

        .name = "BOOTX64",
        .root_module = module,

    });

    module.addOptions("options", options);
    module.addAnonymousImport("application", .{

        .root_source_file = application.getEmittedBin(),

    });

    const api = b.createModule(.{

        .root_source_file = b.path("src/api/root.zig"),
        .target = application.root_module.resolved_target,
        .optimize = optimize,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
        .code_model = .large,

    });
    api.addAnonymousImport("abi", .{

        .root_source_file = b.path("src/kernel/abi.zig"),

    });

    for ([_][]const u8{

        "supervisor", "serial", "helper", "shell", "client",

    }) |name| {

        const program = b.addExecutable(.{

            .name = name,
            .use_llvm = true,
            .use_lld = true,
            .root_module = b.createModule(.{

                .root_source_file = b.path(b.fmt("src/{s}/{s}.zig", .{

                    if (std.mem.eql(u8, name, "shell") or std.mem.eql(u8, name, "client")) "apps" else "services", name,

                })),
                .target = application.root_module.resolved_target,
                .optimize = optimize,
                .red_zone = false,
                .stack_check = false,
                .stack_protector = false,
                .code_model = .large,

            }),

        });

        program.root_module.addImport("api", api);
        program.root_module.addOptions("options", service_options);
        program.root_module.addAssemblyFile(b.path("src/user/asm/entry.S"));
        program.setLinkerScript(b.path("src/user/asm/link.ld"));
        b.installArtifact(program);
        module.addAnonymousImport(name, .{

            .root_source_file = program.getEmittedBin(),

        });

    }

    boot.subsystem = .EfiApplication;
    module.addAssemblyFile(b.path("src/arch/x86/asm/entry.S"));
    module.addAssemblyFile(b.path("src/arch/x86/asm/interrupt.S"));
    module.addAssemblyFile(b.path("src/arch/x86/asm/startup.S"));

    const install = b.addInstallArtifact(boot, .{

        .dest_dir = .{

            .override = .{

                .custom = "esp/EFI/BOOT",

            },

        },
        .dest_sub_path = "BOOTX64.EFI",

    });

    b.getInstallStep().dependOn(&install.step);

    const tests = b.addTest(.{

        .root_module = b.createModule(.{

            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,

        }),

    });

    b.step("test", "Test boot contracts and kernel policies").dependOn(&b.addRunArtifact(tests).step);

}
