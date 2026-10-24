//! 传输层抽象：SDK 自有的请求/响应模型与 vtable 边界，以及基于 `std.http` 的默认适配器。
//!
//! 本模块只依赖 std。`Transport` 借用其 context，调用方须保证
//! `StdTransport`（或其它实现）比 `Transport` 活得久。
//! `Response.body` 由传入 `send` 的 allocator 分配，所有权归调用方。
const std = @import("std");

/// 传输协议。
pub const Scheme = enum {
    http,
    https,
};

/// 一次 HTTP 请求的描述（SDK 内部统一形态）。
///
/// 固定以 HTTP **POST** 发送，故没有 method 字段（支付宝网关只接受 POST）。
/// 所有切片均为借用：调用方须保证它们在 `send` 返回前有效；`send` 不保留引用。
pub const Request = struct {
    scheme: Scheme,
    /// 主机名；IPv6 字面量不带方括号。拒绝空串、`@ / ? #` 与空白。
    host: []const u8,
    /// 显式端口；适配器总是写进 URL，不依赖协议默认端口。
    port: u16,
    /// 请求目标，必须以 `/` 开头；可含 query，如 `/gateway.do?charset=utf-8`。
    /// 拒绝 CR/LF、空格、C0 控制字符与 DEL（防请求行注入）以及 `#`——`std.Uri`
    /// 会把 `#` 之后当作 fragment 静默丢弃，导致实际发送的字节与调用方给出的不一致。
    /// 其余字节原样使用。
    target: []const u8,
    /// 请求体类型，如 `application/x-www-form-urlencoded;charset=utf-8`。拒绝 CR/LF。
    content_type: []const u8,
    /// 请求体字节。
    body: []const u8,
    /// 响应体上限（字节）。实际生效值为 `@min(max_response, max_response_limit)`。
    max_response: usize,
};

/// 响应体硬上限：调用方无论传多大的 `max_response` 都不会超过此值，
/// 也避免 `.limited(maxInt)` 在内部加一后溢出。
pub const max_response_limit: usize = 8 * 1024 * 1024;

/// 一次 HTTP 响应。`body` 一般由 `send` 的 allocator 分配，所有权归调用方。
pub const Response = struct {
    /// HTTP 状态码。非 2xx 状态照常返回，由上层决定如何处理；`Client` 会把它们映射为
    /// `error.Transport`。
    /// 3xx 例外：`StdTransport` 关闭了重定向，301/302/303/307/308 由 `std.http` 报
    /// `error.TooManyHttpRedirects`，适配器收敛为 `error.Transport`，不会出现在本字段。
    /// 但 304（Not Modified）按 RFC 是空体响应，`std.http` 不按重定向处理，因此照常返回
    /// `status = 304` 与空体切片；`Client` 仍会因其非 2xx 而映射为 `error.Transport`。
    /// 自定义 Transport 若放行其它 3xx，则仍可能出现在这里。
    status: u16,
    /// 响应体。204/304 时为空体例外：返回静态零长度切片 `&.{}`（无需 free；
    /// 对零长度切片调用 `allocator.free` 是 no-op），其余情况由 `send` 的 allocator 分配。
    body: []u8,
};

/// 传输层错误集合。
pub const TransportError = error{
    OutOfMemory,
    Transport,
    Timeout,
    Tls,
    ResponseTooLarge,
    /// 调用方任务被协作式取消。
    Canceled,
    /// Io 实现无法派生计时任务（不支持并发或线程资源耗尽），因而无法兑现 `timeout_ms`。
    ConcurrencyUnavailable,
};

/// 传输实现的 vtable 边界。
///
/// `send` 固定以 POST 发送 `Request.body`。`Request` 中的所有切片为借用，只须在
/// `send` 返回前有效；实现不得保留任何引用。响应体由 `send` 的 allocator 分配，
/// 所有权归调用方（用同一 allocator 释放）。
pub const Transport = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 固定 POST；不得保留 `request` 中的切片引用。
        send: *const fn (
            context: *anyopaque,
            allocator: std.mem.Allocator,
            request: Request,
        ) TransportError!Response,
    };

    /// 发送一次 POST 请求；返回的 `Response.body` 归调用方所有。
    pub fn send(self: Transport, allocator: std.mem.Allocator, request: Request) TransportError!Response {
        return self.vtable.send(self.context, allocator, request);
    }
};

