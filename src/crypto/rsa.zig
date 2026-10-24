//! RSA 原语：签名用自实现的 PKCS#1 v1.5 + 常量时间 modexp（默认走 CRT 加速）；验签复用 std。
//! 覆盖 ≤2048-bit（支付宝 RSA2 固定 2048-bit）。
const std = @import("std");
const ff = std.crypto.ff;
const pkcs1v15 = @import("pkcs1v15.zig");
const pkcs8 = @import("pkcs8.zig");
const rsa_std = std.crypto.Certificate.rsa;

/// 全模数域宽度（n）；CRT 子运算域宽度（p/q，为 n 的一半）。
const N = ff.Modulus(2048);
const H = ff.Modulus(1024); // p、q ≤ 1024-bit（2048-bit 密钥）
const WideUint = ff.Uint(2048);

/// 支付宝密钥固定 256 字节（2048-bit）；亦为签名缓冲上限。
pub const max_modulus_bytes = 256;
const half_bytes = max_modulus_bytes / 2;

pub const Error = error{ SignFailed, VerifyFailed };

/// SHA256withRSA / SHA1withRSA 签名。out 长度须等于模数字节数，写入原始签名字节。
/// 默认走 CRT（约 3–4× 加速），回验失败回退直接 modexp；任一路径的产出都经公钥
/// 回验后才返回，密钥损坏时返回 SignFailed 而非外发无效签名。
pub fn sign(
    comptime hash: pkcs1v15.Hash,
    key: pkcs8.RsaPrivateKey,
    content: []const u8,
    out: []u8,
) Error!void {
    const modn = N.fromBytes(key.n, .big) catch return error.SignFailed;
    const mlen = (modn.bits() + 7) / 8;
    if (out.len != mlen or mlen > max_modulus_bytes) return error.SignFailed;

    var em_buf: [max_modulus_bytes]u8 = undefined;
    const em = em_buf[0..mlen];
    pkcs1v15.encode(hash, content, em) catch return error.SignFailed;

    // Bellcore/Lenstra 防护：CRT 结果必须先用公钥回验 s^e mod n == em 才可外发——
    // 密钥分量不自洽或计算故障产出的错误 CRT 签名，一旦被观测（page/sdk 场景
    // 签名直达终端）即可用于分解 n、泄露私钥。回验失败回退直接 modexp。
    const crt_ok = if (signCrt(modn, key, em, out)) |_|
        signatureValid(modn, key.e, em, out)
    else |_|
        false;
    if (crt_ok) return;

    // 直接路径同样回验：d 损坏产出的垃圾签名不可利用，但宁可本地 SignFailed，
    // 也不外发无效签名让故障只表现为网关侧不可解释的拒绝。
    try signDirectEm(modn, key.d, em, out);
    if (!signatureValid(modn, key.e, em, out)) return error.SignFailed;
}

/// 用公钥指数回验签名：s^e mod n 必须还原出 em（e 公开，用 vartime 幂即可）。
fn signatureValid(modn: N, e: []const u8, em: []const u8, sig: []const u8) bool {
    const sig_fe = N.Fe.fromBytes(modn, sig, .big) catch return false;
    const back = modn.powWithEncodedPublicExponent(sig_fe, e, .big) catch return false;
    var buf: [max_modulus_bytes]u8 = undefined;
    back.toBytes(buf[0..em.len], .big) catch return false;
    return std.mem.eql(u8, buf[0..em.len], em);
}

/// 直接 modexp：s = em^d mod n。作为 CRT 回退，也供回归对比。
pub fn signDirect(
    comptime hash: pkcs1v15.Hash,
    key: pkcs8.RsaPrivateKey,
    content: []const u8,
    out: []u8,
) Error!void {
    const modn = N.fromBytes(key.n, .big) catch return error.SignFailed;
    const mlen = (modn.bits() + 7) / 8;
    if (out.len != mlen or mlen > max_modulus_bytes) return error.SignFailed;
    var em_buf: [max_modulus_bytes]u8 = undefined;
    const em = em_buf[0..mlen];
    pkcs1v15.encode(hash, content, em) catch return error.SignFailed;
    return signDirectEm(modn, key.d, em, out);
}

fn signDirectEm(modn: N, d: []const u8, em: []const u8, out: []u8) Error!void {
    const em_fe = N.Fe.fromBytes(modn, em, .big) catch return error.SignFailed;
    // 私钥指数为秘密 → 常量时间幂运算，抗时序侧信道。
    const sig_fe = modn.powWithEncodedExponent(em_fe, d, .big) catch return error.SignFailed;
    sig_fe.toBytes(out, .big) catch return error.SignFailed;
}

