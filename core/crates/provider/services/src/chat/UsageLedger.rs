use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

/// Ported from rikkahub-agent-pure's data/usage/ package (22 files).
///
/// Usage ledger: per-call attribution by purpose, cost frozen at write time,
/// orchestration budgets that are enforced before dispatch, price tables,
/// CSV/JSON export, and the orchestration tree.
///
/// Metadata only — never message content. Separate from the chat DB.

// ========== UsagePurpose (from UsagePurpose.kt) ==========

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum UsagePurpose {
    Main,
    ToolLoop,
    Compaction,
    Title,
    Suggestion,
    MemoryExtract,
    SubAgent,
    Cron,
    Workflow,
    SkillTest,
    Translation,
    Unknown,
}

impl UsagePurpose {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Main => "MAIN",
            Self::ToolLoop => "TOOL_LOOP",
            Self::Compaction => "COMPACTION",
            Self::Title => "TITLE",
            Self::Suggestion => "SUGGESTION",
            Self::MemoryExtract => "MEMORY_EXTRACT",
            Self::SubAgent => "SUBAGENT",
            Self::Cron => "CRON",
            Self::Workflow => "WORKFLOW",
            Self::SkillTest => "SKILL_TEST",
            Self::Translation => "TRANSLATION",
            Self::Unknown => "UNKNOWN",
        }
    }

    pub fn from_name(s: &str) -> Self {
        match s {
            "MAIN" => Self::Main,
            "TOOL_LOOP" => Self::ToolLoop,
            "COMPACTION" => Self::Compaction,
            "TITLE" => Self::Title,
            "SUGGESTION" => Self::Suggestion,
            "MEMORY_EXTRACT" => Self::MemoryExtract,
            "SUBAGENT" => Self::SubAgent,
            "CRON" => Self::Cron,
            "WORKFLOW" => Self::Workflow,
            "SKILL_TEST" => Self::SkillTest,
            "TRANSLATION" => Self::Translation,
            _ => Self::Unknown,
        }
    }
}

// ========== UsageRecordEntity (from UsageRecordEntity.kt) ==========

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageRecord {
    pub id: String,
    pub created_at_ms: i64,
    pub purpose: String,
    pub provider_id: Option<String>,
    pub model_id: Option<String>,
    pub assistant_id: Option<String>,
    pub conversation_id: Option<String>,
    pub run_id: Option<String>,
    pub parent_run_id: Option<String>,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
    pub cached_tokens: i64,
    pub cached_tokens_reported: bool,
    pub cache_miss_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub reasoning_tokens: Option<i64>,
    pub provider_cost_usd: Option<f64>,
    pub cost_micros: Option<i64>,
    pub price_version_id: Option<String>,
    pub streaming: bool,
    pub latency_ms: Option<i64>,
}

// ========== UsageCallContext (from UsageCallContext.kt) ==========

#[derive(Debug, Clone)]
pub struct UsageCallContext {
    pub purpose: UsagePurpose,
    pub assistant_id: Option<String>,
    pub conversation_id: Option<String>,
    pub run_id: Option<String>,
    pub parent_run_id: Option<String>,
}

// ========== OrchestrationBudget (from OrchestrationBudget.kt) ==========

pub struct OrchestrationBudget;

impl OrchestrationBudget {
    pub fn effective_budget(assistant_budget: Option<i64>, expert_budget: Option<i64>) -> Option<i64> {
        expert_budget.or(assistant_budget)
    }

    pub fn exceeded(used_tokens: i64, budget: Option<i64>) -> bool {
        budget.map_or(false, |b| used_tokens >= b)
    }

    pub fn remaining(used_tokens: i64, budget: Option<i64>) -> Option<i64> {
        budget.map(|b| (b - used_tokens).max(0))
    }
}

// ========== OrchestrationGate (from OrchestrationGate.kt) ==========

pub struct OrchestrationGate;

#[derive(Debug, Clone)]
pub enum GateDecision {
    Allow,
    Refuse { used_tokens: i64, budget_tokens: i64 },
}

