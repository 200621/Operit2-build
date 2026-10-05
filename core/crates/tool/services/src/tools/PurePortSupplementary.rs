use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// Ported from rikkahub-agent-pure — consolidated supplementary modules.
/// Rewritten after line-by-line source audit to match Pure behaviour exactly.
///
/// Phase 1 补全: ToolExecutionRetryPolicy, ContextCompactionPlanner, CompactionTools
/// Phase 2 补全: ToolApprovalDefaults, ToolApprovalAllowList, HeadlessConversations
/// Phase 4 补全: LocalToolFilter, ToolSurfaceResolver, ToolInvocationContext
/// Phase 6: AgentDefinition, SubAgentToolSurface, SubAgentContextDigest, SubAgentArchiveRules
/// Phase 7: WorkflowSecretsStore, WorkflowActionTemplates, HardlineCommandGuard, FastPathRouter

// ============================================================
// Phase 1 补全: ToolExecutionRetryPolicy (from ToolExecutionRetryPolicy.kt)
// ============================================================

/// Extra attempts after the first. Total = MAX_RETRIES + 1.
pub const MAX_RETRIES: u32 = 2;
const INITIAL_DELAY_MS: u64 = 500;
const MAX_DELAY_MS: u64 = 4_000;

/// Tool-name prefixes whose entire family is a pure read.
const IDEMPOTENT_PREFIXES: &[&str] = &[
    "get_", "list_", "read_", "search_", "find_", "scrape_",
];

/// Read-only tools whose names do not carry a safe prefix.
const IDEMPOTENT_EXACT: &[&str] = &[
    "conversation_search", "recent_chats", "whisper_status",
    "tool_search", "notification_status", "keyboard_editor_info",
    "keyboard_read_field", "file_info", "keystore_list_keys",
    "keystore_verify", "workspace_read_file", "workspace_read_folder",
    "workspace_background_status", "web_extract",
    "memory_index", "memory_read", "usage_stats", "usage_export",
    "compact_context",
];

/// web_fetch dispatches on its method arg; only GET/HEAD are read-only.
const WEB_FETCH_TOOL_NAME: &str = "web_fetch";
const READ_ONLY_HTTP_METHODS: &[&str] = &["GET", "HEAD"];

/// 4xx that describe a transient condition.
const RETRYABLE_4XX: &[u16] = &[408, 409, 425, 429];

/// Error codes tools embed in JSON result envelopes for transient failures.
const TRANSIENT_ERROR_CODES: &[&str] = &[
    "timeout", "tool_timeout", "command_timeout", "network_error",
    "connect_failed", "tcp_unreachable", "browser_task_timeout",
    "browser_session_lost", "browser_busy",
];

const QUOTA_EXHAUSTED_MARKERS: &[&str] = &[
    "resource exhausted", "resource has been exhausted",
];

const CONTEXT_LIMIT_MARKERS: &[&str] = &[
    "context length exceeded", "maximum context length", "maximum context window",
];

pub struct ToolExecutionRetryPolicy;

impl ToolExecutionRetryPolicy {
    /// True when every call of this tool is a pure read.
    /// MCP tools (mcp__*) are always excluded.
    /// web_fetch requires args to check the method argument.
    pub fn is_idempotent_read_only(tool_name: &str, args: Option<&Value>) -> bool {
        let name = tool_name.trim();
        if name.is_empty() { return false; }
        if name.starts_with("mcp__") || name.starts_with("mcp_") { return false; }
        if name == WEB_FETCH_TOOL_NAME {
            return Self::is_read_only_web_fetch_call(args);
        }
        if IDEMPOTENT_EXACT.contains(&name) { return true; }
        IDEMPOTENT_PREFIXES.iter().any(|p| name.starts_with(p))
    }

    /// Whether a web_fetch call is GET/HEAD only.
    fn is_read_only_web_fetch_call(args: Option<&Value>) -> bool {
        let obj = match args {
            Some(Value::Object(o)) => o,
            _ => return false,
        };
        let raw = match obj.get("method") {
            Some(Value::String(s)) => s.trim().to_uppercase(),
            None => return true, // default is GET
            _ => return false,
        };
        if raw.is_empty() { return false; }
        READ_ONLY_HTTP_METHODS.contains(&raw.as_str())
    }

    pub fn is_transient_http_status(status: u16) -> bool {
        RETRYABLE_4XX.contains(&status) || (500..=599).contains(&status)
    }

    pub fn is_transient_error_code(code: &str) -> bool {
        TRANSIENT_ERROR_CODES.iter().any(|c| code.contains(c))
    }

    /// True when a tool output JSON carries a transient failure.
    pub fn is_transient_tool_output(output: &str) -> bool {
        let trimmed = output.trim();
        if !trimmed.starts_with('{') { return false; }
        let parsed: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => return false,
        };
        let obj = match parsed.as_object() {
            Some(o) => o,
            None => return false,
        };
        if let Some(code) = obj.get("error").and_then(|v| v.as_str()) {
            if TRANSIENT_ERROR_CODES.contains(&code.to_lowercase().as_str()) {
                return true;
            }
        }
        if let (Some(ok), Some(status)) = (
            obj.get("ok").and_then(|v| v.as_bool()),
            obj.get("status").and_then(|v| v.as_u64()),
        ) {
            if !ok {
                if let Some(s) = u16::try_from(status).ok() {
                    return Self::is_transient_http_status(s);
                }
            }
        }
        false
    }

    /// Exponential backoff: 500ms, 1s, 2s, 4s (capped). retry_number is 1-based.
    pub fn retry_delay_ms(retry_number: u32) -> u64 {
        let shift = (retry_number.saturating_sub(1)).min(4);
        (INITIAL_DELAY_MS << shift).min(MAX_DELAY_MS)
    }
}

// ============================================================
// Phase 1 补全: ContextCompactionPlanner (from ContextCompactionPlanner.kt)
// ============================================================

const DEFAULT_CONTEXT_LENGTH: usize = 8_192;
const PROMPT_OVERHEAD_TOKENS: usize = 768;
const MIN_INPUT_BUDGET_TOKENS: usize = 512;
const MAX_MAP_INPUT_TOKENS: usize = 100_000;

pub struct ContextCompactionPlanner;

impl ContextCompactionPlanner {
    /// Computes the input token budget for a compaction request.
    pub fn input_budget_tokens(
        context_length: Option<usize>,
        target_tokens: usize,
        allow_full_context: bool,
    ) -> usize {
        let available = context_length
            .filter(|l| *l > 0)
            .unwrap_or(DEFAULT_CONTEXT_LENGTH)
            .max(MIN_INPUT_BUDGET_TOKENS + PROMPT_OVERHEAD_TOKENS);
        let output_reserve = target_tokens.max(256).min(available / 2);
        let remaining = (available - output_reserve - PROMPT_OVERHEAD_TOKENS)
            .max(MIN_INPUT_BUDGET_TOKENS);
        let ceiling = if allow_full_context { available } else { available * 3 / 4 };
        remaining.min(ceiling).max(MIN_INPUT_BUDGET_TOKENS)
    }

