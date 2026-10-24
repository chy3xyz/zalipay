//! 待签串构造：这一步拼错，签名就对不上、请求会被网关直接拒绝，是集成的高发坑点。
//! 规则：按 key 升序、跳过空值和 sign、用原始值按 `k=v&` 拼接，签名前绝不做 URL 编码。
//! key 按字节升序即可 —— `std.mem.lessThan` 就是逐字节比较，正好满足支付宝的排序要求。
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 一个参数键值对（原始未编码值）。
pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

fn lessThan(_: void, a: Pair, b: Pair) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// 构造待签串（请求签名方向）。跳过空 key / 空 value 与 `sign`；其余按 key 升序原值拼接。
/// 返回新分配缓冲，调用方负责释放。
pub fn build(gpa: Allocator, pairs: []const Pair) Allocator.Error![]u8 {
    var kept: std.ArrayList(Pair) = .empty;
    defer kept.deinit(gpa);
    try kept.ensureTotalCapacity(gpa, pairs.len);
    for (pairs) |p| {
        if (p.key.len == 0 or p.value.len == 0) continue;
        if (std.mem.eql(u8, p.key, "sign")) continue;
        kept.appendAssumeCapacity(p);
    }
    return sortAndJoin(gpa, kept.items);
}

/// 构造异步通知的待验串：与官方 rsaCheckV1/V2 语义一致，**保留空值参数**——
/// 支付宝对通知签名时不剔除空值，验签侧丢弃空值会造成待验串不一致而误判失败。
/// 空 key 跳过（官方 Map 语义下不可能存在，只会是调用方解析噪音）。
/// 调用方须先自行剔除 sign（V1 还须剔除 sign_type）。返回新分配缓冲，调用方负责释放。
pub fn buildKeepEmpty(gpa: Allocator, pairs: []const Pair) Allocator.Error![]u8 {
    var kept: std.ArrayList(Pair) = .empty;
    defer kept.deinit(gpa);
    try kept.ensureTotalCapacity(gpa, pairs.len);
    for (pairs) |p| {
        if (p.key.len == 0) continue;
        kept.appendAssumeCapacity(p);
    }
    return sortAndJoin(gpa, kept.items);
}

/// 两个方向共享的核心：按 key 升序（稳定排序）后以 `k=v&` 原值拼接。
/// 此处的字节布局必须与支付宝的签名计算逐字节一致，改动须两个方向同时回归。
fn sortAndJoin(gpa: Allocator, pairs: []Pair) Allocator.Error![]u8 {
    std.mem.sort(Pair, pairs, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '&');
        try out.appendSlice(gpa, p.key);
        try out.append(gpa, '=');
        try out.appendSlice(gpa, p.value);
    }
    return out.toOwnedSlice(gpa);
}

test "canonical: sort ascending, drop empty and sign" {
    const gpa = std.testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "method", .value = "alipay.trade.query" },
        .{ .key = "app_id", .value = "2021" },
        .{ .key = "sign", .value = "SHOULD_BE_DROPPED" },
        .{ .key = "empty_v", .value = "" },
        .{ .key = "charset", .value = "utf-8" },
        .{ .key = "biz_content", .value = "{\"a\":1}" },
    };
    const got = try build(gpa, &pairs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "app_id=2021&biz_content={\"a\":1}&charset=utf-8&method=alipay.trade.query",
        got,
    );
}

test "canonical: buildKeepEmpty keeps empty values (notify verification semantics)" {
    const gpa = std.testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "trade_status", .value = "TRADE_SUCCESS" },
        .{ .key = "body", .value = "" },
        .{ .key = "", .value = "parser-noise" }, // 空 key 为调用方解析噪音，须跳过
        .{ .key = "out_trade_no", .value = "T-0001" },
    };
    const got = try buildKeepEmpty(gpa, &pairs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "body=&out_trade_no=T-0001&trade_status=TRADE_SUCCESS",
        got,
    );
}

test "canonical: raw values not url-encoded" {
    const gpa = std.testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "timestamp", .value = "2026-07-01 12:34:56" },
        .{ .key = "notify_url", .value = "https://x.com/cb?a=1" },
    };
    const got = try build(gpa, &pairs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "notify_url=https://x.com/cb?a=1&timestamp=2026-07-01 12:34:56",
        got,
    );
}
