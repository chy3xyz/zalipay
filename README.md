# alipay-sdk for Zig

An Alipay Open Platform SDK for **Zig 0.17.0** with **zero third-party dependencies**. It provides pure-Zig RSA2 request signing and response verification, compile-time typed endpoint definitions, synchronous response verification, V1/V2 asynchronous notification verification, certificate SN handling, and a small `std`-only HTTP transport. Both boundaries that touch the outside world — network I/O and time — are injectable.

## Features

- Typed endpoints created with `alipay.Api(method, Biz, Resp)`; `A.call` returns the concrete response type.
- `Client` coordinates system parameters, `biz_content` serialization, the canonical signing string, signing, form encoding, the transport call, raw-node response verification, and business-code checks.
- Public-key and certificate modes, including detection of Alipay certificate rotation.
- Pure-Zig cryptography: RSA signing, PKCS#1/PKCS#8/PEM parsing, and certificate SN generation, with no OpenSSL or C dependency.
- Any Alipay endpoint not included in `alipay.models` can be added with the same typed API mechanism.
- No package dependencies: `build.zig.zon` declares none, so builds resolve nothing from the network.

## Requirements

- Zig 0.17.0.
- An Alipay application ID, application private key, and Alipay public key or certificate for real gateway calls.
- Network access at runtime for server-to-server calls. Building and the test suite require no external network; transport tests use loopback listeners.

## Zero-dependency architecture

The SDK uses only `std` and does not embed a coroutine runtime or event loop:

- `Client.init(gpa, io, cfg, options)` takes `std.Io` positionally and an optional `Transport` through `InitOptions`; it never creates a runtime of its own.
- `Transport` is a minimal vtable (`context` plus `send`) over SDK-owned `Request` and `Response` types. The built-in `StdTransport` adapts `std.http.Client`.
- `Clock` is a union that supplies the signing timestamp: `.io`, `.fixed`, or `.custom`.
- Offline operations (`pageExecute`, `sdkExecute`, `verifyNotify`) never touch the transport.
- Examples run sequentially on `std.process.Init.io`; nothing is spawned unless a transport needs it.

The result stays portable across `std.Io` implementations and leaves connection pooling, TLS policy, and concurrency strategy to the transport in use.

```text
src/root.zig          Public exports
src/config.zig        Client configuration
src/client.zig        Request orchestration, response verification, errors
src/transport.zig     Transport vtable and the std.http adapter
src/clock.zig         Injectable signing clock
src/api.zig           Typed Api(method, Biz, Resp) facade
src/crypto/           RSA, PKCS#1/PKCS#8, PEM, certificate SN
src/wire/             Canonical signing string, form encoding, envelope, timestamp
src/json.zig          Compile-time JSON serialization and parsing
src/models/           Included Alipay endpoints
src/errors.zig        Error set and ErrorDetail
examples/             Executable examples and the shared harness
```

## Build and test

Run these commands from the project root:

```sh
zig fmt --check build.zig src examples
zig build
zig build test
```

- `zig build` compiles the SDK and every `examples/*.zig` program. It does not run them.
- `zig build test` runs the offline unit tests for signing, verification, protocol encoding, JSON handling, timestamps, transport behavior, and certificate SN generation. The suite uses no external network: transport tests bind loopback listeners and may fail in sandboxes that block sockets.
- Files beginning with `_` are shared example modules and are not built as standalone examples.
- Each example file automatically becomes an `example-<name>` executable and a `run-<name>` build step.

## Quick start

The program below creates a `StdTransport`, injects it into the `Client`, and calls `alipay.trade.query`.

```zig
const std = @import("std");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var http = alipay.StdTransport.init(gpa, init.io, .{});
    defer http.deinit();

    var client = try alipay.Client.init(gpa, init.io, .{
        .app_id = "2021xxxxxxxxxxxx",
        .app_private_key = "<PKCS#8 or PKCS#1 PEM body>",
        .alipay_public_key = "<Alipay public-key PEM body>",
    }, .{ .transport = http.transport() });
    defer client.deinit();

    const resp = try alipay.models.trade.Query.call(&client, .{
        .out_trade_no = "T-0001",
    }, .{});
    std.debug.print("status={?s}\n", .{resp.trade_status});
}
```

Replace the placeholders with real credentials and query an order that exists in the target environment. The `StdTransport` must outlive the `Client`, which only borrows it. If the transport is omitted, `execute` (and therefore `A.call`) returns `error.TransportNotConfigured` before signing or any network action.