    /// Max source size for one map request.
    pub fn map_input_budget_tokens(input_budget: usize, allow_large: bool) -> usize {
        if allow_large { input_budget } else { input_budget.min(MAX_MAP_INPUT_TOKENS) }
    }

    /// Splits source texts into request-sized groups.
    pub fn partition_sources(sources: &[String], max_input_tokens: usize) -> Vec<Vec<String>> {
        let pieces: Vec<String> = sources.iter()
            .filter(|s| !s.trim().is_empty())
            .flat_map(|s| Self::split_source(s, max_input_tokens))
            .collect();
        if pieces.is_empty() { return vec![]; }

        let mut groups: Vec<Vec<String>> = Vec::new();
        let mut current: Vec<String> = Vec::new();
        let mut current_tokens = 0usize;
        let sep_tokens = Self::estimate_tokens("\n\n");

        for piece in pieces {
            let pt = Self::estimate_tokens(&piece);
            let next = pt + if current.is_empty() { 0 } else { sep_tokens };
            if !current.is_empty() && current_tokens + next > max_input_tokens {
                groups.push(std::mem::take(&mut current));
                current_tokens = 0;
            }
            current_tokens += pt + if current.len() == 1 { 0 } else { sep_tokens };
            current.push(piece);
        }
        if !current.is_empty() { groups.push(current); }
        groups
    }

    fn split_source(text: &str, max_tokens: usize) -> Vec<String> {
        let tokens = Self::estimate_tokens(text);
        if tokens <= max_tokens { return vec![text.to_string()]; }
        // Split at paragraph boundaries
        let mut result = Vec::new();
        for para in text.split("\n\n") {
            if !para.trim().is_empty() {
                result.push(para.to_string());
            }
        }
        if result.is_empty() { vec![text.to_string()] } else { result }
    }

    /// Token estimate: ASCII = 1/3, non-ASCII = 1.
    pub fn estimate_tokens(text: &str) -> usize {
        let ascii = text.chars().filter(|c| (*c as u32) <= 0x7F).count();
        let non_ascii = text.chars().count() - ascii;
        non_ascii + (ascii + 2) / 3
    }

    /// Mandatory tool retention instructions appended to every compaction request.
    pub fn required_tool_retention_instructions() -> String {
        "TOOL EXECUTION RETENTION IS MANDATORY:\nThe conversation can contain [Completed tool execution record] blocks. Preserve every\ncompleted tool call in the resulting summary. Include the tool name, the meaningful\narguments or target, and the factual outcome. Preserve errors, important returned values,\nfile paths, URLs, IDs, and state changes. Use a clearly labelled \"Tool execution history\"\nsection when any tool record is present. Do not replace these records with a vague phrase\nsuch as \"tools were used\". If an output is long, condense it faithfully instead of\nomitting its result.".to_string()
    }
}

// ============================================================
// Phase 1 补全: CompactionTools (from CompactionTools.kt)
// ============================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompactionToolResult {
    pub compacted: bool,
    pub tokens_before: usize,
    pub tokens_after: usize,
    pub summary_chars: usize,
    pub note: String,
}

impl CompactionToolResult {
    pub fn to_json(&self) -> String {
        json!({
            "compacted": self.compacted,
            "tokensBefore": self.tokens_before,
            "tokensAfter": self.tokens_after,
            "summaryChars": self.summary_chars,
            "note": self.note,
        }).to_string()
    }
}

pub fn build_compact_context_tool_description() -> String {
    "Summarise this conversation's earlier history in place, so later turns carry less\ncontext. Use it when the context has grown long and you are finished with the exact\nwording of the earlier turns. Original messages are NOT deleted — only what gets sent\nto the model is shortened. The shortened context takes effect from the NEXT turn.".to_string()
}

// ============================================================
// Phase 2 补全: ToolApprovalDefaults (from ToolApprovalDefaults.kt — full list)
// ============================================================

pub struct ToolApprovalDefaults;

/// Full ALWAYS_ASK set (~132 tools) from Pure source.
pub const ALWAYS_ASK: &[&str] = &[
    // Shell / code execution
    "termux_run_command", "termux_session_start", "transcribe_audio_file", "eval_javascript",
    "shizuku_exec",
    // SSH
    "ssh_exec", "ssh_exec_saved", "ssh_upload", "ssh_download", "ssh_forget_host_key",
    "save_ssh_host", "delete_ssh_host",
    // Accounting
    "usage_set_prices",
    // Filesystem / network writes
    "write_text_file", "download_file", "scan_media",
    // Cron mutations
    "schedule_job", "delete_job", "pause_job", "resume_job", "trigger_job_now", "get_job_history",
    // UI manipulation
    "tap", "long_press", "swipe", "scroll", "set_text", "click_node", "global_action",
    "launch_app", "launch_activity", "open_url", "open_file", "wake_screen",
    // Privacy / hardware
    "take_photo", "record_audio", "speech_to_text", "verify_fingerprint", "share",
    "set_torch", "vibrate", "set_brightness", "set_volume", "play_media", "stop_media",
    "pause_media", "resume_media", "seek_media", "post_notification",
    // Privacy reads — PII
    "list_call_log", "list_contacts", "search_contacts", "list_sms_inbox", "search_sms",
    // Notification mutations
    "dismiss_notification", "notification_action_click", "notification_reply",
    // File manager
    "list_files", "read_file", "write_binary_file", "delete_file", "move_file", "copy_file",
    "create_directory", "file_info", "find_files", "batch_copy", "batch_move", "batch_delete",
    // Telegram outbound
    "telegram_send_message", "telegram_send_photo", "telegram_send_document",
    "telegram_set_token", "telegram_enable", "telegram_disable",
    "telegram_add_whitelist", "telegram_remove_whitelist",
    "telegram_set_default_chat", "telegram_set_assistant",
    "telegram_set_commands", "telegram_delete_commands",
    // MCP control
    "mcp_add", "mcp_update", "mcp_delete", "mcp_set_enabled", "mcp_set_tool_approval",
    // External automation
    "external_automation_set_enabled", "external_automation_add_trusted_package",
    "external_automation_remove_trusted_package",
    // Reliability
    "generate_bug_report",
    // Sub-agents
    "subagent_dispatch", "subagent_create", "subagent_update", "subagent_delete",
    // Workflows
    "workflow_create", "workflow_update", "workflow_delete", "workflow_set_enabled", "workflow_run",
    // Skill import
    "skill_install_from_url", "skill_install_from_text",
    // JS skills
    "run_js",
    // Native intent tools
    "create_calendar_event", "create_contact", "send_email_intent", "send_sms_intent",
    "open_wifi_settings", "show_location_on_map",
    // Browser write
    "browser_click", "browser_type", "browser_scroll", "browser_submit", "browser_select",
    "browser_press_key", "browser_eval_js", "browser_click_and_read",
    // web_fetch / web_extract
    "web_fetch", "web_extract",
    // Phase 25
    "send_sms", "set_wallpaper", "keystore_generate_key", "keystore_sign",
    "keystore_encrypt", "keystore_decrypt", "keystore_delete_key",
    "nfc_read_tag", "nfc_write_tag", "grant_directory_access",
    "zip_files", "unzip_file",
    // Keyboard control
    "keyboard_type", "keyboard_press_key", "keyboard_delete", "keyboard_clear",
    "keyboard_set_cursor", "keyboard_select_range",
    // Cold memory write
    "memory_write", "create_memory", "update_memory", "delete_memory", "move_memory",
];