/// `StdTransport` 配置。
pub const StdTransportOptions = struct {
    /// 单次 `send` 的总截止时间（毫秒），覆盖连接、发送、等待响应与读体全过程。
    ///
    /// 实现依赖 `Io.concurrent` 派生的计时任务。若 Io 实现不支持并发或线程资源耗尽，
    /// `send` 返回 `error.ConcurrencyUnavailable`，**不会**静默退化为无超时请求；
    /// 调用方如需接受无超时语义，可显式将本字段设为 `null`。
    timeout_ms: ?u64 = 60_000,
    /// 是否参与 `std.http.Client` 的连接池复用（`Connection: keep-alive`）。
    keep_alive: bool = true,
};

/// 基于 `std.http.Client` 的传输实现。
///
/// 这是 std 侧的适配器：固定以 POST 发送，不做签名/验签/业务码判断。
/// 关闭重定向：301/302/303/307/308 由 `std.http` 报 `error.TooManyHttpRedirects`，
/// 本适配器收敛为 `error.Transport`；304（空体响应）是例外，照常返回 `status = 304`。
/// 其余非 2xx 状态同样照常返回 `Response.status`，由 `Client` 映射。
/// `Request` 的切片只在 `send` 期间被读取，不保留引用。
/// `Client` 的连接池是线程安全的，同一实例可被多个线程并发调用 `send`。
pub const StdTransport = struct {
    client: std.http.Client,
    io: std.Io,
    options: StdTransportOptions,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: StdTransportOptions) StdTransport {
        return .{
            .client = .{ .allocator = gpa, .io = io },
            .io = io,
            .options = options,
        };
    }

    /// 释放连接池与 CA bundle。调用前必须保证没有进行中的请求。
    pub fn deinit(self: *StdTransport) void {
        self.client.deinit();
    }

    /// 取得借用本实例的 `Transport`。调用方须保证本实例存活。
    pub fn transport(self: *StdTransport) Transport {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: Transport.VTable = .{ .send = sendErased };

    fn sendErased(context: *anyopaque, allocator: std.mem.Allocator, request: Request) TransportError!Response {
        const self: *StdTransport = @ptrCast(@alignCast(context));
        return self.send(allocator, request);
    }

    /// 调用方任务被取消时返回 `error.Canceled`（能否观察到取决于 std.http 是否吞掉了取消，
    /// 详见模块内 `mapHttpError` 的说明）。
    pub fn send(self: *StdTransport, allocator: std.mem.Allocator, request: Request) TransportError!Response {
        const timeout_ms = self.options.timeout_ms orelse return sendOnce(self, allocator, request);

        var buffer: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(self.io, &buffer);

        // 先启动计时任务：`concurrent` 不会像 `async` 那样在池满时内联执行，
        // 因此计时任务一定在真正的网络操作开始前进入调度。
        // 无法并发时不静默降级：没有计时任务就没有总截止时间保证。
        select.concurrent(.deadline, deadlineTask, .{ self.io, timeout_ms }) catch
            return error.ConcurrencyUnavailable;
        select.concurrent(.send, workTask, .{ self, allocator, request }) catch {
            drainSelect(&select, allocator);
            return error.ConcurrencyUnavailable;
        };

        // `Select.await` 唯一的错误是调用方自身被取消；清理两个任务后原样上报。
        // 这里的 `drainSelect` 只取消 select 拥有的任务，不会把调用方的取消改写成
        // Timeout/Transport。
        const first = select.await() catch {
            drainSelect(&select, allocator);
            return error.Canceled;
        };

        switch (first) {
            .send => |outcome| {
                drainSelect(&select, allocator);
                if (outcome.response) |response| return response;
                // 不变量：`workTask` 保证 response/err 恰好一个非空。即使该不变量
                // 被破坏，也走总量检查路径，不做 `unreachable` 假设。
                if (outcome.err) |err| return err;
                return error.Transport;
            },
            .deadline => {
                drainSelect(&select, allocator);
                return error.Timeout;
            },
        }
    }
};

const SendOutcome = struct {
    response: ?Response = null,
    err: ?TransportError = null,
};

