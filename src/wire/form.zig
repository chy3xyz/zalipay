//! transport 编码：application/x-www-form-urlencoded body 构造。
//! 仅此处做 URL 编码（RFC3986 百分号编码），签名之后发生。
const std = @import("std");
const Allocator = std.mem.Allocator;
const Pair = @import("canonical.zig").Pair;

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// 将 s 按 RFC3986 百分号编码追加到 out。非 unreserved 字符编码为 %XX（大写 hex）。
pub fn percentEncode(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(gpa, c);
        } else {
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0x0f]);
        }
    }
}

/// 构造 form body：`k=urlencode(v)&...`，包含 sign，跳过空 key/value。
/// 返回新分配缓冲，调用方负责释放。
pub fn build(gpa: Allocator, pairs: []const Pair) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var first = true;
    for (pairs) |p| {
        if (p.key.len == 0 or p.value.len == 0) continue;
        if (!first) try out.append(gpa, '&');
        first = false;
        try percentEncode(gpa, &out, p.key);
        try out.append(gpa, '=');
        try percentEncode(gpa, &out, p.value);
    }
    return out.toOwnedSlice(gpa);
}

test "form: percent-encode reserved chars, keep unreserved" {
    const gpa = std.testing.allocator;
    const pairs = [_]Pair{
        .{ .key = "biz_content", .value = "{\"amount\":\"1.00\"}" },
        .{ .key = "sign", .value = "a+b/c=" },
    };
    const got = try build(gpa, &pairs);
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        "biz_content=%7B%22amount%22%3A%221.00%22%7D&sign=a%2Bb%2Fc%3D",
        got,
    );
}