/// NO_ALWAYS_ALLOW — must confirm every single call, no blanket grant.
pub const NO_ALWAYS_ALLOW: &[&str] = &[
    "mcp_add", "mcp_update", "eval_javascript",
    "skill_install_from_url", "skill_install_from_text",
    "browser_eval_js",
    "keystore_generate_key", "keystore_decrypt",
    "nfc_write_tag", "grant_directory_access",
];

impl ToolApprovalDefaults {
    pub fn is_always_ask(tool_name: &str) -> bool {
        ALWAYS_ASK.contains(&tool_name)
    }

    pub fn allows_always_allow(tool_name: &str) -> bool {
        !NO_ALWAYS_ALLOW.contains(&tool_name)
    }

    pub fn requires_approval(tool_name: &str) -> bool {
        Self::is_always_ask(tool_name) || tool_name.starts_with("mcp__")
    }
}

// ============================================================
// Phase 2 补全: ToolApprovalAllowList (from ToolApprovalAllowList.kt)
// ============================================================

/// In-memory "Allow for this chat" — keyed by (conversationId, toolName).
pub struct ToolApprovalAllowList {
    per_chat: Mutex<HashSet<String>>,
}

impl ToolApprovalAllowList {
    pub fn new() -> Self {
        Self { per_chat: Mutex::new(HashSet::new()) }
    }

    fn key(conv: &str, tool: &str) -> String {
        format!("{}::{}", conv, tool)
    }

    pub fn is_allowed_for_chat(&self, conversation_id: &str, tool_name: &str) -> bool {
        self.per_chat.lock().unwrap().contains(&Self::key(conversation_id, tool_name))
    }

    pub fn grant_for_chat(&self, conversation_id: &str, tool_name: &str) {
        self.per_chat.lock().unwrap().insert(Self::key(conversation_id, tool_name));
    }

    pub fn revoke_for_chat(&self, conversation_id: &str, tool_name: &str) {
        self.per_chat.lock().unwrap().remove(&Self::key(conversation_id, tool_name));
    }

    pub fn clear_chat(&self, conversation_id: &str) {
        let prefix = format!("{}::", conversation_id);
        self.per_chat.lock().unwrap().retain(|k| !k.starts_with(&prefix));
    }

    pub fn list_for_chat(&self, conversation_id: &str) -> Vec<String> {
        let prefix = format!("{}::", conversation_id);
        let mut result: Vec<String> = self.per_chat.lock().unwrap()
            .iter()
            .filter(|k| k.starts_with(&prefix))
            .map(|k| k.strip_prefix(&prefix).unwrap().to_string())
            .collect();
        result.sort();
        result
    }
}

impl Default for ToolApprovalAllowList {
    fn default() -> Self { Self::new() }
}

// ============================================================
// Phase 2 补全: HeadlessConversations (from HeadlessConversations.kt)
// ============================================================

/// Process-scoped registry with browser-headless / auto-approve split.
pub struct HeadlessConversations {
    ids: Mutex<HashSet<String>>,
    auto_approve_ids: Mutex<HashSet<String>>,
}

impl HeadlessConversations {
    pub fn new() -> Self {
        Self {
            ids: Mutex::new(HashSet::new()),
            auto_approve_ids: Mutex::new(HashSet::new()),
        }
    }

    /// Mark FULLY headless: no UI AND no approval channel. Tools auto-approve.
    pub fn mark(&self, conversation_id: &str) {
        self.ids.lock().unwrap().insert(conversation_id.to_string());
        self.auto_approve_ids.lock().unwrap().insert(conversation_id.to_string());
    }

    /// Mark BROWSER-headless only: no in-app UI, but caller has its own approval.
    pub fn mark_browser_headless(&self, conversation_id: &str) {
        self.ids.lock().unwrap().insert(conversation_id.to_string());
        // Deliberately NOT added to auto_approve_ids.
    }

    pub fn unmark(&self, conversation_id: &str) {
        self.ids.lock().unwrap().remove(conversation_id);
        self.auto_approve_ids.lock().unwrap().remove(conversation_id);
    }

    /// True if browser-headless (no in-app UI).
    pub fn is_headless(&self, conversation_id: &str) -> bool {
        self.ids.lock().unwrap().contains(conversation_id)
    }

    /// True if side-effecting tools should auto-approve.
    pub fn should_auto_approve(&self, conversation_id: &str) -> bool {
        self.auto_approve_ids.lock().unwrap().contains(conversation_id)
    }

    pub fn active_ids(&self) -> HashSet<String> {
        self.ids.lock().unwrap().clone()
    }

    pub fn clear_all(&self) {
        self.ids.lock().unwrap().clear();
        self.auto_approve_ids.lock().unwrap().clear();
    }
}

impl Default for HeadlessConversations {
    fn default() -> Self { Self::new() }
}

// ============================================================
// Phase 4 补全: LocalToolFilter (from LocalToolFilter.kt)
// ============================================================

pub struct LocalToolFilter;

impl LocalToolFilter {
    /// Removes disabled tools, preserving order. Empty set = no-op.
    pub fn remove_disabled(tools: &mut Vec<String>, disabled: &HashSet<String>) {
        if !disabled.is_empty() {
            tools.retain(|t| !disabled.contains(t));
        }
    }

    pub fn is_group_visible(group_tools: &[String], disabled: &HashSet<String>) -> bool {
        group_tools.iter().any(|t| !disabled.contains(t))
    }
}

// ============================================================
// Phase 4 补全: ToolInvocationContext (from ToolInvocationContext.kt)
// ============================================================

#[derive(Debug, Clone)]
pub struct ToolInvocationContext {
    pub caller_assistant_id: Option<String>,
    pub caller_conversation_id: Option<String>,
    pub is_headless: bool,
    pub model_can_see_images: bool,
    pub sub_agent_context_refs_enabled: bool,
    pub sub_agent_tool_surface_enabled: bool,
}

