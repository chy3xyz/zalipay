//! 示例：单笔转账 alipay.fund.trans.uni.transfer（强类型门面 + S2S 调用）。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig；收款方需换成沙箱买家账号登录名）：
//!   zig build run-transfer
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const resp = try alipay.models.fund.UniTransfer.call(ctx.client, .{
        .out_biz_no = "demo-20260701-0001",
        .trans_amount = "0.10",
        .order_title = "示例转账",
        .payee_info = .{ .identity = "receiver@example.com", .identity_type = "ALIPAY_LOGON_ID" },
    }, .{});
    std.debug.print("transfer ok: status={?s} order_id={?s} pay_fund_order_id={?s}\n", .{ resp.status, resp.order_id, resp.pay_fund_order_id });
}