impl GateDecision {
    pub fn over_by_tokens(&self) -> i64 {
        match self {
            Self::Allow => 0,
            Self::Refuse { used_tokens, budget_tokens } => (*used_tokens - *budget_tokens).max(0),
        }
    }
}

impl OrchestrationGate {
    pub const ERROR_CODE: &'static str = "budget_exceeded";

    pub fn decide(used_tokens: i64, budget: Option<i64>) -> GateDecision {
        let ceiling = match budget {
            None => return GateDecision::Allow,
            Some(b) => b,
        };
        if !OrchestrationBudget::exceeded(used_tokens, Some(ceiling)) {
            return GateDecision::Allow;
        }
        GateDecision::Refuse { used_tokens, budget_tokens: ceiling }
    }

    pub fn refusal_detail(decision: &GateDecision) -> Option<String> {
        match decision {
            GateDecision::Allow => None,
            GateDecision::Refuse { used_tokens, budget_tokens } => Some(format!(
                "this conversation has already spent {} of its {}-token orchestration budget \
                 on sub-agent runs ({} over the ceiling), so no further dispatch is allowed. \
                 Raise the assistant's per-orchestration token limit (or the expert's own token \
                 budget), or do the work inline instead of dispatching.",
                used_tokens, budget_tokens, decision.over_by_tokens()
            )),
        }
    }

    pub fn refusal_envelope(decision: &GateDecision) -> Option<String> {
        let detail = Self::refusal_detail(decision)?;
        Some(json!({
            "error": Self::ERROR_CODE,
            "detail": detail,
        }).to_string())
    }
}

