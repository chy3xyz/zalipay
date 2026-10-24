//! comptime (反)序列化薄封装。序列化用 std.json.Stringify（按 struct 字段生成，
//! 省略 null 可选字段 —— 支付宝要求缺省而非 null）；解析用 parseFromSlice（忽略未知字段）。
const std = @import("std");
const Allocator = std.mem.Allocator;

/// std.json.Parsed(T) 的别名（含独立 arena，需 deinit）。
pub fn Parsed(comptime T: type) type {
    return std.json.Parsed(T);
}

/// 序列化 biz_content struct 为紧凑 JSON。返回分配于 gpa 的缓冲，调用方负责释放。
/// 省略 null 可选字段（支付宝要求缺省而非 null）。
pub fn serializeBiz(gpa: Allocator, value: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

/// 解析响应节点为强类型。忽略未知字段（响应字段远多于 model 声明）。
pub fn parse(comptime T: type, gpa: Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true });
}

/// 解析到指定 allocator（无独立 arena 包装）；所有字符串深拷贝，生命周期随 alloc。
/// 供 Client 将结果解析进请求外的 out_arena / 内部 arena，独立于响应原始 buffer。
pub fn parseLeaky(comptime T: type, alloc: Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "serializeBiz omits null optional fields" {
    const gpa = std.testing.allocator;
    const Biz = struct {
        out_biz_no: []const u8,
        trans_amount: []const u8,
        remark: ?[]const u8 = null,
    };
    const s = try serializeBiz(gpa, Biz{ .out_biz_no = "T1", .trans_amount = "1.00" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings(
        "{\"out_biz_no\":\"T1\",\"trans_amount\":\"1.00\"}",
        s,
    );
}

test "serializeBiz emits present optional" {
    const gpa = std.testing.allocator;
    const Biz = struct { a: []const u8, b: ?[]const u8 = null };
    const s = try serializeBiz(gpa, Biz{ .a = "x", .b = "y" });
    defer gpa.free(s);
    try std.testing.expectEqualStrings("{\"a\":\"x\",\"b\":\"y\"}", s);
}

test "parse ignores unknown fields" {
    const gpa = std.testing.allocator;
    const Resp = struct { code: []const u8, msg: []const u8 };
    const p = try parse(Resp, gpa, "{\"code\":\"10000\",\"msg\":\"Success\",\"extra\":\"ignored\"}");
    defer p.deinit();
    try std.testing.expectEqualStrings("10000", p.value.code);
    try std.testing.expectEqualStrings("Success", p.value.msg);
}