/// CRT 签名：m1=em^dp mod p，m2=em^dq mod q，h=(m1-m2)·qinv mod p，m=m2+q·h。
/// 子运算在半宽域（p/q）进行；重组因 q·h<n、m2+q·h<n 而在 N 域用 mul/add 即得精确整数值。
fn signCrt(modn: N, key: pkcs8.RsaPrivateKey, em: []const u8, out: []u8) Error!void {
    const p = H.fromBytes(key.p, .big) catch return error.SignFailed;
    const q = H.fromBytes(key.q, .big) catch return error.SignFailed;
    const em_uint = WideUint.fromBytes(em, .big) catch return error.SignFailed;

    // em mod p、em mod q（reduce 接受更宽的 Uint 输入）。
    const cp = p.reduce(em_uint);
    const cq = q.reduce(em_uint);
    const m1 = p.powWithEncodedExponent(cp, key.dp, .big) catch return error.SignFailed;
    const m2 = q.powWithEncodedExponent(cq, key.dq, .big) catch return error.SignFailed;

    // h = (m1 - (m2 mod p)) · qinv mod p。
    const m2p = p.reduce(m2.v);
    const s = p.sub(m1, m2p);
    const qinv = H.Fe.fromBytes(p, key.qinv, .big) catch return error.SignFailed;
    const h = p.mul(s, qinv);

    // m = m2 + q·h，在 N 域计算（结果 < n，故 mul/add mod n 即精确）。
    var hb: [half_bytes]u8 = undefined;
    var m2b: [half_bytes]u8 = undefined;
    h.toBytes(&hb, .big) catch return error.SignFailed;
    m2.toBytes(&m2b, .big) catch return error.SignFailed;

    const h_n = N.Fe.fromBytes(modn, &hb, .big) catch return error.SignFailed;
    const m2_n = N.Fe.fromBytes(modn, &m2b, .big) catch return error.SignFailed;
    const q_n = N.Fe.fromBytes(modn, key.q, .big) catch return error.SignFailed;
    const qh = modn.mul(q_n, h_n);
    const m = modn.add(m2_n, qh);
    m.toBytes(out, .big) catch return error.SignFailed;
}

/// 从 X509 SubjectPublicKeyInfo（DER）构造 std 公钥。
pub fn publicKeyFromSpki(spki: []const u8) Error!rsa_std.PublicKey {
    // std 的 der.Element.parse 对空输入会越界 panic，须先挡掉。
    if (spki.len == 0) return error.VerifyFailed;
    const der = std.crypto.Certificate.der;
    const seq = der.Element.parse(spki, 0) catch return error.VerifyFailed;
    if (seq.identifier.tag != .sequence) return error.VerifyFailed;
    // 第一个子元素为 AlgorithmIdentifier，跳过；第二个为 BIT STRING。
    const algo = der.Element.parse(spki, seq.slice.start) catch return error.VerifyFailed;
    const bitstr = der.Element.parse(spki, algo.slice.end) catch return error.VerifyFailed;
    if (bitstr.identifier.tag != .bitstring) return error.VerifyFailed;
    // BIT STRING 首字节为 unused-bits 计数（0），其后为 RSAPublicKey DER。
    if (bitstr.slice.start + 1 > bitstr.slice.end) return error.VerifyFailed;
    const inner = spki[bitstr.slice.start + 1 .. bitstr.slice.end];
    return publicKeyFromRsaDer(inner);
}

/// 从 RSAPublicKey（SEQUENCE{modulus,exponent}）DER 构造 std 公钥。
pub fn publicKeyFromRsaDer(rsa_der: []const u8) Error!rsa_std.PublicKey {
    const parts = rsa_std.PublicKey.parseDer(rsa_der) catch return error.VerifyFailed;
    return rsa_std.PublicKey.fromBytes(parts.exponent, parts.modulus) catch return error.VerifyFailed;
}

/// 用给定公钥验签。sig 为原始签名字节（长度须等于模数字节数）。
pub fn verify(
    comptime hash: pkcs1v15.Hash,
    pk: rsa_std.PublicKey,
    content: []const u8,
    sig: []const u8,
) Error!void {
    const mlen = (pk.n.bits() + 7) / 8;
    if (sig.len != mlen) return error.VerifyFailed;
    const Hash = comptime switch (hash) {
        .sha1 => std.crypto.hash.Sha1,
        .sha256 => std.crypto.hash.sha2.Sha256,
    };
    const Sig = rsa_std.PKCS1v1_5Signature;
    // std 的 verify 需 comptime 模数字节数；覆盖支付宝常见位宽（128=旧 RSA/SHA1 1024-bit）。
    switch (mlen) {
        128 => Sig.verify(128, sig[0..128], content, pk, Hash) catch return error.VerifyFailed,
        256 => Sig.verify(256, sig[0..256], content, pk, Hash) catch return error.VerifyFailed,
        384 => Sig.verify(384, sig[0..384], content, pk, Hash) catch return error.VerifyFailed,
        512 => Sig.verify(512, sig[0..512], content, pk, Hash) catch return error.VerifyFailed,
        else => return error.VerifyFailed,
    }
}
