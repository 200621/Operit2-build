use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::Path;

/// Ported from rikkahub-agent-pure's ColdMemoryTools.kt.
///
/// Cold memory: a Markdown knowledge base on disk, read on demand.
/// Documents stay on disk and are pulled in only when the model requests them,
/// so a large knowledge base costs nothing until it is actually read.
///
/// Three tools: memory_index, memory_read, memory_write.
/// All IO is injected by the caller — this module is pure and testable.

// --- Constants ---

pub const WORKSPACE_PREFIX: &str = "/workspace";
pub const MARKDOWN_SUFFIX: &str = ".md";
pub const INDEX_FILE_NAME: &str = "INDEX.md";
pub const READ_WINDOW_CHARS: usize = 16_000;
pub const INDEX_MAX_CHARS: usize = 16_000;
const MAX_CANDIDATES: usize = 20;

// --- Data types ---

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColdMemoryDoc {
    pub name: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColdMemoryWriteResult {
    pub file_name: String,
    pub mode: String,
    pub total_chars: usize,
}

#[derive(Debug, Clone)]
pub enum ColdMemoryLookup {
    Found(String),
    Ambiguous(Vec<String>),
    NotFound,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColdMemoryWindow {
    pub content: String,
    pub start: usize,
    pub end_exclusive: usize,
    pub total_chars: usize,
    pub truncated: bool,
}

// --- Pure rules (no IO, no Android) ---

pub struct ColdMemoryRules;

impl ColdMemoryRules {
    pub fn is_markdown(name: &str) -> bool {
        name.to_lowercase().ends_with(MARKDOWN_SUFFIX)
    }

    /// Turns a workspace picker path into a relative directory.
    /// Returns None when blank or trying to escape (any ".." segment).
    pub fn normalize_dir(raw: Option<&str>) -> Option<String> {
        let trimmed = raw.unwrap_or("").trim();
        if trimmed.is_empty() {
            return None;
        }
        let relative = trimmed
            .strip_prefix(&format!("{}/", WORKSPACE_PREFIX))
            .or_else(|| trimmed.strip_prefix(WORKSPACE_PREFIX))
            .unwrap_or(trimmed);
        let mut cleaned = relative.replace('\\', "/");
        while cleaned.starts_with("./") {
            cleaned = cleaned[2..].to_string();
        }
        cleaned = cleaned.trim_matches('/').to_string();
        if cleaned.is_empty() {
            return Some(String::new());
        }
        if cleaned.split('/').any(|s| s == "..") {
            return None;
        }
        Some(cleaned)
    }

    /// Valid write name: single segment, .md extension, no traversal.
    pub fn is_valid_write_name(name: &str) -> bool {
        let trimmed = name.trim();
        if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
            return false;
        }
        if trimmed.contains('/') || trimmed.contains('\\') || trimmed.contains("..") {
            return false;
        }
        Self::is_markdown(trimmed)
    }

    /// Resolves a model-supplied file reference against the directory listing.
    /// Exact > without-suffix > prefix > substring. Ambiguous = list candidates.
    pub fn lookup(query: &str, names: &[String]) -> ColdMemoryLookup {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return ColdMemoryLookup::NotFound;
        }
        let mut pool: Vec<&String> = names.iter().collect();
        pool.sort();

        let unique_or_candidates = |matches: Vec<&String>| -> ColdMemoryLookup {
            if matches.is_empty() {
                ColdMemoryLookup::NotFound
            } else if matches.len() == 1 {
                ColdMemoryLookup::Found(matches[0].clone())
            } else {
                ColdMemoryLookup::Ambiguous(
                    matches.iter().take(MAX_CANDIDATES).map(|s| s.to_string()).collect(),
                )
            }
        };

        // Exact match (with or without .md suffix)
        let exact: Vec<&String> = pool
            .iter()
            .filter(|n| {
                let lower = n.to_lowercase();
                lower == q || lower.strip_suffix(MARKDOWN_SUFFIX) == Some(q.as_str())
            })
            .copied()
            .collect();
        if !exact.is_empty() {
            return unique_or_candidates(exact);
        }

        // Prefix match
        let prefix: Vec<&String> = pool
            .iter()
            .filter(|n| {
                let lower = n.to_lowercase();
                lower.starts_with(&q) || lower.strip_suffix(MARKDOWN_SUFFIX).map(|s| s.starts_with(&q)).unwrap_or(false)
            })
            .copied()
            .collect();
        if !prefix.is_empty() {
            return unique_or_candidates(prefix);
        }

        // Substring match
        let substr: Vec<&String> = pool.iter().filter(|n| n.to_lowercase().contains(&q)).copied().collect();
        unique_or_candidates(substr)
    }

    /// Clips text to one READ_WINDOW_CHARS window starting at requested_start.
    pub fn window(text: &str, requested_start: Option<usize>) -> ColdMemoryWindow {
        let total = text.len();
        let start = requested_start.unwrap_or(0).min(total);
        let end = (start + READ_WINDOW_CHARS).min(total);
        ColdMemoryWindow {
            content: text[start..end].to_string(),
            start,
            end_exclusive: end,
            total_chars: total,
            truncated: end < total,
        }
    }
}

