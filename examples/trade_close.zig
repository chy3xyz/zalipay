//! 示例：交易关闭（alipay.trade.close）。演示强类型门面方法 `Close.call`。
//! 仅等待买家付款状态的交易可关闭；成功后回传 trade_no/out_trade_no 并触发 TRADE_CLOSED 通知。
//!
//! 运行（凭据内置沙箱账号，见 _sandbox.zig；订单号需指向沙箱中真实待付款交易）：
//!   zig build run-trade_close
const std = @import("std");
const harness = @import("harness");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    return harness.run(init, demo);
}

fn demo(ctx: *harness.Ctx) !void {
    // trade_no 与 out_trade_no 二选一，同传以 trade_no 为准。
    const resp = try alipay.models.trade.Close.call(ctx.client, .{
        .out_trade_no = "test_no_0001",
    }, .{});
    std.debug.print("closed: trade_no={?s} out_trade_no={?s}\n", .{ resp.trade_no, resp.out_trade_no });
}
