//! 交易类接口：支付、查询、退款、关闭。
const Api = @import("../api.zig").Api;

// ---------- alipay.trade.pay（当面付/条码支付） ----------

pub const PayBiz = struct {
    /// 商户订单号。64 字符内，仅支持字母、数字、下划线，商户端唯一。
    out_trade_no: []const u8,
    /// 支付场景。bar_code=当面付条码支付；wave_code=声波支付。
    scene: []const u8,
    /// 支付授权码（买家出示的付款码，一次性有效）。
    auth_code: []const u8,
    /// 订单标题。不可使用 / = & 等特殊字符。
    subject: []const u8,
    /// 订单总金额。单位元，精确到小数点后两位，取值 [0.01, 100000000]。
    total_amount: []const u8,
    /// 商户门店编号。
    store_id: ?[]const u8 = null,
    /// 商户操作员编号。
    operator_id: ?[]const u8 = null,
    /// 订单最晚付款时长，如 "90m"。取值范围 1m~15d，m/h/d/c（当日），不接受小数。
    timeout_express: ?[]const u8 = null,
};

pub const PayResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝交易号。
    trade_no: ?[]const u8 = null,
    /// 商户订单号（回显）。
    out_trade_no: ?[]const u8 = null,
    /// 交易金额。单位元。
    total_amount: ?[]const u8 = null,
    /// 交易支付时间。格式 yyyy-MM-dd HH:mm:ss。
    gmt_payment: ?[]const u8 = null,
    /// 买家实付金额。单位元。
    buyer_pay_amount: ?[]const u8 = null,
};

/// 当面付/条码支付。用 `.call`。
pub const Pay = Api("alipay.trade.pay", PayBiz, PayResp);

// ---------- alipay.trade.query ----------

pub const QueryBiz = struct {
    /// 商户订单号。与 trade_no 二选一，同传时以 trade_no 为准。
    out_trade_no: ?[]const u8 = null,
    /// 支付宝交易号。与 out_trade_no 二选一。
    trade_no: ?[]const u8 = null,
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
    /// 支付宝交易号。
    trade_no: ?[]const u8 = null,
    /// 商户订单号。
    out_trade_no: ?[]const u8 = null,
    /// 交易状态。WAIT_BUYER_PAY=待付款 / TRADE_SUCCESS=支付成功 /
    /// TRADE_CLOSED=未付款交易超时关闭或支付完成后全额退款 / TRADE_FINISHED=交易结束不可退款。
    trade_status: ?[]const u8 = null,
    /// 订单总金额。单位元。
    total_amount: ?[]const u8 = null,
    /// 买家支付宝账号（脱敏登录号）。
    buyer_logon_id: ?[]const u8 = null,
};

/// 交易查询。out_trade_no 与 trade_no 二选一。用 `.call`。
pub const Query = Api("alipay.trade.query", QueryBiz, QueryResp);

// ---------- alipay.trade.refund ----------

pub const RefundBiz = struct {
    /// 需退款金额。单位元，不大于订单剩余可退金额。
    refund_amount: []const u8,
    /// 商户订单号。与 trade_no 二选一，同传时以 trade_no 为准。
    out_trade_no: ?[]const u8 = null,
    /// 支付宝交易号。与 out_trade_no 二选一。
    trade_no: ?[]const u8 = null,
    /// 退款请求号。同一笔交易多次（部分）退款时必填且商户端唯一；不传默认取 out_trade_no。
    out_request_no: ?[]const u8 = null,
    /// 退款原因说明。会在买家账单的退款详情中展示。
    refund_reason: ?[]const u8 = null,
};

pub const RefundResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝交易号。
    trade_no: ?[]const u8 = null,
    /// 商户订单号。
    out_trade_no: ?[]const u8 = null,
    /// 本次退款金额。单位元。
    refund_fee: ?[]const u8 = null,
    /// 退款支付时间。格式 yyyy-MM-dd HH:mm:ss。
    gmt_refund_pay: ?[]const u8 = null,
};

/// 交易退款。out_trade_no 与 trade_no 二选一；out_request_no 标识部分退款。用 `.call`。
pub const Refund = Api("alipay.trade.refund", RefundBiz, RefundResp);

// ---------- alipay.trade.fastpay.refund.query ----------

