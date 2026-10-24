//! 示例：当面付/订单码支付预下单（alipay.trade.precreate）。演示强类型门面方法 `Precreate.call`。
//! 成功返回二维码码串（有效期 2 小时），用二维码生成工具生成二维码供买家扫码付款。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig；同一订单号不可重复申请二维码，重跑请换 out_trade_no）：
//!   zig build run-trade_precreate
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const resp = try alipay.models.trade.Precreate.call(ctx.client, .{
        .out_trade_no = "test_precreate_0001",
        .total_amount = "88.88",
        .subject = "Iphone6 16G",
    }, .{});
    std.debug.print("precreate ok: out_trade_no={?s} qr_code={?s}\n", .{ resp.out_trade_no, resp.qr_code });
}
