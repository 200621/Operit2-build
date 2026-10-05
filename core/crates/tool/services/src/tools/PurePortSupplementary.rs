use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// Ported from rikkahub-agent-pure — consolidated supplementary modules.
///
/// Phase 1 补全: ToolExecutionRetryPolicy, ContextCompactionPlanner, CompactionTools
/// Phase 2 补全: ToolApprovalDefaults, ToolApprovalAllowList, HeadlessConversations
/// Phase 4 补全: LocalToolFilter, ToolSurfaceResolver, ToolInvocationContext

// ============================================================
// Phase 1 补全: ToolExecutionRetryPolicy (from ToolExecutionRetryPolicy.kt)
// ============================================================

/// Error codes that indicate a transient failure worth retrying.
pub const TRANSIENT_ERROR_CODES: &[&str] = &[
    "timeout",
    "rate_limited",
    "server_error",
    "connection_reset",
    "dns_failure",
];

/// Maximum retry attempts for a transient tool failure.
pub const MAX_RETRY_ATTEMPTS: u32 = 3;

/// Base delay between retries (exponential backoff).
pub const RETRY_BASE_DELAY_MS: u64 = 500;

/// Tools that may be safely retried (idempotent operations).
pub const IDEMPOTENT_TOOL_NAMES: &[&str] = &[
    "read_file",
    "list_files",
    "web_fetch",
    "query_memory",
    "get_memory_by_title",
    "memory_index",
    "memory_read",
    "tool_search",
    "usage_stats",
    "usage_export",
    "battery",
    "wifi_info",
    "take_screenshot",
    "get_location",
];

/// Tools that must NEVER be retried.
pub const NO_RETRY_TOOL_NAMES: &[&str] = &[
    "send_sms",
    "send_email_intent",
    "write_file",
    "create_memory",
    "update_memory",
    "delete_memory",
    "memory_write",
    "subagent_create",
    "subagent_update",
    "subagent_delete",
];

pub struct ToolExecutionRetryPolicy;

impl ToolExecutionRetryPolicy {
    pub fn should_retry(tool_name: &str, error_code: &str, attempt: u32) -> bool {
        if attempt >= MAX_RETRY_ATTEMPTS {
            return false;
        }
        if Self::is_no_retry_tool(tool_name) {
            return false;
        }
        if !Self::is_idempotent(tool_name) {
            return false;
        }
        Self::is_transient_error(error_code)
    }

    pub fn is_transient_error(code: &str) -> bool {
        TRANSIENT_ERROR_CODES.iter().any(|c| code.contains(c))
    }

    pub fn is_idempotent(tool_name: &str) -> bool {
        IDEMPOTENT_TOOL_NAMES.iter().any(|n| n == tool_name)
    }

    pub fn is_no_retry_tool(tool_name: &str) -> bool {
        NO_RETRY_TOOL_NAMES.iter().any(|n| n == tool_name)
    }

    pub fn retry_delay_ms(attempt: u32) -> u64 {
        RETRY_BASE_DELAY_MS * (1 << attempt.min(5))
    }
}

// ============================================================
// Phase 1 补全: ContextCompactionPlanner (from ContextCompactionPlanner.kt)
// ============================================================

/// Estimates tokens using the same heuristic as ToolResultTruncation:
/// ASCII = 1/3 token, non-ASCII = 1 token.
pub fn estimate_tokens_compaction(text: &str) -> usize {
    let ascii = text.chars().filter(|c| (*c as u32) <= 0x7F).count();
    let non_ascii = text.chars().count() - ascii;
    non_ascii + (ascii + 2) / 3
}

/// Compaction trigger thresholds.
pub const COMPACTION_TRIGGER_TOKENS: usize = 100_000;
pub const COMPACTION_TARGET_TOKENS: usize = 50_000;
pub const COMPACTION_MIN_MESSAGES: usize = 10;

pub struct ContextCompactionPlanner;

impl ContextCompactionPlanner {
    /// Decides whether compaction should fire.
    pub fn should_compact(total_tokens: usize, message_count: usize) -> bool {
        total_tokens >= COMPACTION_TRIGGER_TOKENS && message_count >= COMPACTION_MIN_MESSAGES
    }

    /// How many recent messages to keep uncompressed.
    pub fn keep_recent_messages(total_messages: usize) -> usize {
        (total_messages / 4).max(3).min(20)
    }