/// 计时任务与工作任务的返回类型必须分别与 union 字段一致。
const Outcome = union(enum) {
    send: SendOutcome,
    deadline: void,
};

/// 计时任务：睡满 `timeout_ms`。被取消时 `sleep` 返回 `error.Canceled`，直接吞掉。
fn deadlineTask(io: std.Io, timeout_ms: u64) void {
    const ms = std.math.cast(i64, timeout_ms) orelse std.math.maxInt(i64);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
}

/// 工作任务的返回值必须是 `SendOutcome` 本身，不能是 error union。
///
/// 注意：工作线程只会被 `drainSelect` 取消，且该结果总会被丢弃并释放响应体，
/// 因此这里的 `error.Canceled` 不会到达调用方。
fn workTask(self: *StdTransport, allocator: std.mem.Allocator, request: Request) SendOutcome {
    const response = sendOnce(self, allocator, request) catch |err| return .{ .err = err };
    return .{ .response = response };
}

/// 取消 select 中剩余的任务并释放它们可能已产出的响应体。
///
/// `Select.cancel` 每调用一次取出一个已完成的结果，因此需要循环到 `null`；
/// 这样被取消的工作任务即使在取消前一刻成功返回，其响应体也会被释放。
/// 这里丢弃的都是“输掉竞争”的任务结果（含被 drain 取消而得到的 `error.Canceled`），
/// 不会把调用方的取消或超时改写成本函数的返回值。
fn drainSelect(select: *std.Io.Select(Outcome), allocator: std.mem.Allocator) void {
    while (select.cancel()) |outcome| switch (outcome) {
        .send => |result| if (result.response) |response| allocator.free(response.body),
        .deadline => {},
    };
}

fn sendOnce(self: *StdTransport, allocator: std.mem.Allocator, request: Request) TransportError!Response {
    const url = try buildUrl(allocator, request);
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch return error.Transport;

    var req = self.client.request(.POST, uri, .{
        .redirect_behavior = .not_allowed,
        .keep_alive = self.options.keep_alive,
        .headers = .{
            // 不发 Accept-Encoding，响应体保持原样，避免引入解压依赖。
            .accept_encoding = .omit,
            .content_type = .{ .override = request.content_type },
        },
    }) catch |err| return mapHttpError(err);
    defer req.deinit();

    // std 的签名是 `[]u8`，但该函数只读取 body 作为发送缓冲，不会写入。
    // `Writer.Error` 只有 WriteFailed：发送阶段的底层取消会被 std 吞成 WriteFailed，
    // 因而无法在这里区分取消与写失败（详见 `mapHttpError`）。
    req.sendBodyComplete(@constCast(request.body)) catch return error.Transport;

    var response = req.receiveHead(&.{}) catch |err| return mapHttpError(err);

    const status: u16 = @intCast(@backingInt(response.head.status));

    // 204/304 按 RFC 不带响应体。不要调用 `response.reader()`：那会进入 body 读取路径，
    // 若异常服务端声明了 body 却不再发送数据，有超时时会拖到 Timeout，无超时时永久阻塞。
    switch (response.head.status) {
        .no_content, .not_modified => return .{ .status = status, .body = &.{} },
        else => {},
    }

    var transfer_buffer: [8192]u8 = undefined;
    const effective_limit = @min(request.max_response, max_response_limit);
    const body = response.reader(&transfer_buffer).allocRemaining(
        allocator,
        .limited(effective_limit),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return error.Transport,
    };

    return .{ .status = status, .body = body };
}

/// 把 std.http 的具名错误收敛到 `TransportError`。
///
/// 已知限制（已在任务报告中记录）：std.http 的写路径（`Writer.drain`）与读路径
/// （`Io.net.Stream.Reader.readVec` / `http.Reader.receiveHead`）会把底层
/// `error.Canceled` 吞成 `error.WriteFailed` / `error.ReadFailed`，因此
/// 「在发送/读体中发生的调用方取消」只能呈现为 `error.Transport`；
/// 连接阶段的取消与 `Select.await` 处的取消会如实保留为 `error.Canceled`。
fn mapHttpError(err: anyerror) TransportError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => error.Tls,
        else => error.Transport,
    };
}