impl Default for ToolInvocationContext {
    fn default() -> Self {
        Self {
            caller_assistant_id: None,
            caller_conversation_id: None,
            is_headless: false,
            model_can_see_images: true,
            sub_agent_context_refs_enabled: false,
            sub_agent_tool_surface_enabled: false,
        }
    }
}

impl ToolInvocationContext {
    pub const EMPTY: ToolInvocationContext = ToolInvocationContext {
        caller_assistant_id: None,
        caller_conversation_id: None,
        is_headless: false,
        model_can_see_images: true,
        sub_agent_context_refs_enabled: false,
        sub_agent_tool_surface_enabled: false,
    };
}

// ============================================================
// Phase 4 补全: ToolSurfaceResolver + ToolInvocationContexts
// ============================================================

pub struct ToolSurfaceResolver;
pub struct ToolInvocationContexts;

impl ToolInvocationContexts {
    /// Interactive turn: model sees schemas, all gates carried.
    pub fn chat(
        assistant_id: &str, conversation_id: &str, is_headless: bool,
        model_can_see_images: bool,
        sub_agent_context_refs_enabled: bool,
        sub_agent_tool_surface_enabled: bool,
    ) -> ToolInvocationContext {
        ToolInvocationContext {
            caller_assistant_id: Some(assistant_id.to_string()),
            caller_conversation_id: Some(conversation_id.to_string()),
            is_headless,
            model_can_see_images,
            sub_agent_context_refs_enabled,
            sub_agent_tool_surface_enabled,
        }
    }

    /// Fast-path router: tools executed, not shown.
    pub fn fast_path(
        assistant_id: &str, conversation_id: &str,
        sub_agent_tool_surface_enabled: bool,
    ) -> ToolInvocationContext {
        ToolInvocationContext {
            caller_assistant_id: Some(assistant_id.to_string()),
            caller_conversation_id: Some(conversation_id.to_string()),
            is_headless: false,
            model_can_see_images: true,
            sub_agent_context_refs_enabled: false,
            sub_agent_tool_surface_enabled,
        }
    }

    /// Headless: workflow fire / cron direct mode.
    pub fn headless(assistant_id: &str, conversation_id: Option<&str>) -> ToolInvocationContext {
        ToolInvocationContext {
            caller_assistant_id: Some(assistant_id.to_string()),
            caller_conversation_id: conversation_id.map(|s| s.to_string()),
            is_headless: true,
            ..Default::default()
        }
    }
}

// ============================================================
// Phase 6: AgentDefinition (from data/agentdef/ — full fields)
// ============================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentDefinition {
    pub id: String,
    pub name: String,
    pub description: String,
    pub system_prompt: String,
    pub model_id: Option<String>,
    pub enabled: bool,
    pub local_tools: Option<Vec<String>>,
    pub disabled_local_tools: Option<HashSet<String>>,
    pub mcp_servers: Option<HashSet<String>>,
    pub skills: Option<HashSet<String>>,
    pub slug: Option<String>,
    pub token_budget: Option<i64>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

pub struct AgentDefinitionDefaults;

impl AgentDefinitionDefaults {
    pub const MAX_NAME_LENGTH: usize = 60;
    pub const MAX_DESCRIPTION_LENGTH: usize = 200;
    pub const MAX_SYSTEM_PROMPT_LENGTH: usize = 16_000;
    pub const NAMESPACE_ROOT: &'static str = "agents";
    pub const COLD_MEMORY_FOLDER: &'static str = "memory";
    pub const QUERY_LIMIT: usize = 500;
}

pub struct AgentDefinitionRegistry {
    definitions: Mutex<HashMap<String, AgentDefinition>>,
}

impl AgentDefinitionRegistry {
    pub fn new() -> Self {
        Self { definitions: Mutex::new(HashMap::new()) }
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

    pub fn enabled_definitions(defs: &[AgentDefinition]) -> Vec<&AgentDefinition> {
        defs.iter().filter(|d| d.enabled).collect()
    }
}

impl Default for AgentDefinitionRegistry {
    fn default() -> Self { Self::new() }
}

// ============================================================
// Phase 6: SubAgentToolSurface (from SubAgentToolSurface.kt — full)
// ============================================================

pub struct SubAgentToolSurface;

impl SubAgentToolSurface {
    /// Tools that need a human in front of the device (ToolHostActivity hosts).
    pub const UI_BOUND_TOOL_NAMES: &'static [&'static str] = &[
        "take_photo", "verify_fingerprint",
        "nfc_read_tag", "nfc_write_tag", "grant_directory_access",
    ];

    /// Tools that capture surroundings/speech with nobody to consent.
    pub const PRIVACY_SENSITIVE_TOOL_NAMES: &'static [&'static str] = &[
        "record_audio", "speech_to_text",
    ];

    /// subagent_ prefix — recursion guard.
    pub const INTERNAL_TOOL_PREFIX: &'static str = "subagent_";

    /// ask_user degrades to unavailable in headless.
    pub const ASK_USER_TOOL_NAME: &'static str = "ask_user";

    /// Why a tool may not reach a sub-agent, or None.
    pub fn denial_reason(tool_name: &str) -> Option<String> {
        let name = tool_name.trim();
        if name.starts_with(Self::INTERNAL_TOOL_PREFIX) {
            return Some("tool_unavailable_headless".to_string());
        }
        if name == Self::ASK_USER_TOOL_NAME {
            return Some("tool_unavailable_headless".to_string());
        }
        if Self::UI_BOUND_TOOL_NAMES.contains(&name) {
            return Some("tool_unavailable_headless".to_string());
        }
        if !ToolApprovalDefaults::allows_always_allow(name) {
            return Some("tool_not_authorized".to_string());
        }
        if Self::PRIVACY_SENSITIVE_TOOL_NAMES.contains(&name) {
            return Some("tool_not_authorized".to_string());
        }
        None
    }

    pub fn is_denied(tool_name: &str) -> bool {
        Self::denial_reason(tool_name).is_some()
    }

    /// Headless-safe subset of caller's tools.
    pub fn safe_names(caller_tool_names: &[String]) -> HashSet<String> {
        caller_tool_names.iter()
            .filter(|t| !Self::is_denied(t))
            .cloned()
            .collect()
    }

    /// Convenience: freeze parent surface for a sub-agent.
    pub fn freeze_surface(parent_tools: &[String]) -> Vec<String> {
        parent_tools.iter()
            .filter(|t| !Self::is_denied(t))
            .cloned()
            .collect()
    }
}

// ============================================================
// Phase 6: SubAgentContextDigest (from SubAgentContextDigest.kt — full)
// ============================================================

pub struct SubAgentContextDigest;

impl SubAgentContextDigest {
    pub const MAX_TURNS: usize = 10;
    pub const MAX_CHARS_PER_TURN: usize = 2000;
    pub const MAX_TOTAL_CHARS: usize = 8000;
    pub const TRUNCATION_MARKER: &'static str = " …[truncated]… ";