    /// Estimated tokens for a text block.
    pub fn estimate_tokens(text: &str) -> usize {
        estimate_tokens_compaction(text)
    }
}

// ============================================================
// Phase 1 补全: CompactionTools (from CompactionTools.kt)
// ============================================================

pub fn build_compact_context_tool_description() -> String {
    format!(
        "Summarise earlier turns in this conversation to free up context. \
         The summariser runs the same pipeline as the manual compress action. \
         Messages after the compaction point are kept verbatim; everything before \
         is replaced with a structured summary. Use this proactively when the \
         conversation is long and you notice context pressure (trigger: {} tokens).",
        COMPACTION_TRIGGER_TOKENS
    )
}

pub fn build_compact_context_result(
    compacted_messages: usize,
    freed_tokens: usize,
    summary: &str,
) -> String {
    json!({
        "compactedMessages": compacted_messages,
        "freedTokens": freed_tokens,
        "summary": summary,
        "note": "Earlier turns were summarised. The summary is now part of your context. \
                 If you need a specific detail from before compaction, ask the user."
    }).to_string()
}

// ============================================================
// Phase 2 补全: ToolApprovalDefaults (from ToolApprovalDefaults.kt)
// ============================================================

/// Tools that are always auto-approved (no user prompt needed).
pub const NO_ALWAYS_ALLOW: &[&str] = &[
    "read_file", "read_file_part", "list_files", "find_files", "grep_code",
    "grep_context", "make_directory", "download_file", "visit_web",
    "query_memory", "get_memory_by_title", "get_memory_owner_key",
    "battery", "wifi_info", "get_location", "volume", "brightness",
    "torch", "vibrate", "sensor", "telephony_info", "audio_info",
    "memory_index", "memory_read", "tool_search", "tool_open",
    "usage_stats", "usage_export", "compact_context",
];

/// Tools that always require per-call user confirmation.
pub const ALWAYS_ASK: &[&str] = &[
    "write_file", "edit_file", "delete_file", "create_file",
    "send_sms", "send_sms_intent", "send_email_intent",
    "list_contacts", "search_contacts", "create_contact",
    "list_sms_inbox", "search_sms", "list_call_log",
    "take_photo", "take_screenshot",
    "notification_action_click", "notification_reply", "dismiss_notification",
    "record_audio", "speech_to_text",
    "memory_write", "create_memory", "update_memory", "delete_memory", "move_memory",
    "subagent_create", "subagent_update", "subagent_delete",
    "mcp_add", "mcp_update",
    "skill_install_from_text", "skill_install_from_url",
    "set_wallpaper",
];

pub struct ToolApprovalDefaults;

impl ToolApprovalDefaults {
    pub fn is_always_allowed(tool_name: &str) -> bool {
        NO_ALWAYS_ALLOW.iter().any(|n| n == tool_name)
    }

    pub fn is_always_ask(tool_name: &str) -> bool {
        ALWAYS_ASK.iter().any(|n| n == tool_name)
    }

    pub fn needs_approval(tool_name: &str) -> bool {
        !Self::is_always_allowed(tool_name)
    }
}

// ============================================================
// Phase 2 补全: ToolApprovalAllowList (from ToolApprovalAllowList.kt)
// ============================================================

pub struct ToolApprovalAllowList {
    session_approved: Mutex<HashSet<String>>,
}

impl ToolApprovalAllowList {
    pub fn new() -> Self {
        Self {
            session_approved: Mutex::new(HashSet::new()),
        }
    }

    pub fn allow_session(&self, tool_name: &str) {
        self.session_approved.lock().unwrap().insert(tool_name.to_string());
    }

    pub fn is_session_approved(&self, tool_name: &str) -> bool {
        self.session_approved.lock().unwrap().contains(tool_name)
    }

    pub fn clear(&self) {
        self.session_approved.lock().unwrap().clear();
    }

    pub fn is_auto_approved(&self, tool_name: &str) -> bool {
        ToolApprovalDefaults::is_always_allowed(tool_name) || self.is_session_approved(tool_name)
    }
}

impl Default for ToolApprovalAllowList {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================
// Phase 2 补全: HeadlessConversations (from HeadlessConversations.kt)
// ============================================================

pub struct HeadlessConversations {
    marked: Mutex<HashSet<String>>,
}

impl HeadlessConversations {
    pub fn new() -> Self {
        Self {
            marked: Mutex::new(HashSet::new()),
        }
    }