// --- Tool result builders (JSON envelopes) ---

/// Builds the memory_index result JSON.
pub fn build_index_result(
    dir_label: &str,
    docs: &[ColdMemoryDoc],
    index_text: Option<&str>,
) -> String {
    let markdown: Vec<&ColdMemoryDoc> = docs.iter().filter(|d| ColdMemoryRules::is_markdown(&d.name)).collect();
    let files: Vec<Value> = markdown
        .iter()
        .map(|d| json!({"name": d.name, "sizeBytes": d.size_bytes}))
        .collect();

    let mut result = json!({
        "dir": dir_label,
        "fileCount": markdown.len(),
        "files": files,
    });

    match index_text {
        Some(text) => {
            let truncated = text.len() > INDEX_MAX_CHARS;
            result["index"] = Value::String(text.chars().take(INDEX_MAX_CHARS).collect());
            if truncated {
                result["indexTruncated"] = Value::Bool(true);
            }
        }
        None => {
            result["index"] = Value::String(String::new());
            result["note"] = Value::String(format!("{} not found in this directory.", INDEX_FILE_NAME));
        }
    }

    result.to_string()
}

/// Builds the memory_read result JSON for a found document.
pub fn build_read_result(name: &str, text: &str, start: Option<usize>) -> String {
    let window = ColdMemoryRules::window(text, start);
    let mut result = json!({
        "file": name,
        "start": window.start,
        "endExclusive": window.end_exclusive,
        "totalChars": window.total_chars,
        "truncated": window.truncated,
        "content": window.content,
    });
    if window.truncated {
        result["nextStart"] = Value::from(window.end_exclusive);
    }
    result.to_string()
}

/// Builds an ambiguous-match result.
pub fn build_ambiguous_result(query: &str, candidates: &[String]) -> String {
    json!({
        "error": "ambiguous",
        "file": query,
        "candidates": candidates,
        "detail": "Several documents match. Call memory_read again with one exact name."
    })
    .to_string()
}

/// Builds a not-found result.
pub fn build_not_found_result(query: &str, names: &[String]) -> String {
    let mut sorted = names.to_vec();
    sorted.sort();
    let available: Vec<&String> = sorted.iter().take(50).collect();
    json!({
        "error": "not_found",
        "file": query,
        "available": available,
        "detail": "No document matches. Use memory_index to list what exists."
    })
    .to_string()
}

/// Builds a memory_write result.
pub fn build_write_result(result: &ColdMemoryWriteResult) -> String {
    json!({
        "file": result.file_name,
        "mode": result.mode,
        "totalChars": result.total_chars,
    })
    .to_string()
}

/// Builds an error envelope.
pub fn error_envelope(code: &str, detail: &str) -> String {
    json!({"error": code, "detail": detail}).to_string()
}