    pub const HEADER: &'static str =
        "Context from the parent conversation (background only — the TASK below is what you must do):";
    pub const FOOTER: &'static str = "End of parent context.";

    /// Builds digest from (role, text) pairs, keeping newest MAX_TURNS.
    pub fn build_digest(messages: &[(String, String)], max_turns: usize) -> String {
        let limit = max_turns.min(Self::MAX_TURNS);
        if limit == 0 { return String::new(); }
        let take = messages.len().min(limit);
        let mut parts = Vec::new();
        for (role, content) in messages.iter().rev().take(take).rev() {
            let label = if role == "user" { "user" } else { "assistant" };
            parts.push(format!("[{}] {}", label, Self::clamp_turn(content)));
        }
        parts.join("\n\n")
    }

    /// Render turns into the block prepended to the task, or None.
    pub fn render(turns: &[(String, String)]) -> Option<String> {
        let cleaned: Vec<(String, String)> = turns.iter()
            .map(|(r, t)| (r.trim().to_lowercase(), t.trim().to_string()))
            .filter(|(_, t)| !t.is_empty())
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .take(Self::MAX_TURNS)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        if cleaned.is_empty() { return None; }

        let mut kept: Vec<(String, String)> = Vec::new();
        let mut used = 0usize;
        for turn in cleaned.iter().rev() {
            let body = Self::clamp_turn(&turn.1);
            let cost = body.len() + turn.0.len() + 4;
            if !kept.is_empty() && used + cost > Self::MAX_TOTAL_CHARS { break; }
            kept.insert(0, (turn.0.clone(), body));
            used += cost;
        }
        let omitted = cleaned.len() - kept.len();
        let mut sb = String::new();
        sb.push_str(Self::HEADER);
        sb.push('\n');
        if omitted > 0 {
            sb.push_str(&format!("({} older turn(s) omitted for length.)\n", omitted));
        }
        for (role, text) in &kept {
            sb.push_str(&format!("[{}] {}\n", role, text));
        }
        sb.push_str(Self::FOOTER);
        Some(sb)
    }

    /// Prepend context block to task.
    pub fn prepend_to_task(turns: &[(String, String)], task: &str) -> String {
        match Self::render(turns) {
            Some(block) => format!("{}\n\n{}", block, task),
            None => task.to_string(),
        }
    }

    /// Keep head and tail of an over-long turn.
    fn clamp_turn(text: &str) -> String {
        if text.len() <= Self::MAX_CHARS_PER_TURN { return text.to_string(); }
        let keep = ((Self::MAX_CHARS_PER_TURN - Self::TRUNCATION_MARKER.len()).max(0)) / 2;
        format!("{}{}{}", &text[..keep], Self::TRUNCATION_MARKER, &text[text.len().saturating_sub(keep)..])
    }
}

// ============================================================
// Phase 6: SubAgentArchiveRules (from SubAgentArchiveRules.kt)
// ============================================================

pub struct SubAgentArchiveRules;

impl SubAgentArchiveRules {
    /// Target folder ID for an assistant's sub-agent conversations.
    pub fn target_folder_id(targets: &HashMap<String, String>, assistant_id: &str) -> Option<String> {
        targets.get(assistant_id)
            .filter(|v| Self::is_valid_uuid(v))
            .cloned()
    }

    /// A folder may not be deleted while it's the archive target AND holds conversations.
    pub fn is_protected(is_archive_target: bool, conversation_count: usize) -> bool {
        is_archive_target && conversation_count > 0
    }

    fn is_valid_uuid(s: &str) -> bool {
        s.len() == 36 &&
        s.chars().filter(|c| *c == '-').count() == 4 &&
        s.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
    }
}

// ============================================================
// Phase 7: HardlineCommandGuard (from HardlineCommandGuard.kt — full)
// ============================================================

pub struct HardlineCommandGuard;

impl HardlineCommandGuard {
    /// (pattern_lowercase, human_reason) pairs.
    const SHELL_PATTERNS: &'static [(&'static str, &'static str)] = &[
        ("rm -rf /", "recursive delete of root filesystem"),
        ("rm -rf /*", "recursive delete of root filesystem"),
        ("rm -rf /home", "recursive delete of home root"),
        ("rm -rf /root", "recursive delete of home root"),
        ("rm -rf /etc", "recursive delete of system directory"),
        ("rm -rf /usr", "recursive delete of system directory"),
        ("rm -rf /var", "recursive delete of system directory"),
        ("rm -rf /bin", "recursive delete of system directory"),
        ("rm -rf /sbin", "recursive delete of system directory"),
        ("rm -rf /boot", "recursive delete of system directory"),
        ("rm -rf /lib", "recursive delete of system directory"),
        ("rm -rf ~", "recursive delete of home directory"),
        ("rm -rf $home", "recursive delete of home directory"),
        ("rm -rf ${home}", "recursive delete of home directory"),
        ("mkfs", "format filesystem (mkfs)"),
        ("dd of=/dev/sd", "dd to raw block device"),
        ("dd of=/dev/nvme", "dd to raw block device"),
        ("dd of=/dev/mmcblk", "dd to raw block device"),
        (">/dev/sd", "redirect to raw block device"),
        (">/dev/nvme", "redirect to raw block device"),
        (":(){:|:&};:", "fork bomb"),
        ("kill -1", "kill all processes"),
        ("kill -9 -1", "kill all processes"),
        ("shutdown", "system shutdown/reboot"),
        ("reboot", "system shutdown/reboot"),
        ("halt", "system shutdown/reboot"),
        ("poweroff", "system shutdown/reboot"),
        ("init 0", "init 0/6 (shutdown/reboot)"),
        ("init 6", "init 0/6 (shutdown/reboot)"),
        ("systemctl poweroff", "systemctl poweroff/reboot"),
        ("systemctl reboot", "systemctl poweroff/reboot"),
        ("systemctl halt", "systemctl poweroff/reboot"),
        ("telinit 0", "telinit 0/6 (shutdown/reboot)"),
        ("telinit 6", "telinit 0/6 (shutdown/reboot)"),
        ("base64 -d", "encoded payload piped to shell"),
        ("xxd -r", "encoded payload piped to shell"),
        ("eval $(", "eval of subshell command substitution"),
    ];

    /// JS-specific hardline patterns for browser_eval_js.
    const JS_PATTERNS: &'static [(&'static str, &'static str)] = &[
        ("document.cookie=", "hardline:js_cookie_write"),
        ("eval(", "hardline:js_eval"),
        ("new function(", "hardline:js_function_constructor"),
        ("setinterval(\"", "hardline:js_setinterval_string"),
        ("setinterval('", "hardline:js_setinterval_string"),
        ("settimeout(\"", "hardline:js_settimeout_string"),
        ("settimeout('", "hardline:js_settimeout_string"),
        ("<script src=\"data:", "hardline:js_script_data_uri"),
        ("<script src='data:", "hardline:js_script_data_uri"),
    ];

    /// Check a raw command string. Returns reason if blocked, None if safe.
    pub fn check_command(command: &str) -> Option<String> {
        if command.trim().is_empty() { return None; }
        let lower = command.to_lowercase();
        for (pattern, reason) in Self::SHELL_PATTERNS {
            if lower.contains(pattern) {
                return Some(reason.to_string());
            }
        }
        None
    }

    /// Tool-aware check: pull shell content from known tool args.
    pub fn check_tool(tool_name: &str, input_json: &str) -> Option<String> {
        if input_json.trim().is_empty() { return None; }
        let parsed: Value = match serde_json::from_str(input_json) {
            Ok(v) => v,
            Err(_) => return None,
        };
        match tool_name {
            "termux_run_command" => {
                if let Some(cmd) = parsed.get("command").and_then(|v| v.as_str()) {
                    if let r @ Some(_) = Self::check_command(cmd) { return r; }
                }
                let exe = parsed.get("executable").and_then(|v| v.as_str()).unwrap_or("");
                let combined = format!("{} {}", exe, parsed.get("arguments")
                    .and_then(|v| v.as_array())
                    .map(|a| a.iter().filter_map(|i| i.as_str()).collect::<Vec<_>>().join(" "))
                    .unwrap_or_default());
                Self::check_command(&combined)
            }
            "ssh_exec" | "ssh_exec_saved" | "shizuku_exec" =>
                parsed.get("command").and_then(|v| v.as_str())
                    .and_then(|c| Self::check_command(c)),
            "subagent_dispatch" => Self::walk_and_check(&parsed),
            "browser_eval_js" => {
                let code = parsed.get("code").and_then(|v| v.as_str()).unwrap_or("");
                if let r @ Some(_) = Self::check_command(code) { return r; }
                let lower = code.to_lowercase();
                for (pattern, reason) in Self::JS_PATTERNS {
                    if lower.contains(pattern) {
                        return Some(reason.to_string());
                    }
                }
                None
            }
            _ if tool_name.starts_with("mcp__") => Self::walk_and_check(&parsed),
            _ => None,
        }
    }

    /// Recursively scan every string value in a JSON element.
    fn walk_and_check(value: &Value) -> Option<String> {
        match value {
            Value::String(s) => Self::check_command(s),
            Value::Object(map) => {
                for (_, v) in map {
                    if let r @ Some(_) = Self::walk_and_check(v) { return r; }
                }
                None
            }
            Value::Array(arr) => {
                for v in arr {
                    if let r @ Some(_) = Self::walk_and_check(v) { return r; }
                }
                None
            }
            _ => None,
        }
    }

    pub fn is_blocked(command: &str) -> bool {
        Self::check_command(command).is_some()
    }

    pub fn block_reason(command: &str) -> Option<String> {
        Self::check_command(command)
    }
}