    pub fn mark(&self, conversation_id: &str) {
        self.marked.lock().unwrap().insert(conversation_id.to_string());
    }

    pub fn unmark(&self, conversation_id: &str) {
        self.marked.lock().unwrap().remove(conversation_id);
    }

    pub fn is_headless(&self, conversation_id: &str) -> bool {
        self.marked.lock().unwrap().contains(conversation_id)
    }

    pub fn is_tool_auto_approved(&self, conversation_id: &str) -> bool {
        self.is_headless(conversation_id)
    }
}

impl Default for HeadlessConversations {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================
// Phase 4 补全: LocalToolFilter (from LocalToolFilter.kt)
// ============================================================

pub struct LocalToolFilter;

impl LocalToolFilter {
    /// Filters tool names by removing disabled individual tools.
    pub fn filter(
        all_tools: &[String],
        disabled_tools: &HashSet<String>,
    ) -> Vec<String> {
        all_tools
            .iter()
            .filter(|t| !disabled_tools.contains(*t))
            .cloned()
            .collect()
    }

    /// Checks if a tool group should be visible based on per-tool toggles.
    pub fn is_group_visible(group_tools: &[String], disabled_tools: &HashSet<String>) -> bool {
        group_tools.iter().any(|t| !disabled_tools.contains(t))
    }
}

// ============================================================
// Phase 4 补全: ToolSurfaceResolver (from ToolSurfaceResolver.kt)
// ============================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolSurfaceMode {
    Direct,
    ProgressiveCatalog,
}

pub struct ToolSurfaceResolver;

impl ToolSurfaceResolver {
    /// Resolves which tools to inject into the current request.
    pub fn resolve(
        mode: ToolSurfaceMode,
        all_tools: &[String],
        disabled_tools: &HashSet<String>,
        active_progressive: &HashSet<String>,
    ) -> Vec<String> {
        let filtered = LocalToolFilter::filter(all_tools, disabled_tools);
        match mode {
            ToolSurfaceMode::Direct => filtered,
            ToolSurfaceMode::ProgressiveCatalog => {
                filtered.into_iter()
                    .filter(|t| active_progressive.contains(t))
                    .collect()
            }
        }
    }
}

// ============================================================
// Phase 4 补全: ToolInvocationContext (from ToolInvocationContext.kt)
// ============================================================

#[derive(Debug, Clone)]
pub struct ToolInvocationContext {
    pub conversation_id: String,
    pub assistant_id: String,
    pub is_headless: bool,
    pub workspace_path: Option<String>,
    pub turn_budget_ms: Option<u64>,
    pub max_tool_steps: Option<u32>,
    pub tool_result_token_budget: Option<usize>,
}

impl ToolInvocationContext {
    pub fn new(conversation_id: String, assistant_id: String) -> Self {
        Self {
            conversation_id,
            assistant_id,
            is_headless: false,
            workspace_path: None,
            turn_budget_ms: None,
            max_tool_steps: None,
            tool_result_token_budget: None,
        }
    }

    pub fn with_headless(mut self, headless: bool) -> Self {
        self.is_headless = headless;
        self
    }

    pub fn with_workspace(mut self, path: String) -> Self {
        self.workspace_path = Some(path);
        self
    }
}

// ============================================================
// Phase 6: AgentDefinition (from data/agentdef/ — 9 files consolidated)
// ============================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentDefinition {
    pub id: String,
    pub name: String,
    pub system_prompt: String,
    pub model_id: Option<String>,
    pub tool_surface: ToolSurfaceConfig,
    pub mcp_servers: Vec<String>,
    pub skills: Vec<String>,
    pub namespace: String,
    pub token_budget: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolSurfaceConfig {
    pub mode: String,
    pub enabled_tools: Vec<String>,
    pub disabled_tools: Vec<String>,
    pub inherit_parent: bool,
}

impl Default for ToolSurfaceConfig {
    fn default() -> Self {
        Self {
            mode: "inherit".to_string(),
            enabled_tools: vec![],
            disabled_tools: vec![],
            inherit_parent: true,
        }
    }
}

pub struct AgentDefinitionRegistry {
    definitions: Mutex<HashMap<String, AgentDefinition>>,
}

impl AgentDefinitionRegistry {
    pub fn new() -> Self {
        Self {
            definitions: Mutex::new(HashMap::new()),
        }
    }

