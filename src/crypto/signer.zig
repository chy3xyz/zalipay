//! Signer：RSA 签名/验签器。私钥在 init 时解析一次并缓存，绝不每请求解析 PEM。
//! Client 内部持有其一个实例；也可经 `alipay.crypto.Signer` 独立使用（如自定义通知验签）。
const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const errors = @import("../errors.zig");
const pem = @import("pem.zig");
const pkcs8 = @import("pkcs8.zig");
const pkcs1v15 = @import("pkcs1v15.zig");
const rsa = @import("rsa.zig");
const cert = @import("cert.zig");

const Error = errors.Error;

pub const Signer = struct {
    gpa: Allocator,
    hash: pkcs1v15.Hash,
    /// 私钥 DER（拥有）；key 各分量切片借用其中。
    priv_der: []u8,
    key: pkcs8.RsaPrivateKey,
    /// 验签公钥来源（拥有的 DER 缓冲）+ 已解析公钥。任一为 null 表示未配置验签。
    pub_der: ?[]u8 = null,
    pub_key: ?std.crypto.Certificate.rsa.PublicKey = null,

    /// 解析私钥（必需）与验签公钥（可选：证书优先，其次公钥）。
    /// 私钥非法返回 InvalidConfig。签名算法由 cfg.sign_type 决定（rsa→SHA1，rsa2→SHA256）。
    pub fn init(gpa: Allocator, cfg: config.Config) Error!Signer {
        const priv_der = pem.decode(gpa, cfg.app_private_key) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidConfig,
        };
        // 错误路径同样擦零后释放，与 deinit 一致，避免私钥残留在已归还堆内存。
        errdefer {
            std.crypto.secureZero(u8, priv_der);
            gpa.free(priv_der);
        }
        const key = pkcs8.parse(priv_der) catch return error.InvalidConfig;
        if (key.n.len > rsa.max_modulus_bytes) return error.InvalidConfig;

        var self: Signer = .{
            .gpa = gpa,
            .hash = switch (cfg.sign_type) {
                .rsa => .sha1,
                .rsa2 => .sha256,
            },
            .priv_der = priv_der,
            .key = key,
        };

        // 验签来源：优先证书模式，其次公钥。
        if (cfg.alipay_public_cert) |cert_pem| {
            const cert_der = pem.decode(gpa, cert_pem) catch return error.InvalidConfig;
            errdefer gpa.free(cert_der);
            const spki = cert.extractSpki(cert_der) catch return error.InvalidConfig;
            self.pub_key = rsa.publicKeyFromSpki(spki) catch return error.InvalidConfig;
            self.pub_der = cert_der;
        } else if (cfg.alipay_public_key) |pub_pem| {
            const spki = pem.decode(gpa, pub_pem) catch return error.InvalidConfig;
            errdefer gpa.free(spki);
            self.pub_key = rsa.publicKeyFromSpki(spki) catch return error.InvalidConfig;
            self.pub_der = spki;
        }
        return self;
    }

    pub fn deinit(self: *Signer) void {
        // 私钥 DER 释放前擦零，避免密钥残留在已归还的堆内存中。
        std.crypto.secureZero(u8, self.priv_der);
        self.gpa.free(self.priv_der);
        if (self.pub_der) |b| self.gpa.free(b);
        self.* = undefined;
    }

    /// 对 content 签名，返回 base64 字符串（分配于 out_gpa，调用方负责释放）。
    pub fn sign(self: *const Signer, out_gpa: Allocator, content: []const u8) Error![]u8 {
        var raw_buf: [rsa.max_modulus_bytes]u8 = undefined;
        const raw = raw_buf[0..self.key.n.len];
        switch (self.hash) {
            inline else => |h| rsa.sign(h, self.key, content, raw) catch return error.SignFailed,
        }
        const enc = std.base64.standard.Encoder;
        const out = try out_gpa.alloc(u8, enc.calcSize(raw.len));
        _ = enc.encode(out, raw);
        return out;
    }

    /// 用配置的公钥验签。sig_b64 为 base64 签名（透传前须已 URL-decode）。
    pub fn verify(self: *const Signer, content: []const u8, sig_b64: []const u8) Error!void {
        const pk = self.pub_key orelse return error.VerifyFailed;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(sig_b64) catch return error.VerifyFailed;
        if (n > rsa.max_modulus_bytes) return error.VerifyFailed;
        var sig_buf: [rsa.max_modulus_bytes]u8 = undefined;
        dec.decode(sig_buf[0..n], sig_b64) catch return error.VerifyFailed;
        switch (self.hash) {
            inline else => |h| rsa.verify(h, pk, content, sig_buf[0..n]) catch return error.VerifyFailed,
        }
    }
};

