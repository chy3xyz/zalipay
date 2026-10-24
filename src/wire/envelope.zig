//! 响应 envelope：在原始 body 字节上定位 `{method}_response` / `error_response` 的
//! 精确大括号子串（引号/转义感知），同时取顶层 sign。
//! 关键：验签用的是**原始子串**，绝不重新序列化（JSON 库重排键会破坏验签）。
const std = @import("std");

pub const Error = error{ EnvelopeNotFound, BadResponse, MethodTooLong };

pub const Envelope = struct {
    /// `{...}` 原始子串（借用 raw 缓冲），既供验签又供解码。
    node: []const u8,
    /// 顶层 sign 值（原始 base64，借用 raw）；error_response 或缺失时为 null。
    sign: ?[]const u8,
    /// 顶层 alipay_cert_sn（证书模式下网关回填，标识验签用的支付宝公钥证书）；缺失为 null。
    cert_sn: ?[]const u8 = null,
    is_error: bool,
};

/// 由 method 生成成功节点名：`.`→`_` + `_response`，写入 buf。
pub fn nodeName(method: []const u8, buf: []u8) Error![]u8 {
    const suffix = "_response";
    if (method.len + suffix.len > buf.len) return error.MethodTooLong;
    for (method, 0..) |c, i| buf[i] = if (c == '.') '_' else c;
    @memcpy(buf[method.len..][0..suffix.len], suffix);
    return buf[0 .. method.len + suffix.len];
}

/// 从 obj_start（指向 `{`）起做引号/转义感知的括号匹配，返回含首尾大括号的子串。
fn matchObject(raw: []const u8, obj_start: usize) Error![]const u8 {
    var depth: usize = 0;
    var in_str = false;
    var esc = false;
    var i = obj_start;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
        } else switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return raw[obj_start .. i + 1];
            },
            else => {},
        }
    }
    return error.BadResponse;
}

/// 在 raw[from..] 中找到 `"key"` 后的对象值（`{...}`），返回子串与其结束索引。
fn findObjectAfterKey(raw: []const u8, key: []const u8, from: usize) ?struct { node: []const u8, end: usize } {
    var search_from = from;
    while (std.mem.findPos(u8, raw, search_from, key)) |pos| {
        var i = pos + key.len;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) i += 1;
        if (i < raw.len and raw[i] == ':') {
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) i += 1;
            if (i < raw.len and raw[i] == '{') {
                const node = matchObject(raw, i) catch return null;
                return .{ .node = node, .end = i + node.len };
            }
        }
        search_from = pos + key.len;
    }
    return null;
}

/// 在 raw[from..] 中找到 `"key"` 后的字符串值，返回原始内容（不去转义）。
fn findStringAfterKey(raw: []const u8, key: []const u8, from: usize) ?[]const u8 {
    const pos = std.mem.findPos(u8, raw, from, key) orelse return null;
    var i = pos + key.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) i += 1;
    if (i >= raw.len or raw[i] != ':') return null;
    i += 1;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t' or raw[i] == '\n' or raw[i] == '\r')) i += 1;
    if (i >= raw.len or raw[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            i += 1;
            continue;
        }
        if (raw[i] == '"') return raw[start..i];
    }
    return null;
}

/// 在成功节点之外的顶层区域找 `"key"` 的字符串值：先搜节点之后（网关惯常字段序），
/// 找不到再回退节点之前的前缀（前缀不含节点本身，容忍字段序变化）。
/// 注意：原始字节扫描、不感知嵌套深度，正确性依赖网关顶层除响应节点外
/// 仅有字符串值字段（sign / alipay_cert_sn 等）这一响应形态。
fn findTopLevelString(raw: []const u8, hit: anytype, key: []const u8) ?[]const u8 {
    return findStringAfterKey(raw, key, hit.end) orelse
        findStringAfterKey(raw[0 .. hit.end - hit.node.len], key, 0);
}

/// 解析响应 envelope。name_buf 提供成功节点名构造缓冲（>= method.len + 9）。
pub fn parse(raw: []const u8, method: []const u8, name_buf: []u8) Error!Envelope {
    const success_name = try nodeName(method, name_buf);

    // 用带引号的 key 定位，避免命中子串。
    var qbuf: [160]u8 = undefined;
    if (success_name.len + 2 > qbuf.len) return error.MethodTooLong;
    qbuf[0] = '"';
    @memcpy(qbuf[1..][0..success_name.len], success_name);
    qbuf[success_name.len + 1] = '"';
    const quoted = qbuf[0 .. success_name.len + 2];

    if (findObjectAfterKey(raw, quoted, 0)) |hit| {
        // 防篡改：拒绝重复的成功节点。
        if (std.mem.findPos(u8, raw, hit.end, quoted) != null) return error.BadResponse;
        const sign = findTopLevelString(raw, hit, "\"sign\"");
        const cert_sn = findTopLevelString(raw, hit, "\"alipay_cert_sn\"");
        return .{ .node = hit.node, .sign = sign, .cert_sn = cert_sn, .is_error = false };
    }
    if (findObjectAfterKey(raw, "\"error_response\"", 0)) |hit| {
        return .{ .node = hit.node, .sign = null, .is_error = true };
    }
    return error.EnvelopeNotFound;
}

test "envelope: extract success node raw substring + sign" {
    const raw =
        \\{"alipay_trade_query_response":{"code":"10000","msg":"Success","trade_no":"20\/25"},"sign":"ABC+/="}
    ;
    var buf: [128]u8 = undefined;
    const env = try parse(raw, "alipay.trade.query", &buf);
    try std.testing.expect(!env.is_error);
    try std.testing.expectEqualStrings(
        "{\"code\":\"10000\",\"msg\":\"Success\",\"trade_no\":\"20\\/25\"}",
        env.node,
    );
    try std.testing.expectEqualStrings("ABC+/=", env.sign.?);
}

test "envelope: sign before node and alipay_cert_sn extraction" {
    const raw =
        \\{"sign":"EARLY","alipay_cert_sn":"4c3fe7b7767ab44c8ec828a552f016de","alipay_x_response":{"code":"10000"}}
    ;
    var buf: [128]u8 = undefined;
    const env = try parse(raw, "alipay.x", &buf);
    try std.testing.expectEqualStrings("EARLY", env.sign.?);
    try std.testing.expectEqualStrings("4c3fe7b7767ab44c8ec828a552f016de", env.cert_sn.?);
}

test "envelope: nested braces and escaped quotes" {
    const raw =
        \\{"alipay_x_response":{"a":{"b":"}{"},"c":"he\"llo"},"sign":"S"}
    ;
    var buf: [128]u8 = undefined;
    const env = try parse(raw, "alipay.x", &buf);
    try std.testing.expectEqualStrings(
        "{\"a\":{\"b\":\"}{\"},\"c\":\"he\\\"llo\"}",
        env.node,
    );
}

test "envelope: error_response" {
    const raw =
        \\{"error_response":{"code":"40002","msg":"Invalid Arguments"},"sign":"S"}
    ;
    var buf: [128]u8 = undefined;
    const env = try parse(raw, "alipay.trade.query", &buf);
    try std.testing.expect(env.is_error);
    try std.testing.expectEqualStrings(
        "{\"code\":\"40002\",\"msg\":\"Invalid Arguments\"}",
        env.node,
    );
}

test "envelope: not found" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.EnvelopeNotFound, parse("{\"other\":{}}", "alipay.trade.query", &buf));
}