    pub fn create(&self, def: AgentDefinition) {
        self.definitions.lock().unwrap().insert(def.id.clone(), def);
    }

    pub fn get(&self, id: &str) -> Option<AgentDefinition> {
        self.definitions.lock().unwrap().get(id).cloned()
    }

    pub fn list(&self) -> Vec<AgentDefinition> {
        self.definitions.lock().unwrap().values().cloned().collect()
    }

    pub fn update(&self, def: AgentDefinition) {
        self.definitions.lock().unwrap().insert(def.id.clone(), def);
    }

    pub fn delete(&self, id: &str) -> bool {
        self.definitions.lock().unwrap().remove(id).is_some()
    }

    pub fn resolve_namespace(&self, name: &str) -> String {
        name.trim().to_lowercase()
            .replace(' ', "-")
            .replace(|c: char| !c.is_alphanumeric() && c != '-', "")
    }
}

impl Default for AgentDefinitionRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================
// Phase 6: SubAgentToolSurface (from SubAgentToolSurface.kt)
// ============================================================

pub struct SubAgentToolSurface;

impl SubAgentToolSurface {
    /// Tools that a sub-agent must NEVER see (device-UI or must-confirm tools).
    pub const DENIED_PREFIX: &'static str = "subagent_";

    pub const PRIVACY_SENSITIVE: &[&str] = &["record_audio", "speech_to_text"];

    pub const DEVICE_UI_TOOLS: &[&str] = &[
        "take_photo", "take_screenshot", "tap", "swipe", "scroll",
        "find_node", "window_tree", "global_action", "keyboard",
        "show_image", "open_file",
    ];

    /// Filters the parent's tool surface for a sub-agent.
    pub fn freeze_surface(parent_tools: &[String]) -> Vec<String> {
        parent_tools
            .iter()
            .filter(|t| !t.starts_with(Self::DENIED_PREFIX))
            .filter(|t| !Self::PRIVACY_SENSITIVE.contains(&t.as_str()))
            .filter(|t| !Self::DEVICE_UI_TOOLS.contains(&t.as_str()))
            .filter(|t| !ToolApprovalDefaults::is_always_ask(t))
            .cloned()
            .collect()
    }

    /// Denial reason for a tool the sub-agent surface excludes.
    pub fn denial_reason(tool_name: &str) -> Option<String> {
        if tool_name.starts_with(Self::DENIED_PREFIX) {
            return Some(format!(
                "{} is a sub-agent management tool — a sub-agent must not be able to dispatch \
                 further sub-agents (recursion guard, D11).",
                tool_name
            ));
        }
        if Self::PRIVACY_SENSITIVE.contains(&tool_name) {
            return Some(format!(
                "{} records the user's surroundings or speech — a sub-agent has no approval \
                 channel, so it must not capture.",
                tool_name
            ));
        }
        if Self::DEVICE_UI_TOOLS.contains(&tool_name) {
            return Some(format!(
                "{} is a device-UI tool that requires an interactive surface — a sub-agent run \
                 is headless and has none.",
                tool_name
            ));
        }
        if ToolApprovalDefaults::is_always_ask(tool_name) {
            return Some(format!(
                "{} requires per-call user confirmation, and a sub-agent has no approval channel.",
                tool_name
            ));
        }
        None
    }
}

// ============================================================
// Phase 6: SubAgentContextDigest (from SubAgentContextDigest.kt)
// ============================================================

pub struct SubAgentContextDigest;

impl SubAgentContextDigest {
    /// Builds a compact text digest of recent turns for a sub-agent dispatch.
    pub fn build_digest(messages: &[(String, String)], max_messages: usize) -> String {
        let take = messages.len().min(max_messages);
        let mut parts = Vec::new();
        for (role, content) in messages.iter().rev().take(take).rev() {
            let label = if role == "user" { "User" } else { "Assistant" };
            parts.push(format!("{}: {}", label, content));
        }
        parts.join("\n\n")
    }
}

// ============================================================
// Phase 6: SubAgentArchiveRules (from SubAgentArchiveRules.kt)
// ============================================================

pub struct SubAgentArchiveRules;

impl SubAgentArchiveRules {
    pub const MAX_ARCHIVE_SIZE: usize = 10;
    pub const ARCHIVE_DIR: &'static str = "agents";