test "sign matches openssl SHA256withRSA vector" {
    const gpa = std.testing.allocator;
    var signer = try Signer.init(gpa, .{
        .app_id = "test",
        .app_private_key = @embedFile("testdata/app_priv_pkcs8.pem"),
        .alipay_public_key = @embedFile("testdata/app_pub.pem"),
    });
    defer signer.deinit();

    const plain = @embedFile("testdata/sign_plain.txt");
    const expected = @embedFile("testdata/sign_expected_b64.txt");

    const sig = try signer.sign(gpa, plain);
    defer gpa.free(sig);
    try std.testing.expectEqualStrings(expected, sig);

    // 回环验签：自签用自配公钥应通过。
    try signer.verify(plain, sig);
    // 篡改后应失败。
    try std.testing.expectError(error.VerifyFailed, signer.verify("tampered", sig));
}

test "CRT and direct modexp produce identical signature (vector regression)" {
    const gpa = std.testing.allocator;
    const priv_der = try pem.decode(gpa, @embedFile("testdata/app_priv_pkcs8.pem"));
    defer gpa.free(priv_der);
    const key = try pkcs8.parse(priv_der);

    const plain = @embedFile("testdata/sign_plain.txt");
    const mlen = key.n.len;

    var crt_raw: [rsa.max_modulus_bytes]u8 = undefined;
    var dir_raw: [rsa.max_modulus_bytes]u8 = undefined;
    try rsa.sign(.sha256, key, plain, crt_raw[0..mlen]); // CRT 路径
    try rsa.signDirect(.sha256, key, plain, dir_raw[0..mlen]); // 直接 modexp

    // 两路径必须逐字节一致。
    try std.testing.expectEqualSlices(u8, dir_raw[0..mlen], crt_raw[0..mlen]);

    // 且等于 OpenSSL SHA256withRSA 期望向量（base64）。
    const enc = std.base64.standard.Encoder;
    var b64: [rsa.max_modulus_bytes * 2]u8 = undefined;
    const sig = enc.encode(b64[0..enc.calcSize(mlen)], crt_raw[0..mlen]);
    try std.testing.expectEqualStrings(@embedFile("testdata/sign_expected_b64.txt"), sig);
}

test "corrupted CRT component falls back to correct direct signature (Bellcore guard)" {
    const gpa = std.testing.allocator;
    const priv_der = try pem.decode(gpa, @embedFile("testdata/app_priv_pkcs8.pem"));
    defer gpa.free(priv_der);
    const key = try pkcs8.parse(priv_der);

    // 篡改 qinv：CRT 不报错但产出错误结果，公钥回验必须拦下并走直接 modexp。
    var bad = key;
    bad.qinv = key.dp;

    const plain = @embedFile("testdata/sign_plain.txt");
    var raw: [rsa.max_modulus_bytes]u8 = undefined;
    try rsa.sign(.sha256, bad, plain, raw[0..key.n.len]);

    const enc = std.base64.standard.Encoder;
    var b64: [rsa.max_modulus_bytes * 2]u8 = undefined;
    const sig = enc.encode(b64[0..enc.calcSize(key.n.len)], raw[0..key.n.len]);
    try std.testing.expectEqualStrings(@embedFile("testdata/sign_expected_b64.txt"), sig);
}
