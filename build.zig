const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const alipay_mod = b.addModule("alipay", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // 单元测试。
    const mod_tests = b.addTest(.{ .root_module = alipay_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // 示例共享骨架（凭据/Client 样板），示例通过 @import("harness") 使用。
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("examples/_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "alipay", .module = alipay_mod },
        },
    });

    // 示例程序：自动发现 examples/*.zig -> run-<name>；`_` 前缀为共享模块，跳过。
    // 新增示例只需新建文件，无需改动本文件。
    const io = b.graph.io;
    b.dependOnDirectoryMetadata(b.path("examples"));
    var examples_dir = b.root.openDir(io, "examples", .{ .iterate = true }) catch |e|
        std.debug.panic("open examples/: {s}", .{@errorName(e)});
    defer examples_dir.close(io);
    // 目录迭代顺序由文件系统决定，先收集再排序，保证 run-<name> 步骤按文件名有序。
    var example_names: std.ArrayList([]const u8) = .empty;
    var it = examples_dir.iterate();
    while (it.next(io) catch |e| std.debug.panic("iterate examples/: {s}", .{@errorName(e)})) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '_') continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        // entry.name 指向迭代器复用的缓冲区，必须复制。
        const name = b.graph.dupeString(entry.name[0 .. entry.name.len - ".zig".len]);
        example_names.append(b.allocator, name) catch @panic("OOM");
    }
    std.mem.sort([]const u8, example_names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (example_names.items) |name| {
        const ex = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "alipay", .module = alipay_mod },
                    .{ .name = "harness", .module = harness_mod },
                },
            }),
        });
        const ex_run = b.addRunArtifact(ex);
        ex_run.addPassthruArgs();
        const ex_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run example: {s}", .{name}));
        ex_step.dependOn(&ex_run.step);
        // 纳入构建产物，保证示例始终可编译。
        b.getInstallStep().dependOn(&ex.step);
    }
}