pub const RefundQueryBiz = struct {
    /// 退款请求号。即发起退款时的 out_request_no（未传则为 out_trade_no）。
    out_request_no: []const u8,
    /// 支付宝交易号。与 out_trade_no 二选一定位交易。
    trade_no: ?[]const u8 = null,
    /// 商户订单号。与 trade_no 二选一定位交易。
    out_trade_no: ?[]const u8 = null,
    /// 附加返回项。如 "refund_detail_item_list"（退款使用的资金渠道）、"gmt_refund_pay"。
    query_options: ?[]const []const u8 = null,
};

/// 退款使用的资金渠道明细（refund_detail_item_list 元素）。
pub const TradeFundBill = struct {
    /// 交易使用的资金渠道，如 ALIPAYACCOUNT、BANKCARD。
    fund_channel: []const u8,
    /// 该渠道退款金额。单位元。
    amount: []const u8,
    /// 渠道实际退款金额。单位元。
    real_amount: ?[]const u8 = null,
    /// 资金类型。仅 fund_channel 为 BANKCARD 时返回：DEBIT_CARD/CREDIT_CARD/MIXED_CARD。
    fund_type: ?[]const u8 = null,
};

pub const RefundQueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝交易号。
    trade_no: ?[]const u8 = null,
    /// 商户订单号。
    out_trade_no: ?[]const u8 = null,
    /// 退款请求号（回显）。
    out_request_no: ?[]const u8 = null,
    /// 订单总金额。单位元。
    total_amount: ?[]const u8 = null,
    /// 本次退款请求的退款金额。单位元。
    refund_amount: ?[]const u8 = null,
    /// 退款状态。REFUND_SUCCESS=退款成功；未返回该字段表示退款未收到请求或退款失败。
    refund_status: ?[]const u8 = null,
    /// 退款时间。需在 query_options 传 "gmt_refund_pay" 才返回。
    gmt_refund_pay: ?[]const u8 = null,
    /// 本次退款使用的资金渠道。需在 query_options 传 "refund_detail_item_list" 才返回。
    refund_detail_item_list: ?[]const TradeFundBill = null,
    /// 本次商户实际退回金额。单位元。需在 query_options 传 "refund_detail_item_list" 才返回。
    send_back_fee: ?[]const u8 = null,
};

/// 退款查询。out_request_no 必填；trade_no 与 out_trade_no 二选一定位交易。用 `.call`。
/// 建议退款发起 10 秒后再查询；refund_status 为 REFUND_SUCCESS 才代表退款成功。
pub const RefundQuery = Api("alipay.trade.fastpay.refund.query", RefundQueryBiz, RefundQueryResp);

// ---------- alipay.trade.close ----------

pub const CloseBiz = struct {
    /// 商户订单号。64 字符内。与 trade_no 不能同时为空，同传时以 trade_no 为准。
    out_trade_no: ?[]const u8 = null,
    /// 支付宝交易号。16~64 字符。与 out_trade_no 不能同时为空。
    trade_no: ?[]const u8 = null,
    /// 商家操作员编号。28 字符内，由商家自定义。
    operator_id: ?[]const u8 = null,
};

pub const CloseResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。如 ACQ.TRADE_NOT_EXIST=交易不存在；
    /// ACQ.TRADE_STATUS_ERROR=交易非待支付状态，不支持关单。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 支付宝交易号（成功时回传）。
    trade_no: ?[]const u8 = null,
    /// 创建交易传入的商户订单号（成功时回传）。
    out_trade_no: ?[]const u8 = null,
};

/// 交易关闭。用于交易创建后用户在一定时间内未支付时直接关闭未付款交易。用 `.call`。
/// out_trade_no 与 trade_no 二选一；仅等待买家付款状态可关闭，成功后触发 TRADE_CLOSED 通知。
pub const Close = Api("alipay.trade.close", CloseBiz, CloseResp);

// ---------- alipay.trade.page.pay（电脑网站支付；用 pageExecute 返回 HTML） ----------

/// 订单包含的商品明细（goods_detail 数组元素）。
pub const GoodsDetail = struct {
    /// 商品的编号。
    goods_id: []const u8,
    /// 商品名称。
    goods_name: []const u8,
    /// 商品数量。
    quantity: u32,
    /// 商品单价。单位元。
    price: []const u8,
    /// 支付宝定义的统一商品编号。
    alipay_goods_id: ?[]const u8 = null,
    /// 商品类目。
    goods_category: ?[]const u8 = null,
    /// 商品类目树。根节点到叶子节点的类目 id，用 | 分割。
    categories_tree: ?[]const u8 = null,
    /// 商品描述信息。
    body: ?[]const u8 = null,
    /// 商品的展示地址。
    show_url: ?[]const u8 = null,
};

