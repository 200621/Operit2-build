# 远程 MCP 实测（2026-10-07）

## 范围

通过集成测试 `apps/cli/tests/mcp_remote_smoke.rs`，使用实际的
`MCPBridgeClient → MCPBridge → MacosHttpHost → NativeHttpHost` 调用公网服务。
没有使用 curl 结果代替软件客户端结果。curl 仅用于预先确认服务端点及协议。

所有调用均为公共文档的只读查询，不需要账户、API Key 或 OAuth。
测试只注册内存中的临时服务，完成后停止并注销，不更改用户配置或用户数据。

## 最终结果

| 服务 | 端点 | 传输 | 工具数 | 结果 | 完整检查耗时 |
| --- | --- | --- | ---: | --- | ---: |
| Microsoft Learn | `https://learn.microsoft.com/api/mcp` | Streamable HTTP | 3 | 通过 | 3.112 秒 |
| DeepWiki | `https://mcp.deepwiki.com/mcp` | Streamable HTTP | 3 | 通过 | 3.982 秒 |
| Cloudflare Docs | `https://docs.mcp.cloudflare.com/mcp` | Streamable HTTP | 2 | 通过 | 16.455 秒 |
| CoinGecko | `https://mcp.api.coingecko.com/sse` | 旧式 HTTP+SSE | 2 | 修复后通过 | 4.580 秒 |

每个服务均验证：

1. `initialize` 和 `notifications/initialized`。
2. `tools/list`，且客户端获取到的数量与桥接层一致。
3. 连续两次 `tools/call`，成功返回非空内容。
4. 不存在的工具被正确拒绝，不触发重复调用。
5. `unspawn` 停止连接和注销服务。

实际调用的工具分别为 `microsoft_docs_search`、`read_wiki_structure`、
`search_cloudflare_documentation`、`search_docs`。耗时包含初始化和全部调用，
不是单独的连接延迟，也不是性能基准。公网服务的可用性、工具列表和耗时会变化。

结构化记录：`docs/assets/mcp-remote-smoke-2026-10-07.json`。

## 发现并修复的 SSE 问题

原实现使用缓冲 HTTP GET 收取完整 SSE 响应，再用内存 `Cursor` 读取。
真正的 SSE 连接不会在发送 `endpoint` 后关闭，因此初始化无法及时进行，
即使取得了缓冲内容，后续 POST 对应的新事件也无法进入原有内存读缓冲。

CoinGecko 的基线测试设置了 8 秒启动预算，实际约 31.098 秒后仍然失败，
错误为 `error decoding response body: operation timed out`。

修复位于 `core/crates/tool/services/src/tools/mcp_runtime/plugins/MCPBridge.rs`：

- 使用已有 Host 的 `openHttpByteStream` 接收实时事件，并增量解析分块字节。
- 对每次协议读取设置截止时间；POST 与对应 SSE 读取共享同一预算。
- 连接关闭立即报错，不在流末尾忙循环。
- 会话销毁、初始化失败或正常停止时取消 Host 流。
- 启动超时不再作为整个 SSE 会话的空闲超时。
- 保留同源端点校验，避免把认证信息发送给异源端点。

新增 `MCPBridgeRemoteTests.rs` 中的 6 个离线回归测试覆盖实时握手/连续调用、
分块 UTF-8/CRLF/心跳与通知、启动超时、断流、异源拒绝、共享预算及连接清理。
`operit-tools` 全部 42 个 Rust 测试通过，现有 7 个 MCP 启动契约测试通过。

## 复测

在项目根目录运行：

```sh
cargo test --manifest-path apps/cli/Cargo.toml --test mcp_remote_smoke -- --ignored --nocapture
cargo test --manifest-path apps/cli/Cargo.toml --test mcp_http_streaming
cargo test --manifest-path core/Cargo.toml -p operit-tools
node --test tools/tests/mcp_startup_contracts.test.mjs
```

