//! 时钟注入：签名时间戳的来源可替换，测试与回放可得到确定性输出。
const std = @import("std");

/// 当前 Unix 秒的来源。
pub const Clock = union(enum) {
    /// 读取 `std.Io.Clock.real`（Unix 秒）。
    io,
    /// 固定 Unix 秒，用于测试与确定性输出。支持范围与 `wire/timestamp.zig` 一致：
    /// `0 .. 253402271999`（+08:00 墙钟仍是 4 位年份）；越界在安全构建下触发断言。
    fixed: i64,
    /// 调用方提供的时钟。
    custom: Custom,

    pub const Custom = struct {
        /// 借用：`Client` 不复制也不接管该指针，调用方须保证 context 活过 Client。
        context: ?*anyopaque,
        now_fn: *const fn (?*anyopaque, std.Io) i64,
    };

    /// 取当前 Unix 秒。
    pub fn now(self: Clock, io: std.Io) i64 {
        return switch (self) {
            .io => std.Io.Clock.real.now(io).toSeconds(),
            .fixed => |seconds| seconds,
            .custom => |custom| custom.now_fn(custom.context, io),
        };
    }
};

test "clock: fixed 不触碰 io" {
    const clock: Clock = .{ .fixed = 1782880496 };
    // 传入 undefined 的 io：若 fixed 分支误用 io，debug 下会读到毒值/崩溃。
    try std.testing.expectEqual(@as(i64, 1782880496), clock.now(undefined));
}

test "clock: custom 读取调用方栈上状态" {
    const State = struct {
        seconds: i64,

        fn nowFn(ctx: ?*anyopaque, io: std.Io) i64 {
            _ = io;
            const state: *@This() = @ptrCast(@alignCast(ctx.?));
            return state.seconds;
        }
    };

    var state: State = .{ .seconds = 42 };
    const clock: Clock = .{ .custom = .{ .context = &state, .now_fn = State.nowFn } };
    try std.testing.expectEqual(@as(i64, 42), clock.now(undefined));
}