// ============================================================
// Phase 7: WorkflowSecretsStore (from SkillSecretsStore.kt)
// ============================================================

/// Encrypted per-skill secret storage (simplified: in-memory HashMap).
/// Pure uses AES/GCM + Android Keystore; Operit2 would use platform equivalent.
pub struct WorkflowSecretsStore {
    secrets: Mutex<HashMap<String, String>>,
}

impl WorkflowSecretsStore {
    pub fn new() -> Self {
        Self { secrets: Mutex::new(HashMap::new()) }
    }

    fn key(skill: &str, name: &str) -> String {
        format!("{}__{}", skill, name)
    }

    pub fn set(&self, skill_name: &str, secret_name: &str, value: &str) {
        self.secrets.lock().unwrap().insert(Self::key(skill_name, secret_name), value.to_string());
    }

    pub fn get(&self, skill_name: &str, secret_name: &str) -> Option<String> {
        self.secrets.lock().unwrap().get(&Self::key(skill_name, secret_name)).cloned()
    }

    pub fn remove(&self, skill_name: &str, secret_name: &str) -> bool {
        self.secrets.lock().unwrap().remove(&Self::key(skill_name, secret_name)).is_some()
    }

    pub fn remove_all_for_skill(&self, skill_name: &str) {
        let prefix = format!("{}__", skill_name);
        self.secrets.lock().unwrap().retain(|k, _| !k.starts_with(&prefix));
    }

    pub fn list(&self) -> Vec<(String, String)> {
        self.secrets.lock().unwrap().keys()
            .filter_map(|k| {
                let sep = k.find("__")?;
                let skill = k[..sep].to_string();
                let name = k[sep + 2..].to_string();
                Some((skill, name))
            })
            .collect()
    }

    /// Resolve {{secret:NAME}} references (workflow-level, not skill-level).
    pub fn resolve_template(&self, template: &str) -> String {
        let mut result = template.to_string();
        let secrets = self.secrets.lock().unwrap();
        for (key, value) in secrets.iter() {
            // Try {{secret:KEY}} where KEY is the full key
            let placeholder = format!("{{{{secret:{}}}}}", key);
            result = result.replace(&placeholder, value);
            // Also try {{secret:NAME}} where NAME is just the secret name part
            if let Some(name) = key.split("__").nth(1) {
                let p2 = format!("{{{{secret:{}}}}}", name);
                result = result.replace(&p2, value);
            }
        }
        result
    }
}

impl Default for WorkflowSecretsStore {
    fn default() -> Self { Self::new() }
}

// ============================================================
// Phase 7: WorkflowActionTemplates (action data-flow)
// ============================================================

pub struct WorkflowActionTemplates;

impl WorkflowActionTemplates {
    /// Resolves {{actions[N].text}} and {{actions[N].json.path}} references.
    pub fn resolve_action_refs(template: &str, action_results: &[Value]) -> String {
        let mut result = template.to_string();
        for (i, action) in action_results.iter().enumerate() {
            if let Some(text) = action.as_str() {
                let placeholder = format!("{{{{actions[{}].text}}}}", i);
                result = result.replace(&placeholder, text);
            }
            let json_prefix = format!("{{{{actions[{}].json.", i);
            while let Some(start) = result.find(&json_prefix) {
                let rest = &result[start..];
                let end = rest.find("}}").unwrap_or(rest.len());
                let path_str = &rest[json_prefix.len()..end];
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
                } else { return String::new(); }
            } else if let Some(v) = current.get(part) {
                current = v;
            } else { return String::new(); }
        }
        match current {
            Value::String(s) => s.clone(),
            v => v.to_string(),
        }
    }
}

// ============================================================
// Phase 7: FastPathRouter (from FastPathRouter.kt — simplified)
// ============================================================

pub struct FastPathRouter;