    pub fn archive_path(namespace: &str) -> String {
        format!("{}/{}/", Self::ARCHIVE_DIR, namespace)
    }

    pub fn is_valid_namespace(ns: &str) -> bool {
        !ns.is_empty()
            && ns.chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_')
            && ns.len() <= 64
    }
}

// ============================================================
// Phase 7: WorkflowSecretsStore (from SkillSecretsStore.kt)
// ============================================================

pub struct WorkflowSecretsStore {
    secrets: Mutex<HashMap<String, String>>,
}

impl WorkflowSecretsStore {
    pub fn new() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
        }
    }

    pub fn set(&self, name: &str, value: &str) {
        self.secrets.lock().unwrap().insert(name.to_string(), value.to_string());
    }

    pub fn get(&self, name: &str) -> Option<String> {
        self.secrets.lock().unwrap().get(name).cloned()
    }

    pub fn delete(&self, name: &str) -> bool {
        self.secrets.lock().unwrap().remove(name).is_some()
    }

    pub fn list_names(&self) -> Vec<String> {
        self.secrets.lock().unwrap().keys().cloned().collect()
    }

    /// Resolves `{{secret:NAME}}` references in a template string.
    pub fn resolve_template(&self, template: &str) -> String {
        let mut result = template.to_string();
        let secrets = self.secrets.lock().unwrap();
        for (name, value) in secrets.iter() {
            let placeholder = format!("{{{{secret:{}}}}}", name);
            result = result.replace(&placeholder, value);
        }
        result
    }
}

impl Default for WorkflowSecretsStore {
    fn default() -> Self {
        Self::new()
    }
}

// ============================================================
// Phase 7: WorkflowActionTemplates (action data-flow)
// ============================================================

pub struct WorkflowActionTemplates;

impl WorkflowActionTemplates {
    /// Resolves `{{actions[N].text}}` and `{{actions[N].json.path}}` references.
    pub fn resolve_action_refs(template: &str, action_results: &[Value]) -> String {
        let mut result = template.to_string();
        for (i, action) in action_results.iter().enumerate() {
            // {{actions[0].text}}
            if let Some(text) = action.as_str() {
                let placeholder = format!("{{{{actions[{}].text}}}}", i);
                result = result.replace(&placeholder, text);
            }
            // {{actions[0].json.a.b}}
            let json_placeholder = format!("{{{{actions[{}].json.", i);
            while let Some(start) = result.find(&json_placeholder) {
                let rest = &result[start..];
                let end = rest.find("}}").unwrap_or(rest.len());
                let path_str = &rest[json_placeholder.len()..end];
                let value = Self::extract_json_path(action, path_str);
                let full_ref = format!("{{{{actions[{}].json.{}}}}}", i, path_str);
                result = result.replace(&full_ref, &value);
            }
        }
        result
    }

    fn extract_json_path(value: &Value, path: &str) -> String {
        let mut current = value;
        for part in path.split('.') {
            if let Ok(idx) = part.parse::<usize>() {
                if let Some(arr) = current.as_array() {
                    current = arr.get(idx).unwrap_or(&Value::Null);
                } else {
                    return String::new();
                }
            } else if let Some(v) = current.get(part) {
                current = v;
            } else {
                return String::new();
            }
        }
        match current {
            Value::String(s) => s.clone(),
            v => v.to_string(),
        }
    }
}

// ============================================================
// Phase 7: HardlineCommandGuard (from HardlineCommandGuard.kt)
// ============================================================

pub struct HardlineCommandGuard;

impl HardlineCommandGuard {
    /// Commands that a headless run must never execute.
    pub const BLOCKED_PATTERNS: &[&str] = &[
        "rm -rf /",
        "mkfs",
        "dd if=/dev/",
        "shutdown",
        "reboot",
        ":(){:|:&};:",
    ];

    pub fn is_blocked(command: &str) -> bool {
        let lower = command.to_lowercase();
        Self::BLOCKED_PATTERNS.iter().any(|p| lower.contains(p))
    }

    pub fn block_reason(command: &str) -> Option<String> {
        if Self::is_blocked(command) {
            Some(format!(
                "Command matches a blocked pattern (destructive system command). \
                 Headless runs must not execute this."
            ))
        } else {
            None
        }
    }
}

