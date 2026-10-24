//! 示例：手机网站支付（alipay.trade.wap.pay）。演示页面跳转门面 `WapPay.page`：
//! 不发起 HTTP，本地签名后生成自动提交到网关的 HTML 表单，下发手机浏览器渲染即跳转支付页。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-trade_wap_pay
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.runOffline(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const html = try alipay.models.trade.WapPay.page(ctx.client, ctx.gpa, .{
        .out_trade_no = "test_wap_pay_0001",
        .total_amount = "9.00",
        .subject = "大乐透",
        // 可选：用户付款中途退出时返回商户网站的地址。
        .quit_url = "https://example.com/alipay/quit",
    }, .{
        // 支付完成后的同步跳转地址与异步通知地址（均可选，也可在 Config 里配默认值）。
        .return_url = "https://example.com/alipay/return",
        .notify_url = "https://example.com/alipay/notify",
    });
    defer ctx.gpa.free(html);

    // 实际业务中将该 HTML 作为 text/html 响应下发手机浏览器，表单自动提交跳转到支付宝收银台。
    std.debug.print("{s}\n", .{html});
}
