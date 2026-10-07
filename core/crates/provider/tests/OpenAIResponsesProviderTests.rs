use super::{
    build_responses_web_search_chunks, extract_responses_metadata, normalize_codex_responses_body,
    strip_responses_protocol_markup, OpenAIResponsesPayloadAdapter, UsageCounts,
    RESPONSES_OUTPUT_ITEM_META_PROVIDER,
};
use serde_json::json;

/// Renders search queries, citations, and replay metadata together.
#[test]
fn renders_responses_web_search_output() {
    let item = json!({
        "type": "web_search_call",
        "id": "search_1",
        "status": "completed",
        "action": {
            "type": "search",
            "queries": ["DeepSeek V4"],
            "sources": [{"title": "DeepSeek", "url": "https://deepseek.com"}]
        }
    });
    let chunks = build_responses_web_search_chunks(&[item.clone()], &json!({}));
    assert!(chunks[0].contains("<query>DeepSeek V4</query>"));
    assert!(chunks[0].contains("url=\"https://deepseek.com\""));
    assert_eq!(chunks.len(), 1);
    let metadata = OpenAIResponsesPayloadAdapter::create_output_item_metadata_tag(&item)
        .expect("web search item metadata");
    assert_eq!(
        extract_responses_metadata(&metadata, RESPONSES_OUTPUT_ITEM_META_PROVIDER),
        vec![item]
    );
}

/// Removes search presentation and hidden replay metadata from model text.
#[test]
fn strips_responses_search_protocol_markup() {
    let chunks = build_responses_web_search_chunks(
        &[json!({"type": "web_search_call", "id": "search_1"})],
        &json!({}),
    );
    let content = format!("before{}after", chunks.join(""));
    assert_eq!(strip_responses_protocol_markup(&content), "beforeafter");
}

/// Preserves an explicitly reported all-zero usage payload.
#[test]
fn parses_zero_usage_payload() {
    assert_eq!(
        OpenAIResponsesPayloadAdapter::parse_usage_counts(Some(&json!({
            "input_tokens": 0,
            "output_tokens": 0
        }))),
        Some(UsageCounts {
            totalInputTokens: 0,
            actualInputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
        })
    );
}

#[test]
fn codex_fast_model_normalizes_to_base_model_and_priority_tier() {
    let mut request = json!({
        "model": "gpt-5.5-fast",
        "messages": [{"role": "user", "content": "hello"}],
        "max_output_tokens": 1000,
        "temperature": 0.7
    });
    normalize_codex_responses_body(&mut request);
    assert_eq!(request["model"], "gpt-5.5");
    assert_eq!(request["service_tier"], "priority");
    assert_eq!(request["store"], false);
    assert_eq!(request["stream"], true);
    assert!(request.get("max_output_tokens").is_none());
    assert!(request.get("temperature").is_none());
}

#[test]
fn codex_standard_model_removes_service_tier() {
    let mut request = json!({
        "model": "gpt-5.5",
        "messages": [{"role": "user", "content": "hello"}]
    });
    normalize_codex_responses_body(&mut request);
    assert_eq!(request["model"], "gpt-5.5");
    assert!(request.get("service_tier").is_none());
}
