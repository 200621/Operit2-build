# DeepSeek 图片链路：Kotlin / Rust 对照

## 对照版本与范围

- 上游：`AAswordman/Operit`，`main`，提交 `dbf71916fae9750cfdc9f9a774f5a0fee56633fb`。
- 范围：用户图片附件、assistant 历史图片、工具结果图片，以及 Chat Completions / Responses 的请求构造。
- Kotlin 路径前缀：`app/src/main/java/com/ai/assistance/operit/`。
- 回归测试目录：`core/crates/provider/tests/`；不与实现文件混放。

## 文件对应关系

| Kotlin 文件 | Rust 文件 | 对齐内容 |
| --- | --- | --- |
| `api/chat/llmprovider/DeepseekProvider.kt` | `core/crates/provider/services/src/chat/llmprovider/DeepseekProvider.rs` | Chat Completions 在提取 `reasoning_content` 后复用通用图片转换；Responses 和流式发送复用同一个配置明确的 OpenAI parent。 |
| `api/chat/llmprovider/OpenAIProvider.kt` | `core/crates/provider/services/src/chat/llmprovider/OpenAIProvider.rs` | 图片链接转 Base64 `image_url`；assistant 图片补 user 消息；Chat Completions 工具图片在完整结果批次之后补 user 消息并按 ID 去重。 |
| `api/chat/llmprovider/OpenAIResponsesProvider.kt` 及 `DeepseekProvider.kt` 中的 `DeepseekResponsesProvider` | `core/crates/provider/services/src/chat/llmprovider/OpenAIResponsesProvider.rs`、`DeepseekProvider.rs` | 按 Kotlin `useResponsesApi` 显式标记 parent 的协议，不依赖 provider 名称白名单。工具图片保留在 `function_call_output.output` 内，由已有 adapter 转为 `input_image`。 |
| `core/chat/AIMessageManager.kt` | `core/crates/runtime/application/src/core/chat/AIMessageManager.rs` | 已有本地附件读入图片池并生成内部图片链接的实现，本次不重复修改附件入口。 |
| `api/chat/llmprovider/AIServiceFactory.kt` | `core/crates/provider/services/src/chat/llmprovider/AIServiceFactory.rs`、`chat/enhance/MultiServiceManager.rs` | 已有识图能力参数传递，本次不改配置解析和用户能力开关。 |
| `data/model/ModelConfigData.kt` | `core/crates/foundation/model/src/ModelConfigData.rs` | Kotlin 的直接图片处理开关也默认关闭。保留显式能力设置；默认关闭不等于图片转换已经接通，也不应为了修传输问题强行覆盖用户配置。 |

## 请求构造规则

### Chat Completions

1. 用户图片链接转换成包含真实 Base64 数据的 `image_url` 内容块。
2. assistant 原消息保留文本和推理字段，图片通过紧随其后的 user 图片消息传递。
3. 原生工具结果保留 `tool_call_id` 和文本；图片通过追加 user 图片消息传递。
4. 多工具结果必须先完整返回，再追加图片消息，不能把 user 消息插进尚未完成的工具结果批次。
5. 同一工具结果批次/assistant 消息内的重复图片只追加一次。
6. 关闭识图、图片池条目已过期或角色不接受图片时，回退到文本；不发送内部图片 ID 给模型。
7. Responses 的隐藏回放元数据、搜索展示标记不作为 Chat Completions 可见文本重放，与 Kotlin `inputContentText()` 一致。

### Responses

1. 用户图片转换成 `input_image`。
2. 工具图片转换成 `function_call_output.output` 中的 `input_image`，不额外制造 user 回合。
3. assistant 历史图片仍通过 user 图片消息输入。
4. 在通用 parent 构造阶段保留隐藏推理元数据，交由 Responses adapter 恢复回放项，不能提前当作 Chat Completions 标记移除。
5. 同一规则适用于 DeepSeek Responses、OpenAI Responses、OpenAI Responses Generic 和 OpenAI Codex。

## 测试文件

均位于 `core/crates/provider/tests/`：

- `DeepseekProviderMediaRoleTests.rs`：移植上游 DeepSeek 图片角色测试，并覆盖双协议、流式/非流式请求构造、关闭识图和系统消息限制。
- `OpenAIProviderContentFieldTests.rs`：移植通用图片历史行为，覆盖工具批次去重、过期图片、空工具调用内容、推理字段及协议标记清理。
- `OpenAIResponsesProviderMediaRoleTests.rs`：单独覆盖通用 Responses 包装器，验证图片位于工具输出，并保留加密推理回放。
- `DeepseekProviderResponsesTests.rs`、`DeepseekProviderTests.rs`、`OpenAIProviderTests.rs`、`OpenAIResponsesProviderTests.rs`：从对应实现文件移出的原有测试。
- `ClaudeProviderTests.rs`、`GeminiProviderTests.rs`、`MediaLinkParserTests.rs`：移出相关旧图片测试。去掉进程级 `ImagePoolManager::clear()`，只删除本用例自己的图片，避免并行运行破坏其他测试。
- `ProviderMediaTestSupport.rs`：唯一图片池条目、请求和运行时公共夹具。

```sh
cargo test --manifest-path core/Cargo.toml -p operit-providers
cargo check --manifest-path core/Cargo.toml -p operit-runtime
```

这些测试断言真实请求内容和协议回放结构，不依赖外部 API key，也不产生模型调用费用。流式测试验证请求构造，不代表已使用真实 DeepSeek API 完成流式识图实测。
