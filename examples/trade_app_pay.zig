//! 示例：App 支付（alipay.trade.app.pay）。演示 SDK 调用门面 `AppPay.sdk`：
//! 不发起 HTTP，服务端本地签名生成 orderStr，下发给商户 App 唤起支付宝客户端完成支付。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-trade_app_pay
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.runOffline(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const order_str = try alipay.models.trade.AppPay.sdk(ctx.client, ctx.gpa, .{
        .out_trade_no = "test_app_pay_0001",
        .total_amount = "9.00",
        .subject = "大乐透",
    }, .{
        // 支付结果异步通知地址（可选，也可在 Config 里配默认值）。
        .notify_url = "https://example.com/alipay/notify",
    });
    defer ctx.gpa.free(order_str);

    // 实际业务中将 orderStr 原样下发给商户 App，由 App 端调用支付宝 SDK 唤起支付。
    std.debug.print("{s}\n", .{order_str});
}
