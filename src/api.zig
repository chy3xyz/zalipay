//! 强类型门面工厂（核心 DX，公开给下游）。
//!
//! 下游同法为任意接口定义强类型 API：
//!   const Pay = alipay.Api("alipay.trade.pay", PayBiz, PayResp);
//!   const r = try Pay.call(&client, .{ .out_trade_no = "..." }, .{});
//!
//! 约定：
//! - Biz：普通 struct，字段名即 JSON snake_case；`?T = null` 的可选字段在序列化时省略（缺省而非 null）。
//! - Resp：普通 struct，建议含 `code`/`msg`/`sub_code`/`sub_msg` 公共字段（Client 据 `code` 判定业务成功），
//!   其后为业务字段。解析忽略未声明字段，故只需声明关心的字段。
//!
//! 为何提供 `call`/`page`/`sdk` 方法而非只用 `client.execute(A, ...)`：
//! 方法的返回类型直接写作具体 `Response`（本实例化中已绑定为如 PayResp），
//! IDE/ZLS 能对结果做跳转与字段补全；而 `execute` 的返回 `A.Resp` 经不透明
//! `comptime A: type` 成员访问，IDE 往往无法回推类型。二者行为完全一致。
const std = @import("std");
const client_mod = @import("client.zig");
const Error = @import("errors.zig").Error;

/// 生成描述某接口 method / Biz / Resp 三元组的类型，并挂载强类型调用方法。
pub fn Api(comptime method: []const u8, comptime BizContent: type, comptime Response: type) type {
    return struct {
        /// 接口方法名，如 "alipay.trade.pay"。
        pub const api_method = method;
        /// 请求 biz_content 类型。
        pub const Biz = BizContent;
        /// 响应类型。
        pub const Resp = Response;

        /// 发起 S2S（服务端到服务端）调用，返回强类型 `Response`（IDE 可跳转/补全）。
        /// 语义同 `client.execute`：须已注入传输；Client 非并发安全（每次 execute 会重置
        /// 内部 arena），并发场景请每线程各持一个 Client。返回值生命周期见 Options.out_arena。
        pub fn call(client: *client_mod.Client, biz: BizContent, opts: client_mod.Options) Error!Response {
            return client.execute(@This(), biz, opts);
        }

        /// 页面跳转类接口：返回自动提交的 HTML 表单串（分配于 out_gpa）。不发起 HTTP。
        pub fn page(client: *client_mod.Client, out_gpa: std.mem.Allocator, biz: BizContent, opts: client_mod.Options) Error![]u8 {
            return client.pageExecute(out_gpa, @This(), biz, opts);
        }

        /// App 端调用：返回 orderString（分配于 out_gpa）。不发起 HTTP。
        pub fn sdk(client: *client_mod.Client, out_gpa: std.mem.Allocator, biz: BizContent, opts: client_mod.Options) Error![]u8 {
            return client.sdkExecute(out_gpa, @This(), biz, opts);
        }
    };
}
