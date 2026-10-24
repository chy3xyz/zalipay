//! 资金类接口：转账、转账查询、单笔转账页面、账户查询、记账本。
const Api = @import("../api.zig").Api;

// ---------- alipay.fund.trans.uni.transfer（单笔转账） ----------

/// 收款方信息。
pub const PayeeInfo = struct {
    /// 收款方标识。与 identity_type 配套：支付宝登录号或 2088 开头的 userId。
    identity: []const u8,
    /// 标识类型。ALIPAY_LOGON_ID=支付宝登录号 / ALIPAY_USER_ID=支付宝会员 ID。
    identity_type: []const u8,
    /// 收款方真实姓名。identity_type=ALIPAY_LOGON_ID 时必填，用于校验账号与姓名一致。
    name: ?[]const u8 = null,
};

pub const UniTransferBiz = struct {
    /// 商户转账唯一订单号。64 字符内，商户端唯一（幂等键，重复请求返回原单结果）。
    out_biz_no: []const u8,
    /// 转账金额。单位元，两位小数字符串，最小 0.1。
    trans_amount: []const u8,
    /// 业务产品码。单笔无密转账到支付宝账户固定 TRANS_ACCOUNT_TRANSFER。
    product_code: []const u8 = "TRANS_ACCOUNT_TRANSFER",
    /// 业务场景。单笔无密转账固定 DIRECT_TRANSFER。
    biz_scene: []const u8 = "DIRECT_TRANSFER",
    /// 转账业务的标题。用于在支付宝用户的账单里显示。
    order_title: ?[]const u8 = null,
    /// 收款方信息。
    payee_info: PayeeInfo,
    /// 业务备注。收款方可见。
    remark: ?[]const u8 = null,
};

pub const UniTransferResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 商户订单号（回显）。
    out_biz_no: ?[]const u8 = null,
    /// 支付宝转账订单号。
    order_id: ?[]const u8 = null,
    /// 支付宝支付资金流水号。
    pay_fund_order_id: ?[]const u8 = null,
    /// 转账单据状态。SUCCESS=成功 / FAIL=失败 / DEALING=处理中 / REFUND=退票。
    status: ?[]const u8 = null,
    /// 订单支付时间。格式 yyyy-MM-dd HH:mm:ss。
    trans_date: ?[]const u8 = null,
};

/// 单笔转账。payee_info 指定收款方。用 `.call`。
pub const UniTransfer = Api("alipay.fund.trans.uni.transfer", UniTransferBiz, UniTransferResp);

// ---------- alipay.fund.trans.common.query（转账业务单据查询） ----------

pub const CommonQueryBiz = struct {
    /// 业务产品码。与发起转账时一致，如 TRANS_ACCOUNT_TRANSFER。
    product_code: []const u8 = "TRANS_ACCOUNT_TRANSFER",
    /// 业务场景。与发起转账时一致，如 DIRECT_TRANSFER。
    biz_scene: []const u8 = "DIRECT_TRANSFER",
    /// 商户转账订单号。与 order_id / pay_fund_order_id 任一定位单据。
    out_biz_no: ?[]const u8 = null,
    /// 支付宝转账订单号。
    order_id: ?[]const u8 = null,
    /// 支付宝支付资金流水号。
    pay_fund_order_id: ?[]const u8 = null,
};

pub const CommonQueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝转账订单号。
    order_id: ?[]const u8 = null,
    /// 支付宝支付资金流水号。
    pay_fund_order_id: ?[]const u8 = null,
    /// 商户转账订单号。
    out_biz_no: ?[]const u8 = null,
    /// 转账金额。单位元。
    trans_amount: ?[]const u8 = null,
    /// 转账单据状态。SUCCESS=成功 / FAIL=失败 / DEALING=处理中 / REFUND=退票。
    status: ?[]const u8 = null,
    /// 支付时间。格式 yyyy-MM-dd HH:mm:ss。
    pay_date: ?[]const u8 = null,
};

/// 转账单据查询。out_biz_no / order_id / pay_fund_order_id 任一定位。用 `.call`。
pub const CommonQuery = Api("alipay.fund.trans.common.query", CommonQueryBiz, CommonQueryResp);

// ---------- alipay.fund.trans.page.pay（页面转账；pageExecute） ----------

pub const PagePayBiz = struct {
    /// 商户转账唯一订单号。商户端唯一（幂等键）。
    out_biz_no: []const u8,
    /// 转账金额。单位元，两位小数字符串。
    trans_amount: []const u8,
    /// 业务产品码。现金红包固定 STD_RED_PACKET。
    product_code: []const u8 = "STD_RED_PACKET",
    /// 业务场景。个人红包固定 PERSONAL_PAY。
    biz_scene: []const u8 = "PERSONAL_PAY",
    /// 转账业务的标题。用于在支付宝用户的账单里显示。
    order_title: []const u8,
};

/// page.pay 走 pageExecute 返回 HTML，无 JSON 响应；此 Resp 仅占位。
pub const PagePayResp = struct {};

/// 页面转账（如红包）。用 `.page` 取 HTML 表单。
pub const PagePay = Api("alipay.fund.trans.page.pay", PagePayBiz, PagePayResp);

// ---------- alipay.fund.account.query（账户余额查询） ----------

pub const AccountQueryBiz = struct {
    /// 蚂蚁统一会员 ID（2088 开头）。查询他人账户时传入，需获得授权。
    alipay_user_id: ?[]const u8 = null,
    /// 查询的账户类型。ACCTRANS_ACCOUNT=余额账户。
    account_type: []const u8 = "ACCTRANS_ACCOUNT",
};

pub const AccountQueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 账户可用余额。单位元。
    available_amount: ?[]const u8 = null,
    /// 账户冻结金额。单位元。
    freeze_amount: ?[]const u8 = null,
};

/// 账户余额查询。用 `.call`。
pub const AccountQuery = Api("alipay.fund.account.query", AccountQueryBiz, AccountQueryResp);

// ---------- alipay.fund.accountbook.create（记账本创建） ----------

pub const AccountbookCreateBiz = struct {
    /// 外部业务单号。商户端唯一（幂等键）。
    out_biz_no: []const u8,
    /// 记账本名称。
    accountbook_name: []const u8,
    /// 业务场景。由支付宝分配，未约定可不传。
    biz_scene: ?[]const u8 = null,
};

pub const AccountbookCreateResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝分配的记账本 ID。
    accountbook_id: ?[]const u8 = null,
};

/// 记账本创建。用 `.call`。
pub const AccountbookCreate = Api("alipay.fund.accountbook.create", AccountbookCreateBiz, AccountbookCreateResp);

// ---------- alipay.fund.accountbook.query（记账本查询） ----------

pub const AccountbookQueryBiz = struct {
    /// 记账本 ID。与 out_biz_no 二选一。
    accountbook_id: ?[]const u8 = null,
    /// 创建记账本时的外部业务单号。与 accountbook_id 二选一。
    out_biz_no: ?[]const u8 = null,
};

pub const AccountbookQueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 记账本 ID。
    accountbook_id: ?[]const u8 = null,
    /// 记账本名称。
    accountbook_name: ?[]const u8 = null,
    /// 记账本可用余额。单位元。
    available_amount: ?[]const u8 = null,
};

/// 记账本查询。accountbook_id 与 out_biz_no 二选一。用 `.call`。
pub const AccountbookQuery = Api("alipay.fund.accountbook.query", AccountbookQueryBiz, AccountbookQueryResp);
