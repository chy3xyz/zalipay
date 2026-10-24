//! RSA 私钥 DER 解析：兼容 PKCS#8（PrivateKeyInfo）与 PKCS#1（RSAPrivateKey）。
//! 复用 std 的 DER 元素解析器，只做薄结构遍历，输出各整数的 magnitude 字节切片
//! （已剥离 DER 正号前导 0x00），切片均借用输入 der_bytes 缓冲。
const std = @import("std");
const der = std.crypto.Certificate.der;

pub const ParseError = error{ InvalidKey, InvalidKeyEncoding };

/// RSA 私钥各分量（big-endian 无前导零的 magnitude）。CRT 分量在 PKCS#1/#8 完整密钥中总是存在。
pub const RsaPrivateKey = struct {
    n: []const u8, // 模数
    e: []const u8, // 公钥指数
    d: []const u8, // 私钥指数
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qinv: []const u8,
};

fn expect(bytes: []const u8, idx: usize, tag: der.Tag) ParseError!der.Element {
    const el = der.Element.parse(bytes, @intCast(idx)) catch return error.InvalidKeyEncoding;
    if (el.identifier.tag != tag) return error.InvalidKey;
    return el;
}

/// 取 INTEGER 元素的 magnitude，剥离 DER 为保持正号而加的前导 0x00。
fn intMagnitude(bytes: []const u8, el: der.Element) []const u8 {
    const raw = bytes[el.slice.start..el.slice.end];
    var i: usize = 0;
    while (i < raw.len and raw[i] == 0) i += 1;
    return raw[i..];
}

/// 解析 DER 编码的 RSA 私钥；自动区分 PKCS#8 与 PKCS#1。
pub fn parse(der_bytes: []const u8) ParseError!RsaPrivateKey {
    const outer = try expect(der_bytes, 0, .sequence);
    // 第一个元素恒为 version INTEGER。
    const v = try expect(der_bytes, outer.slice.start, .integer);
    const second = der.Element.parse(der_bytes, v.slice.end) catch return error.InvalidKeyEncoding;

    // PKCS#8: version, AlgorithmIdentifier(SEQUENCE), privateKey(OCTET STRING{RSAPrivateKey})。
    // PKCS#1: version, n(INTEGER), e, d, ...
    if (second.identifier.tag == .sequence) {
        const pk_octet = der.Element.parse(der_bytes, second.slice.end) catch return error.InvalidKeyEncoding;
        if (pk_octet.identifier.tag != .octetstring) return error.InvalidKey;
        // OCTET STRING 内容即 RSAPrivateKey DER。
        return parsePkcs1(der_bytes, pk_octet.slice.start);
    }
    if (second.identifier.tag == .integer) {
        // 外层 SEQUENCE 就是 RSAPrivateKey。
        return parsePkcs1Fields(der_bytes, v.slice.end);
    }
    return error.InvalidKey;
}

/// 从 RSAPrivateKey SEQUENCE 的起始偏移解析（seq_start 指向 SEQUENCE 元素本身）。
fn parsePkcs1(bytes: []const u8, seq_start: usize) ParseError!RsaPrivateKey {
    const seq = try expect(bytes, seq_start, .sequence);
    const ver = try expect(bytes, seq.slice.start, .integer);
    return parsePkcs1Fields(bytes, ver.slice.end);
}

/// 从 version 之后的偏移顺序读取 n,e,d,p,q,dp,dq,qinv 八个 INTEGER。
fn parsePkcs1Fields(bytes: []const u8, after_version: usize) ParseError!RsaPrivateKey {
    var off = after_version;
    var out: [8][]const u8 = undefined;
    inline for (0..8) |i| {
        const el = try expect(bytes, off, .integer);
        out[i] = intMagnitude(bytes, el);
        off = el.slice.end;
    }
    return .{
        .n = out[0],
        .e = out[1],
        .d = out[2],
        .p = out[3],
        .q = out[4],
        .dp = out[5],
        .dq = out[6],
        .qinv = out[7],
    };
}
