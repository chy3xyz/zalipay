//! 示例共享骨架：凭据加载、Client 构建、统一错误打印。
//! 凭据默认取 `_sandbox.zig` 内置沙箱账号，环境变量可逐项覆盖（切生产/预发时用）。
//! 文件名以 `_` 开头——build.zig 自动发现示例时跳过此类共享模块。
//!
//! 两个入口：
//!   - `run`：需要网络的示例（`execute`/`A.call`）。创建 StdTransport 并注入 Client。
//!   - `runOffline`：纯本地签名示例（`page`/`sdk`/`verifyNotify`）。不创建 StdTransport。
//!
//! 新示例只需两段（业务函数里 client 已就绪）：
//!   pub fn main(init: std.process.Init) !void {
//!       return harness.runOffline(init, demo); // 或 harness.run(init, demo)
//!   }
//!   fn demo(ctx: *harness.Ctx) !void {
//!       const resp = try alipay.models.xxx.Yyy.call(ctx.client, .{ ... }, .{});
//!   }
const std = @import("std");
const alipay = @import("alipay");
const sandbox = @import("_sandbox.zig");

/// 传给示例业务函数的上下文。gpa 供 `Api.page`/`Api.sdk` 这类需要 out_gpa 的调用使用。
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    client: *alipay.Client,
};

const Credentials = struct {
    app_id: []const u8,
    app_private_key: []const u8,
    alipay_public_key: []const u8,
    endpoint: []const u8,
};

/// 骨架入口（联网）：加载标准凭据 → 初始化 StdTransport → 构建 Client 并顺序执行 demo。
/// demo 签名：`fn (*Ctx) !void`；demo 报错时自动打印 `client.last_error`（若有）。
pub fn run(init: std.process.Init, comptime demo: anytype) !void {
    const creds = try loadCredentials(init);

    // 所有权契约：StdTransport / Client 由组合根创建并持有，传输借用其存活期。
    var std_transport = alipay.StdTransport.init(init.gpa, init.io, .{});
    defer std_transport.deinit();

    var client = try alipay.Client.init(init.gpa, init.io, clientConfig(creds), .{
        .transport = std_transport.transport(),
    });
    defer client.deinit();

    try runDemo(demo, init.gpa, &client);
}

/// 骨架入口（离线）：仅加载凭据并构建无传输的 Client（`.{ }`），不触碰 std.http/TLS。
/// 适用于 `page`/`sdk`/`verifyNotify` 等纯本地签名与验签示例。
pub fn runOffline(init: std.process.Init, comptime demo: anytype) !void {
    const creds = try loadCredentials(init);

    var client = try alipay.Client.init(init.gpa, init.io, clientConfig(creds), .{});
    defer client.deinit();

    try runDemo(demo, init.gpa, &client);
}

fn loadCredentials(init: std.process.Init) !Credentials {
    const environ = init.environ_map;
    const creds: Credentials = .{
        .app_id = environ.get("ALIPAY_APP_ID") orelse sandbox.app_id,
        .app_private_key = environ.get("ALIPAY_APP_PRIVATE_KEY") orelse sandbox.app_private_key,
        .alipay_public_key = environ.get("ALIPAY_PUBLIC_KEY") orelse sandbox.alipay_public_key,
        .endpoint = environ.get("ALIPAY_ENDPOINT") orelse sandbox.endpoint,
    };
    inline for (.{ "app_id", "app_private_key", "alipay_public_key" }) |field| {
        const v = @field(creds, field);
        if (v.len == 0) {
            std.debug.print("内置沙箱凭据缺 {s}，请编辑 examples/_sandbox.zig 补全。\n", .{field});
            return error.MissingCredentials;
        }
    }
    return creds;
}

fn clientConfig(creds: Credentials) alipay.Config {
    return .{
        .app_id = creds.app_id,
        .app_private_key = creds.app_private_key,
        .alipay_public_key = creds.alipay_public_key,
        .endpoint = creds.endpoint,
    };
}

fn runDemo(comptime demo: anytype, gpa: std.mem.Allocator, client: *alipay.Client) !void {
    var ctx: Ctx = .{ .gpa = gpa, .client = client };
    demo(&ctx) catch |err| {
        if (client.last_error) |detail| std.debug.print("{f}\n", .{detail});
        return err;
    };
}