/// 二级商户信息。直付通/机构间连模式下必传，其余场景不传。
pub const SubMerchant = struct {
    /// 间连受理商户的支付宝商户编号（间连商户入驻后获得）。
    merchant_id: []const u8,
    /// 二级商户编号类型。目前仅支持 "alipay"（支付宝分配的间联商户编号），可不传。
    merchant_type: ?[]const u8 = null,
};

/// 业务扩展参数（系统商返佣、花呗分期等）。
pub const ExtendParams = struct {
    /// 系统商编号。作为系统商返佣数据提取依据，填写系统商签约协议的 PID。
    sys_service_provider_id: ?[]const u8 = null,
    /// 花呗分期数。如 "3"。
    hb_fq_num: ?[]const u8 = null,
    /// 花呗分期卖家承担的手续费比例百分值。"100" 代表 100%。
    hb_fq_seller_percent: ?[]const u8 = null,
    /// 行业数据回流信息。JSON 字符串，详见地铁支付接口参数补充说明。
    industry_reflux_info: ?[]const u8 = null,
    /// 卡类型。枚举值：S0JP0000。
    card_type: ?[]const u8 = null,
    /// 是否资金冻结（用于后续分账）。"true"=冻结；"false" 或不传=不冻结。
    royalty_freeze: ?[]const u8 = null,
};

/// 外部指定买家。need_check_info=T 时支付宝校验买家身份与传入信息是否匹配。
pub const ExtUserInfo = struct {
    /// 买家证件号。need_check_info=T 或 fix_buyer=T 时才生效。
    cert_no: ?[]const u8 = null,
    /// 买家证件类型。IDENTITY_CARD=身份证 / PASSPORT=护照 / OFFICER_CARD=军官证 /
    /// SOLDIER_CARD=士兵证 / HOKOU=户口本。need_check_info=T 或 fix_buyer=T 时才生效。
    cert_type: ?[]const u8 = null,
    /// 允许的最小买家年龄（整数 >= 0）。need_check_info=T 时才生效。
    min_age: ?[]const u8 = null,
    /// 指定买家手机号。注：该参数暂不校验。
    mobile: ?[]const u8 = null,
    /// 指定买家姓名。need_check_info=T 或 fix_buyer=T 时才生效。
    name: ?[]const u8 = null,
    /// 是否强制校验买家身份。"T"=强制校验（须同传 cert_type/cert_no/name）；"F" 或不传=不校验。
    fix_buyer: ?[]const u8 = null,
    /// 是否强制校验买家信息。"T"=强制校验；"F" 或不传=不校验。
    need_check_info: ?[]const u8 = null,
    /// 买家加密身份信息。姓名+证件号拼接后 sha256(utf-8) 的 hash；
    /// 与明文身份信息（name/cert_type/cert_no）同传时以明文校验为准。
    identity_hash: ?[]const u8 = null,
};

/// 开票关键信息。
pub const InvoiceKeyInfo = struct {
    /// 该交易是否支持开票。
    is_support_invoice: bool,
    /// 开票商户名称。格式：商户品牌简称|商户门店简称，如 "ABC|003"。
    invoice_merchant_name: []const u8,
    /// 税号。
    tax_num: []const u8,
};

/// 开票信息。details 为 JSON 数组格式字符串。
pub const InvoiceInfo = struct {
    /// 开票关键信息。
    key_info: InvoiceKeyInfo,
    /// 开票内容。JSON 数组字符串，如
    /// `[{"code":"100294400","name":"服饰","num":"2","sumPrice":"200.00","taxRate":"6%"}]`。
    details: []const u8,
};

