//! X509 证书解析：提取 SubjectPublicKeyInfo，计算支付宝证书 SN。
//! SN = lowercase_hex(MD5(issuerDN_RFC2253 + serialNumber_decimal))，左补 0 至 32 位。
//! issuerDN 取 RFC 2253 形式（RDN 相对 DER 反序、`,` 分隔、逗号后无空格）。
const std = @import("std");
const der = std.crypto.Certificate.der;
const pem = @import("pem.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidCert, OutOfMemory };

/// TBS 中定位到的关键字段（切片借用 cert_der 缓冲）。
pub const CertFields = struct {
    spki: []const u8, // 完整 SubjectPublicKeyInfo DER 元素
    issuer: []const u8, // issuer Name SEQUENCE 的内容（RDN 序列）
    serial: []const u8, // serialNumber INTEGER 的 magnitude（含可能的前导 0）
    sig_alg_oid: []const u8, // signatureAlgorithm 的 OID 内容
};

fn parseAt(bytes: []const u8, idx: usize) Error!der.Element {
    return der.Element.parse(bytes, @intCast(idx)) catch return error.InvalidCert;
}

/// 从 X509 证书 DER 提取关键字段。
pub fn parseFields(cert_der: []const u8) Error!CertFields {
    const cert = try parseAt(cert_der, 0);
    if (cert.identifier.tag != .sequence) return error.InvalidCert;
    const tbs = try parseAt(cert_der, cert.slice.start);
    if (tbs.identifier.tag != .sequence) return error.InvalidCert;

    // signatureAlgorithm 是 Certificate 的第二个子元素。
    const sig_alg = try parseAt(cert_der, tbs.slice.end);
    const sig_oid = try parseAt(cert_der, sig_alg.slice.start);
    if (sig_oid.identifier.tag != .object_identifier) return error.InvalidCert;

    // TBS 字段顺序：[0]version?(context), serialNumber, signature, issuer, validity, subject, spki。
    var el = try parseAt(cert_der, tbs.slice.start);
    if (el.identifier.class == .context_specific) {
        el = try parseAt(cert_der, el.slice.end); // 跳过 version → serialNumber
    }
    const serial = cert_der[el.slice.start..el.slice.end];

    const signature = try parseAt(cert_der, el.slice.end);
    const issuer = try parseAt(cert_der, signature.slice.end);
    if (issuer.identifier.tag != .sequence) return error.InvalidCert;
    const validity = try parseAt(cert_der, issuer.slice.end);
    const subject = try parseAt(cert_der, validity.slice.end);
    const spki_el = try parseAt(cert_der, subject.slice.end);
    if (spki_el.identifier.tag != .sequence) return error.InvalidCert;

    return .{
        .spki = cert_der[subject.slice.end..spki_el.slice.end],
        .issuer = cert_der[issuer.slice.start..issuer.slice.end],
        .serial = serial,
        .sig_alg_oid = cert_der[sig_oid.slice.start..sig_oid.slice.end],
    };
}

/// 提取 SPKI DER（供验签构造公钥）。
pub fn extractSpki(cert_der: []const u8) Error![]const u8 {
    return (try parseFields(cert_der)).spki;
}

/// 属性 OID（DER 内容）到 RFC2253 短名。未知返回 null（调用方回退 OID 点分形式）。
fn attrShortName(oid: []const u8) ?[]const u8 {
    const map = .{
        .{ &[_]u8{ 0x55, 0x04, 0x03 }, "CN" },
        .{ &[_]u8{ 0x55, 0x04, 0x06 }, "C" },
        .{ &[_]u8{ 0x55, 0x04, 0x07 }, "L" },
        .{ &[_]u8{ 0x55, 0x04, 0x08 }, "ST" },
        .{ &[_]u8{ 0x55, 0x04, 0x0a }, "O" },
        .{ &[_]u8{ 0x55, 0x04, 0x0b }, "OU" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, oid, entry[0])) return entry[1];
    }
    return null;
}

/// 将 RFC2253 属性值写入 w，转义特殊字符（`,+"\<>;` 及首尾空格与首 `#`）。
fn writeEscaped(w: *std.Io.Writer, v: []const u8) std.Io.Writer.Error!void {
    for (v, 0..) |c, i| {
        const lead_space = c == ' ' and (i == 0 or i == v.len - 1);
        const lead_hash = c == '#' and i == 0;
        switch (c) {
            ',', '+', '"', '\\', '<', '>', ';' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => {
                if (lead_space or lead_hash) try w.writeByte('\\');
                try w.writeByte(c);
            },
        }
    }
}

