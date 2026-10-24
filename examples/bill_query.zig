//! 示例：查询对账单下载地址。演示强类型门面方法 `DownloadUrlQuery.call`（结果可 IDE 跳转/补全）。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-bill_query
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const resp = try alipay.models.bill.DownloadUrlQuery.call(ctx.client, .{
        .bill_type = "trade",
        // 日账单日期，需为有账单数据的历史日期。
        .bill_date = "2026-06-01",
    }, .{});
    std.debug.print("bill_download_url={?s}\n", .{resp.bill_download_url});
}
