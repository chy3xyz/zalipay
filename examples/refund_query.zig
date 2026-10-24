//! 示例：退款查询。演示强类型门面方法 `RefundQuery.call`（结果可 IDE 跳转/补全）。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-refund_query
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const resp = try alipay.models.trade.RefundQuery.call(ctx.client, .{
        .out_trade_no = "test_no_0001",
        // 全额退款场景退款请求号可复用订单号。
        .out_request_no = "test_no_0001",
        // 额外返回退款时间与资金渠道明细。
        .query_options = &.{ "gmt_refund_pay", "refund_detail_item_list" },
    }, .{});
    std.debug.print("trade_no={?s} refund_status={?s} refund_amount={?s} gmt_refund_pay={?s}\n", .{ resp.trade_no, resp.refund_status, resp.refund_amount, resp.gmt_refund_pay });
    if (resp.refund_detail_item_list) |items| for (items) |item| {
        std.debug.print("fund_channel={s} amount={s}\n", .{ item.fund_channel, item.amount });
    };
}
