//! Client：持有 Signer + Config + io + 可选 Transport + 可注入 Clock，编排一次 S2S 调用的完整数据流：
//! 合并系统参数 → biz_content 序列化 → 待签串 → 签名 → form body → Transport.send → envelope 提取
//! → 验签 → 解码 → 业务码检查。
//!
//! 网络 I/O 不依赖任何协程运行时：`execute` 通过注入的 `Transport` 发起请求。
//! 传输实现自身的并发能力（如 `StdTransport` 基于 std.http.Client）不等同于 Client 可并发：
//! `Client` 仍非并发安全（见下）。未注入传输时 Client 仍可完成全部离线工作
//! （pageExecute/sdkExecute/verifyNotify）。
const std = @import("std");
const Allocator = std.mem.Allocator;

const clock_mod = @import("clock.zig");
const config = @import("config.zig");
const errors = @import("errors.zig");
const json = @import("json.zig");
const signer_mod = @import("crypto/signer.zig");
const cert = @import("crypto/cert.zig");
const transport_mod = @import("transport.zig");
const canonical = @import("wire/canonical.zig");
const form = @import("wire/form.zig");
const envelope = @import("wire/envelope.zig");
const timestamp = @import("wire/timestamp.zig");

const Pair = canonical.Pair;
const Error = errors.Error;
pub const ErrorDetail = errors.ErrorDetail;

/// 响应体读取上限（与 Transport 的硬上限一致）。
const max_response = transport_mod.max_response_limit;

pub const NotifyVersion = enum { v1, v2 };

/// Client 初始化选项。
pub const InitOptions = struct {
    /// 网络传输实现。为 null 时 Client 处于离线模式：签名串/表单/通知验签可用，
    /// `execute` 返回 error.TransportNotConfigured。
    transport: ?transport_mod.Transport = null,
    /// 签名时间戳来源。默认 `.io` 读取系统时钟；测试可用 `.fixed` 得到确定性输出。
    clock: clock_mod.Clock = .io,
};

/// 单次调用的可选参数。为 null 的字段回退到 Config 里的同名默认值。
pub const Options = struct {
    /// 异步通知回调地址，覆盖 Config.notify_url。
    notify_url: ?[]const u8 = null,
    /// 同步跳转返回地址，覆盖 Config.return_url。
    return_url: ?[]const u8 = null,
    /// 第三方代调用授权令牌，覆盖 Config.app_auth_token。
    app_auth_token: ?[]const u8 = null,
    /// 是否验证同步响应签名。默认开启；仅在沙箱/调试且未配置支付宝公钥时可关，生产勿关。
    verify_response: bool = true,
    /// 返回值的分配去处。传入自有 arena 可延长返回值生命周期；
    /// 不传则借用 Client 内部 arena，返回值在下次 execute 的结果分配前失效
    /// （内部 arena 在响应 envelope 解析后重置）。
    out_arena: ?*std.heap.ArenaAllocator = null,
};

pub const NotifyOptions = struct {
    /// v1=标准交易/资金/协议通知（默认，rsaCheckV1）；v2=仅生活号（rsaCheckV2）。
    version: NotifyVersion = .v1,
};

/// error_response / 成功节点里的公共错误头，用于填充 ErrorDetail。
const CodeHead = struct {
    code: []const u8 = "",
    msg: []const u8 = "",
    sub_code: ?[]const u8 = null,
    sub_msg: ?[]const u8 = null,
};

