//! 预置接口聚合。全部用 `Api(...)` 实例化，既是功能也是用法范例。
//! 未预置的接口，下游照同样方式用 `Api(method, Biz, Resp)` 自定义即可。
pub const trade = @import("trade.zig");
pub const fund = @import("fund.zig");
pub const agreement = @import("agreement.zig");
pub const bill = @import("bill.zig");