## Offline use

Construct the client with no transport. Signing, form generation, and notification verification work normally, and no HTTP or TLS code is used.

```zig
const std = @import("std");
const alipay = @import("alipay");

pub fn main(init: std.process.Init) !void {
    var client = try alipay.Client.init(init.gpa, init.io, .{
        .app_id = "2021xxxxxxxxxxxx",
        .app_private_key = "<PKCS#8 or PKCS#1 PEM body>",
        .alipay_public_key = "<Alipay public-key PEM body>",
    }, .{});
    defer client.deinit();

    const order_string = try alipay.models.trade.AppPay.sdk(
        &client,
        init.gpa,
        .{ .out_trade_no = "T-0001", .total_amount = "9.00", .subject = "Demo" },
        .{},
    );
    defer init.gpa.free(order_string);
    std.debug.print("{s}\n", .{order_string});
}
```

`pageExecute` and `sdkExecute` allocate their return value with the supplied `out_gpa`; the caller frees it. `verifyNotify` performs no allocation visible to the caller.

## Transport and Clock extension points

### Transport

`Transport` is the only network boundary. A request is always sent as HTTP **POST**, so `Request` has no method field. `send` receives an allocator, must return a response body allocated with that allocator, may return any HTTP status, and must not retain any slice from `Request` after returning.

```zig
const MyTransport = struct {
    fn sendErased(
        context: *anyopaque,
        gpa: std.mem.Allocator,
        request: alipay.Request,
    ) alipay.TransportError!alipay.Response {
        _ = context;
        _ = request;
        return .{ .status = 200, .body = try gpa.dupe(u8, "{}") };
    }

    const vtable: alipay.Transport.VTable = .{ .send = sendErased };

    fn transport(self: *MyTransport) alipay.Transport {
        return .{ .context = self, .vtable = &vtable };
    }
};
```

The contract in detail:

- `Request` carries `scheme`, `host`, `port`, `target`, `content_type`, `body`, and `max_response`. The target may include a query string; it may not contain CR/LF, spaces, C0 control characters, DEL, or `#` (`std.Uri` would treat everything after `#` as a fragment and silently drop it).
- `Response` carries the HTTP `status` and the `body`. With redirects disabled, `StdTransport` surfaces 301/302/303/307/308 as `error.Transport` (`std.http` reports `TooManyHttpRedirects`), so those redirect statuses do not appear in `Response.status`. 304 is the exception: it is a no-body response and is returned as `status = 304` with an empty body; `Client` still maps it to `error.Transport` because it is non-2xx. Other non-2xx statuses are returned normally in `Response.status`; `Client` maps them to `error.Transport`.
- `TransportError` is `OutOfMemory`, `Transport`, `Timeout`, `Tls`, `ResponseTooLarge`, `Canceled`, or `ConcurrencyUnavailable`.
- `StdTransport` clamps the effective response limit to `alipay.max_response_limit` (8 MiB), regardless of `Request.max_response`.
- A custom transport owns connection pooling, TLS and trust policy, proxying, retries, and observability. The SDK performs no network policy of its own.

### StdTransport

```zig
var http = alipay.StdTransport.init(gpa, io, .{});
defer http.deinit();
const transport = http.transport();
```

`StdTransportOptions` has two fields:

| Field | Default | Meaning |
|---|---|---|
| `timeout_ms` | `60_000` | Total deadline for one `send`, covering connect, write, response headers, and body read |
| `keep_alive` | `true` | Participate in the `std.http.Client` connection pool |

Behavior worth knowing:

- `StdTransport` adds a total deadline on top of `std.http.Client`, whose `request()` path exposes no timeout. The deadline races a deadline task against a worker task with `std.Io.Select`. This requires an `std.Io` implementation that can run concurrent tasks (for example, `std.Io.Threaded`). If concurrency is unavailable, `send` returns `error.ConcurrencyUnavailable` rather than silently dropping the deadline. Set `timeout_ms = null` to consciously opt out; in that mode there is no request timeout.
- Redirects are disabled. `Accept-Encoding` is omitted, so response bodies are not decompressed and no decompression dependency is involved.
- The allocator passed to `StdTransport.init` is retained by `std.http.Client` for connection and TLS buffers, so it **must outlive the transport**. A `send` with a non-null `timeout_ms` races a worker task against a deadline task, and one transport may serve concurrent sends; this allocator must be suitable for that concurrent deadline path (thread-safe when the transport is shared across threads). Response bodies are allocated with the allocator passed to `send`, not with the `init` allocator.
- `deinit` releases the connection pool and CA bundle; no request may be in flight when it is called.

