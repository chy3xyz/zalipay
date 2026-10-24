//! 示例：电脑网站支付（alipay.trade.page.pay）。演示页面跳转门面 `PagePay.page`：
//! 不发起 HTTP，本地签名后生成自动提交到网关的 HTML 表单，下发浏览器渲染即跳转支付页。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig）：
//!   zig build run-trade_page_pay
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.runOffline(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    const html = try alipay.models.trade.PagePay.page(ctx.client, ctx.gpa, .{
        .out_trade_no = "test_page_pay_0001",
        .total_amount = "88.88",
        .subject = "Iphone6 16G",
        // 可选：商品明细，演示嵌套结构序列化。
        .goods_detail = &.{.{
            .goods_id = "apple-01",
            .goods_name = "ipad",
            .quantity = 1,
            .price = "88.88",
        }},
    }, .{
        // 支付完成后的同步跳转地址与异步通知地址（均可选，也可在 Config 里配默认值）。
        .return_url = "https://example.com/alipay/return",
        .notify_url = "https://example.com/alipay/notify",
    });
    defer ctx.gpa.free(html);

    // 实际业务中将该 HTML 作为 text/html 响应下发浏览器，表单自动提交跳转到支付宝收银台。
    std.debug.print("{s}\n", .{html});
}