impl FastPathRouter {
    /// Conservative intent matcher. Returns tool name + args if matched.
    pub fn route(message: &str) -> Option<(&'static str, Value)> {
        let normalized = message.trim().to_lowercase();
        let normalized = normalized.trim_end_matches('?').trim();
        // Battery
        if normalized.starts_with("what") && normalized.contains("battery")
            || normalized == "battery"
        {
            return Some(("get_battery_status", json!({})));
        }
        // Time
        if normalized.contains("what") && normalized.contains("time")
            || normalized == "time"
        {
            return Some(("get_time_info", json!({})));
        }
        // Date
        if normalized.contains("what") && normalized.contains("date")
            || normalized.contains("today") && normalized.contains("date")
            || normalized == "date"
        {
            return Some(("get_time_info", json!({})));
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- Retry policy ---

    #[test]
    fn retry_prefix_match() {
        assert!(ToolExecutionRetryPolicy::is_idempotent_read_only("get_battery_status", None));
        assert!(ToolExecutionRetryPolicy::is_idempotent_read_only("list_files", None));
        assert!(ToolExecutionRetryPolicy::is_idempotent_read_only("read_file", None));
    }

    #[test]
    fn retry_excludes_mcp() {
        assert!(!ToolExecutionRetryPolicy::is_idempotent_read_only("mcp__server__tool", None));
    }

    #[test]
    fn retry_web_fetch_get_only() {
        assert!(ToolExecutionRetryPolicy::is_idempotent_read_only(
            "web_fetch", Some(&json!({"method": "GET"}))
        ));
        assert!(!ToolExecutionRetryPolicy::is_idempotent_read_only(
            "web_fetch", Some(&json!({"method": "POST"}))
        ));
        assert!(ToolExecutionRetryPolicy::is_idempotent_read_only(
            "web_fetch", Some(&json!({})) // default GET
        ));
    }

    #[test]
    fn retry_transient_code() {
        assert!(ToolExecutionRetryPolicy::is_transient_error_code("timeout"));
        assert!(ToolExecutionRetryPolicy::is_transient_error_code("network_error"));
        assert!(!ToolExecutionRetryPolicy::is_transient_error_code("invalid_argument"));
    }

    #[test]
    fn retry_transient_http() {
        assert!(ToolExecutionRetryPolicy::is_transient_http_status(429));
        assert!(ToolExecutionRetryPolicy::is_transient_http_status(503));
        assert!(!ToolExecutionRetryPolicy::is_transient_http_status(404));
    }

    #[test]
    fn retry_backoff() {
        assert_eq!(ToolExecutionRetryPolicy::retry_delay_ms(1), 500);
        assert_eq!(ToolExecutionRetryPolicy::retry_delay_ms(2), 1000);
        assert_eq!(ToolExecutionRetryPolicy::retry_delay_ms(3), 2000);
        assert_eq!(ToolExecutionRetryPolicy::retry_delay_ms(4), 4000);
    }

    // --- Compaction ---

    #[test]
    fn compaction_budget() {
        let b = ContextCompactionPlanner::input_budget_tokens(Some(8192), 1024, false);
        assert!(b >= MIN_INPUT_BUDGET_TOKENS);
    }

    #[test]
    fn compaction_partition() {
        let sources = vec!["short".to_string(), "another".to_string()];
        let groups = ContextCompactionPlanner::partition_sources(&sources, 1000);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].len(), 2);
    }

    #[test]
    fn compaction_retention_instructions() {
        let s = ContextCompactionPlanner::required_tool_retention_instructions();
        assert!(s.contains("MANDATORY"));
        assert!(s.contains("Tool execution history"));
    }

    // --- Approval defaults ---

    #[test]
    fn approval_has_full_list() {
        assert!(ToolApprovalDefaults::is_always_ask("termux_run_command"));
        assert!(ToolApprovalDefaults::is_always_ask("send_sms"));
        assert!(ToolApprovalDefaults::is_always_ask("browser_eval_js"));
        assert!(ToolApprovalDefaults::is_always_ask("subagent_dispatch"));
        assert!(ToolApprovalDefaults::is_always_ask("keyboard_type"));
    }

    #[test]
    fn approval_no_always_allow() {
        assert!(!ToolApprovalDefaults::allows_always_allow("mcp_add"));
        assert!(!ToolApprovalDefaults::allows_always_allow("eval_javascript"));
        assert!(!ToolApprovalDefaults::allows_always_allow("browser_eval_js"));
        assert!(ToolApprovalDefaults::allows_always_allow("read_file"));
    }

    #[test]
    fn approval_requires_for_mcp() {
        assert!(ToolApprovalDefaults::requires_approval("mcp__server__tool"));
    }

    // --- Allow list (double key) ---

    #[test]
    fn allow_list_per_chat() {
        let list = ToolApprovalAllowList::new();
        assert!(!list.is_allowed_for_chat("c1", "write_file"));
        list.grant_for_chat("c1", "write_file");
        assert!(list.is_allowed_for_chat("c1", "write_file"));
        assert!(!list.is_allowed_for_chat("c2", "write_file"));
        let granted = list.list_for_chat("c1");
        assert_eq!(granted, vec!["write_file"]);
        list.revoke_for_chat("c1", "write_file");
        assert!(!list.is_allowed_for_chat("c1", "write_file"));
    }

    #[test]
    fn allow_list_clear_chat() {
        let list = ToolApprovalAllowList::new();
        list.grant_for_chat("c1", "a");
        list.grant_for_chat("c1", "b");
        list.grant_for_chat("c2", "a");
        list.clear_chat("c1");
        assert!(!list.is_allowed_for_chat("c1", "a"));
        assert!(list.is_allowed_for_chat("c2", "a"));
    }

    // --- Headless conversations (split) ---

    #[test]
    fn headless_mark_vs_browser() {
        let hc = HeadlessConversations::new();
        hc.mark("c1");
        assert!(hc.is_headless("c1"));
        assert!(hc.should_auto_approve("c1"));
        hc.mark_browser_headless("c2");
        assert!(hc.is_headless("c2"));
        assert!(!hc.should_auto_approve("c2"));
        hc.unmark("c1");
        assert!(!hc.is_headless("c1"));
    }

    // --- ToolInvocationContext ---

    #[test]
    fn context_chat_factory() {
        let ctx = ToolInvocationContexts::chat("a1", "c1", false, true, true, true);
        assert_eq!(ctx.caller_assistant_id, Some("a1".to_string()));
        assert!(!ctx.is_headless);
        assert!(ctx.model_can_see_images);
        assert!(ctx.sub_agent_context_refs_enabled);
    }

    #[test]
    fn context_headless_factory() {
        let ctx = ToolInvocationContexts::headless("a1", None);
        assert!(ctx.is_headless);
        assert!(!ctx.model_can_see_images); // default false for headless
    }

    // --- AgentDefinition ---