/// 校验并拼接 `scheme://host:port{target}`；端口总是显式写出。
///
/// 任一非法输入都返回 `error.Transport`（属于编程错误，不做静默修正）：
/// 空 host、host 含 `@ / ? #` 或空白、target 不以 `/` 开头、target 含 CR/LF/
/// 空格/C0 控制字符/DEL（防请求行注入）或 `#`（`std.Uri` 会把它之后当 fragment 丢掉）、
/// content_type 含 CR/LF。
/// 其余字节（含 UTF-8 与常规 path/query 字符）原样透传，不解析、不转义。
fn buildUrl(allocator: std.mem.Allocator, request: Request) TransportError![]u8 {
    if (request.host.len == 0) return error.Transport;
    for (request.host) |c| {
        if (std.ascii.isWhitespace(c)) return error.Transport;
        switch (c) {
            '@', '/', '?', '#' => return error.Transport,
            else => {},
        }
    }
    if (request.target.len == 0 or request.target[0] != '/') return error.Transport;
    for (request.target) |c| {
        if (c == '#' or c == ' ' or std.ascii.isControl(c)) return error.Transport;
    }
    for (request.content_type) |c| {
        if (c == '\r' or c == '\n') return error.Transport;
    }

    const is_ipv6 = std.mem.indexOfScalar(u8, request.host, ':') != null and
        request.host[0] != '[';
    return std.fmt.allocPrint(allocator, "{s}://{s}{s}{s}:{d}{s}", .{
        @tagName(request.scheme),
        if (is_ipv6) "[" else "",
        request.host,
        if (is_ipv6) "]" else "",
        request.port,
        request.target,
    }) catch return error.OutOfMemory;
}

// ---- 测试 ----

const test_scheme = Scheme.http;
const test_content_type = "application/x-www-form-urlencoded;charset=utf-8";

/// 回环 HTTP 服务端的单次行为。
const Behavior = struct {
    kind: enum { echo, body, hang, close },
    body: []const u8 = "",
    status: std.http.Status = .ok,
};

/// 服务端观测到的请求信息；服务端任务结束后读取，无并发访问。
const Observed = struct {
    method: ?std.http.Method = null,
    target: [128]u8 = undefined,
    target_len: usize = 0,
    content_type: [128]u8 = undefined,
    content_type_len: usize = 0,
    content_length: ?u64 = null,
    saw_accept_encoding: bool = false,

    fn targetSlice(self: *const Observed) []const u8 {
        return self.target[0..self.target_len];
    }

    fn contentTypeSlice(self: *const Observed) []const u8 {
        return self.content_type[0..self.content_type_len];
    }
};

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,

    fn start(io: std.Io) !TestServer {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .io = io, .server = try address.listen(io, .{}) };
    }

    fn port(self: *const TestServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn deinit(self: *TestServer) void {
        self.server.deinit(self.io);
    }

    /// 派生一个服务端任务；`Group.concurrent` 保证它跑在独立线程上。
    fn spawn(self: *TestServer, group: *std.Io.Group, behavior: Behavior, observed: *Observed) !void {
        try group.concurrent(self.io, serveOnce, .{ self.io, &self.server, behavior, observed });
    }
};

fn serveOnce(io: std.Io, server: *std.Io.net.Server, behavior: Behavior, observed: *Observed) void {
    serveOnceInner(io, server, behavior, observed) catch {};
}

fn serveOnceInner(
    io: std.Io,
    server: *std.Io.net.Server,
    behavior: Behavior,
    observed: *Observed,
) !void {
    const stream = try server.accept(io);
    defer stream.close(io);

    switch (behavior.kind) {
        .close => return,
        .hang => {
            std.Io.sleep(io, .fromSeconds(5), .awake) catch {};
            return;
        },
        else => {},
    }

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = try http_server.receiveHead();

    observed.method = req.head.method;
    observed.target_len = @min(req.head.target.len, observed.target.len);
    @memcpy(observed.target[0..observed.target_len], req.head.target[0..observed.target_len]);
    if (req.head.content_type) |ct| {
        observed.content_type_len = @min(ct.len, observed.content_type.len);
        @memcpy(observed.content_type[0..observed.content_type_len], ct[0..observed.content_type_len]);
    }
    observed.content_length = req.head.content_length;

    var headers = req.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) observed.saw_accept_encoding = true;
    }

    switch (behavior.kind) {
        .echo => {
            var echo_buffer: [512]u8 = undefined;
            const echo = try std.fmt.bufPrint(&echo_buffer, "{s}|{s}|{d}", .{
                req.head.target,
                req.head.content_type orelse "",
                req.head.content_length orelse 0,
            });
            try req.respond(echo, .{ .status = behavior.status });
        },
        .body => try req.respond(behavior.body, .{ .status = behavior.status }),
        .close, .hang => unreachable,
    }
}

