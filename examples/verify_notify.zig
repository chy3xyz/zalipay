//! 示例：异步通知验签（V1 标准交易通知）。
//!
//! 演示 client.verifyNotify 的用法与「验签通过后回纯文本 success」契约。
//! 纯离线：Client 以 `.{ }` 构建，不注入传输，也不会创建 std.http/TLS 传输。
//! 为可离线自证，用同一测试密钥对：以私钥对 V1 待验串签名，再用其公钥验签。
//! 生产中签名来自支付宝，公钥应配置为支付宝公钥。
//!
//! 运行（自证需一对匹配密钥；缺省则仅打印契约说明）：
//!   ALIPAY_DEMO_PRIVATE_KEY=<PKCS8 base64> ALIPAY_DEMO_PUBLIC_KEY=<对应公钥 base64> \
//!   zig build run-verify_notify
const std = @import("std");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    printContract();

    const demo_private_key = init.environ_map.get("ALIPAY_DEMO_PRIVATE_KEY");
    const demo_public_key = init.environ_map.get("ALIPAY_DEMO_PUBLIC_KEY");
    if (demo_private_key == null or demo_public_key == null) {
        std.debug.print("\n未提供 ALIPAY_DEMO_PRIVATE_KEY / ALIPAY_DEMO_PUBLIC_KEY，跳过离线自证。\n", .{});
        return;
    }

    var client = try alipay.Client.init(gpa, init.io, .{
        .app_id = "demo",
        .app_private_key = demo_private_key.?,
        .alipay_public_key = demo_public_key.?,
    }, .{});
    defer client.deinit();

    runInner(gpa, &client, demo_private_key.?) catch |err| switch (err) {
        // FAILED 已由 runInner 打印，直接以非零状态退出。
        error.VerifyFailed => return err,
        else => {
            std.debug.print("verify_notify failed: {s}\n", .{@errorName(err)});
            return err;
        },
    };
}

fn runInner(gpa: std.mem.Allocator, client: *alipay.Client, demo_private_key: []const u8) !void {
    // 模拟支付宝回调（已 URL-decode）的表单键值对。
    // `passback_params` 演示空值参数：V1 待验串保留空值（rsaCheckV1 语义）。
    const notify = [_][2][]const u8{
        .{ "gmt_create", "2026-07-01 12:00:00" },
        .{ "charset", "utf-8" },
        .{ "trade_no", "2026070122001400000000000001" },
        .{ "out_trade_no", "demo-20260701-0001" },
        .{ "trade_status", "TRADE_SUCCESS" },
        .{ "total_amount", "0.10" },
        .{ "passback_params", "" },
        .{ "sign_type", "RSA2" },
    };

    // 用私钥对 V1 待验串签名（V1 去 sign+sign_type，保留空值），
    // 与 Client.verifyNotify 使用同一 canonical.buildKeepEmpty 语义。
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var kept: std.ArrayList(alipay.wire.canonical.Pair) = .empty;
    for (notify) |kv| {
        if (std.mem.eql(u8, kv[0], "sign_type")) continue;
        try kept.append(a, .{ .key = kv[0], .value = kv[1] });
    }
    const content = try alipay.wire.canonical.buildKeepEmpty(a, kept.items);

    var signer = try alipay.crypto.Signer.init(gpa, .{ .app_id = "demo", .app_private_key = demo_private_key });
    defer signer.deinit();
    const sign = try signer.sign(a, content);

    // 组装带 sign 的完整回调，交给 verifyNotify。
    var pairs: std.ArrayList([2][]const u8) = .empty;
    for (notify) |kv| try pairs.append(a, kv);
    try pairs.append(a, .{ "sign", sign });

    client.verifyNotify(pairs.items, .{ .version = .v1 }) catch {
        std.debug.print("verifyNotify(v1): FAILED\n", .{});
        return error.VerifyFailed;
    };
    std.debug.print("verifyNotify(v1): OK  -> 业务校验通过后应回复纯文本 success\n", .{});
}

fn printContract() void {
    std.debug.print(
        \\异步通知验签契约：
        \\  - 通知为 form-urlencoded POST；框架先 URL-decode，对解码后值验签。
        \\  - V1（默认，标准交易/资金/协议）：待验串去除 sign 与 sign_type。
        \\  - V2（仅生活号）：仅去除 sign，保留 sign_type。
        \\  - 验签 + 业务校验通过后，须回复纯文本 success（否则支付宝重试约 24h）。
        \\
    , .{});
}