// ========== PriceTable (from UsagePriceTable.kt — simplified) ==========

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceWindowSpec {
    pub start_minute: i32,
    pub end_minute: i32,
    pub zone_offset_minutes: i32,
    pub days_of_week: Vec<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceEntrySpec {
    pub provider_name: String,
    pub model_id: String,
    pub input_per_million: Option<f64>,
    pub output_per_million: Option<f64>,
    pub cache_hit_per_million: Option<f64>,
    pub cache_write_per_million: Option<f64>,
    pub off_peak_input_per_million: Option<f64>,
    pub off_peak_output_per_million: Option<f64>,
    pub off_peak_cache_hit_per_million: Option<f64>,
    pub off_peak_cache_write_per_million: Option<f64>,
    pub peak_windows: Vec<PriceWindowSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PriceTableSpec {
    pub version: Option<String>,
    pub note: Option<String>,
    pub entries: Vec<PriceEntrySpec>,
}

#[derive(Debug, Clone)]
pub struct RejectedEntrySpec {
    pub index: usize,
    pub provider_name: String,
    pub model_id: String,
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct PriceTableValidation {
    pub accepted: Vec<PriceEntrySpec>,
    pub rejected: Vec<RejectedEntrySpec>,
}

impl PriceTableValidation {
    pub fn is_clean(&self) -> bool {
        self.rejected.is_empty()
    }
}

pub struct UsagePriceTable;

impl UsagePriceTable {
    pub const MAX_ENTRIES: usize = 200;

    pub fn validate(spec: &PriceTableSpec) -> PriceTableValidation {
        let mut accepted = Vec::new();
        let mut rejected = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

        for (index, entry) in spec.entries.iter().enumerate() {
            let provider = entry.provider_name.trim().to_string();
            let model = entry.model_id.trim().to_string();
            let reason = if index >= Self::MAX_ENTRIES {
                format!("table exceeds {} entries", Self::MAX_ENTRIES)
            } else if provider.is_empty() {
                "blank provider name".to_string()
            } else if model.is_empty() {
                "blank model id".to_string()
            } else if !seen.insert(format!("{}\u{0000}{}", provider, model)) {
                format!("duplicate entry for {} / {}", provider, model)
            } else {
                Self::price_problem(entry).or_else(|| Self::window_problem(&entry.peak_windows))
            };

            if reason.is_none() {
                let mut clean = entry.clone();
                clean.provider_name = provider;
                clean.model_id = model;
                clean.peak_windows = Self::normalize_windows(&entry.peak_windows);
                accepted.push(clean);
            } else {
                rejected.push(RejectedEntrySpec {
                    index,
                    provider_name: provider,
                    model_id: model,
                    reason: reason.unwrap(),
                });
            }
        }
        PriceTableValidation { accepted, rejected }
    }

    fn price_problem(entry: &PriceEntrySpec) -> Option<String> {
        let named: Vec<(&str, Option<f64>)> = vec![
            ("inputPerMillion", entry.input_per_million),
            ("outputPerMillion", entry.output_per_million),
            ("cacheHitPerMillion", entry.cache_hit_per_million),
            ("cacheWritePerMillion", entry.cache_write_per_million),
            ("offPeakInputPerMillion", entry.off_peak_input_per_million),
            ("offPeakOutputPerMillion", entry.off_peak_output_per_million),
            ("offPeakCacheHitPerMillion", entry.off_peak_cache_hit_per_million),
            ("offPeakCacheWritePerMillion", entry.off_peak_cache_write_per_million),
        ];
        let mut given = false;
        for (name, value) in &named {
            if let Some(v) = value {
                given = true;
                if !v.is_finite() {
                    return Some(format!("{} is not a finite number", name));
                }
                if *v < 0.0 {
                    return Some(format!("{} is negative", name));
                }
            }
        }
        if given { None } else { Some("no rate given".to_string()) }
    }

    fn window_problem(windows: &[PriceWindowSpec]) -> Option<String> {
        for (index, w) in windows.iter().enumerate() {
            if !(0..=1439).contains(&w.start_minute) {
                return Some(format!("window[{}] startMinute must be 0..1439", index));
            }
            if !(0..=1439).contains(&w.end_minute) {
                return Some(format!("window[{}] endMinute must be 0..1439", index));
            }
            if w.start_minute == w.end_minute {
                return Some(format!("window[{}] start and end are the same minute", index));
            }
            if !(-720..=840).contains(&w.zone_offset_minutes) {
                return Some(format!("window[{}] zoneOffsetMinutes must be -720..840", index));
            }
            if w.days_of_week.iter().any(|d| !(1..=7).contains(d)) {
                return Some(format!("window[{}] daysOfWeek is ISO 1..7 (Mon..Sun)", index));
            }
        }
        None
    }

    fn normalize_windows(windows: &[PriceWindowSpec]) -> Vec<PriceWindowSpec> {
        let mut result: Vec<PriceWindowSpec> = windows.iter().map(|w| {
            let mut days: Vec<i32> = w.days_of_week.iter().copied().collect();
            days.sort();
            days.dedup();
            PriceWindowSpec {
                start_minute: w.start_minute,
                end_minute: w.end_minute,
                zone_offset_minutes: w.zone_offset_minutes,
                days_of_week: days,
            }
        }).collect();
        result.sort_by(|a, b| {
            a.zone_offset_minutes.cmp(&b.zone_offset_minutes)
                .then_with(|| a.start_minute.cmp(&b.start_minute))
                .then_with(|| a.end_minute.cmp(&b.end_minute))
        });
        result
    }

    pub fn compute_cost_micros(
        entry: &PriceEntrySpec,
        input_tokens: i64,
        output_tokens: i64,
        cached_tokens: i64,
    ) -> Option<i64> {
        let input_cost = entry.input_per_million
            .map(|p| (input_tokens as f64 * p / 1_000_000.0 * 1_000_000.0) as i64)
            .unwrap_or(0);
        let output_cost = entry.output_per_million
            .map(|p| (output_tokens as f64 * p / 1_000_000.0 * 1_000_000.0) as i64)
            .unwrap_or(0);
        let cache_cost = entry.cache_hit_per_million
            .map(|p| (cached_tokens as f64 * p / 1_000_000.0 * 1_000_000.0) as i64)
            .unwrap_or(0);
        if input_cost == 0 && output_cost == 0 && cache_cost == 0 {
            return None;
        }
        Some(input_cost + output_cost + cache_cost)
    }
}

// ========== UsageExport (from UsageExport.kt) ==========

pub struct UsageExport;

impl UsageExport {
    pub fn csv_header() -> Vec<&'static str> {
        vec![
            "id", "created_at_ms", "purpose", "provider_id", "model_id",
            "assistant_id", "conversation_id", "run_id", "parent_run_id",
            "input_tokens", "output_tokens", "total_tokens", "cached_tokens",
            "cached_tokens_reported", "cache_miss_tokens", "cache_write_tokens",
            "reasoning_tokens", "provider_cost_usd", "cost_micros",
            "price_version_id", "streaming", "latency_ms",
        ]
    }

    pub fn to_csv(records: &[UsageRecord]) -> String {
        let header = Self::csv_header().join(",");
        let mut lines = vec![header];
        for r in records {
            let row = vec![
                r.id.clone(),
                r.created_at_ms.to_string(),
                r.purpose.clone(),
                r.provider_id.clone().unwrap_or_default(),
                r.model_id.clone().unwrap_or_default(),
                r.assistant_id.clone().unwrap_or_default(),
                r.conversation_id.clone().unwrap_or_default(),
                r.run_id.clone().unwrap_or_default(),
                r.parent_run_id.clone().unwrap_or_default(),
                r.input_tokens.to_string(),
                r.output_tokens.to_string(),
                r.total_tokens.to_string(),
                r.cached_tokens.to_string(),
                r.cached_tokens_reported.to_string(),
                r.cache_miss_tokens.map(|v| v.to_string()).unwrap_or_default(),
                r.cache_write_tokens.map(|v| v.to_string()).unwrap_or_default(),
                r.reasoning_tokens.map(|v| v.to_string()).unwrap_or_default(),
                r.provider_cost_usd.map(|v| v.to_string()).unwrap_or_default(),
                r.cost_micros.map(|v| v.to_string()).unwrap_or_default(),
                r.price_version_id.clone().unwrap_or_default(),
                r.streaming.to_string(),
                r.latency_ms.map(|v| v.to_string()).unwrap_or_default(),
            ];
            lines.push(row.join(","));
        }
        lines.join("\n")
    }

    pub fn to_json(records: &[UsageRecord]) -> String {
        serde_json::to_string_pretty(records).unwrap_or_else(|_| "[]".to_string())
    }
}

// ========== OrchestrationTree (from OrchestrationTree.kt) ==========

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestrationNode {
    pub run_id: String,
    pub label: String,
    pub status: String,
    pub started_at_ms: i64,
    pub finished_at_ms: Option<i64>,
    pub call_count: usize,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub provider_cost_usd: Option<f64>,
    pub cost_micros: Option<i64>,
}

impl OrchestrationNode {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens
    }
    pub fn has_ledger_rows(&self) -> bool {
        self.call_count > 0
    }
    pub fn is_running(&self) -> bool {
        matches!(self.status.as_str(), "running" | "pending" | "started")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestrationTree {
    pub parent_conversation_id: Option<String>,
    pub children: Vec<OrchestrationNode>,
    pub budget: Option<i64>,
}

impl OrchestrationTree {
    pub fn child_count(&self) -> usize {
        self.children.len()
    }
    pub fn call_count(&self) -> usize {
        self.children.iter().map(|c| c.call_count).sum()
    }
    pub fn total_tokens(&self) -> i64 {
        self.children.iter().map(|c| c.total_tokens()).sum()
    }
    pub fn has_running_child(&self) -> bool {
        self.children.iter().any(|c| c.is_running())
    }
    pub fn has_budget(&self) -> bool {
        self.budget.is_some()
    }
    pub fn remaining_budget(&self) -> Option<i64> {
        OrchestrationBudget::remaining(self.total_tokens(), self.budget)
    }
}

// ========== UsageLedger (in-memory store, from UsageLedger.kt) ==========

pub struct UsageLedger {
    records: Mutex<Vec<UsageRecord>>,
}

impl UsageLedger {
    pub fn new() -> Self {
        Self { records: Mutex::new(Vec::new()) }
    }

    pub fn record(&self, record: UsageRecord) {
        self.records.lock().unwrap().push(record);
    }

    pub fn tokens_for_orchestration(&self, parent_run_id: &str) -> i64 {
        self.records.lock().unwrap()
            .iter()
            .filter(|r| r.parent_run_id.as_deref() == Some(parent_run_id))
            .map(|r| r.total_tokens)
            .sum()
    }

    pub fn records_since(&self, since_ms: i64) -> Vec<UsageRecord> {
        self.records.lock().unwrap()
            .iter()
            .filter(|r| r.created_at_ms >= since_ms)
            .cloned()
            .collect()
    }

    pub fn prune(&self, before_ms: i64) -> usize {
        let mut records = self.records.lock().unwrap();
        let before = records.len();
        records.retain(|r| r.created_at_ms >= before_ms);
        before - records.len()
    }

    pub fn all_records(&self) -> Vec<UsageRecord> {
        self.records.lock().unwrap().clone()
    }

    pub fn stats_by_purpose(&self) -> HashMap<String, (i64, i64)> {
        let records = self.records.lock().unwrap();
        let mut map: HashMap<String, (i64, i64)> = HashMap::new();
        for r in records.iter() {
            let entry = map.entry(r.purpose.clone()).or_insert((0, 0));
            entry.0 += r.total_tokens;
            entry.1 += 1;
        }
        map
    }
}

impl Default for UsageLedger {
    fn default() -> Self {
        Self::new()
    }
}

// ========== UsageCallRecorder (from UsageCallRecorder.kt) ==========

pub struct UsageCallRecorder;

#[derive(Debug)]
pub enum RecorderOutcome {
    Recorded(UsageRecord),
    NoUsage,
    Failed(String),
}

impl UsageCallRecorder {
    pub fn record(
        ledger: &UsageLedger,
        input_tokens: Option<i64>,
        output_tokens: Option<i64>,
        cached_tokens: Option<i64>,
        cached_tokens_reported: bool,
        context: &UsageCallContext,
        provider_name: Option<&str>,
        model_id: Option<&str>,
        cost_micros: Option<i64>,
        price_version_id: Option<&str>,
        streaming: bool,
        latency_ms: Option<i64>,
    ) -> RecorderOutcome {
        let input = input_tokens.unwrap_or(0);
        let output = output_tokens.unwrap_or(0);
        if input == 0 && output == 0 {
            return RecorderOutcome::NoUsage;
        }
        let cached = cached_tokens.unwrap_or(0);
        let record = UsageRecord {
            id: format!("{}", chrono::Utc::now().timestamp_millis()),
            created_at_ms: chrono::Utc::now().timestamp_millis(),
            purpose: context.purpose.name().to_string(),
            provider_id: provider_name.map(|s| s.to_string()),
            model_id: model_id.map(|s| s.to_string()),
            assistant_id: context.assistant_id.clone(),
            conversation_id: context.conversation_id.clone(),
            run_id: context.run_id.clone(),
            parent_run_id: context.parent_run_id.clone(),
            input_tokens: input,
            output_tokens: output,
            total_tokens: input + output,
            cached_tokens: cached,
            cached_tokens_reported,
            cache_miss_tokens: if cached_tokens_reported { Some(input - cached) } else { None },
            cache_write_tokens: None,
            reasoning_tokens: None,
            provider_cost_usd: None,
            cost_micros,
            price_version_id: price_version_id.map(|s| s.to_string()),
            streaming,
            latency_ms,
        };
        ledger.record(record.clone());
        RecorderOutcome::Recorded(record)
    }
}

// ========== TokenBudgetTracker (from costguards/TokenBudgetTracker.kt) ==========

pub struct TokenBudgetTracker {
    used: Mutex<i64>,
    budget: Option<i64>,
}

impl TokenBudgetTracker {
    pub fn new(budget: Option<i64>) -> Self {
        Self { used: Mutex::new(0), budget }
    }

    pub fn add(&self, tokens: i64) {
        *self.used.lock().unwrap() += tokens;
    }

    pub fn used(&self) -> i64 {
        *self.used.lock().unwrap()
    }

    pub fn remaining(&self) -> Option<i64> {
        OrchestrationBudget::remaining(self.used(), self.budget)
    }

    pub fn exceeded(&self) -> bool {
        OrchestrationBudget::exceeded(self.used(), self.budget)
    }
}

// ========== UsageTools (tool result builders, from UsageTools.kt) ==========

pub fn build_stats_result(ledger: &UsageLedger) -> String {
    let stats = ledger.stats_by_purpose();
    let mut entries: Vec<Value> = Vec::new();
    for (purpose, (tokens, count)) in &stats {
        entries.push(json!({
            "purpose": purpose,
            "totalTokens": tokens,
            "callCount": count,
        }));
    }
    json!({
        "totalCalls": stats.values().map(|(_, c)| *c as usize).sum::<usize>(),
        "totalTokens": stats.values().map(|(t, _)| t).sum::<i64>(),
        "byPurpose": entries,
    }).to_string()
}

pub fn build_export_result(csv: &str, json: &str, format: &str) -> String {
    match format {
        "csv" => json!({ "format": "csv", "content": csv }).to_string(),
        "json" => json!({ "format": "json", "content": json }).to_string(),
        _ => json!({ "format": "both", "csv": csv, "json": json }).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn purpose_round_trip() {
        for p in [UsagePurpose::Main, UsagePurpose::ToolLoop, UsagePurpose::SubAgent] {
            assert_eq!(UsagePurpose::from_name(p.name()), p);
        }
    }

    #[test]
    fn budget_effective_prefers_expert() {
        assert_eq!(OrchestrationBudget::effective_budget(Some(1000), Some(500)), Some(500));
        assert_eq!(OrchestrationBudget::effective_budget(Some(1000), None), Some(1000));
        assert_eq!(OrchestrationBudget::effective_budget(None, None), None);
    }

    #[test]
    fn budget_exceeded_at_ceiling() {
        assert!(OrchestrationBudget::exceeded(1000, Some(1000)));
        assert!(!OrchestrationBudget::exceeded(999, Some(1000)));
        assert!(!OrchestrationBudget::exceeded(i64::MAX, None));
    }

    #[test]
    fn budget_remaining_clamps_at_zero() {
        assert_eq!(OrchestrationBudget::remaining(1500, Some(1000)), Some(0));
        assert_eq!(OrchestrationBudget::remaining(500, Some(1000)), Some(500));
        assert_eq!(OrchestrationBudget::remaining(0, None), None);
    }

    #[test]
    fn gate_allows_when_no_budget() {
        assert!(matches!(OrchestrationGate::decide(i64::MAX, None), GateDecision::Allow));
    }

    #[test]
    fn gate_refuses_when_exceeded() {
        let d = OrchestrationGate::decide(2000, Some(1000));
        assert!(matches!(d, GateDecision::Refuse { .. }));
        assert_eq!(d.over_by_tokens(), 1000);
    }

    #[test]
    fn gate_refusal_envelope_has_error_code() {
        let d = OrchestrationGate::decide(2000, Some(1000));
        let env = OrchestrationGate::refusal_envelope(&d).unwrap();
        let parsed: Value = serde_json::from_str(&env).unwrap();
        assert_eq!(parsed["error"], "budget_exceeded");
    }

    #[test]
    fn price_table_validates() {
        let spec = PriceTableSpec {
            version: None,
            note: None,
            entries: vec![
                PriceEntrySpec {
                    provider_name: "OpenAI".to_string(),
                    model_id: "gpt-4".to_string(),
                    input_per_million: Some(30.0),
                    output_per_million: Some(60.0),
                    cache_hit_per_million: None,
                    cache_write_per_million: None,
                    off_peak_input_per_million: None,
                    off_peak_output_per_million: None,
                    off_peak_cache_hit_per_million: None,
                    off_peak_cache_write_per_million: None,
                    peak_windows: vec![],
                },
            ],
        };
        let val = UsagePriceTable::validate(&spec);
        assert!(val.is_clean());
        assert_eq!(val.accepted.len(), 1);
    }

    #[test]
    fn price_table_rejects_blank_provider() {
        let spec = PriceTableSpec {
            version: None,
            note: None,
            entries: vec![PriceEntrySpec {
                provider_name: "  ".to_string(),
                model_id: "x".to_string(),
                input_per_million: Some(10.0),
                output_per_million: None,
                cache_hit_per_million: None,
                cache_write_per_million: None,
                off_peak_input_per_million: None,
                off_peak_output_per_million: None,
                off_peak_cache_hit_per_million: None,
                off_peak_cache_write_per_million: None,
                peak_windows: vec![],
            }],
        };
        let val = UsagePriceTable::validate(&spec);
        assert!(!val.is_clean());
        assert_eq!(val.rejected[0].reason, "blank provider name");
    }

    #[test]
    fn price_table_rejects_negative_rate() {
        let spec = PriceTableSpec {
            version: None,
            note: None,
            entries: vec![PriceEntrySpec {
                provider_name: "X".to_string(),
                model_id: "y".to_string(),
                input_per_million: Some(-5.0),
                output_per_million: None,
                cache_hit_per_million: None,
                cache_write_per_million: None,
                off_peak_input_per_million: None,
                off_peak_output_per_million: None,
                off_peak_cache_hit_per_million: None,
                off_peak_cache_write_per_million: None,
                peak_windows: vec![],
            }],
        };
        let val = UsagePriceTable::validate(&spec);
        assert!(!val.is_clean());
        assert!(val.rejected[0].reason.contains("negative"));
    }

    #[test]
    fn cost_computation() {
        let entry = PriceEntrySpec {
            provider_name: "X".to_string(),
            model_id: "y".to_string(),
            input_per_million: Some(30.0),
            output_per_million: Some(60.0),
            cache_hit_per_million: Some(3.0),
            cache_write_per_million: None,
            off_peak_input_per_million: None,
            off_peak_output_per_million: None,
            off_peak_cache_hit_per_million: None,
            off_peak_cache_write_per_million: None,
            peak_windows: vec![],
        };
        let cost = UsagePriceTable::compute_cost_micros(&entry, 1_000_000, 500_000, 100_000);
        assert!(cost.is_some());
        assert!(cost.unwrap() > 0);
    }

    #[test]
    fn export_csv_has_header() {
        let csv = UsageExport::to_csv(&[]);
        assert!(csv.starts_with("id,created_at_ms,purpose"));
    }

    #[test]
    fn export_json_empty() {
        let json = UsageExport::to_json(&[]);
        assert_eq!(json, "[]");
    }

    #[test]
    fn ledger_records_and_queries() {
        let ledger = UsageLedger::new();
        ledger.record(UsageRecord {
            id: "r1".to_string(),
            created_at_ms: 1000,
            purpose: "MAIN".to_string(),
            provider_id: None,
            model_id: None,
            assistant_id: None,
            conversation_id: Some("c1".to_string()),
            run_id: Some("run1".to_string()),
            parent_run_id: Some("parent1".to_string()),
            input_tokens: 100,
            output_tokens: 50,
            total_tokens: 150,
            cached_tokens: 0,
            cached_tokens_reported: false,
            cache_miss_tokens: None,
            cache_write_tokens: None,
            reasoning_tokens: None,
            provider_cost_usd: None,
            cost_micros: None,
            price_version_id: None,
            streaming: false,
            latency_ms: None,
        });
        assert_eq!(ledger.tokens_for_orchestration("parent1"), 150);
        assert_eq!(ledger.records_since(0).len(), 1);
        assert_eq!(ledger.records_since(2000).len(), 0);
    }

    #[test]
    fn ledger_prune_removes_old() {
        let ledger = UsageLedger::new();
        ledger.record(UsageRecord {
            id: "old".to_string(), created_at_ms: 100, purpose: "MAIN".to_string(),
            provider_id: None, model_id: None, assistant_id: None, conversation_id: None,
            run_id: None, parent_run_id: None, input_tokens: 10, output_tokens: 5,
            total_tokens: 15, cached_tokens: 0, cached_tokens_reported: false,
            cache_miss_tokens: None, cache_write_tokens: None, reasoning_tokens: None,
            provider_cost_usd: None, cost_micros: None, price_version_id: None,
            streaming: false, latency_ms: None,
        });
        let removed = ledger.prune(500);
        assert_eq!(removed, 1);
        assert_eq!(ledger.all_records().len(), 0);
    }

    #[test]
    fn recorder_skips_zero_usage() {
        let ledger = UsageLedger::new();
        let ctx = UsageCallContext {
            purpose: UsagePurpose::Main,
            assistant_id: None,
            conversation_id: None,
            run_id: None,
            parent_run_id: None,
        };
        let outcome = UsageCallRecorder::record(
            &ledger, None, None, None, false, &ctx, None, None, None, None, false, None,
        );
        assert!(matches!(outcome, RecorderOutcome::NoUsage));
    }

    #[test]
    fn recorder_writes_nonzero() {
        let ledger = UsageLedger::new();
        let ctx = UsageCallContext {
            purpose: UsagePurpose::ToolLoop,
            assistant_id: Some("a1".to_string()),
            conversation_id: Some("c1".to_string()),
            run_id: None,
            parent_run_id: None,
        };
        let outcome = UsageCallRecorder::record(
            &ledger, Some(500), Some(200), None, false, &ctx,
            Some("OpenAI"), Some("gpt-4"), None, None, true, Some(1234),
        );
        assert!(matches!(outcome, RecorderOutcome::Recorded(_)));
        assert_eq!(ledger.all_records().len(), 1);
    }

    #[test]
    fn token_budget_tracker_tracks() {
        let tracker = TokenBudgetTracker::new(Some(1000));
        tracker.add(600);
        assert!(!tracker.exceeded());
        assert_eq!(tracker.remaining(), Some(400));
        tracker.add(400);
        assert!(tracker.exceeded());
        assert_eq!(tracker.remaining(), Some(0));
    }

    #[test]
    fn stats_result_serializes() {
        let ledger = UsageLedger::new();
        ledger.record(UsageRecord {
            id: "r1".to_string(), created_at_ms: 1000, purpose: "MAIN".to_string(),
            provider_id: None, model_id: None, assistant_id: None, conversation_id: None,
            run_id: None, parent_run_id: None, input_tokens: 100, output_tokens: 50,
            total_tokens: 150, cached_tokens: 0, cached_tokens_reported: false,
            cache_miss_tokens: None, cache_write_tokens: None, reasoning_tokens: None,
            provider_cost_usd: None, cost_micros: None, price_version_id: None,
            streaming: false, latency_ms: None,
        });
        let result = build_stats_result(&ledger);
        let parsed: Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["totalCalls"], 1);
        assert_eq!(parsed["totalTokens"], 150);
    }

    #[test]
    fn orchestration_tree_sums() {
        let tree = OrchestrationTree {
            parent_conversation_id: Some("c1".to_string()),
            children: vec![
                OrchestrationNode {
                    run_id: "r1".to_string(), label: "agent1".to_string(),
                    status: "completed".to_string(), started_at_ms: 1000,
                    finished_at_ms: Some(2000), call_count: 3,
                    input_tokens: 500, output_tokens: 200,
                    provider_cost_usd: Some(0.05), cost_micros: Some(50000),
                },
                OrchestrationNode {
                    run_id: "r2".to_string(), label: "agent2".to_string(),
                    status: "running".to_string(), started_at_ms: 3000,
                    finished_at_ms: None, call_count: 1,
                    input_tokens: 100, output_tokens: 50,
                    provider_cost_usd: None, cost_micros: None,
                },
            ],
            budget: Some(1000),
        };
        assert_eq!(tree.child_count(), 2);
        assert_eq!(tree.call_count(), 4);
        assert_eq!(tree.total_tokens(), 850);
        assert!(tree.has_running_child());
        assert!(tree.has_budget());
        assert_eq!(tree.remaining_budget(), Some(150));
    }
}