/// 计算 issuerDN 的 RFC2253 字符串（RDN 相对 DER 反序）。
fn issuerRfc2253(gpa: Allocator, issuer: []const u8) Error![]u8 {
    // 先按 DER 顺序收集 (short_name, value)。
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(gpa);
    var oid_bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (oid_bufs.items) |b| gpa.free(b);
        oid_bufs.deinit(gpa);
    }

    var off: usize = 0;
    while (off < issuer.len) {
        const rdn = parseAt(issuer, off) catch return error.InvalidCert; // SET
        const atv = try parseAt(issuer, rdn.slice.start); // SEQUENCE
        const oid = try parseAt(issuer, atv.slice.start);
        const val = try parseAt(issuer, oid.slice.end);
        const oid_bytes = issuer[oid.slice.start..oid.slice.end];
        if (attrShortName(oid_bytes)) |sn| {
            try names.append(gpa, sn);
        } else {
            const dotted = try oidToDotted(gpa, oid_bytes);
            try oid_bufs.append(gpa, dotted);
            try names.append(gpa, dotted);
        }
        try values.append(gpa, issuer[val.slice.start..val.slice.end]);
        off = rdn.slice.end;
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    // 反序输出。
    var i: usize = names.items.len;
    var first = true;
    while (i > 0) {
        i -= 1;
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll(names.items[i]) catch return error.OutOfMemory;
        w.writeByte('=') catch return error.OutOfMemory;
        writeEscaped(w, values.items[i]) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// OID DER 内容 → 点分十进制字符串。
fn oidToDotted(gpa: Allocator, oid: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (oid.len == 0) return out.toOwnedSlice() catch return error.OutOfMemory;
    const first = oid[0];
    w.print("{d}.{d}", .{ first / 40, first % 40 }) catch return error.OutOfMemory;
    var val: u64 = 0;
    for (oid[1..]) |b| {
        val = (val << 7) | (b & 0x7f);
        if (b & 0x80 == 0) {
            w.print(".{d}", .{val}) catch return error.OutOfMemory;
            val = 0;
        }
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// 大端 magnitude → 十进制字符串（支持任意长度序列号）。
fn bytesToDecimal(gpa: Allocator, mag: []const u8) Error![]u8 {
    var start: usize = 0;
    while (start < mag.len and mag[start] == 0) start += 1;
    if (start == mag.len) return gpa.dupe(u8, "0");

    var buf = try gpa.dupe(u8, mag[start..]);
    defer gpa.free(buf);
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);

    var lo: usize = 0;
    while (lo < buf.len) {
        var rem: u16 = 0;
        for (buf[lo..]) |*b| {
            const cur: u16 = (rem << 8) | b.*;
            b.* = @intCast(cur / 10);
            rem = cur % 10;
        }
        try digits.append(gpa, '0' + @as(u8, @intCast(rem)));
        while (lo < buf.len and buf[lo] == 0) lo += 1;
    }
    std.mem.reverse(u8, digits.items);
    return digits.toOwnedSlice(gpa);
}

fn md5HexLower(input: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = alphabet[byte >> 4];
        hex[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return hex;
}

/// 计算单张证书的 SN（32 位小写 hex）。
pub fn computeSn(gpa: Allocator, cert_der: []const u8) Error![32]u8 {
    const f = try parseFields(cert_der);
    const issuer = try issuerRfc2253(gpa, f.issuer);
    defer gpa.free(issuer);
    const serial = try bytesToDecimal(gpa, f.serial);
    defer gpa.free(serial);

    const joined = try std.mem.concat(gpa, u8, &.{ issuer, serial });
    defer gpa.free(joined);
    return md5HexLower(joined);
}

/// signatureAlgorithm OID 是否属 PKCS#1 RSA 族（1.2.840.113549.1.1.*）。
fn isRsaFamily(oid: []const u8) bool {
    const prefix = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01 };
    return oid.len >= prefix.len and std.mem.eql(u8, oid[0..prefix.len], &prefix);
}

/// 计算根证书 SN：对 PEM 链中每张 RSA 族证书算 SN，按 PEM 顺序以 `_` 连接。
/// 调用方负责 free 返回值。
pub fn computeRootSn(gpa: Allocator, root_pem: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var first = true;

    var rest = root_pem;
    while (std.mem.find(u8, rest, "-----BEGIN")) |begin| {
        const after = rest[begin..];
        const end_marker = "-----END";
        const end_idx = std.mem.find(u8, after, end_marker) orelse break;
        // 定位 END 行结尾。
        const end_line_end = std.mem.findScalarPos(u8, after, end_idx, '\n') orelse after.len;
        const block = after[0..end_line_end];

        const cert_der = pem.decode(gpa, block) catch {
            rest = after[end_line_end..];
            continue;
        };
        defer gpa.free(cert_der);

        const f = parseFields(cert_der) catch {
            rest = after[end_line_end..];
            continue;
        };
        if (isRsaFamily(f.sig_alg_oid)) {
            const sn = try computeSn(gpa, cert_der);
            if (!first) w.writeByte('_') catch return error.OutOfMemory;
            first = false;
            w.writeAll(&sn) catch return error.OutOfMemory;
        }
        rest = after[end_line_end..];
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "cert SN matches openssl+md5 reference" {
    const gpa = std.testing.allocator;
    const cert_pem = @embedFile("testdata/test_cert.pem");
    const cert_der = try pem.decode(gpa, cert_pem);
    defer gpa.free(cert_der);

    const sn = try computeSn(gpa, cert_der);
    // 参考值由 openssl(issuer RFC2253) + python md5 生成。
    try std.testing.expectEqualStrings("4c3fe7b7767ab44c8ec828a552f016de", &sn);
}
