//! Client 的一次性配置。options 风格 + 合理默认值。
//! 所有字符串字段均为借用，调用方须保证其生命周期覆盖 Client 生命周期。
const std = @import("std");

/// 签名算法。rsa = SHA1withRSA（旧）；rsa2 = SHA256withRSA（默认、推荐）。
pub const SignType = enum {
    rsa,
    rsa2,

    /// 待签串中 `sign_type` 字段的字面量。
    pub fn wireName(self: SignType) []const u8 {
        return switch (self) {
            .rsa => "RSA",
            .rsa2 => "RSA2",
        };
    }
};

pub const Config = struct {
    /// 应用 ID（开放平台分配）。
    app_id: []const u8,
    /// 应用私钥：PKCS#8 或 PKCS#1，PEM body（可含或不含 -----BEGIN----- 头）。init 时解析一次。
    app_private_key: []const u8,
    /// 网关地址。生产默认；沙箱用 https://openapipre.alipay.com/gateway.do。
    endpoint: []const u8 = "https://openapi.alipay.com/gateway.do",
    /// 报文格式。仅支持 JSON。
    format: []const u8 = "JSON",
    /// 字符集。同时用于 URL 的 ?charset= 与待签串取字节。
    charset: []const u8 = "utf-8",
    /// 签名算法。默认 rsa2（SHA256withRSA）。
    sign_type: SignType = .rsa2,
    /// 接口协议版本。固定 "1.0"。
    version: []const u8 = "1.0",

    // 验签来源：alipay_public_key 与 alipay_public_cert 二选一。
    // 两者都为 null 时无法验签，须在 Options 关闭 verify_response（仅调试）。
    /// 支付宝公钥（X509 SubjectPublicKeyInfo 的 PEM body）。非证书模式使用。
    alipay_public_key: ?[]const u8 = null,
    /// 支付宝公钥证书（完整 X509 证书 PEM）。证书模式使用。
    alipay_public_cert: ?[]const u8 = null,

    // 证书模式系统参数（可选）。每项可直接给预计算 SN 字符串，
    // 或给对应证书 PEM 由 SDK 在 init 时计算（见 crypto/cert.zig）。
    /// 应用证书 SN（32 位 hex）。显式给出则直接使用。
    app_cert_sn: ?[]const u8 = null,
    /// 支付宝根证书 SN（多张以 `_` 连接）。显式给出则直接使用。
    alipay_root_cert_sn: ?[]const u8 = null,
    /// 应用公钥证书 PEM；提供且 app_cert_sn 未给时，由 SDK 计算 app_cert_sn。
    app_public_cert: ?[]const u8 = null,
    /// 支付宝根证书 PEM 链；提供且 alipay_root_cert_sn 未给时，由 SDK 计算。
    alipay_root_cert: ?[]const u8 = null,

    /// 异步通知回调地址默认值，可被 Options.notify_url 覆盖。
    notify_url: ?[]const u8 = null,
    /// 同步跳转返回地址默认值，可被 Options.return_url 覆盖。
    return_url: ?[]const u8 = null,
    /// 第三方代调用授权令牌默认值，可被 Options.app_auth_token 覆盖。
    app_auth_token: ?[]const u8 = null,
};