/// Builds an invalid-name error.
pub fn build_invalid_name_error(name: &str) -> String {
    json!({
        "error": "invalid_name",
        "file": name,
        "detail": format!("Use a single file name ending in {} (no directory separators, no \"..\").", MARKDOWN_SUFFIX)
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_markdown_checks_suffix() {
        assert!(ColdMemoryRules::is_markdown("notes.md"));
        assert!(ColdMemoryRules::is_markdown("NOTES.MD"));
        assert!(!ColdMemoryRules::is_markdown("notes.txt"));
    }

    #[test]
    fn normalize_dir_strips_workspace_prefix() {
        assert_eq!(ColdMemoryRules::normalize_dir(Some("/workspace/notes/memory")), Some("notes/memory".to_string()));
        assert_eq!(ColdMemoryRules::normalize_dir(Some("/workspace")), Some("".to_string()));
        assert_eq!(ColdMemoryRules::normalize_dir(None), None);
    }

    #[test]
    fn normalize_dir_rejects_traversal() {
        assert_eq!(ColdMemoryRules::normalize_dir(Some("/workspace/../etc")), None);
        assert_eq!(ColdMemoryRules::normalize_dir(Some("/workspace/notes/../etc")), None);
    }

    #[test]
    fn valid_write_name_requires_md() {
        assert!(ColdMemoryRules::is_valid_write_name("M01-notes.md"));
        assert!(!ColdMemoryRules::is_valid_write_name("notes.txt"));
        assert!(!ColdMemoryRules::is_valid_write_name("../escape.md"));
        assert!(!ColdMemoryRules::is_valid_write_name("dir/file.md"));
        assert!(!ColdMemoryRules::is_valid_write_name(""));
    }

    #[test]
    fn lookup_exact_match() {
        let names = vec!["M01.md".to_string(), "M02.md".to_string()];
        assert!(matches!(ColdMemoryRules::lookup("M01.md", &names), ColdMemoryLookup::Found(_)));
    }

    #[test]
    fn lookup_without_suffix() {
        let names = vec!["M01-device.md".to_string()];
        assert!(matches!(ColdMemoryRules::lookup("M01-device", &names), ColdMemoryLookup::Found(_)));
    }

    #[test]
    fn lookup_prefix_match() {
        let names = vec!["M01-device-shell.md".to_string()];
        assert!(matches!(ColdMemoryRules::lookup("M01", &names), ColdMemoryLookup::Found(_)));
    }

    #[test]
    fn lookup_ambiguous() {
        let names = vec!["M01-a.md".to_string(), "M01-b.md".to_string()];
        assert!(matches!(ColdMemoryRules::lookup("M01", &names), ColdMemoryLookup::Ambiguous(_)));
    }

    #[test]
    fn lookup_not_found() {
        let names = vec!["M01.md".to_string()];
        assert!(matches!(ColdMemoryRules::lookup("xyz", &names), ColdMemoryLookup::NotFound));
    }

    #[test]
    fn window_clips_to_limit() {
        let text = "a".repeat(20_000);
        let w = ColdMemoryRules::window(&text, None);
        assert_eq!(w.content.len(), READ_WINDOW_CHARS);
        assert!(w.truncated);
        assert_eq!(w.start, 0);
        assert_eq!(w.end_exclusive, READ_WINDOW_CHARS);
    }

    #[test]
    fn window_with_offset() {
        let text = "a".repeat(20_000);
        let w = ColdMemoryRules::window(&text, Some(1000));
        assert_eq!(w.start, 1000);
        assert!(w.truncated);
    }

    #[test]
    fn window_no_truncation_for_short_text() {
        let w = ColdMemoryRules::window("hello", None);
        assert!(!w.truncated);
        assert_eq!(w.content, "hello");
    }

    #[test]
    fn build_index_result_serializes() {
        let docs = vec![ColdMemoryDoc { name: "M01.md".to_string(), size_bytes: 1024 }];
        let result = build_index_result("notes/memory", &docs, None);
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["fileCount"], 1);
        assert!(parsed["note"].as_str().unwrap().contains("INDEX.md"));
    }

    #[test]
    fn build_read_result_includes_next_start_when_truncated() {
        let text = "a".repeat(20_000);
        let result = build_read_result("M01.md", &text, None);
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["truncated"], true);
        assert_eq!(parsed["nextStart"], READ_WINDOW_CHARS);
    }
}
