//! 分类错误集合与网关业务错误详情。
//!
//! 传输层错误在 `Transport` 边界收敛到本集合（子集，可直接冒泡）；
//! 业务错误码（`code != "10000"`）映射为 GatewayError/BusinessError，
//! 具体码/文案通过 Client 的 last_error 字段以 ErrorDetail 暴露。
const std = @import("std");

/// SDK 对外统一错误集合。传输层错误经 Client 的 Transport 边界收敛至此。
pub const Error = error{
    // -- 传输 / 底层 --
    /// 连接失败、读写失败等未细分的网络错误；网关返回非 2xx 状态也归入此类
    /// （此时响应体被丢弃）。
    Transport,
    /// 请求或响应超时。
    Timeout,
    /// TLS 握手或证书验证失败。
    Tls,
    /// 内存分配失败。
    OutOfMemory,
    /// 响应体超过调用方设定的上限（`Request.max_response`，硬上限 `transport.max_response_limit`）。
    ResponseTooLarge,
    /// 传输层无法获得并发资源以兑现超时（Io 不支持并发或线程资源耗尽）。
    ConcurrencyUnavailable,
    /// 调用方任务被协作式取消。
    Canceled,
    /// `execute` 时未注入 `Transport`（在签名与任何网络动作之前返回）。
    /// 离线方法（pageExecute/sdkExecute/verifyNotify）不受影响。
    TransportNotConfigured,
    // -- 协议 / 解析 --
    /// 响应结构异常（如括号不匹配、重复响应节点）。
    BadResponse,
    /// 响应中找不到 `{method}_response` 也无 `error_response` 节点。
    EnvelopeNotFound,
    /// 响应节点 JSON 解码失败或与声明类型不符。
    JsonParse,
    // -- 安全 --
    /// 请求签名失败（私钥异常）。
    SignFailed,
    /// 响应/通知验签失败，或未配置验签公钥。
    VerifyFailed,
    /// 证书模式下响应 alipay_cert_sn 与配置的支付宝公钥证书不符（支付宝证书已轮换，
    /// 须更新 alipay_public_cert 配置）。
    CertMismatch,
    // -- 业务（详情见 Client.last_error）--
    /// 网关返回业务码非 "10000"（含 error_response）。详情见 `last_error`。
    GatewayError,
    /// 预留：细分业务错误（当前统一走 GatewayError）。
    BusinessError,
    // -- 配置 --
    /// 私钥、证书或 endpoint 非法（init 阶段）。
    InvalidConfig,
};

/// 网关返回的业务错误详情。字段均借用响应 arena 中的切片，生命周期随该次调用的 arena。
/// 实现 `format`，可用 `{f}` 打印，如 `std.debug.print("{f}", .{detail})`。
pub const ErrorDetail = struct {
    /// 网关返回码，如 "40004"。
    code: []const u8,
    /// 网关返回文案。
    msg: []const u8,
    /// 业务子错误码，如 "ACQ.TRADE_NOT_EXIST"。
    sub_code: ?[]const u8 = null,
    /// 业务子错误文案。
    sub_msg: ?[]const u8 = null,

    pub fn format(self: ErrorDetail, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("gateway code={s} msg={s}", .{ self.code, self.msg });
        if (self.sub_code) |c| try w.print(" sub_code={s}", .{c});
        if (self.sub_msg) |m| try w.print(" sub_msg={s}", .{m});
    }
};
