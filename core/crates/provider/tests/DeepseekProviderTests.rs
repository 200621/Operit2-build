use super::deepseek_uses_responses_protocol;

/// Selects Responses only from the final endpoint path segment.
#[test]
fn resolves_deepseek_endpoint_protocol() {
    assert!(
        deepseek_uses_responses_protocol("https://api.deepseek.com/v1/responses?trace=1").unwrap()
    );
    assert!(
        !deepseek_uses_responses_protocol("https://api.deepseek.com/v1/chat/completions").unwrap()
    );
}