fn testRequest(server: *const TestServer, body: []const u8, max_response: usize) Request {
    return .{
        .scheme = test_scheme,
        .host = "127.0.0.1",
        .port = server.port(),
        .target = "/gateway.do",
        .content_type = test_content_type,
        .body = body,
        .max_response = max_response,
    };
}

test "StdTransport posts form body and returns the response" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .echo }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{});
    defer transport_impl.deinit();
    const transport = transport_impl.transport();

    const body = "app_id=2021000000000000&method=alipay.trade.query";
    const response = try transport.send(allocator, testRequest(&server, body, 1024));
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(
        "/gateway.do|application/x-www-form-urlencoded;charset=utf-8|49",
        response.body,
    );

    try group.await(io);
    try std.testing.expectEqual(std.http.Method.POST, observed.method.?);
    try std.testing.expectEqualStrings("/gateway.do", observed.targetSlice());
    try std.testing.expectEqualStrings(test_content_type, observed.contentTypeSlice());
    try std.testing.expectEqual(@as(?u64, body.len), observed.content_length);
    // Accept-Encoding 必须被省略，响应体才不会被压缩。
    try std.testing.expect(!observed.saw_accept_encoding);
}

test "StdTransport returns non-2xx status instead of rejecting it" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{
        .kind = .body,
        .body = "gateway error",
        .status = .internal_server_error,
    }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .keep_alive = false });
    defer transport_impl.deinit();

    const response = try transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024));
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 500), response.status);
    try std.testing.expectEqualStrings("gateway error", response.body);

    try group.await(io);
}

test "StdTransport maps a 302 redirect to Transport (redirects disabled)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{
        .kind = .body,
        .body = "redirecting",
        .status = .found,
    }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .keep_alive = false });
    defer transport_impl.deinit();

    // 重定向被禁用：301/302/303/307/308 由 std.http 在 receiveHead 报
    // TooManyHttpRedirects，适配器收敛为 error.Transport。
    try std.testing.expectError(
        error.Transport,
        transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024)),
    );

    try group.await(io);
}

test "StdTransport returns 304 as an empty-body Response (Client maps it to Transport)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .body, .body = "", .status = .not_modified }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .keep_alive = false });
    defer transport_impl.deinit();

    // 304 是 3xx 里的例外：std.http 按空体响应处理，不走重定向路径，因此照常返回；
    // 上层（Client）仍会因非 2xx 把它映射为 error.Transport。
    const response = try transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024));
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 304), response.status);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);

    try group.await(io);
}

test "StdTransport maps an over-limit response body to ResponseTooLarge" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{
        .kind = .body,
        .body = "0123456789012345678901234567890123456789012345678901234567890123456789",
    }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{});
    defer transport_impl.deinit();

    try std.testing.expectError(
        error.ResponseTooLarge,
        transport_impl.transport().send(allocator, testRequest(&server, "x=1", 16)),
    );

    // 让服务端把响应写完并退出，避免测试结束时仍有线程在写已关闭的 socket。
    group.await(io) catch {};
}

test "StdTransport maps a peer that closes before responding to Transport" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .close }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{});
    defer transport_impl.deinit();

    try std.testing.expectError(
        error.Transport,
        transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024)),
    );

    group.await(io) catch {};
}

test "StdTransport enforces the total timeout and cleans up the canceled request" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .hang }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .timeout_ms = 150 });
    defer transport_impl.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(
        error.Timeout,
        transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024)),
    );
    const elapsed_ms = start.untilNow(io).raw.toMilliseconds();

    // 服务端会挂 5 秒；若超时无效，这里会明显超过该阈值。
    // 下界同时证明 Timeout 来自真正的计时器，而不是立即失败。
    try std.testing.expect(elapsed_ms >= 100);
    try std.testing.expect(elapsed_ms < 1_000);
}

