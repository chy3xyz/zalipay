//! 东八区时间戳 `YYYY-MM-DD HH:MM:SS`（无 DST，固定 +8 偏移）。
//! 用 std.time.epoch 计算，规避机器本地时区隐患。
//! 取当前时间请用 `Clock.now`（`clock.zig`）；本模块只做 Unix 秒 → 墙钟字符串的格式化。
//!
//! 支持范围：Unix 秒 `0 .. 253402271999`，即 +08:00 墙钟的
//! `1970-01-01 08:00:00 .. 9999-12-31 23:59:59`——正好覆盖 4 位年份。
//! 越界入参在安全构建（debug/ReleaseSafe）下触发断言，不会静默格式化成 5 位年份。
const std = @import("std");

/// 支付宝时间戳固定长度：`2026-07-01 12:34:56`。
pub const len = 19;

/// 支持的 Unix 秒下界：1970-01-01 00:00:00 UTC（+08:00 即 `1970-01-01 08:00:00`）。
const min_unix_seconds: i64 = 0;
/// 支持的 Unix 秒上界：253402271999 = 9999-12-31 15:59:59 UTC，
/// +08:00 为 `9999-12-31 23:59:59`，是 4 位年份能表达的最大时刻。
/// 再大就会输出 5 位年份，突破固定 19 字节格式（`bufWrite` 的 fixed writer 会失败）。
const max_unix_seconds: i64 = 253402271999;

/// 东八区相对 UTC 的固定偏移（秒）。
const cst_offset = 8 * std.time.s_per_hour;

const TimestampParts = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

/// 将 Unix 秒拆成东八区墙钟各字段（早于 epoch 的时刻夹到 0；write 已先断言非负）。
fn parts(unix_seconds: i64) TimestampParts {
    const shifted: u64 = @intCast(@max(unix_seconds, 0) + cst_offset);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = shifted };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return .{
        .year = year_day.year,
        .month = @intCast(@backingInt(month_day.month)),
        .day = month_day.day_index + 1,
        .hour = day_seconds.getHoursIntoDay(),
        .minute = day_seconds.getMinutesIntoHour(),
        .second = day_seconds.getSecondsIntoMinute(),
    };
}

/// 将 Unix 秒以东八区墙钟写入 w，格式 `YYYY-MM-DD HH:MM:SS`。
///
/// `unix_seconds` 必须在 `min_unix_seconds .. max_unix_seconds` 内；越界在安全构建下
/// 触发断言（超出 4 位年份就无法维持 `len` 字节的固定宽度）。
pub fn write(w: *std.Io.Writer, unix_seconds: i64) std.Io.Writer.Error!void {
    std.debug.assert(unix_seconds >= min_unix_seconds and unix_seconds <= max_unix_seconds);
    const p = parts(unix_seconds);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        p.year, p.month, p.day, p.hour, p.minute, p.second,
    });
}

/// 写入固定缓冲（buf.len 须 >= len），返回时间戳切片。
pub fn bufWrite(buf: []u8, unix_seconds: i64) []const u8 {
    std.debug.assert(buf.len >= len);
    var w = std.Io.Writer.fixed(buf);
    write(&w, unix_seconds) catch unreachable; // 19 字节固定，缓冲足够时不会失败
    return w.buffered();
}

test "timestamp: fixed epoch -> +8 wall clock string" {
    // 1782880496 = 2026-07-01 04:34:56 UTC = 2026-07-01 12:34:56 +08:00
    var buf: [len]u8 = undefined;
    try std.testing.expectEqualStrings("2026-07-01 12:34:56", bufWrite(&buf, 1782880496));
}

test "timestamp: leap day and year boundary in +08:00" {
    var buf: [len]u8 = undefined;
    // 1835395200 = 2028-02-29 00:00:00 UTC（闰日）
    try std.testing.expectEqualStrings("2028-02-29 08:00:00", bufWrite(&buf, 1835395200));
    // 1798761599 = 2026-12-31 23:59:59 UTC = 2027-01-01 07:59:59 +08:00
    try std.testing.expectEqualStrings("2027-01-01 07:59:59", bufWrite(&buf, 1798761599));
}

test "timestamp: supported upper bound keeps the 4-digit year" {
    var buf: [len]u8 = undefined;
    // 253402271999 = 9999-12-31 15:59:59 UTC = 9999-12-31 23:59:59 +08:00
    const max = bufWrite(&buf, 253402271999);
    try std.testing.expectEqualStrings("9999-12-31 23:59:59", max);
    try std.testing.expectEqual(len, max.len);
    try std.testing.expectEqualStrings("9999-12-31 23:59:58", bufWrite(&buf, 253402271998));
}

test "timestamp: 各字段补零且总长恰为 len" {
    var buf: [len]u8 = undefined;
    // 0 = 1970-01-01 00:00:00 UTC = 1970-01-01 08:00:00 +08:00
    const s = bufWrite(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01 08:00:00", s);
    try std.testing.expectEqual(len, s.len);
}

test "timestamp: write 与 bufWrite 输出一致" {
    var streamed: [len]u8 = undefined;
    var w = std.Io.Writer.fixed(&streamed);
    try write(&w, 1782880496);

    var buf: [len]u8 = undefined;
    try std.testing.expectEqualStrings(bufWrite(&buf, 1782880496), w.buffered());
}
