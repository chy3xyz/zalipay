//! EMSA-PKCS1-v1.5 编码（用于签名方向；验签方向复用 std）。
//! EM = 0x00 || 0x01 || PS(0xff…) || 0x00 || DigestInfo(Hash(M))。
//! DigestInfo DER 前缀照搬 std/crypto/Certificate.zig 的常量。
const std = @import("std");

/// 支持的摘要算法及其 DigestInfo DER 前缀。
pub const Hash = enum {
    sha1,
    sha256,

    fn Impl(comptime self: Hash) type {
        return switch (self) {
            .sha1 => std.crypto.hash.Sha1,
            .sha256 => std.crypto.hash.sha2.Sha256,
        };
    }

    fn prefix(self: Hash) []const u8 {
        return switch (self) {
            .sha1 => &.{
                0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
                0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
            },
            .sha256 => &.{
                0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
                0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
                0x00, 0x04, 0x20,
            },
        };
    }

    fn digestLen(self: Hash) usize {
        return switch (self) {
            .sha1 => std.crypto.hash.Sha1.digest_length,
            .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
        };
    }
};

pub const EncodeError = error{ IntendedLengthTooShort, DigestTooLarge };

/// 计算 msg 摘要并写出长度为 em_len 的 EM 到 out（out.len 必须 == em_len）。
pub fn encode(comptime hash: Hash, msg: []const u8, out: []u8) EncodeError!void {
    const H = comptime hash.Impl();
    var digest: [H.digest_length]u8 = undefined;
    var hasher = H.init(.{});
    hasher.update(msg);
    hasher.final(&digest);

    const pfx = hash.prefix();
    const t_len = pfx.len + digest.len; // DigestInfo 总长
    // EM = 00 01 [PS>=8 个 ff] 00 [T]；至少 t_len + 11 字节。
    if (out.len < t_len + 11) return error.IntendedLengthTooShort;

    out[0] = 0x00;
    out[1] = 0x01;
    const ps_end = out.len - t_len - 1; // 0x00 分隔符位置
    @memset(out[2..ps_end], 0xff);
    out[ps_end] = 0x00;
    @memcpy(out[ps_end + 1 ..][0..pfx.len], pfx);
    @memcpy(out[ps_end + 1 + pfx.len ..][0..digest.len], &digest);
}