### Clock

The signing timestamp comes from `Client.clock`:

- `.io` (default) reads the system clock via `std.Io.Clock.real`.
- `.fixed` returns a fixed Unix second value and is useful for deterministic tests and replay.
- `.custom { context, now_fn }` calls a caller-supplied function. The context pointer is borrowed: it is neither copied nor owned, and must outlive the `Client`.
- Supported Unix-second range: `0` to `253402271999`, the window whose +08:00 wall clock still has a 4-digit year. Out-of-range values trip an assertion in safety-checked builds instead of silently producing a malformed fixed-width timestamp.

## Ownership and lifetimes

- All string fields in `alipay.Config` are borrowed. They must remain valid for the lifetime of the `Client`.
- The transport implementation (`StdTransport` or a custom type) is created and owned by the caller and must outlive the `Client`. `client.deinit()` does not deinitialize the transport. The allocator passed to `StdTransport.init` is retained by the transport for connections and TLS buffers and must outlive it; response bodies use the allocator passed to `send`.
- A `Clock.custom` context is borrowed and must outlive the `Client`.
- The application private key is parsed once during `Client.init`; it is not re-parsed per request.
- By default, `A.call` and `client.execute` allocate their response in the client's internal arena. A later `execute` resets that arena **after the response envelope parses** (just before result allocation), so responses and related error details must not be retained across calls. The reset also clears `last_error` before the old memory is recycled; an `execute` that fails before the envelope parses leaves the previous arena and `last_error` untouched.
- Pass `Options.out_arena` to allocate a response in a caller-managed arena and control its lifetime.
- `A.page`, `A.sdk`, `client.pageExecute`, and `client.sdkExecute` allocate their returned slices with the supplied `out_gpa`; the caller frees them.
- A single `Client` is **not** safe for concurrent `execute` calls: a call resets the internal arena after the response envelope parses, and `last_error` may be cleared and overwritten. A thread-safe transport is only a prerequisite, not a fix. Use one client per thread or serialize calls externally. The offline methods do not touch the internal arena or `last_error`, so they have no additional client-level concurrency constraint (allocator thread safety remains the caller's responsibility).

## Public API

For an endpoint type `const A = alipay.Api(method, Biz, Resp);`:

| Operation | API | Network | Notes |
|---|---|---|---|
| Server-to-server call | `A.call(&client, biz, opts) Error!A.Resp` | Yes | Requires an injected transport |
| Web page payment or agreement | `A.page(&client, out_gpa, biz, opts) Error![]u8` | No | Returns an auto-submitting HTML form |
| App payment | `A.sdk(&client, out_gpa, biz, opts) Error![]u8` | No | Returns a signed order string |
| Generic typed call | `client.execute(A, biz, opts) Error!A.Resp` | Yes | Same behavior as `A.call` |
| Page form (generic) | `client.pageExecute(out_gpa, A, biz, opts) Error![]u8` | No | Same as `A.page` |
| App order string (generic) | `client.sdkExecute(out_gpa, A, biz, opts) Error![]u8` | No | Same as `A.sdk` |
| Notification verification | `client.verifyNotify(pairs, .{ .version = .v1 }) Error!void` | No | Verifies URL-decoded key/value pairs |

Prefer `A.call` over `client.execute`: its return type is the concrete response type, which gives IDEs and ZLS better navigation and completion.

### Per-call options

```zig
pub const Options = struct {
    notify_url: ?[]const u8 = null,
    return_url: ?[]const u8 = null,
    app_auth_token: ?[]const u8 = null,
    verify_response: bool = true,
    out_arena: ?*std.heap.ArenaAllocator = null,
};
```

Values set in `Options` override the corresponding defaults in `Config`. Synchronous response verification is enabled by default and should remain enabled in production.

### Errors

`Client.last_error` is populated for `error.GatewayError`; inspect its `code`, `msg`, `sub_code`, and `sub_msg`. The detail borrows data from the result arena, so with the default internal arena it becomes invalid when a later `execute` resets the arena after the response envelope parses; `last_error` itself is cleared at that point and may then be replaced by the new call's error. With `Options.out_arena`, it remains valid according to the caller's arena lifetime (the internal arena is not reset), although the `last_error` slot is replaced by a later error.

The public error set is grouped as follows:

- **Configuration:** `InvalidConfig` — `Client.init` rejected the private key, certificate data, or endpoint.
- **Signing and verification:** `SignFailed` — request signing failed; `VerifyFailed` — a response or notification signature is missing or invalid, or no verification key is configured; `CertMismatch` — certificate mode detected a rotated Alipay certificate (see below).
- **Response parsing:** `EnvelopeNotFound` — neither `{method}_response` nor `error_response` was present; `BadResponse` — the envelope is malformed (for example, unbalanced braces or a duplicate response node); `JsonParse` — the response node could not be decoded into the declared `Resp` type.
- **Business:** `GatewayError` — the business code is not `"10000"`, including `error_response`; details are in `last_error`. `BusinessError` is reserved.
- **Transport:** `TransportNotConfigured` — `execute` had no injected transport; `Transport` — connection, read, or write failure, a redirected 3xx (301/302/303/307/308) surfaced by `StdTransport`, or any other non-2xx gateway status, including a 304 that `StdTransport` returns normally; `Timeout`, `Tls`, `ResponseTooLarge`, `ConcurrencyUnavailable`, and `Canceled` — the corresponding transport conditions. `OutOfMemory` is not transport-specific: it can come from any allocation, including `Client.init`, `pageExecute`, and `sdkExecute`.

### Included endpoints

- `alipay.models.trade`: `Pay`, `Precreate`, `Query`, `Refund`, `RefundQuery`, `Close`, `PagePay`, `WapPay`, `AppPay`
- `alipay.models.fund`: `UniTransfer`, `CommonQuery`, `PagePay`, `AccountQuery`, `AccountbookCreate`, `AccountbookQuery`
- `alipay.models.agreement`: `PageSign`, `Query`
- `alipay.models.bill`: `DownloadUrlQuery`

## Public-key and certificate modes

For public-key mode, set `Config.alipay_public_key`.

For certificate mode, set `Config.alipay_public_cert` instead. Application and root certificate data can be provided either way:

- Precomputed `Config.app_cert_sn` and `Config.alipay_root_cert_sn`.
- `Config.app_public_cert` and `Config.alipay_root_cert`; the SDK computes the SN values during `Client.init`.

In certificate mode, if response signature verification fails and the response carries an `alipay_cert_sn` that differs from the configured Alipay certificate, the client returns `error.CertMismatch`. This indicates that Alipay has rotated its certificate and the configuration must be updated. If the response carries no `alipay_cert_sn`, the failure remains `error.VerifyFailed`.

## Custom endpoint

`Biz` is serialized as `biz_content`; field names are the JSON keys. Optional fields declared as `?T = null` are omitted when null. Undeclared response fields are ignored, so `Resp` only needs the fields the application uses.

```zig
const MyBiz = struct {
    some_field: []const u8,
    optional_field: ?[]const u8 = null,
};

const MyResp = struct {
    code: []const u8,
    msg: []const u8,
    sub_code: ?[]const u8 = null,
    sub_msg: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

const MyApi = alipay.Api("alipay.some.new.api", MyBiz, MyResp);

const resp = try MyApi.call(&client, .{ .some_field = "value" }, .{});
// resp has type MyResp.
```

A response is treated as successful when its `code` is `"10000"`. If `Resp` has no `code` field, the SDK treats the response as successful without a business-code check.

## Examples

`zig build` compiles every example automatically; `zig build run-<name>` runs one.

### Offline examples

These sign, generate output, or verify data locally and do not contact an Alipay gateway. The three trade/wap examples use `harness.runOffline`; `verify_notify` constructs an offline `Client` directly. All four construct a `Client` without a transport and contain no `std.http` or TLS code.

```sh
zig build run-trade_app_pay
zig build run-trade_page_pay
zig build run-trade_wap_pay
zig build run-verify_notify
```

- `run-trade_app_pay` generates an App payment order string.
- `run-trade_page_pay` generates a web payment HTML form.
- `run-trade_wap_pay` generates a mobile web payment HTML form.
- `run-verify_notify` demonstrates the notification verification contract. It performs a full local sign/verify check only when both demo keys are supplied, and exits nonzero when verification fails.

To run the `verify_notify` self-check:

```sh
ALIPAY_DEMO_PRIVATE_KEY=<PKCS#8-base64> \
ALIPAY_DEMO_PUBLIC_KEY=<matching-public-key-base64> \
zig build run-verify_notify
```

If either variable is missing, the example prints the contract and skips the self-check. Use keys reserved for this demonstration, never production credentials.

### Sandbox network examples

These examples use `harness.run`, inject `StdTransport`, and contact an Alipay gateway. They require network access, matching credentials, and data that satisfies each example's business preconditions. They were **not** executed as part of the final verification of this repository.

```sh
zig build run-bill_query
zig build run-refund_query
zig build run-trade_close
zig build run-trade_precreate
zig build run-trade_query
zig build run-transfer
```

The harness reads default sandbox credentials from `examples/_sandbox.zig`. That file contains a shared, sandbox-only credential for the examples; never place production credentials there. Use environment overrides for any other account. Each value can be overridden with an environment variable:

| Variable | Configuration |
|---|---|
| `ALIPAY_APP_ID` | `Config.app_id` |
| `ALIPAY_APP_PRIVATE_KEY` | `Config.app_private_key` |
| `ALIPAY_PUBLIC_KEY` | `Config.alipay_public_key` |
| `ALIPAY_ENDPOINT` | `Config.endpoint` |

A failure in a sandbox example may come from credentials, networking, order state, or Alipay business rules and is separate from the offline test suite.

## Protocol invariants

Changes to the protocol layer must preserve these behaviors:

- **Request signing:** parameters are sorted by key, empty values and `sign` are removed, and values are concatenated as `key=value&...` without URL encoding. `sign_type` participates in request signing.
- **Response verification:** verification uses the original brace-delimited substring of the `{method}_response` node in the raw response body. The JSON must not be parsed and re-serialized for verification.
- **Asynchronous notifications:** V1, the default for standard trade, funding, and agreement notifications, removes `sign` and `sign_type`. V2, used only by the lifestyle app, removes only `sign`. Empty values are retained in the verification string. After verification and business checks succeed, the HTTP layer must reply with the plain text `success`.
- **Certificate SN:** `MD5(issuerDN_RFC2253 + serialNumber_decimal)`, where the issuer RDN sequence is reversed relative to the DER order and commas are not followed by spaces.

## Limitations

These are the real consequences of a `std`-only implementation:

- **Two tasks per deadline request.** With a non-null `timeout_ms`, every `StdTransport.send` derives a deadline task and a worker task and races them with `std.Io.Select`. An `std.Io` that cannot run concurrent tasks yields `error.ConcurrencyUnavailable`; it does not silently fall back to no timeout.
- **Concurrency is implementation-defined; `std.Io.Threaded` uses a worker-pool run queue.** The SDK and its examples use no `async`/`await` constructs and provide no scheduler or event loop of their own; `std.process.Init.io` is backed by `std.Io.Threaded`, whose concurrency is thread-based. Other `std.Io` implementations may behave differently. Examples are sequential; parallel requests require multiple threads or callers' own orchestration.
- **Standard-library TLS.** Certificate validation is whatever `std.http.Client` provides. `StdTransport` exposes no custom trust store, certificate pinning, hostname policy, HTTP/2, or TLS session resumption.
- **No transport policy in the SDK.** A custom transport is responsible for pooling, TLS configuration, proxies, retries, and metrics. `StdTransport` offers only `timeout_ms` and `keep_alive`.
- **Bounded responses in `StdTransport`.** `StdTransport` clamps the effective response limit to `alipay.max_response_limit` (8 MiB); larger bodies return `error.ResponseTooLarge`. A custom transport may return a larger body, and `Client` will accept it.
- **No response compression.** `Accept-Encoding` is omitted, so servers must return identity-encoded bodies.
- **No redirects.** Redirects are disabled in `StdTransport`. 301/302/303/307/308 do not reach the caller as `Response.status`: `std.http` reports `TooManyHttpRedirects`, which the adapter maps to `error.Transport`. 304 is the exception: it is a no-body response, returned as `Response.status == 304` with an empty body, and `Client` still maps it to `error.Transport`.
- **Non-2xx statuses are not inspected.** Statuses that reach `Client` (for example 4xx/5xx, and 304) stay in `Response.status`; `Client` discards any body and returns `error.Transport`.
- **Notification verification is only verification.** The caller must parse the form, URL-decode values, perform business checks, and send the `success` reply.
- **`Client` is not concurrency-safe for `execute`.** The internal arena and `last_error` are per-client mutable state.

## Non-goals

This version does not implement the v3 RESTful protocol with header signing, AES `biz_content` encryption, automatic pagination, automatic retries, multipart uploads, an HTTP/2 client, or a coroutine runtime.