/// SDK 主入口。长生命周期、可跨请求复用（连接池/TLS 复用最大化）。
///
/// 所有权契约：`InitOptions.transport` 的底层实现由调用方创建并持有，须活过 Client；
/// Client 只借用不接管。私钥在 init 时解析一次并缓存，绝不每请求重复解析 PEM。
///
/// 并发约束：`Client` **非并发安全**。每次 `execute` 在响应 envelope 解析后重置内部 arena
/// （使上次返回值失效）并清空/覆写 `last_error`，多线程并发调用同一 Client 会产生悬垂引用
/// 与竞态。线程安全的传输实现（如 `StdTransport`）只是并发的前提，不改变这一约束；
/// 并发场景请每线程各持一个 Client，或外部串行化。非网络方法
/// （pageExecute/sdkExecute/verifyNotify）只读取 Client 且不触碰内部 arena / `last_error`，
/// 没有额外的 Client 级并发约束（分配器自身的线程安全性仍由调用方保证）。
///
/// 返回 GatewayError/BusinessError 时，业务码/文案见 `last_error`。
pub const Client = struct {
    gpa: Allocator,
    io: std.Io,
    cfg: config.Config,
    signer: signer_mod.Signer,
    /// 网络传输；null 表示未配置（离线模式）。
    transport: ?transport_mod.Transport,
    /// 签名时间戳来源。
    clock: clock_mod.Clock,

    // 解析并持有的 endpoint 组件（owned）。
    scheme: transport_mod.Scheme,
    host: []u8,
    port: u16,
    target: []u8, // 形如 "/gateway.do?charset=utf-8"

    // 证书 SN（owned；预置字符串或由证书 PEM 计算所得）。
    app_cert_sn: ?[]const u8,
    root_cert_sn: ?[]const u8,
    /// 配置的支付宝公钥证书的 SN（证书模式）。用于比对响应顶层 alipay_cert_sn，
    /// 不一致说明支付宝已轮换证书（CertMismatch）。
    alipay_pub_cert_sn: ?[32]u8,

    internal_arena: std.heap.ArenaAllocator,
    /// 最近一次网关/业务错误详情。GatewayError 返回后读取；
    /// 生命周期随该次调用的结果 arena（使用内部 arena 时，下次 execute 在响应 envelope
    /// 解析后会先清空本字段并重置 arena，之后可能被新错误覆写）。
    last_error: ?ErrorDetail = null,

    /// 初始化 Client：解析 endpoint、解析私钥、（若配置）计算证书 SN。
    /// 不要求网络传输：`options.transport` 为 null 时得到离线可用的 Client。
    /// 失败返回 InvalidConfig（私钥/证书/endpoint 非法）或 OutOfMemory。
    pub fn init(gpa: Allocator, io: std.Io, cfg: config.Config, options: InitOptions) Error!Client {
        var signer = try signer_mod.Signer.init(gpa, cfg);
        errdefer signer.deinit();

        const ep = parseEndpoint(cfg.endpoint) catch return error.InvalidConfig;
        const host = try gpa.dupe(u8, ep.host);
        errdefer gpa.free(host);
        // target = path + "?charset=<charset>"
        const target = gpa.print("{s}?charset={s}", .{ ep.path, cfg.charset }) catch return error.OutOfMemory;
        errdefer gpa.free(target);

        // 证书 SN：优先显式字符串，否则由证书 PEM 计算。
        var app_sn: ?[]const u8 = null;
        errdefer if (app_sn) |s| gpa.free(s);
        if (cfg.app_cert_sn) |s| {
            app_sn = try gpa.dupe(u8, s);
        } else if (cfg.app_public_cert) |pem_str| {
            const der = @import("crypto/pem.zig").decode(gpa, pem_str) catch return error.InvalidConfig;
            defer gpa.free(der);
            const sn = cert.computeSn(gpa, der) catch return error.InvalidConfig;
            app_sn = try gpa.dupe(u8, &sn);
        }

        var root_sn: ?[]const u8 = null;
        errdefer if (root_sn) |s| gpa.free(s);
        if (cfg.alipay_root_cert_sn) |s| {
            root_sn = try gpa.dupe(u8, s);
        } else if (cfg.alipay_root_cert) |pem_str| {
            root_sn = cert.computeRootSn(gpa, pem_str) catch return error.InvalidConfig;
        }

        // 证书模式：记录所配支付宝公钥证书的 SN，供响应侧 alipay_cert_sn 比对（轮换检测）。
        // signer 已解码过该证书 PEM 并持有 DER（pub_der），直接复用，避免双解码路径分叉。
        var alipay_pub_sn: ?[32]u8 = null;
        if (cfg.alipay_public_cert != null) {
            alipay_pub_sn = cert.computeSn(gpa, signer.pub_der.?) catch return error.InvalidConfig;
        }

        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .signer = signer,
            .transport = options.transport,
            .clock = options.clock,
            .scheme = ep.scheme,
            .host = host,
            .port = ep.port,
            .target = target,
            .app_cert_sn = app_sn,
            .root_cert_sn = root_sn,
            .alipay_pub_cert_sn = alipay_pub_sn,
            .internal_arena = .init(gpa),
        };
    }

    /// 释放 Client 持有的资源（私钥、endpoint、SN、内部 arena）。不触及注入的 `transport`。
    pub fn deinit(self: *Client) void {
        self.signer.deinit();
        self.gpa.free(self.host);
        self.gpa.free(self.target);
        if (self.app_cert_sn) |s| self.gpa.free(s);
        if (self.root_cert_sn) |s| self.gpa.free(s);
        self.internal_arena.deinit();
        self.* = undefined;
    }

    /// 发起 S2S（server-to-server）调用，返回强类型响应 `A.Resp`。
    /// `A` 由 `Api(method, Biz, Resp)` 生成（预置接口见 `models`）。
    ///
    /// DX 提示：优先用等价的 `A.call(&client, biz, opts)`——其返回类型是具体的
    /// `Resp`，IDE 可对结果跳转/字段补全；本函数返回 `A.Resp` 经 comptime 类型
    /// 参数，IDE 通常无法回推类型。
    ///
    /// 数据流：合并系统参数 → biz 序列化 → 待签串 → 签名 → form body → Transport.send → 提取响应节点 → 验签 → 解码 → 业务码检查。
    /// 未注入传输时在入口直接返回 TransportNotConfigured（不做签名、不触碰网络）。
    /// 返回值默认借用内部 arena（下次 execute 在响应 envelope 解析后重置 arena 即失效），
    /// 传 `opts.out_arena` 可延长。
    ///
    /// 错误：GatewayError=业务码非 "10000"（详情见 `last_error`）；VerifyFailed=响应验签失败；
    /// CertMismatch=证书模式下支付宝公钥证书已轮换；Transport/Timeout/Tls=网络层；
    /// TransportNotConfigured=未注入 Transport；EnvelopeNotFound/JsonParse=响应格式异常。
    pub fn execute(self: *Client, comptime A: type, biz: A.Biz, opts: Options) Error!A.Resp {
        const tx = self.transport orelse return error.TransportNotConfigured;

        var req_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer req_arena.deinit();
        const ra = req_arena.allocator();

        const biz_json = try json.serializeBiz(ra, biz);
        const body = try self.buildFormBody(ra, A.api_method, biz_json, opts);
        const raw = try self.post(tx, ra, body);

        var name_buf: [160]u8 = undefined;
        const env = envelope.parse(raw, A.api_method, &name_buf) catch |e| return mapEnvelope(e);

        const result_alloc = self.resultAllocator(opts);
        if (env.is_error) return self.gatewayError(result_alloc, env.node);
        if (opts.verify_response) try self.verifyNode(env);

        const resp = json.parseLeaky(A.Resp, result_alloc, env.node) catch return error.JsonParse;
        try self.checkBusinessCode(A.Resp, resp);
        return resp;
    }

    /// 页面跳转类接口（如 alipay.trade.page.pay）：返回自动提交到网关的 HTML 表单串。
    /// 由调用方将该 HTML 下发浏览器完成跳转。不发起 HTTP；返回值分配于 `out_gpa`，调用方负责释放。
    /// 等价方法：`A.page(&client, out_gpa, biz, opts)`。
    pub fn pageExecute(self: *Client, out_gpa: Allocator, comptime A: type, biz: A.Biz, opts: Options) Error![]u8 {
        var req_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer req_arena.deinit();
        const ra = req_arena.allocator();

        const biz_json = try json.serializeBiz(ra, biz);
        const pairs = try self.assembleSigned(ra, A.api_method, biz_json, opts);
        return self.renderHtmlForm(out_gpa, pairs);
    }

    /// App 端调用：返回 orderString（URL 编码的已签名参数串），交由客户端 App SDK 唤起支付。
    /// 不发起 HTTP；返回值分配于 `out_gpa`，调用方负责释放。
    /// 等价方法：`A.sdk(&client, out_gpa, biz, opts)`。
    pub fn sdkExecute(self: *Client, out_gpa: Allocator, comptime A: type, biz: A.Biz, opts: Options) Error![]u8 {
        var req_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer req_arena.deinit();
        const ra = req_arena.allocator();

        const biz_json = try json.serializeBiz(ra, biz);
        const pairs = try self.assembleSigned(ra, A.api_method, biz_json, opts);
        return form.build(out_gpa, pairs);
    }

    /// 异步通知验签。`pairs` 为**已 URL-decode** 的表单键值对（`.{key, value}`）。
    /// 验签通过返回 void；失败返回 VerifyFailed。不发起 HTTP。
    ///
    /// 调用方契约：SDK 只负责验签，HTTP 层解析与回执由调用方处理——
    /// 验签 + 业务校验通过后须向支付宝回纯文本 `success`，否则会被重试约 24h。
    pub fn verifyNotify(self: *Client, pairs: []const [2][]const u8, opts: NotifyOptions) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        var kept: std.ArrayList(Pair) = .empty;
        var sign: ?[]const u8 = null;
        for (pairs) |kv| {
            if (std.mem.eql(u8, kv[0], "sign")) {
                sign = kv[1];
                continue;
            }
            // v1 额外去除 sign_type；v2 保留。
            if (opts.version == .v1 and std.mem.eql(u8, kv[0], "sign_type")) continue;
            try kept.append(a, .{ .key = kv[0], .value = kv[1] });
        }
        // 通知验签串与官方 rsaCheckV1/V2 一致：保留空值参数（区别于请求签名的去空语义）。
        const content = try canonical.buildKeepEmpty(a, kept.items);
        const sig = sign orelse return error.VerifyFailed;
        return self.signer.verify(content, sig);
    }

    // ---- 内部 ----

    fn resultAllocator(self: *Client, opts: Options) Allocator {
        if (opts.out_arena) |ar| return ar.allocator();
        // 复用内部 arena 前先丢弃 last_error：其中的切片可能指向即将被回收的旧内存，
        // 保留会变成悬垂引用。out_arena 路径不重置 arena，生命周期由调用方 arena 决定。
        self.last_error = null;
        _ = self.internal_arena.reset(.retain_capacity);
        return self.internal_arena.allocator();
    }

    /// 组装系统参数 + 签名，返回含 sign 的完整 pair 列表（分配于 arena）。
    fn assembleSigned(self: *Client, arena: Allocator, method: []const u8, biz_json: []const u8, opts: Options) Error![]Pair {
        var ts_buf: [timestamp.len]u8 = undefined;
        const ts = try arena.dupe(u8, timestamp.bufWrite(&ts_buf, self.clock.now(self.io)));

        var pairs: std.ArrayList(Pair) = .empty;
        try pairs.append(arena, .{ .key = "app_id", .value = self.cfg.app_id });
        try pairs.append(arena, .{ .key = "method", .value = method });
        try pairs.append(arena, .{ .key = "format", .value = self.cfg.format });
        try pairs.append(arena, .{ .key = "charset", .value = self.cfg.charset });
        try pairs.append(arena, .{ .key = "sign_type", .value = self.cfg.sign_type.wireName() });
        try pairs.append(arena, .{ .key = "timestamp", .value = ts });
        try pairs.append(arena, .{ .key = "version", .value = self.cfg.version });
        try pairs.append(arena, .{ .key = "biz_content", .value = biz_json });

        const notify = opts.notify_url orelse self.cfg.notify_url;
        if (notify) |v| try pairs.append(arena, .{ .key = "notify_url", .value = v });
        const ret = opts.return_url orelse self.cfg.return_url;
        if (ret) |v| try pairs.append(arena, .{ .key = "return_url", .value = v });
        const token = opts.app_auth_token orelse self.cfg.app_auth_token;
        if (token) |v| try pairs.append(arena, .{ .key = "app_auth_token", .value = v });
        if (self.app_cert_sn) |v| try pairs.append(arena, .{ .key = "app_cert_sn", .value = v });
        if (self.root_cert_sn) |v| try pairs.append(arena, .{ .key = "alipay_root_cert_sn", .value = v });

        const content = try canonical.build(arena, pairs.items);
        const sig = try self.signer.sign(arena, content);
        try pairs.append(arena, .{ .key = "sign", .value = sig });
        return pairs.toOwnedSlice(arena);
    }

    fn buildFormBody(self: *Client, arena: Allocator, method: []const u8, biz_json: []const u8, opts: Options) Error![]u8 {
        const pairs = try self.assembleSigned(arena, method, biz_json, opts);
        return form.build(arena, pairs);
    }

    fn post(self: *Client, tx: transport_mod.Transport, arena: Allocator, body: []const u8) Error![]u8 {
        const response = try tx.send(arena, .{
            .scheme = self.scheme,
            .host = self.host,
            .port = self.port,
            .target = self.target,
            .content_type = "application/x-www-form-urlencoded;charset=utf-8",
            .body = body,
            .max_response = max_response,
        });
        if (response.status < 200 or response.status >= 300) return error.Transport;
        return response.body;
    }

    fn verifyNode(self: *Client, env: envelope.Envelope) Error!void {
        // 先验签。alipay_cert_sn 是未签名数据，绝不能在验签前据其拒绝响应——
        // 本地 SN 渲染与网关的任何分歧都会误伤全部有效请求。仅在验签失败时
        // 用它把 VerifyFailed 细化为 CertMismatch（支付宝已轮换证书，须更新配置）。
        const sig = env.sign orelse return error.VerifyFailed;
        self.signer.verify(env.node, sig) catch {
            if (self.alipay_pub_cert_sn) |expected| if (env.cert_sn) |got|
                if (!std.mem.eql(u8, got, &expected)) return error.CertMismatch;
            return error.VerifyFailed;
        };
    }

    fn gatewayError(self: *Client, alloc: Allocator, node: []const u8) Error {
        const head = json.parseLeaky(CodeHead, alloc, node) catch {
            self.last_error = .{ .code = "unknown", .msg = "malformed error_response" };
            return error.GatewayError;
        };
        self.last_error = .{ .code = head.code, .msg = head.msg, .sub_code = head.sub_code, .sub_msg = head.sub_msg };
        return error.GatewayError;
    }

    fn checkBusinessCode(self: *Client, comptime T: type, resp: T) Error!void {
        if (!@hasField(T, "code")) return; // 无 code 字段的响应视为成功
        if (std.mem.eql(u8, resp.code, "10000")) return;
        // detail 借用 resp 字段（生命周期随结果 arena）。
        self.last_error = .{
            .code = resp.code,
            .msg = if (@hasField(T, "msg")) resp.msg else "",
            .sub_code = if (@hasField(T, "sub_code")) resp.sub_code else null,
            .sub_msg = if (@hasField(T, "sub_msg")) resp.sub_msg else null,
        };
        return error.GatewayError;
    }

    fn renderHtmlForm(self: *Client, out_gpa: Allocator, pairs: []const Pair) Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(out_gpa);
        errdefer out.deinit();
        const w = &out.writer;
        const action = self.gpa.print("{s}://{s}{s}", .{ @tagName(self.scheme), self.host, self.target }) catch return error.OutOfMemory;
        defer self.gpa.free(action);

        writeAll(w, "<form id=\"alipay_submit\" name=\"alipay_submit\" action=\"") catch return error.OutOfMemory;
        htmlEscape(w, action) catch return error.OutOfMemory;
        writeAll(w, "\" method=\"post\">") catch return error.OutOfMemory;
        for (pairs) |p| {
            if (p.key.len == 0 or p.value.len == 0) continue;
            writeAll(w, "<input type=\"hidden\" name=\"") catch return error.OutOfMemory;
            htmlEscape(w, p.key) catch return error.OutOfMemory;
            writeAll(w, "\" value=\"") catch return error.OutOfMemory;
            htmlEscape(w, p.value) catch return error.OutOfMemory;
            writeAll(w, "\"/>") catch return error.OutOfMemory;
        }
        writeAll(w, "</form><script>document.forms['alipay_submit'].submit();</script>") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

