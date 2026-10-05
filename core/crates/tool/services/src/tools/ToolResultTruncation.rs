use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TruncationOutcome {
    pub text: String,
    pub truncated: bool,
    pub original_tokens: usize,
    pub result_tokens: usize,
    pub head_chars: usize,
    pub tail_chars: usize,
    pub elided_chars: usize,
}

const DEFAULT_HEAD_RATIO: f64 = 0.6;
const MARKER_RESERVE_TOKENS: usize = 32;

pub fn truncate_tool_result(
    text: &str,
    max_tokens: Option<usize>,
    head_ratio: Option<f64>,
) -> TruncationOutcome {
    let original_tokens = estimate_tokens(text);
    let max_tokens = max_tokens.unwrap_or(0);

    if max_tokens <= 0 || original_tokens <= max_tokens {
        return TruncationOutcome {
            text: text.to_string(),
            truncated: false,
            original_tokens,
            result_tokens: original_tokens,
            head_chars: 0,
            tail_chars: 0,
            elided_chars: 0,
        };
    }

    let ratio = head_ratio.unwrap_or(DEFAULT_HEAD_RATIO).clamp(0.0, 1.0);
    let budget = (max_tokens.saturating_sub(MARKER_RESERVE_TOKENS)).max(1);
    let head_budget = ((budget as f64) * ratio) as usize;
    let tail_budget = budget.saturating_sub(head_budget);

    let head_end = advance_by_tokens(text, 0, text.len(), head_budget, true);
    let tail_start = advance_by_tokens(text, text.len(), 0, tail_budget, false);

    if tail_budget == 0 || tail_start <= head_end {
        let head = text[..head_end].trim_end();
        let elided = text.len() - head.len();
        let rendered = format!("{}{}", head, elision_marker(elided));
        return TruncationOutcome {
            text: rendered,
            truncated: true,
            original_tokens,
            result_tokens: estimate_tokens(&rendered),
            head_chars: head.len(),
            tail_chars: 0,
            elided_chars: elided,
        };
    }

    let head = &text[..head_end];
    let tail = &text[tail_start..];
    let elided = tail_start - head_end;
    let rendered = format!("{}{}{}", head, elision_marker(elided), tail);

    TruncationOutcome {
        text: rendered,
        truncated: true,
        original_tokens,
        result_tokens: estimate_tokens(&rendered),
        head_chars: head.len(),
        tail_chars: tail.len(),
        elided_chars: elided,
    }
}

pub fn estimate_tokens(text: &str) -> usize {
    let ascii = text.chars().filter(|c| (*c as u32) <= 0x7F).count();
    let non_ascii = text.chars().count() - ascii;
    non_ascii + (ascii + 2) / 3
}

fn advance_by_tokens(text: &str, from: usize, to: usize, budget: usize, forward: bool) -> usize {
    if budget == 0 {
        return from;
    }
    let mut ascii = 0usize;
    let mut non_ascii = 0usize;
    let mut index = from;
    let chars: Vec<char> = text.chars().collect();
    while index != to {
        let c = if forward {
            chars[index]
        } else {
            chars[index - 1]
        };
        if (c as u32) <= 0x7F {
            ascii += 1;
        } else {
            non_ascii += 1;
        }
        let tokens = non_ascii + (ascii + 2) / 3;
        if tokens > budget {
            break;
        }
        if forward {
            index += 1;
        } else {
            index -= 1;
        }
    }
    index
}

fn elision_marker(elided_chars: usize) -> String {
    format!(
        "\n…[{} characters elided to fit the tool-result budget]…\n",
        elided_chars
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_truncation_when_budget_is_none() {
        let outcome = truncate_tool_result("hello world", None, None);
        assert!(!outcome.truncated);
        assert_eq!(outcome.text, "hello world");
    }

    #[test]
    fn no_truncation_when_budget_exceeds_content() {
        let outcome = truncate_tool_result("hello", Some(100), None);
        assert!(!outcome.truncated);
    }

    #[test]
    fn truncation_preserves_head_and_tail() {
        let text = "a".repeat(1000);
        let outcome = truncate_tool_result(&text, Some(50), None);
        assert!(outcome.truncated);
        assert!(outcome.text.contains("elided"));
        assert!(outcome.head_chars > 0);
        assert!(outcome.tail_chars > 0);
    }

    #[test]
    fn estimate_tokens_ascii() {
        assert_eq!(estimate_tokens("hello"), 2); // 5 ascii = (5+2)/3 = 2
    }

    #[test]
    fn estimate_tokens_non_ascii() {
        assert_eq!(estimate_tokens("你好"), 2); // 2 non-ascii = 2 tokens
    }
}