test "StdTransport with timeout_ms = null returns the response (and clamps huge limits)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .echo }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .timeout_ms = null });
    defer transport_impl.deinit();

    // maxInt 也不应让 `.limited()` 内部加一溢出，实际生效值被钳到 max_response_limit。
    const response = try transport_impl.transport().send(
        allocator,
        testRequest(&server, "x=1", std.math.maxInt(usize)),
    );
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(
        "/gateway.do|application/x-www-form-urlencoded;charset=utf-8|3",
        response.body,
    );

    try group.await(io);
}

test "StdTransport with timeout_ms = null maps over-limit response to ResponseTooLarge" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{
        .kind = .body,
        .body = "0123456789012345678901234567890123456789012345678901234567890123456789",
    }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .timeout_ms = null });
    defer transport_impl.deinit();

    try std.testing.expectError(
        error.ResponseTooLarge,
        transport_impl.transport().send(allocator, testRequest(&server, "x=1", 16)),
    );

    group.await(io) catch {};
}

test "StdTransport treats 204 as an empty body without reading to EOF" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&group, .{ .kind = .body, .body = "", .status = .no_content }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{});
    defer transport_impl.deinit();

    const response = try transport_impl.transport().send(allocator, testRequest(&server, "x=1", 1024));
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 204), response.status);
    try std.testing.expectEqual(@as(usize, 0), response.body.len);

    try group.await(io);
}

test "StdTransport returns ConcurrencyUnavailable instead of dropping the deadline" {
    const allocator = std.testing.allocator;

    // 单线程 Io 无法派生计时任务；此时必须显式报错，而不是静默变成无超时请求。
    var single_threaded = std.Io.Threaded.init_single_threaded;
    const single_io = single_threaded.io();

    var transport_impl = StdTransport.init(allocator, single_io, .{ .timeout_ms = 1_000 });
    defer transport_impl.deinit();

    try std.testing.expectError(
        error.ConcurrencyUnavailable,
        transport_impl.transport().send(allocator, .{
            .scheme = test_scheme,
            .host = "127.0.0.1",
            .port = 1,
            .target = "/gateway.do",
            .content_type = test_content_type,
            .body = "x=1",
            .max_response = 1024,
        }),
    );
}

test "StdTransport reports caller cancellation as Canceled" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var server = try TestServer.start(io);
    defer server.deinit();

    var server_group: std.Io.Group = .init;
    defer server_group.cancel(io);

    var observed: Observed = .{};
    try server.spawn(&server_group, .{ .kind = .hang }, &observed);

    var transport_impl = StdTransport.init(allocator, io, .{ .timeout_ms = 5_000 });
    defer transport_impl.deinit();

    const Job = struct {
        transport: *StdTransport,
        allocator: std.mem.Allocator,
        request: Request,
        result: ?TransportError!Response = null,

        fn run(job: *@This()) void {
            job.result = job.transport.send(job.allocator, job.request);
        }
    };

    var job: Job = .{
        .transport = &transport_impl,
        .allocator = allocator,
        .request = testRequest(&server, "x=1", 1024),
    };

    var job_group: std.Io.Group = .init;
    try job_group.concurrent(io, Job.run, .{&job});

    // 让 send 进入 Select.await（工作线程会卡在等待服务端响应头上），再取消调用方。
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    job_group.cancel(io);

    const result = job.result orelse return error.TestUnexpectedResult;
    if (result) |response| {
        allocator.free(response.body);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.Canceled, err);
    }
}

