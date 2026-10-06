# operit-providers

`operit-providers` owns Operit's provider contracts and built-in provider
implementations.

The crate root re-exports `AIService`, `SendMessageRequest`, `AiServiceError`,
token/stream helpers, and `ProviderRuntimeSupport`, so SDK consumers do not
need to import the internal `chat::llmprovider` path.

## Usage

External providers implement the public contracts from the crate root:

```toml
operit-providers = "2.0.0-preview.8"
```

The same crate contains the built-in LLM adapters, text-to-speech,
speech-to-text, and market services, ToolPkg provider integration,
conversation orchestration, store access, and tool integration.

## Responsibilities

- Define provider requests, errors, token counters, and streaming contracts.
- Define provider-side interfaces for runtime-owned model bindings, prompt
  context, token accounting, ToolPkg AI provider hooks, and timing logs.
- Provide Operit's built-in provider implementations and orchestration.

## Main Modules

- `src/chat/llmprovider/AIService.rs`: provider request, result, stream, and
  service contracts.
- `src/runtime_support.rs`: provider-side contract implemented by
  `operit-runtime`.
- `src/chat`: built-in chat providers and conversation orchestration.
- `src/tts`: built-in text-to-speech provider contracts and implementations.
- `src/stt`: built-in speech-to-text provider contracts and implementations.
- `src/market`: provider market services.

## Anthropic Model Discovery

`ModelListFetcher` sends both `ANTHROPIC` and `ANTHROPIC_GENERIC` catalog
requests through the shared HTTP host, using `x-api-key` authentication and
`anthropic-version: 2023-06-01`, matching the Kotlin model-list implementation.
The API key comes from the provider's configured key selection, including
rotation through enabled key-pool entries. Explicit custom headers replace
matching header names case-insensitively. Missing required authentication or
an empty version header returns a configuration error before any HTTP request.

Source contract checks are in `tools/tests/anthropic_model_catalog.test.mjs`;
request-header unit tests are in `ModelListFetcher.rs`.

## Boundary

Runtime-owned behavior is requested through `ProviderRuntimeSupport`;
`operit-providers` does not depend on `operit-runtime`.

See `core/CRATE_BOUNDARIES.md` for the full dependency direction.
