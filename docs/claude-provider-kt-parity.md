# Claude Provider 缓存与 Kotlin 对照

## 对照基线

仓库：`AAswordman/Operit`，分支 `main`，固定提交
`dbf71916fae9750cfdc9f9a774f5a0fee56633fb`。

## 文件映射

| Kotlin 文件 | Rust / Flutter 对应文件 | 本次修复 |
| --- | --- | --- |
| `app/src/main/java/com/ai/assistance/operit/api/chat/llmprovider/ClaudeProvider.kt` | `core/crates/provider/services/src/chat/llmprovider/ClaudeProvider.rs` | 实现三个显式缓存断点、可选 `1h` TTL、合并 system、稳定序列化与缓存感知 token 预估。 |
| `app/src/main/java/com/ai/assistance/operit/util/TokenCacheManager.kt` | `core/crates/foundation/util/src/TokenCacheManager.rs` | 接入已有管理器；预检查不更新状态，发送时记录估算，重置请求计数保留历史前缀。 |
| `app/src/main/java/com/ai/assistance/operit/api/chat/llmprovider/AIServiceFactory.kt` | `core/crates/provider/services/src/chat/llmprovider/AIServiceFactory.rs`、`chat/enhance/MultiServiceManager.rs` | 为 `ANTHROPIC` 和 `ANTHROPIC_GENERIC` 传递一小时缓存开关。 |
| `app/src/main/java/com/ai/assistance/operit/data/model/ModelConfigData.kt` | `core/crates/foundation/model/src/ModelConfigData.rs` | `ModelRequestSpec.enableClaude1hPromptCache`，默认 false，兼容缺少该字段的旧配置。 |
| `app/src/main/java/com/ai/assistance/operit/data/preferences/ModelConfigManager.kt` | `core/crates/runtime/application/src/data/preferences/ModelConfigManager.rs`、`apps/flutter/app/lib/ui/features/settings/model/ModelSettingsPanel.dart` | 复用请求配置保存接口，Flutter 模型设置增加 Claude 一小时缓存开关。 |
| Kotlin 原有模型配置 | `core/crates/runtime/application/src/data/backup/operit1/Operit1ModelMigration.rs`、`Operit1SnapshotImportManager.rs` | 导入时保留缓存开关，不再列为跳过字段。 |
| 原生配置编辑入口 | `apps/cli/src/tui/config/model_editor.rs` | 编辑并保存模型时保留已有缓存开关，不因 CLI 编辑被重置。 |

## 断点规则

与 KT `cacheControlObject` / `attachCacheControlIfAbsent` /
`findLastContentBlock` / `applyStableCacheBreakpoints` 对应：

1. `tools` 数组中的最后一个工具对象。
2. `system` 数组中的最后一个内容块；常规历史中的 system 文本先以两个换行合并为单个块。
3. 从最后一条消息开始倒序查找，定位最后一个有效 content 对象。不限定 user，assistant 和 tool_result 外层也可成为断点。
4. 默认添加 `{"type":"ephemeral"}`；开启一小时设置时添加 `ttl:"1h"`。
5. 已有 `cache_control` 不覆盖，包括显式 null；不在每个 system/tool 块或 tool_result 的嵌套图片上重复打断点。
6. 空工具/空 system/空历史不凭空添加缓存块。

发送和预检查复用相同的序列化、工具完整 schema 和断点规则。
实际输入计数包含普通输入、缓存创建和缓存读取；OpenAI 兼容 usage 的
`prompt_tokens` 已包含缓存读取，不能再次累加。参照 KT usage 归一化的部分更新语义，
Rust 流式响应先合并已观察到的 usage 字段，再更新计数，避免仅包含输出计数的
`message_delta` 清掉先前输入和缓存数据。无 usage 不覆盖现有计数。

## 回归测试

Provider 测试全部单独放在 `core/crates/provider/tests/`：

- `ClaudeProviderCacheTests.rs`：断点、TTL、幂等、倒序定位、工具图片、空历史、稳定序列化、预检查只读、配置兼容、工厂传参、usage 合并与缓存计数。
- `ClaudeProviderTests.rs`：已有图片内容块转换测试。

Flutter 测试：`apps/flutter/app/test/claude_prompt_cache_settings_test.dart`，
验证官方/Generic Claude 开关保存与重载、旧 DTO 默认值、非 Claude 隐藏开关、
不覆盖结构化工具设置，以及无改动时不额外调用保存接口。

本次测试不调用真实 Claude API，不产生模型费用；请求断点正确不等于已实测服务器缓存命中。