test "Transport vtable hands the request through and returns caller-owned body" {
    const allocator = std.testing.allocator;

    const Fake = struct {
        seen: ?Request = null,
        reply: []const u8 = "pong",
        status: u16 = 204,

        fn sendErased(context: *anyopaque, gpa: std.mem.Allocator, request: Request) TransportError!Response {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen = request;
            return .{ .status = self.status, .body = try gpa.dupe(u8, self.reply) };
        }
    };

    const fake_vtable: Transport.VTable = .{ .send = Fake.sendErased };
    var fake = Fake{};
    const transport: Transport = .{ .context = &fake, .vtable = &fake_vtable };

    const request: Request = .{
        .scheme = .https,
        .host = "openapi.alipay.com",
        .port = 443,
        .target = "/gateway.do",
        .content_type = test_content_type,
        .body = "a=1",
        .max_response = 64,
    };

    const response = try transport.send(allocator, request);
    defer allocator.free(response.body);

    try std.testing.expectEqual(@as(u16, 204), response.status);
    try std.testing.expectEqualStrings("pong", response.body);
    try std.testing.expectEqualStrings("openapi.alipay.com", fake.seen.?.host);
    try std.testing.expectEqual(@as(u16, 443), fake.seen.?.port);
    try std.testing.expectEqualStrings("a=1", fake.seen.?.body);
}

test "buildUrl always writes the explicit port and brackets IPv6 hosts" {
    const allocator = std.testing.allocator;

    const url = try buildUrl(allocator, .{
        .scheme = .https,
        .host = "openapi.alipay.com",
        .port = 443,
        .target = "/gateway.do?x=1",
        .content_type = test_content_type,
        .body = "",
        .max_response = 1,
    });
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://openapi.alipay.com:443/gateway.do?x=1", url);

    const ipv6 = try buildUrl(allocator, .{
        .scheme = .http,
        .host = "::1",
        .port = 8080,
        .target = "/gateway.do",
        .content_type = test_content_type,
        .body = "",
        .max_response = 1,
    });
    defer allocator.free(ipv6);
    try std.testing.expectEqualStrings("http://[::1]:8080/gateway.do", ipv6);

    try std.testing.expectError(error.Transport, buildUrl(allocator, .{
        .scheme = .http,
        .host = "example.com",
        .port = 80,
        .target = "gateway.do",
        .content_type = test_content_type,
        .body = "",
        .max_response = 1,
    }));

    // 非法 host / content_type 一律拒绝，不做静默修正。
    for ([_][]const u8{ "", "user@host", "host/path", "host?x=1", "host#frag", "ho st", "host\tx" }) |host| {
        try std.testing.expectError(error.Transport, buildUrl(allocator, .{
            .scheme = .http,
            .host = host,
            .port = 80,
            .target = "/gateway.do",
            .content_type = test_content_type,
            .body = "",
            .max_response = 1,
        }));
    }
    for ([_][]const u8{ "application/x-www-form-urlencoded\r\n", "a\nb", "a\rb" }) |content_type| {
        try std.testing.expectError(error.Transport, buildUrl(allocator, .{
            .scheme = .http,
            .host = "example.com",
            .port = 80,
            .target = "/gateway.do",
            .content_type = content_type,
            .body = "",
            .max_response = 1,
        }));
    }
    try std.testing.expectError(error.Transport, buildUrl(allocator, .{
        .scheme = .http,
        .host = "example.com",
        .port = 80,
        .target = "",
        .content_type = test_content_type,
        .body = "",
        .max_response = 1,
    }));
}

test "buildUrl rejects request-line injection bytes and fragments in target" {
    const allocator = std.testing.allocator;

    // target 含 CR/LF/空格/C0/DEL 一律拒绝，防请求行注入；
    // `#` 也拒绝——std.Uri 会把它之后当作 fragment 静默丢弃。
    for ([_][]const u8{
        "/gateway.do\r",
        "/gateway\r\n.do",
        "/gateway.do\n",
        "/gateway .do",
        "/gateway.do?x=\x00",
        "/gateway.do?x=\x1f",
        "/gateway.do?x=\x7f",
        "/gateway.do#frag",
        "/gateway.do?x=1#frag",
    }) |target| {
        try std.testing.expectError(error.Transport, buildUrl(allocator, .{
            .scheme = .http,
            .host = "example.com",
            .port = 80,
            .target = target,
            .content_type = test_content_type,
            .body = "",
            .max_response = 1,
        }));
    }

    // 常规 path/query 与 UTF-8 原样透传，不解析、不转义。
    const url = try buildUrl(allocator, .{
        .scheme = .http,
        .host = "example.com",
        .port = 80,
        .target = "/gateway.do?name=张三&x=%2F",
        .content_type = test_content_type,
        .body = "",
        .max_response = 1,
    });
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://example.com:80/gateway.do?name=张三&x=%2F", url);
}