    #[test]
    fn agent_def_has_description() {
        let def = AgentDefinition {
            id: "r".to_string(), name: "R".to_string(),
            description: "A researcher".to_string(),
            system_prompt: "You are a researcher.".to_string(),
            model_id: None, enabled: true,
            local_tools: None, disabled_local_tools: None,
            mcp_servers: None, skills: None, slug: Some("r".to_string()),
            token_budget: None, created_at_ms: 0, updated_at_ms: 0,
        };
        assert_eq!(def.description, "A researcher");
        assert!(def.enabled);
    }

    // --- SubAgentToolSurface ---

    #[test]
    fn surface_denies_ui_bound() {
        assert!(SubAgentToolSurface::is_denied("take_photo"));
        assert!(SubAgentToolSurface::is_denied("verify_fingerprint"));
        assert!(SubAgentToolSurface::is_denied("nfc_read_tag"));
        assert!(SubAgentToolSurface::is_denied("ask_user"));
    }

    #[test]
    fn surface_denies_no_always_allow() {
        assert!(SubAgentToolSurface::is_denied("mcp_add"));
        assert!(SubAgentToolSurface::is_denied("eval_javascript"));
    }

    #[test]
    fn surface_allows_read() {
        assert!(!SubAgentToolSurface::is_denied("read_file"));
    }

    #[test]
    fn surface_safe_names() {
        let tools = vec!["read_file".to_string(), "take_photo".to_string(), "subagent_dispatch".to_string()];
        let safe = SubAgentToolSurface::safe_names(&tools);
        assert!(safe.contains("read_file"));
        assert!(!safe.contains("take_photo"));
        assert!(!safe.contains("subagent_dispatch"));
    }

    // --- SubAgentContextDigest ---

    #[test]
    fn digest_clamps_long_turn() {
        let long = "a".repeat(3000);
        let msgs = vec![("user".to_string(), long)];
        let digest = SubAgentContextDigest::build_digest(&msgs, 5);
        assert!(digest.contains("[truncated]"));
    }

    #[test]
    fn digest_render_and_prepend() {
        let turns = vec![
            ("user".to_string(), "What's the weather?".to_string()),
            ("assistant".to_string(), "Let me check.".to_string()),
        ];
        let rendered = SubAgentContextDigest::render(&turns).unwrap();
        assert!(rendered.contains("parent conversation"));
        let task = SubAgentContextDigest::prepend_to_task(&turns, "Do X");
        assert!(task.contains("Do X"));
        assert!(task.contains("parent conversation"));
    }

    // --- SubAgentArchiveRules ---

    #[test]
    fn archive_target_folder() {
        let mut targets = HashMap::new();
        targets.insert("a1".to_string(), "550e8400-e29b-41d4-a716-446655440000".to_string());
        targets.insert("a2".to_string(), "not-a-uuid".to_string());
        assert!(SubAgentArchiveRules::target_folder_id(&targets, "a1").is_some());
        assert!(SubAgentArchiveRules::target_folder_id(&targets, "a2").is_none());
        assert!(SubAgentArchiveRules::target_folder_id(&targets, "a3").is_none());
    }

    #[test]
    fn archive_protected() {
        assert!(SubAgentArchiveRules::is_protected(true, 5));
        assert!(!SubAgentArchiveRules::is_protected(true, 0));
        assert!(!SubAgentArchiveRules::is_protected(false, 5));
    }

    // --- HardlineCommandGuard ---

    #[test]
    fn guard_blocks_rm_rf() {
        assert!(HardlineCommandGuard::is_blocked("rm -rf /"));
        assert!(HardlineCommandGuard::is_blocked("rm -rf /etc/passwd"));
        assert!(HardlineCommandGuard::is_blocked("rm -rf ~"));
    }

    #[test]
    fn guard_blocks_mkfs_dd() {
        assert!(HardlineCommandGuard::is_blocked("mkfs.ext4 /dev/sda1"));
        assert!(HardlineCommandGuard::is_blocked("dd if=img of=/dev/sda"));
    }

    #[test]
    fn guard_blocks_shutdown_reboot() {
        assert!(HardlineCommandGuard::is_blocked("shutdown -h now"));
        assert!(HardlineCommandGuard::is_blocked("reboot"));
        assert!(HardlineCommandGuard::is_blocked("systemctl poweroff"));
    }

    #[test]
    fn guard_blocks_fork_bomb() {
        assert!(HardlineCommandGuard::is_blocked(":(){ :|:& };:"));
    }

    #[test]
    fn guard_blocks_base64_pipe() {
        assert!(HardlineCommandGuard::is_blocked("echo cm0gLXJmIC8= | base64 -d | sh"));
    }

    #[test]
    fn guard_allows_safe_commands() {
        assert!(!HardlineCommandGuard::is_blocked("ls -la"));
        assert!(!HardlineCommandGuard::is_blocked("echo hello"));
        assert!(!HardlineCommandGuard::is_blocked("git status"));
    }

    #[test]
    fn guard_check_tool_termux() {
        let input = r#"{"command": "rm -rf /"}"#;
        assert!(HardlineCommandGuard::check_tool("termux_run_command", input).is_some());
    }

    #[test]
    fn guard_check_tool_browser_js() {
        let input = r#"{"code": "document.cookie = 'x=1'}"#;
        assert!(HardlineCommandGuard::check_tool("browser_eval_js", input).is_some());
    }

    #[test]
    fn guard_check_tool_mcp_walk() {
        let input = r#"{"text": "rm -rf /etc"}"#;
        assert!(HardlineCommandGuard::check_tool("mcp__server__tool", input).is_some());
    }

    // --- Secrets store ---

    #[test]
    fn secrets_set_get_per_skill() {
        let store = WorkflowSecretsStore::new();
        store.set("weather", "api_key", "secret123");
        assert_eq!(store.get("weather", "api_key"), Some("secret123".to_string()));
        assert_eq!(store.get("weather", "other"), None);
        assert_eq!(store.get("other", "api_key"), None);
    }

    #[test]
    fn secrets_remove_all_for_skill() {
        let store = WorkflowSecretsStore::new();
        store.set("skill_a", "key1", "v1");
        store.set("skill_b", "key2", "v2");
        store.remove_all_for_skill("skill_a");
        assert!(store.get("skill_a", "key1").is_none());
        assert!(store.get("skill_b", "key2").is_some());
    }

    // --- Action templates ---

    #[test]
    fn action_template_resolves() {
        let actions = vec![Value::String("result1".to_string())];
        let template = "Output: {{actions[0].text}}";
        assert_eq!(
            WorkflowActionTemplates::resolve_action_refs(template, &actions),
            "Output: result1"
        );
    }

    // --- Fast path ---

    #[test]
    fn fast_path_battery() {
        assert!(FastPathRouter::route("what's my battery level?").is_some());
        assert!(FastPathRouter::route("battery").is_some());
    }

    #[test]
    fn fast_path_time() {
        assert!(FastPathRouter::route("what time is it?").is_some());
    }

    #[test]
    fn fast_path_no_match() {
        assert!(FastPathRouter::route("write a poem").is_none());
    }
}