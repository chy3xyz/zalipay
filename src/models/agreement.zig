//! 协议类接口：周期扣款/代扣签约页面、协议查询。
const Api = @import("../api.zig").Api;

// ---------- alipay.user.agreement.page.sign（页面签约；pageExecute） ----------

pub const PageSignBiz = struct {
    /// 个人签约产品码。周期扣款固定 CYCLE_PAY_AUTH_P；商家扣款为 GENERAL_WITHHOLDING_P。
    personal_product_code: []const u8 = "CYCLE_PAY_AUTH_P",
    /// 签约场景码。格式 INDUSTRY|场景，由支付宝规定，与签约产品绑定。
    sign_scene: []const u8 = "INDUSTRY|DEFAULT",
    /// 商户签约号。商户端唯一，标识用户与商户的签约关系。
    external_agreement_no: []const u8,
    /// 用户在商户网站的登录账号。用于签约页展示核对。
    external_logon_id: ?[]const u8 = null,
    /// 签约接入方式。
    access_params: AccessParams,
    /// 周期管控规则参数。周期扣款产品（CYCLE_PAY_AUTH_P）必填。
    period_rule_params: ?PeriodRuleParams = null,
};

/// 签约接入方式参数。
pub const AccessParams = struct {
    /// 签约渠道。ALIPAYAPP=支付宝客户端 / QRCODE=扫码签约 / QRCODEORSMS=扫码或短信签约。
    channel: []const u8 = "ALIPAYAPP",
};

/// 周期扣款管控规则。签约后扣款的周期、金额、次数受此约束。
pub const PeriodRuleParams = struct {
    /// 周期类型。DAY=按天 / MONTH=按月。
    period_type: []const u8,
    /// 周期数。与 period_type 组合，如 MONTH + "1" = 每月扣一次。
    period: []const u8,
    /// 首次执行时间。格式 yyyy-MM-dd，须晚于签约当天。
    execute_time: []const u8,
    /// 单次扣款最大金额。单位元。
    single_amount: []const u8,
    /// 周期内允许扣款的总金额上限。单位元，不传不限制。
    total_amount: ?[]const u8 = null,
    /// 允许扣款的总次数上限。不传不限制。
    total_payments: ?[]const u8 = null,
};

/// page.sign 走 pageExecute 返回 HTML，无 JSON 响应；此 Resp 仅占位。
pub const PageSignResp = struct {};

/// 周期扣款/代扣页面签约。用 `.page` 取 HTML 表单。
pub const PageSign = Api("alipay.user.agreement.page.sign", PageSignBiz, PageSignResp);

// ---------- alipay.user.agreement.query（协议查询） ----------

pub const QueryBiz = struct {
    /// 个人签约产品码。与签约时一致。
    personal_product_code: []const u8 = "CYCLE_PAY_AUTH_P",
    /// 签约场景码。与签约时一致；用 external_agreement_no 查询时必传。
    sign_scene: ?[]const u8 = null,
    /// 商户签约号。与 agreement_no 二选一。
    external_agreement_no: ?[]const u8 = null,
    /// 支付宝协议号。与 external_agreement_no 二选一。
    agreement_no: ?[]const u8 = null,
};

pub const QueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝协议号。
    agreement_no: ?[]const u8 = null,
    /// 商户签约号。
    external_agreement_no: ?[]const u8 = null,
    /// 协议状态。NORMAL=正常 / STOP=暂停（已解约） / TEMP=未生效。
    status: ?[]const u8 = null,
    /// 签约时间。格式 yyyy-MM-dd HH:mm:ss。
    sign_time: ?[]const u8 = null,
    /// 协议生效时间。格式 yyyy-MM-dd HH:mm:ss。
    valid_time: ?[]const u8 = null,
};

/// 协议查询。external_agreement_no 与 agreement_no 二选一。用 `.call`。
pub const Query = Api("alipay.user.agreement.query", QueryBiz, QueryResp);