公网测试默认 `#[ignore]`，仅显式传入 `--ignored` 时访问四个公网服务。
本地集成测试通过 Python 3 启动可控 HTTP fixture，不依赖公网或用户配置；标准 `cargo test` 直接执行。

## 限制

本次不是 Android/iOS/鸿蒙/浏览器真机或 Flutter 界面端到端测试；没有验证
OAuth 登录、带密钥的私有服务器、长时间断网重连或所有服务的协议实现。
修复已经进入工作区源码，但不会自动更新已安装的 App，需要重新构建安装。

## 历史补测：Streamable HTTP 持续流问题（修复前）

上述三个公网 Streamable HTTP 测试通过，只能证明这些服务当前的有限响应能完成
初始化与工具调用，不能据此断言客户端已经完整实现增量流读取。

用本机可控 HTTP 服务、实际 `MCPBridgeClient` 和相同原生网络层补测，
每种情况设置 **200 毫秒启动预算**：

| 返回方式 | 服务行为 | 客户端结果 |
| --- | --- | --- |
| 普通 JSON | 立即返回完整响应 | 3 毫秒连接成功，`echo` 调用成功 |
| 有限 SSE 响应 | 发出 JSON-RPC 事件后立即结束 HTTP body | 1 毫秒连接成功，`echo` 调用成功 |
| SSE 延迟结束 | 立即发出完整初始化事件并 flush，但 HTTP body 继续保持 1.5 秒 | 约 1505 毫秒后失败，`MCP startup deadline exceeded` |

修复前代码确认：非旧式 SSE 的 `sendRemoteJsonRpc` 路径调用缓冲式
`executeHttpRequest`，收到整个 body 后才运行 `parseSseJsonResponse`。
当时结论：**常规有限响应可用，但持续流的及时读取与严格超时存在问题**。
前面的旧式 SSE 修复没有改变这条路径。这不是公网连接失败，也不是对所有
Streamable HTTP 服务不可用的判断，而是对客户端当前读取方式的具体限制。

补测记录：`docs/assets/mcp-http-stream-probe-2026-10-07.json`。


## HTTP Streaming 修复后

原生端现在通过新增 Host 能力 `openHttpResponseStream` 获取响应头和有序字节块，
由 `MCPStreamableHttp.rs` 增量解析 JSON/SSE。收到匹配 ID 的结果后立即返回并取消
剩余 HTTP 响应，不再等待 EOF。等待响应头、读取正文和解析使用同一截止时间。
保留 Session ID、自定义认证头和服务端协商的协议版本；错误或超时不会重放工具调用。

本地回归结果：保持响应打开 1.5 秒的 SSE 初始化现在约 **3 毫秒成功**，普通 JSON
保持打开也约 **2 毫秒成功**；200 毫秒预算下，等待响应头和半截正文分别约
**205 / 202 毫秒超时报错并取消**。全部 **10 个本地场景通过**，四个公网服务再次通过。

测试均位于测试目录，不再使用 `examples`：

- `apps/cli/tests/mcp_http_streaming.rs`：本地原生网络集成测试，含十种响应/超时场景。
- `apps/cli/tests/mcp_remote_smoke.rs`：需要显式启用的公网集成测试。
- `tools/tests/fixtures/mcp_http_streaming_server.py`：仅供本地测试使用的 Python 3 fixture。
- `MCPStreamableHttpTests.rs`：10 个核心单元测试。
- `hosts/common/operit-host-native-http/src/response_stream_tests.rs`：3 个真实 socket 回归测试。

`operit-tools` 全部 60 个测试、原生 HTTP 全部 14 个测试和 7 个 MCP 启动契约测试通过。
Android Host 的 API 编译检查通过，但这不是 Android 真机测试。

本修复覆盖共享原生网络层及 Android、Apple、Linux、Windows、鸿蒙的转发实现。
**浏览器/WASM 保留原有同步有限响应路径，浏览器实时流读取不在本次修复范围内。**

完整记录：`docs/assets/mcp-http-stream-fix-2026-10-07.json`。