fn writeAll(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(s);
}

fn htmlEscape(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

const Endpoint = struct {
    scheme: transport_mod.Scheme,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseEndpoint(endpoint: []const u8) !Endpoint {
    const https = std.mem.startsWith(u8, endpoint, "https://");
    const scheme_len: usize = if (https) "https://".len else if (std.mem.startsWith(u8, endpoint, "http://")) "http://".len else return error.InvalidUrl;
    const rest = endpoint[scheme_len..];
    const slash = std.mem.findScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";

    var host = authority;
    var port: u16 = if (https) 443 else 80;
    if (std.mem.findScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.InvalidUrl;
    }
    if (host.len == 0) return error.InvalidUrl;
    return .{
        .scheme = if (https) .https else .http,
        .host = host,
        .port = port,
        .path = path,
    };
}

fn mapEnvelope(e: envelope.Error) Error {
    return switch (e) {
        error.EnvelopeNotFound => error.EnvelopeNotFound,
        error.BadResponse, error.MethodTooLong => error.BadResponse,
    };
}

test "parseEndpoint: https default port and target path" {
    const ep = try parseEndpoint("https://openapi.alipay.com/gateway.do");
    try std.testing.expectEqual(transport_mod.Scheme.https, ep.scheme);
    try std.testing.expectEqualStrings("openapi.alipay.com", ep.host);
    try std.testing.expectEqual(@as(u16, 443), ep.port);
    try std.testing.expectEqualStrings("/gateway.do", ep.path);
}

test "parseEndpoint: explicit port" {
    const ep = try parseEndpoint("http://127.0.0.1:8080/gw");
    try std.testing.expectEqual(transport_mod.Scheme.http, ep.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", ep.host);
    try std.testing.expectEqual(@as(u16, 8080), ep.port);
    try std.testing.expectEqualStrings("/gw", ep.path);
}

// ---- 测试辅助 ----

const test_priv_pem = @embedFile("crypto/testdata/app_priv_pkcs8.pem");
const test_pub_pem = @embedFile("crypto/testdata/app_pub.pem");

/// 2026-07-01 04:34:56 UTC = 2026-07-01 12:34:56 +08:00。
const test_unix_seconds: i64 = 1782880496;
const test_timestamp = "2026-07-01 12:34:56";

/// 测试密钥对对应的 Config。
fn testConfig() config.Config {
    return .{
        .app_id = "2021000000000000",
        .app_private_key = test_priv_pem,
        .alipay_public_key = test_pub_pem,
    };
}

/// 用测试密钥对构造 Client；默认不注入传输（离线模式）。
fn testClient(gpa: Allocator, io: std.Io, options: InitOptions) Error!Client {
    return Client.init(gpa, io, testConfig(), options);
}

/// execute 所需的 comptime API 三元组；不依赖 api.zig，避免测试侧的循环导入。
const TestApi = struct {
    pub const api_method = "alipay.trade.query";
    pub const Biz = struct { out_trade_no: ?[]const u8 = null };
    pub const Resp = struct {
        code: []const u8,
        msg: []const u8,
        sub_code: ?[]const u8 = null,
        sub_msg: ?[]const u8 = null,
        trade_no: ?[]const u8 = null,
    };
};

/// 捕获请求字段的 vtable 传输。request 里的切片只在 send 期间有效，
/// 因此按值复制到 capture allocator，供调用返回后断言。
const FakeTransport = struct {
    const Captured = struct {
        scheme: transport_mod.Scheme,
        host: []u8,
        port: u16,
        target: []u8,
        content_type: []u8,
        body: []u8,
        max_response: usize,
    };

    capture: Allocator,
    seen: ?Captured = null,
    response: []const u8 = "",
    status: u16 = 200,
    failure: ?transport_mod.TransportError = null,

    fn sendErased(context: *anyopaque, gpa: Allocator, request: transport_mod.Request) transport_mod.TransportError!transport_mod.Response {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.record(request);
        if (self.failure) |err| return err;
        return .{ .status = self.status, .body = try gpa.dupe(u8, self.response) };
    }

    const vtable: transport_mod.Transport.VTable = .{ .send = sendErased };

    fn transport(self: *@This()) transport_mod.Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    /// 只保留最近一次请求；重复调用时先释放上次捕获，避免重复发送造成泄漏。
    fn record(self: *@This(), request: transport_mod.Request) Allocator.Error!void {
        self.clearSeen();
        const host = try self.capture.dupe(u8, request.host);
        errdefer self.capture.free(host);
        const target = try self.capture.dupe(u8, request.target);
        errdefer self.capture.free(target);
        const content_type = try self.capture.dupe(u8, request.content_type);
        errdefer self.capture.free(content_type);
        const body = try self.capture.dupe(u8, request.body);
        self.seen = .{
            .scheme = request.scheme,
            .host = host,
            .port = request.port,
            .target = target,
            .content_type = content_type,
            .body = body,
            .max_response = request.max_response,
        };
    }

    fn clearSeen(self: *@This()) void {
        if (self.seen) |seen| {
            self.capture.free(seen.host);
            self.capture.free(seen.target);
            self.capture.free(seen.content_type);
            self.capture.free(seen.body);
            self.seen = null;
        }
    }

    fn deinit(self: *@This()) void {
        self.clearSeen();
        self.* = undefined;
    }
};

// ---- 离线能力与传输边界 ----

test "Client.init succeeds without a transport" {
    var c = try testClient(std.testing.allocator, std.testing.io, .{});
    defer c.deinit();

    try std.testing.expect(c.transport == null);
    try std.testing.expectEqual(transport_mod.Scheme.https, c.scheme);
    try std.testing.expectEqualStrings("openapi.alipay.com", c.host);
    try std.testing.expectEqual(@as(u16, 443), c.port);
    try std.testing.expectEqualStrings("/gateway.do?charset=utf-8", c.target);
    switch (c.clock) {
        .io => {},
        else => return error.TestUnexpectedResult,
    }
}

test "verifyNotify works without a transport" {
    const gpa = std.testing.allocator;
    var c = try testClient(gpa, std.testing.io, .{});
    defer c.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const content = try canonical.buildKeepEmpty(a, &.{
        .{ .key = "out_trade_no", .value = "T-0001" },
        .{ .key = "total_amount", .value = "1.00" },
        .{ .key = "trade_status", .value = "TRADE_SUCCESS" },
    });
    const sig = try c.signer.sign(a, content);

    var with_sign = [_][2][]const u8{
        .{ "out_trade_no", "T-0001" },
        .{ "total_amount", "1.00" },
        .{ "trade_status", "TRADE_SUCCESS" },
        .{ "sign_type", "RSA2" }, // v1 验签须剔除
        .{ "sign", sig },
    };
    try c.verifyNotify(&with_sign, .{});

    // 篡改任一业务字段后签名不再成立。
    with_sign[1][1] = "2.00";
    try std.testing.expectError(error.VerifyFailed, c.verifyNotify(&with_sign, .{}));
}

test "pageExecute and sdkExecute use the injected clock without a transport" {
    const gpa = std.testing.allocator;
    var c = try testClient(gpa, std.testing.io, .{ .clock = .{ .fixed = test_unix_seconds } });
    defer c.deinit();

    const html = try c.pageExecute(gpa, TestApi, .{ .out_trade_no = "T-0001" }, .{});
    defer gpa.free(html);
    try std.testing.expect(std.mem.find(
        u8,
        html,
        "action=\"https://openapi.alipay.com/gateway.do?charset=utf-8\"",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        html,
        "name=\"timestamp\" value=\"" ++ test_timestamp ++ "\"",
    ) != null);
    try std.testing.expect(std.mem.find(u8, html, "name=\"sign\" value=\"") != null);

    const order_string = try c.sdkExecute(gpa, TestApi, .{ .out_trade_no = "T-0001" }, .{});
    defer gpa.free(order_string);
    try std.testing.expect(std.mem.find(
        u8,
        order_string,
        "timestamp=2026-07-01%2012%3A34%3A56",
    ) != null);
    try std.testing.expect(std.mem.find(u8, order_string, "method=alipay.trade.query") != null);
    try std.testing.expect(std.mem.find(u8, order_string, "app_id=2021000000000000") != null);
}

test "custom clock flows through Client into signed timestamps" {
    const gpa = std.testing.allocator;

    // Clock.Custom.context 由 Client 借用：state 须活过 Client。
    const State = struct {
        seconds: i64,

        fn nowFn(ctx: ?*anyopaque, io: std.Io) i64 {
            _ = io;
            const state: *@This() = @ptrCast(@alignCast(ctx.?));
            return state.seconds;
        }
    };
    var state = State{ .seconds = test_unix_seconds };

    var c = try testClient(gpa, std.testing.io, .{ .clock = .{ .custom = .{
        .context = &state,
        .now_fn = State.nowFn,
    } } });
    defer c.deinit();

    const order_string = try c.sdkExecute(gpa, TestApi, .{ .out_trade_no = "T-0001" }, .{});
    defer gpa.free(order_string);
    try std.testing.expect(std.mem.find(
        u8,
        order_string,
        "timestamp=2026-07-01%2012%3A34%3A56",
    ) != null);
}

test "execute fails fast with TransportNotConfigured when no transport is configured" {
    var c = try testClient(std.testing.allocator, std.testing.io, .{ .clock = .{ .fixed = test_unix_seconds } });
    defer c.deinit();

    try std.testing.expectError(
        error.TransportNotConfigured,
        c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
    );
}

test "execute uses the transport injected through InitOptions" {
    const gpa = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 网关响应：成功节点 + 用同一密钥对签出的 sign（验签路径保持原样）。
    var signer = try signer_mod.Signer.init(gpa, testConfig());
    defer signer.deinit();
    const node = "{\"code\":\"10000\",\"msg\":\"Success\",\"trade_no\":\"20261024001\"}";
    const sig = try signer.sign(a, node);
    const raw = try std.fmt.allocPrint(
        a,
        "{{\"alipay_trade_query_response\":{s},\"sign\":\"{s}\"}}",
        .{ node, sig },
    );

    var fake = FakeTransport{ .capture = gpa, .response = raw };
    defer fake.deinit();

    // 传输只能经 InitOptions 注入：若 init 未接线，此处 execute 会直接报
    // TransportNotConfigured，测试失败。
    var c = try Client.init(gpa, std.testing.io, testConfig(), .{
        .transport = fake.transport(),
        .clock = .{ .fixed = test_unix_seconds },
    });
    defer c.deinit();
    try std.testing.expect(c.transport != null);

    const resp = try c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{});
    try std.testing.expectEqualStrings("10000", resp.code);
    try std.testing.expectEqualStrings("Success", resp.msg);
    try std.testing.expectEqualStrings("20261024001", resp.trade_no.?);

    const seen = fake.seen orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(transport_mod.Scheme.https, seen.scheme);
    try std.testing.expectEqualStrings("openapi.alipay.com", seen.host);
    try std.testing.expectEqual(@as(u16, 443), seen.port);
    try std.testing.expectEqualStrings("/gateway.do?charset=utf-8", seen.target);
    try std.testing.expectEqualStrings(
        "application/x-www-form-urlencoded;charset=utf-8",
        seen.content_type,
    );
    try std.testing.expectEqual(max_response, seen.max_response);
    try std.testing.expect(std.mem.find(u8, seen.body, "method=alipay.trade.query") != null);
    try std.testing.expect(std.mem.find(
        u8,
        seen.body,
        "timestamp=2026-07-01%2012%3A34%3A56",
    ) != null);

    // 验签路径未被削弱：伪造 sign 必须失败。
    fake.response =
        "{\"alipay_trade_query_response\":{\"code\":\"10000\",\"msg\":\"Success\"},\"sign\":\"AAAA\"}";
    try std.testing.expectError(
        error.VerifyFailed,
        c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
    );
}

test "internal arena reset clears last_error; out_arena leaves it alone" {
    const gpa = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var signer = try signer_mod.Signer.init(gpa, testConfig());
    defer signer.deinit();
    const node = "{\"code\":\"10000\",\"msg\":\"Success\"}";
    const sig = try signer.sign(a, node);
    const ok_raw = try std.fmt.allocPrint(
        a,
        "{{\"alipay_trade_query_response\":{s},\"sign\":\"{s}\"}}",
        .{ node, sig },
    );

    var fake = FakeTransport{ .capture = gpa, .response = ok_raw };
    defer fake.deinit();

    var c = try Client.init(gpa, std.testing.io, testConfig(), .{
        .transport = fake.transport(),
        .clock = .{ .fixed = test_unix_seconds },
    });
    defer c.deinit();

    // 第一次调用：网关错误，last_error 借用内部 arena。
    fake.response =
        "{\"error_response\":{\"code\":\"40002\",\"msg\":\"Invalid Arguments\",\"sub_code\":\"isv.invalid-app-id\",\"sub_msg\":\"bad\"}}";
    try std.testing.expectError(
        error.GatewayError,
        c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
    );
    try std.testing.expectEqualStrings("40002", c.last_error.?.code);

    // out_arena：内部 arena 未复用，last_error 保持不变（其指向的旧内存仍有效）。
    var out_arena: std.heap.ArenaAllocator = .init(gpa);
    defer out_arena.deinit();
    fake.response = ok_raw;
    const resp = try c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{ .out_arena = &out_arena });
    try std.testing.expectEqualStrings("10000", resp.code);
    try std.testing.expect(c.last_error != null);

    // 回到内部 arena：成功调用的结果分配会清空 last_error，不能再指向已回收内存。
    const resp2 = try c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{});
    try std.testing.expectEqualStrings("10000", resp2.code);
    try std.testing.expectEqual(@as(?ErrorDetail, null), c.last_error);
}

test "execute propagates transport errors and rejects non-2xx" {
    const gpa = std.testing.allocator;
    var c = try testClient(gpa, std.testing.io, .{ .clock = .{ .fixed = test_unix_seconds } });
    defer c.deinit();

    var fake = FakeTransport{ .capture = gpa, .failure = error.Timeout };
    defer fake.deinit();
    c.transport = fake.transport();
    try std.testing.expectError(
        error.Timeout,
        c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
    );

    // TransportError 是 Error 的子集：每一种都须原样冒泡。
    for ([_]transport_mod.TransportError{
        error.OutOfMemory,
        error.Transport,
        error.Timeout,
        error.Tls,
        error.ResponseTooLarge,
        error.Canceled,
        error.ConcurrencyUnavailable,
    }) |failure| {
        fake.failure = failure;
        try std.testing.expectError(
            failure,
            c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
        );
    }

    // 非 2xx 一律收敛为 error.Transport（响应仍由 Transport 正常返回）。
    fake.failure = null;
    fake.status = 500;
    fake.response = "gateway error";
    try std.testing.expectError(
        error.Transport,
        c.execute(TestApi, .{ .out_trade_no = "T-0001" }, .{}),
    );
}
