//! alipay — 支付宝开放平台 SDK for Zig。
//!
//! comptime 强类型门面（`Api(...)` → `A.call`）+ 底层通用 `execute`：高频接口编译期即类型安全，
//! 其余低频接口用 Api 照样自定义即可。资源所有权交调用方：Transport 实现（如 `StdTransport`）
//! 与分配器由调用方持有并注入。
//!
//! 网络 I/O 不绑定具体协程运行时：`Client` 通过注入的 `Transport` 发请求。
//! 传输实现自身的并发能力不等于 Client 可并发——`Client.execute` 仍非并发安全
//! （每次调用重置内部 arena 并覆写 last_error）。未注入传输时仍可完成签名串/表单/通知验签等离线工作。
const std = @import("std");

/// SDK 版本。
pub const version = "0.1.0";

// ---- 配置 ----
/// Client 一次性配置。
pub const Config = @import("config.zig").Config;
/// 签名算法（rsa / rsa2）。
pub const SignType = @import("config.zig").SignType;

// ---- 客户端与调用选项 ----
const client = @import("client.zig");
/// SDK 主入口，持有签名器与可选传输，编排调用全流程。
pub const Client = client.Client;
/// Client 初始化选项（注入传输与签名时钟）。
pub const InitOptions = client.InitOptions;
/// 单次调用可选参数（覆盖 Config 默认、控制验签与返回值分配）。
pub const Options = client.Options;
/// 异步通知验签选项（V1/V2）。
pub const NotifyOptions = client.NotifyOptions;
pub const NotifyVersion = client.NotifyVersion;

// ---- 时钟 ----
/// 签名时间戳来源（`.io` 系统时钟 / `.fixed` 固定秒 / `.custom` 自定义）。
pub const Clock = @import("clock.zig").Clock;

// ---- 传输 ----
const transport = @import("transport.zig");
/// 传输协议。
pub const Scheme = transport.Scheme;
/// 一次 HTTP 请求描述。
pub const Request = transport.Request;
/// 一次 HTTP 响应（body 由 send 的 allocator 分配）。
pub const Response = transport.Response;
/// 传输层错误集合。
pub const TransportError = transport.TransportError;
/// 传输实现的 vtable 边界。
pub const Transport = transport.Transport;
/// 基于 std.http.Client 的默认传输实现。
pub const StdTransport = transport.StdTransport;
/// StdTransport 配置。
pub const StdTransportOptions = transport.StdTransportOptions;
/// 响应体硬上限（8 MiB）。
pub const max_response_limit = transport.max_response_limit;

// ---- 强类型门面机制 ----
/// 强类型接口工厂：`Api(method, Biz, Resp)`。下游可同法扩展任意接口。
pub const Api = @import("api.zig").Api;

// ---- 错误 ----
/// SDK 统一错误集合。
pub const Error = @import("errors.zig").Error;
/// 网关业务错误详情（见 Client.last_error）。
pub const ErrorDetail = @import("errors.zig").ErrorDetail;

// ---- 预置高频接口 models ----
/// 预置高频接口（trade / fund / agreement），均由 Api 实例化。
pub const models = @import("models/root.zig");

// ---- 低层构件（进阶/自定义扩展用） ----
/// 协议字节层：待签串 / form 编码 / envelope 提取 / 时间戳。
pub const wire = struct {
    pub const canonical = @import("wire/canonical.zig");
    pub const form = @import("wire/form.zig");
    pub const envelope = @import("wire/envelope.zig");
    pub const timestamp = @import("wire/timestamp.zig");
};
pub const crypto = struct {
    pub const Signer = @import("crypto/signer.zig").Signer;
    pub const cert = @import("crypto/cert.zig");
};
pub const json = @import("json.zig");

test {
    std.testing.refAllDecls(@This());
    // 显式纳入各层测试。
    _ = @import("client.zig");
    _ = @import("clock.zig");
    _ = @import("transport.zig");
    _ = @import("json.zig");
    _ = @import("crypto/signer.zig");
    _ = @import("crypto/cert.zig");
    _ = @import("wire/canonical.zig");
    _ = @import("wire/form.zig");
    _ = @import("wire/envelope.zig");
    _ = @import("wire/timestamp.zig");
    _ = @import("models/root.zig");
}
