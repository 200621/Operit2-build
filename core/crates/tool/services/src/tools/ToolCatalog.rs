use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::Mutex;

/// Ported from rikkahub-agent-pure's ToolCatalog.kt.
///
/// On-demand tool exposure: search a tool directory and load only the schemas
/// the model actually opens. Replaces injecting every tool's schema on every turn.
///
/// Two tools: tool_search (find names, no schema) and tool_open (activate names).
/// Real schemas surface only on the model's next turn.

// --- Constants ---

pub const MAX_SEARCH_RESULTS: usize = 8;
pub const MAX_OPEN_PER_CALL: usize = 4;
pub const MAX_ACTIVE_SCHEMAS: usize = 6;
pub const MAX_SUMMARY_CHARS: usize = 180;

// --- Enums ---

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolSurfaceMode {
    Direct,
    ProgressiveCatalog,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ToolCatalogSource {
    Local,
    Mcp,
}

impl ToolCatalogSource {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Local => "LOCAL",
            Self::Mcp => "MCP",
        }
    }
}

// --- Data types ---

#[derive(Debug, Clone)]
pub struct ToolCatalogEntry {
    pub name: String,
    pub summary: String,
    pub source: ToolCatalogSource,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSearchHit {
    pub name: String,
    pub summary: String,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSearchOutcome {
    pub hits: Vec<ToolSearchHit>,
    pub total: usize,
    pub truncated: bool,
}

impl ToolSearchOutcome {
    pub fn to_json(&self) -> String {
        let results: Vec<Value> = self.hits.iter().map(|h| {
            json!({
                "name": h.name,
                "summary": h.summary.chars().take(MAX_SUMMARY_CHARS).collect::<String>(),
                "source": h.source,
            })
        }).collect();

        let mut result = json!({
            "total": self.total,
            "returned": self.hits.len(),
            "truncated": self.truncated,
            "results": results,
        });

        if self.hits.is_empty() {
            result["note"] = Value::String("No tools matched. Try different keywords, or use broader terms.".to_string());
        }

        result.to_string()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolOpenOutcome {
    pub activated: Vec<String>,
    pub already_active: Vec<String>,
    pub unknown: Vec<String>,
    pub rejected_over_cap: Vec<String>,
    pub active_count: usize,
}

impl ToolOpenOutcome {
    pub fn to_json(&self) -> String {
        let mut note = String::from("Activated schemas become callable from your NEXT turn, not this one.");
        if self.activated.is_empty() {
            if self.unknown.is_empty() && self.already_active.is_empty() && self.rejected_over_cap.is_empty() {
                note.push_str(" No tool names were provided, so nothing was activated. Call tool_search first to get exact names, then pass them in the names array.");
            } else {
                note.push_str(" Nothing was activated. Retry: run tool_search first to get exact names, then call tool_open with those names.");
            }
        }

        json!({
            "activated": self.activated,
            "alreadyActive": self.already_active,
            "unknown": self.unknown,
            "rejectedOverCap": self.rejected_over_cap,
            "activeCount": self.active_count,
            "note": note,
        })
        .to_string()
    }
}

// --- Catalog ---

pub struct ToolCatalog {
    pub entries: Vec<ToolCatalogEntry>,
    by_name: std::collections::HashMap<String, ToolCatalogEntry>,
}

impl ToolCatalog {
    pub fn new(entries: Vec<ToolCatalogEntry>) -> Self {
        let by_name = entries.iter().map(|e| (e.name.clone(), e.clone())).collect();
        Self { entries, by_name }
    }

    pub fn size(&self) -> usize {
        self.entries.len()
    }

    pub fn entry(&self, name: &str) -> Option<&ToolCatalogEntry> {
        self.by_name.get(name)
    }

    pub fn search(&self, query: &str, limit: Option<usize>) -> Vec<ToolCatalogEntry> {
        let all = self.match_all(query);
        let cap = limit.unwrap_or(MAX_SEARCH_RESULTS).clamp(1, MAX_SEARCH_RESULTS);
        all.into_iter().take(cap).collect()
    }

    /// Full, untruncated, ranked match list — the single home of the scoring logic.
    pub fn match_all(&self, query: &str) -> Vec<ToolCatalogEntry> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return Vec::new();
        }
        let tokens: Vec<&str> = q.split(|c: char| !c.is_ascii_alphanumeric())
            .filter(|s| s.len() >= 2)
            .collect();

        let mut scored: Vec<(ToolCatalogEntry, i32)> = self.entries.iter()
            .filter_map(|entry| {
                let score = match_score(&q, &tokens, entry);
                if score > 0 { Some((entry.clone(), score)) } else { None }
            })
            .collect();

        scored.sort_by(|a, b| {
            b.1.cmp(&a.1).then_with(|| a.0.name.cmp(&b.0.name))
        });

        scored.into_iter().map(|(e, _)| e).collect()
    }
}

fn match_score(query: &str, tokens: &[&str], entry: &ToolCatalogEntry) -> i32 {
    let name = entry.name.to_lowercase();
    let summary = entry.summary.to_lowercase();
    let source_name = entry.source.name().to_lowercase();
    let mut score = 0;

    if !query.is_empty() {
        if name == query {
            score += 100;
        } else if name.contains(query) {
            score += 40;
        }
    }

    for token in tokens {
        if name.contains(token) {
            score += 10;
        }
        if summary.contains(token) {
            score += 4;
        }
        if source_name.contains(token) {
            score += 2;
        }
    }

    score
}

// --- Activation state ---

pub struct ToolActivationState {
    active_names: Mutex<Vec<String>>,
}

impl ToolActivationState {
    pub fn new() -> Self {
        Self {
            active_names: Mutex::new(Vec::new()),
        }
    }

    pub fn active(&self) -> HashSet<String> {
        let names = self.active_names.lock().unwrap();
        names.iter().cloned().collect()
    }

    pub fn clear(&self) {
        self.active_names.lock().unwrap().clear();
    }

    pub fn retain(&self, known_names: &HashSet<String>) {
        let mut names = self.active_names.lock().unwrap();
        names.retain(|n| known_names.contains(n));
    }

    pub fn activate(&self, catalog: &ToolCatalog, names: &[String]) -> ToolOpenOutcome {
        let mut active = self.active_names.lock().unwrap();
        let mut activated = Vec::new();
        let mut already_active = Vec::new();
        let mut unknown = Vec::new();
        let mut rejected_over_cap = Vec::new();
        let mut opened_this_call = 0usize;

        for name in names {
            if catalog.entry(name).is_none() {
                unknown.push(name.clone());
                continue;
            }
            if active.contains(name) {
                already_active.push(name.clone());
                continue;
            }
            if opened_this_call >= MAX_OPEN_PER_CALL {
                rejected_over_cap.push(name.clone());
                continue;
            }
            if active.len() >= MAX_ACTIVE_SCHEMAS {
                rejected_over_cap.push(name.clone());
                continue;
            }
            active.push(name.clone());
            activated.push(name.clone());
            opened_this_call += 1;
        }

        let active_count = active.len();
        ToolOpenOutcome {
            activated,
            already_active,
            unknown,
            rejected_over_cap,
            active_count,
        }
    }
}

impl Default for ToolActivationState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(name: &str, summary: &str, source: ToolCatalogSource) -> ToolCatalogEntry {
        ToolCatalogEntry {
            name: name.to_string(),
            summary: summary.to_string(),
            source,
        }
    }

    fn make_catalog() -> ToolCatalog {
        ToolCatalog::new(vec![
            make_entry("read_file", "Read a file from the filesystem", ToolCatalogSource::Local),
            make_entry("write_file", "Write content to a file", ToolCatalogSource::Local),
            make_entry("web_fetch", "Fetch a URL and return content", ToolCatalogSource::Mcp),
            make_entry("terminal_exec", "Execute a terminal command", ToolCatalogSource::Local),
        ])
    }

    #[test]
    fn search_exact_name_scores_highest() {
        let catalog = make_catalog();
        let results = catalog.match_all("read_file");
        assert_eq!(results[0].name, "read_file");
    }

    #[test]
    fn search_partial_match() {
        let catalog = make_catalog();
        let results = catalog.match_all("file");
        assert!(results.iter().any(|e| e.name == "read_file"));
        assert!(results.iter().any(|e| e.name == "write_file"));
    }

    #[test]
    fn search_empty_query_returns_empty() {
        let catalog = make_catalog();
        assert!(catalog.match_all("").is_empty());
    }

    #[test]
    fn search_truncates_to_limit() {
        let catalog = make_catalog();
        let results = catalog.search("file", None);
        assert!(results.len() <= MAX_SEARCH_RESULTS);
    }

    #[test]
    fn activation_activates_known_tool() {
        let catalog = make_catalog();
        let state = ToolActivationState::new();
        let outcome = state.activate(&catalog, &["read_file".to_string()]);
        assert_eq!(outcome.activated, vec!["read_file"]);
        assert_eq!(outcome.active_count, 1);
    }

    #[test]
    fn activation_reports_unknown() {
        let catalog = make_catalog();
        let state = ToolActivationState::new();
        let outcome = state.activate(&catalog, &["nonexistent".to_string()]);
        assert!(outcome.activated.is_empty());
        assert_eq!(outcome.unknown, vec!["nonexistent"]);
    }

    #[test]
    fn activation_reports_already_active() {
        let catalog = make_catalog();
        let state = ToolActivationState::new();
        state.activate(&catalog, &["read_file".to_string()]);
        let outcome = state.activate(&catalog, &["read_file".to_string()]);
        assert!(outcome.activated.is_empty());
        assert_eq!(outcome.already_active, vec!["read_file"]);
    }

    #[test]
    fn activation_respects_cap() {
        let catalog = make_catalog();
        let state = ToolActivationState::new();
        let names: Vec<String> = (0..10).map(|i| format!("tool_{}", i)).collect();
        let entries: Vec<ToolCatalogEntry> = names.iter().map(|n| make_entry(n, "test", ToolCatalogSource::Local)).collect();
        let big_catalog = ToolCatalog::new(entries);
        let many: Vec<String> = (0..8).map(|i| format!("tool_{}", i)).collect();
        let outcome = state.activate(&big_catalog, &many);
        assert_eq!(outcome.activated.len(), MAX_OPEN_PER_CALL);
        assert!(!outcome.rejected_over_cap.is_empty());
    }

    #[test]
    fn search_outcome_serializes() {
        let outcome = ToolSearchOutcome {
            hits: vec![ToolSearchHit {
                name: "read_file".to_string(),
                summary: "Read a file".to_string(),
                source: "LOCAL".to_string(),
            }],
            total: 1,
            truncated: false,
        };
        let json = outcome.to_json();
        let parsed: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["total"], 1);
        assert_eq!(parsed["results"][0]["name"], "read_file");
    }

    #[test]
    fn open_outcome_serializes_with_note() {
        let outcome = ToolOpenOutcome {
            activated: vec!["read_file".to_string()],
            already_active: vec![],
            unknown: vec![],
            rejected_over_cap: vec![],
            active_count: 1,
        };
        let json = outcome.to_json();
        let parsed: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["activated"][0], "read_file");
        assert!(parsed["note"].as_str().unwrap().contains("NEXT turn"));
    }
}
