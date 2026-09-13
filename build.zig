const std = @import("std");

pub fn build(b: *std.Build) void {

    const optimize = b.standardOptimizeOption(.{

    });
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
    boot.subsystem = .EfiApplication;
    module.addAssemblyFile(b.path("src/arch/x86/entry.S"));

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
    b.step("test", "Test boot information and firmware handoff").dependOn(&b.addRunArtifact(tests).step);

}
