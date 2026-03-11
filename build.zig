const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const nbt = b.dependency("nbt");

    const exe = b.addExecutable(.{
        .name = "MineSynth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
            .link_libc = true,
        }),
        .use_llvm = true,
    });
    b.installArtifact(exe);

    exe.root_module.addIncludePath(b.path("src/extern"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/extern/nbt.c"), .flags = &.{} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/extern/miniz.c"), .flags = &.{"-fno-sanitize=alignment"} });

    // const aiger_mod = b.createModule(.{ .root_source_file = b.path("src/aiger.zig") });
    // const netlist_mod = b.createModule(.{ .root_source_file = b.path("src/netlist.zig") });
    //
    // exe.root_module.addImport("aiger", aiger_mod);
    // exe.root_module.addImport("netlist", netlist_mod);

    const pretty = b.dependency("pretty", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("pretty", pretty.module("pretty"));

    // Run toplevel command
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_check = b.addExecutable(.{
        .name = "foo",
        .root_module = exe.root_module,
    });
    const check = b.step("check", "Check if MineSynth compiles");
    check.dependOn(&exe_check.step);
}