// ============================================================
// Phase 7: FastPathRouter (from FastPathRouter.kt — simplified)
// ============================================================

pub struct FastPathRouter;

impl FastPathRouter {
    /// Checks if a user message can be answered without a model call (fast path).
    pub fn try_fast_path(message: &str) -> Option<String> {
        let lower = message.to_lowercase().trim();
        match lower {
            "hello" | "hi" | "hey" => Some("Hello! How can I help you?".to_string()),
            "thanks" | "thank you" | "thx" => Some("You're welcome!".to_string()),
            "bye" | "goodbye" => Some("Goodbye!".to_string()),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Retry policy ---

    #[test]
    fn retry_transient_error() {
        assert!(ToolExecutionRetryPolicy::should_retry("read_file", "timeout", 0));
        assert!(!ToolExecutionRetryPolicy::should_retry("read_file", "timeout", 3));
    }

    #[test]
    fn no_retry_for_write_tools() {
        assert!(!ToolExecutionRetryPolicy::should_retry("write_file", "timeout", 0));
    }

    #[test]
    fn no_retry_for_non_transient() {
        assert!(!ToolExecutionRetryPolicy::should_retry("read_file", "invalid_argument", 0));
    }

    #[test]
    fn retry_backoff_exponential() {
        assert!(ToolExecutionRetryPolicy::retry_delay_ms(0) < ToolExecutionRetryPolicy::retry_delay_ms(1));
        assert!(ToolExecutionRetryPolicy::retry_delay_ms(1) < ToolExecutionRetryPolicy::retry_delay_ms(2));
    }

    // --- Compaction ---

    #[test]
    fn compaction_triggers_at_threshold() {
        assert!(ContextCompactionPlanner::should_compact(100_000, 10));
        assert!(!ContextCompactionPlanner::should_compact(100_000, 5));
        assert!(!ContextCompactionPlanner::should_compact(50_000, 10));
    }

    #[test]
    fn compaction_keep_recent() {
        assert_eq!(ContextCompactionPlanner::keep_recent_messages(4), 3);
        assert_eq!(ContextCompactionPlanner::keep_recent_messages(100), 20);
        assert_eq!(ContextCompactionPlanner::keep_recent_messages(12), 3);
    }

    // --- Approval defaults ---

    #[test]
    fn read_tools_auto_approved() {
        assert!(ToolApprovalDefaults::is_always_allowed("read_file"));
        assert!(!ToolApprovalDefaults::needs_approval("read_file"));
    }

    #[test]
    fn write_tools_need_approval() {
        assert!(ToolApprovalDefaults::needs_approval("write_file"));
        assert!(ToolApprovalDefaults::is_always_ask("send_sms"));
    }

    // --- Allow list ---

    #[test]
    fn session_approval() {
        let list = ToolApprovalAllowList::new();
        assert!(!list.is_auto_approved("write_file"));
        list.allow_session("write_file");
        assert!(list.is_auto_approved("write_file"));
        list.clear();
        assert!(!list.is_auto_approved("write_file"));
    }

    // --- Headless conversations ---

    #[test]
    fn headless_marking() {
        let hc = HeadlessConversations::new();
        assert!(!hc.is_headless("c1"));
        hc.mark("c1");
        assert!(hc.is_headless("c1"));
        assert!(hc.is_tool_auto_approved("c1"));
        hc.unmark("c1");
        assert!(!hc.is_headless("c1"));
    }

    // --- Tool filter ---

    #[test]
    fn filter_removes_disabled() {
        let all = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let mut disabled = HashSet::new();
        disabled.insert("b".to_string());
        let filtered = LocalToolFilter::filter(&all, &disabled);
        assert_eq!(filtered, vec!["a".to_string(), "c".to_string()]);
    }

    // --- Surface resolver ---

    #[test]
    fn surface_direct_mode() {
        let all = vec!["a".to_string(), "b".to_string()];
        let disabled = HashSet::new();
        let active = HashSet::new();
        let result = ToolSurfaceResolver::resolve(ToolSurfaceMode::Direct, &all, &disabled, &active);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn surface_progressive_mode() {
        let all = vec!["a".to_string(), "b".to_string()];
        let disabled = HashSet::new();
        let mut active = HashSet::new();
        active.insert("a".to_string());
        let result = ToolSurfaceResolver::resolve(ToolSurfaceMode::ProgressiveCatalog, &all, &disabled, &active);
        assert_eq!(result, vec!["a".to_string()]);
    }

    // --- Agent definition ---

    #[test]
    fn agent_definition_crud() {
        let registry = AgentDefinitionRegistry::new();
        let def = AgentDefinition {
            id: "researcher".to_string(),
            name: "Researcher".to_string(),
            system_prompt: "You are a researcher.".to_string(),
            model_id: Some("gpt-4".to_string()),
            tool_surface: ToolSurfaceConfig::default(),
            mcp_servers: vec![],
            skills: vec![],
            namespace: "researcher".to_string(),
            token_budget: Some(5000),
        };
        registry.create(def.clone());
        assert_eq!(registry.list().len(), 1);
        assert!(registry.get("researcher").is_some());
        assert!(registry.delete("researcher"));
        assert!(registry.get("researcher").is_none());
    }

    #[test]
    fn namespace_resolution() {
        assert_eq!(AgentDefinitionRegistry::new().resolve_namespace("My Agent"), "my-agent");
        assert_eq!(AgentDefinitionRegistry::new().resolve_namespace("Agent 2!"), "agent-2");
    }

    // --- SubAgent surface ---

    #[test]
    fn surface_freeze_removes_dangerous() {
        let parent = vec![
            "read_file".to_string(),
            "subagent_dispatch".to_string(),
            "take_photo".to_string(),
            "send_sms".to_string(),
            "record_audio".to_string(),
        ];
        let frozen = SubAgentToolSurface::freeze_surface(&parent);
        assert!(frozen.contains(&"read_file".to_string()));
        assert!(!frozen.contains(&"subagent_dispatch".to_string()));
        assert!(!frozen.contains(&"take_photo".to_string()));
        assert!(!frozen.contains(&"send_sms".to_string()));
        assert!(!frozen.contains(&"record_audio".to_string()));
    }

    #[test]
    fn surface_denial_reason() {
        assert!(SubAgentToolSurface::denial_reason("subagent_dispatch").is_some());
        assert!(SubAgentToolSurface::denial_reason("read_file").is_none());
    }

    // --- Context digest ---

    #[test]
    fn digest_builds_from_messages() {
        let msgs = vec![
            ("user".to_string(), "Hello".to_string()),
            ("assistant".to_string(), "Hi there".to_string()),
        ];
        let digest = SubAgentContextDigest::build_digest(&msgs, 5);
        assert!(digest.contains("User: Hello"));
        assert!(digest.contains("Assistant: Hi there"));
    }

    // --- Secrets store ---

    #[test]
    fn secrets_store_set_get() {
        let store = WorkflowSecretsStore::new();
        store.set("api_key", "secret123");
        assert_eq!(store.get("api_key"), Some("secret123".to_string()));
        assert_eq!(store.list_names(), vec!["api_key".to_string()]);
        assert!(store.delete("api_key"));
        assert!(store.get("api_key").is_none());
    }

    #[test]
    fn secrets_resolve_template() {
        let store = WorkflowSecretsStore::new();
        store.set("token", "abc");
        let template = "Authorization: Bearer {{secret:token}}";
        assert_eq!(store.resolve_template(template), "Authorization: Bearer abc");
    }

    // --- Workflow action templates ---

    #[test]
    fn action_template_resolves_text() {
        let actions = vec![Value::String("result1".to_string())];
        let template = "Output: {{actions[0].text}}";
        assert_eq!(
            WorkflowActionTemplates::resolve_action_refs(template, &actions),
            "Output: result1"
        );
    }

    // --- Hardline guard ---

    #[test]
    fn guard_blocks_destructive() {
        assert!(HardlineCommandGuard::is_blocked("rm -rf /"));
        assert!(HardlineCommandGuard::is_blocked("mkfs.ext4 /dev/sda1"));
        assert!(!HardlineCommandGuard::is_blocked("ls -la"));
    }

    #[test]
    fn guard_block_reason() {
        assert!(HardlineCommandGuard::block_reason("rm -rf /").is_some());
        assert!(HardlineCommandGuard::block_reason("echo hello").is_none());
    }

    // --- Fast path ---

    #[test]
    fn fast_path_hello() {
        assert!(FastPathRouter::try_fast_path("hello").is_some());
        assert!(FastPathRouter::try_fast_path("complex question").is_none());
    }
}