pub const PagePayBiz = struct {
    /// 商户订单号。64 字符内，仅支持字母、数字、下划线，商户端唯一。
    out_trade_no: []const u8,
    /// 订单总金额。单位元，精确到小数点后两位，取值 [0.01, 100000000]。
    total_amount: []const u8,
    /// 订单标题。不可使用 / = & 等特殊字符。
    subject: []const u8,
    /// 销售产品码。电脑支付场景固定 FAST_INSTANT_TRADE_PAY。
    product_code: []const u8 = "FAST_INSTANT_TRADE_PAY",
    /// PC 扫码支付方式。0=简约前置 / 1=前置 / 3=迷你前置 / 4=可定义宽度嵌入式二维码（iframe 前置模式）；
    /// 2=订单码跳转模式（扫码页由支付宝生成）。
    qr_pay_mode: ?[]const u8 = null,
    /// 商户自定义二维码宽度。仅 qr_pay_mode=4 时有效。
    qrcode_width: ?u32 = null,
    /// 订单包含的商品列表信息。
    goods_detail: ?[]const GoodsDetail = null,
    /// 订单绝对超时时间。格式 yyyy-MM-dd HH:mm:ss，范围 1m~15d；
    /// 与 timeout_express 二选一，同传时优先 time_expire。
    time_expire: ?[]const u8 = null,
    /// 二级商户信息。直付通/机构间连模式下必传。
    sub_merchant: ?SubMerchant = null,
    /// 业务扩展参数。
    extend_params: ?ExtendParams = null,
    /// 商户传入业务信息。JSON 字符串，具体值与支付宝约定（安全、营销等参数直传场景）。
    business_params: ?[]const u8 = null,
    /// 优惠参数。JSON 字符串，仅与支付宝协商后可用。
    promo_params: ?[]const u8 = null,
    /// 请求后页面的集成方式。ALIAPP=支付宝钱包内 / PCWEB=PC 端访问（默认）。
    integration_type: ?[]const u8 = null,
    /// 请求来源地址。ALIAPP 集成方式下用户中途取消支付会返回该地址。
    request_from_url: ?[]const u8 = null,
    /// 商户门店编号。
    store_id: ?[]const u8 = null,
    /// 商户原始订单号。最大长度 32 位。
    merchant_order_no: ?[]const u8 = null,
    /// 外部指定买家。
    ext_user_info: ?ExtUserInfo = null,
    /// 开票信息。
    invoice_info: ?InvoiceInfo = null,
};

/// page.pay 走 pageExecute 返回 HTML，无 JSON 响应；此 Resp 仅占位。
pub const PagePayResp = struct {};

/// 电脑网站支付。用 `.page` 取自动提交的 HTML 表单（非 .call）。
pub const PagePay = Api("alipay.trade.page.pay", PagePayBiz, PagePayResp);

// ---------- alipay.trade.wap.pay（手机网站支付；用 pageExecute 返回 HTML） ----------

pub const WapPayBiz = struct {
    /// 商户订单号。64 字符内，商户端唯一。
    out_trade_no: []const u8,
    /// 订单总金额。单位元，精确到小数点后两位，取值 [0.01, 100000000]。
    total_amount: []const u8,
    /// 订单标题。不可使用 / = & 等特殊字符。
    subject: []const u8,
    /// 销售产品码。手机网站支付场景固定 QUICK_WAP_WAY。
    product_code: []const u8 = "QUICK_WAP_WAY",
    /// 用户授权令牌。针对用户授权接口获取用户相关数据时，用于标识用户授权关系。
    auth_token: ?[]const u8 = null,
    /// 用户付款中途退出返回商户网站的地址。
    quit_url: ?[]const u8 = null,
    /// 订单包含的商品列表信息。
    goods_detail: ?[]const GoodsDetail = null,
    /// 订单绝对超时时间。格式 yyyy-MM-dd HH:mm:ss，超时范围 1m~15d。
    time_expire: ?[]const u8 = null,
    /// 业务扩展参数。
    extend_params: ?ExtendParams = null,
    /// 商户传入业务信息。JSON 字符串，具体值与支付宝约定（安全、营销等参数直传场景）。
    business_params: ?[]const u8 = null,
    /// 公用回传参数。传入后在支付结果异步通知中原样返回；须先 UrlEncode。
    passback_params: ?[]const u8 = null,
    /// 商户原始订单号。最大长度 32 位。
    merchant_order_no: ?[]const u8 = null,
    /// 外部指定买家。
    ext_user_info: ?ExtUserInfo = null,
};

/// wap.pay 走 pageExecute 返回 HTML，无 JSON 响应；此 Resp 仅占位。
pub const WapPayResp = struct {};

/// 手机网站支付。用 `.page` 取自动提交的 HTML 表单（非 .call）。
pub const WapPay = Api("alipay.trade.wap.pay", WapPayBiz, WapPayResp);

