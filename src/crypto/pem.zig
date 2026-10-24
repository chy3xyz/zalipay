//! PEM/base64 解码：容忍带或不带 -----BEGIN/END----- 头，剥离所有空白后 base64 解码。
//! 支付宝配置里的密钥常以裸 base64 body 形式提供，故两种形态都需支持。
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidBase64, OutOfMemory };

/// 解码单个 PEM 块或裸 base64 body，返回新分配的 DER 字节（调用方负责 free）。
pub fn decode(gpa: Allocator, input: []const u8) Error![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or std.mem.startsWith(u8, t, "-----")) continue;
        try body.appendSlice(gpa, t);
    }
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(body.items) catch return error.InvalidBase64;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    dec.decode(out, body.items) catch return error.InvalidBase64;
    return out;
}
