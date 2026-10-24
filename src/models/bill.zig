//! 对账单类接口：查询对账单。
const Api = @import("../api.zig").Api;

// ---------- alipay.data.dataservice.bill.downloadurl.query（查询对账单下载地址） ----------

pub const DownloadUrlQueryBiz = struct {
    /// 账单类型。trade=商户基于支付宝交易收单的业务账单 /
    /// signcustomer=基于商户支付宝余额收支等资金变动的账务账单 / merchant_act=营销活动账单等。
    bill_type: []const u8,
    /// 账单时间。日账单 yyyy-MM-dd（最早可下载 2016-01-01，当日账单次日生成）；月账单 yyyy-MM。
    bill_date: []const u8,
    /// 二级商户 smid。直付通模式下查询二级商户账单时传入。
    smid: ?[]const u8 = null,
    /// 是否返回 https 下载链接。"true"=https，否则为 http。
    secure: ?[]const u8 = null,
};

pub const DownloadUrlQueryResp = struct {
    /// 网关业务码。"10000" 为成功。
    code: []const u8,
    /// 网关业务码描述。
    msg: []const u8,
    /// 业务错误码（失败时返回）。
    sub_code: ?[]const u8 = null,
    /// 业务错误描述（失败时返回）。
    sub_msg: ?[]const u8 = null,
    /// 账单下载地址链接。获取后 30 秒内未下载即失效。
    bill_download_url: ?[]const u8 = null,
    /// 账单文件编码（部分账单类型返回）。
    bill_file_code: ?[]const u8 = null,
};

/// 查询对账单下载地址。下载链接获取后 30 秒未下载即失效。用 `.call`。
pub const DownloadUrlQuery = Api("alipay.data.dataservice.bill.downloadurl.query", DownloadUrlQueryBiz, DownloadUrlQueryResp);
