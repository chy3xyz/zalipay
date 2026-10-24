//! 示例：交易查询。演示强类型门面方法 `Query.call`（结果可 IDE 跳转/补全）。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-trade_query
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const resp = try alipay.models.trade.Query.call(ctx.client, .{
        .out_trade_no = "test_pay_0001",
    }, .{});
    std.debug.print("trade_no={?s} status={?s} amount={?s}\n", .{ resp.trade_no, resp.trade_status, resp.total_amount });
}