// ---------- alipay.trade.app.pay（App 支付；用 sdkExecute 返回 orderStr） ----------

pub const AppPayBiz = struct {
    /// 商户订单号。64 字符内，仅支持字母、数字、下划线，商户端唯一。
    out_trade_no: []const u8,
    /// 订单总金额。单位元，精确到小数点后两位，取值 [0.01, 100000000]。
    total_amount: []const u8,
    /// 订单标题。不可使用 / = & 等特殊字符。
    subject: []const u8,
    /// 销售产品码。App 支付场景固定 QUICK_MSECURITY_PAY。
    product_code: []const u8 = "QUICK_MSECURITY_PAY",
    /// 订单包含的商品列表信息。
    goods_detail: ?[]const GoodsDetail = null,
    /// 订单绝对超时时间。格式 yyyy-MM-dd HH:mm:ss。
    time_expire: ?[]const u8 = null,
    /// 业务扩展参数。
    extend_params: ?ExtendParams = null,
    /// 公用回传参数。传入后在支付结果异步通知中原样返回；须先 UrlEncode。
    passback_params: ?[]const u8 = null,
    /// 商户原始订单号。最大长度 32 位。
    merchant_order_no: ?[]const u8 = null,
    /// 外部指定买家。
    ext_user_info: ?ExtUserInfo = null,
    /// 返回参数选项。定制同步额外返回的字段，如 "hyb_amount"、"enterprise_pay_info"。
    query_options: ?[]const []const u8 = null,
};

/// app.pay 走 sdkExecute 返回 orderStr，无 JSON 响应；此 Resp 仅占位。
pub const AppPayResp = struct {};

/// App 支付。用 `.sdk` 取签名后的 orderStr（非 .call），交由客户端 App 唤起支付宝 SDK。
pub const AppPay = Api("alipay.trade.app.pay", AppPayBiz, AppPayResp);

// ---------- alipay.trade.precreate（当面付/订单码支付：预下单生成二维码） ----------

pub const PrecreateBiz = struct {
    /// 商户订单号。64 字符内，仅支持字母、数字、下划线，商户端唯一。
    out_trade_no: []const u8,
    /// 订单总金额。单位元，精确到小数点后两位，取值 [0.01, 100000000]。
    total_amount: []const u8,
    /// 订单标题。不可使用 / = & 等特殊字符。
    subject: []const u8,
    /// 产品码。订单码支付固定 QR_CODE_OFFLINE。
    product_code: []const u8 = "QR_CODE_OFFLINE",
    /// 卖家支付宝用户 ID。为空时默认为商户签约账号对应的支付宝用户 ID。
    seller_id: ?[]const u8 = null,
    /// 订单附加信息。在异步通知、对账单中原样返回。
    body: ?[]const u8 = null,
    /// 订单包含的商品列表信息。
    goods_detail: ?[]const GoodsDetail = null,
    /// 业务扩展参数。
    extend_params: ?ExtendParams = null,
    /// 商户传入业务信息。JSON 字符串，具体值与支付宝约定（安全、营销等参数直传场景）。
    business_params: ?[]const u8 = null,
    /// 商户端创建订单的用户外网 IP，支持 ipv4/ipv6。
    mc_create_trade_ip: ?[]const u8 = null,
    /// 可打折金额。单位元。若与不可打折金额同传，须满足 总金额 = 可打折 + 不可打折。
    discountable_amount: ?[]const u8 = null,
    /// 商户门店编号。
    store_id: ?[]const u8 = null,
    /// 商户操作员编号。
    operator_id: ?[]const u8 = null,
    /// 商户机具终端编号。
    terminal_id: ?[]const u8 = null,
    /// 商户原始订单号。最大长度 32 位。
    merchant_order_no: ?[]const u8 = null,
};

pub const PrecreateResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。如 ACQ.APPLY_PC_MERCHANT_CODE_ERROR=同一订单号重复申请二维码。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 商户订单号（回显）。
    out_trade_no: ?[]const u8 = null,
    /// 二维码码串，有效期 2 小时。用二维码生成工具据此生成二维码供买家扫码。
    qr_code: ?[]const u8 = null,
};

/// 当面付/订单码支付预下单。生成二维码码串（有效期 2 小时），买家扫码付款。用 `.call`。
pub const Precreate = Api("alipay.trade.precreate", PrecreateBiz, PrecreateResp);
