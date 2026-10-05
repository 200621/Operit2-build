use serde_json::{json, Value};

/// Ported from rikkahub-agent-pure's HeadlessToolApprovalPolicy.kt.
///
/// Determines which tools must NOT run in a headless conversation (cron, workflow,
/// sub-agent, external automation) where there is no approval channel.
///
/// The refusal is explicit: instead of leaving the tool pending (which would
/// block the turn forever), callers emit a structured JSON envelope as the
/// tool's output so the model can pivot to another approach.
pub struct HeadlessToolApprovalPolicy;

impl HeadlessToolApprovalPolicy {
    /// The error code emitted to the model. Not a transient error — a refusal
    /// is deterministic and must never be retried.
    pub const ERROR_CODE: &'static str = "tool_not_authorized";

    /// Tools that capture the user's surroundings or speech — must not run
    /// unattended because finishing means recording with nobody to consent.
    pub fn privacy_sensitive_tool_names() -> &'static [&'static str] {
        &["record_audio", "speech_to_text"]
    }

    /// Tools that read or send the user's personal data, or overwrite the
    /// assistant's persistent memory.
    pub fn private_data_tool_names() -> &'static [&'static str] {
        &[
            "list_contacts",
            "search_contacts",
            "create_contact",
            "list_sms_inbox",
            "search_sms",
            "send_sms",
            "send_sms_intent",
            "list_call_log",
            "take_photo",
            "take_screenshot",
            "notification_action_click",
            "notification_reply",
            "dismiss_notification",
            "send_email_intent",
            "memory_write",
        ]
    }

    /// Expert-library write tools — an unattended run must not silently edit
    /// the roster that every later dispatch resolves against.
    pub fn expert_write_tool_names() -> &'static [&'static str] {
        &["subagent_create", "subagent_update", "subagent_delete"]
    }

    /// Install tools — allowed in headless, but what they install lands disabled.
    pub fn install_tool_names() -> &'static [&'static str] {
        &[
            "mcp_add",
            "mcp_update",
            "skill_install_from_text",
            "skill_install_from_url",
        ]
    }

    /// Convenience: check if a tool name is in the privacy-sensitive set.
    fn is_privacy_sensitive(name: &str) -> bool {
        Self::privacy_sensitive_tool_names().contains(&name)
    }

    /// Convenience: check if a tool name is in the private-data set.
    fn is_private_data(name: &str) -> bool {
        Self::private_data_tool_names().contains(&name)
    }

    /// Convenience: check if a tool name is an expert write tool.
    fn is_expert_write(name: &str) -> bool {
        Self::expert_write_tool_names().contains(&name)
    }

    /// Convenience: check if a tool name is an install tool (allowed headless).
    fn is_install_tool(name: &str) -> bool {
        Self::install_tool_names().contains(&name)
    }

    /// Why a tool must not run in a headless conversation, or None when it may.
    pub fn refusal_detail(tool_name: &str) -> Option<String> {
        let name = tool_name.trim();
        if name.is_empty() {
            return None;
        }

        // Install tools are allowed; what they install lands disabled.
        if Self::is_install_tool(name) {
            return None;
        }

        if Self::is_privacy_sensitive(name) {
            return Some(format!(
                "{} records the user's surroundings or speech and needs somebody present to \
                 consent. This conversation has no approval channel, so there is nobody to \
                 ask. It cannot run unattended.",
                name
            ));
        }

        if Self::is_private_data(name) {
            return Some(format!(
                "{} reads or sends the user's own data — contacts, messages, call log, the \
                 camera or screen, notifications — or overwrites the assistant's persistent \
                 notes. This conversation has no approval channel, so nobody is there to \
                 consent. It cannot run unattended.",
                name
            ));
        }

        if Self::is_expert_write(name) {
            return Some(format!(
                "{} rewrites the expert library, which is the set of named specialists \
                 subagent_dispatch resolves. This conversation has no approval channel, so \
                 the user cannot review the change. Ask the user to create or edit experts \
                 from the settings screen, or run the dispatch without one.",
                name
            ));
        }

        None
    }

    /// Convenience predicate over refusal_detail.
    pub fn is_refused(tool_name: &str) -> bool {
        Self::refusal_detail(tool_name).is_some()
    }

    /// The JSON envelope handed back to the model in place of the tool's real
    /// output, or None when the tool may run.
    pub fn refusal_envelope(tool_name: &str) -> Option<String> {
        let detail = Self::refusal_detail(tool_name)?;
        let envelope = json!({
            "error": Self::ERROR_CODE,
            "tool": tool_name.trim(),
            "detail": detail,
        });
        Some(envelope.to_string())
    }

    /// Refusal envelope gated on whether the call is actually headless.
    ///
    /// Keeping `headless` a parameter — instead of reading a global — is what
    /// turns "a foreground conversation is never affected" into a testable
    /// property.
    pub fn refusal_envelope_for(tool_name: &str, headless: bool) -> Option<String> {
        if headless {
            Self::refusal_envelope(tool_name)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn privacy_sensitive_tools_are_refused() {
        for name in HeadlessToolApprovalPolicy::privacy_sensitive_tool_names() {
            assert!(HeadlessToolApprovalPolicy::is_refused(name));
        }
    }

    #[test]
    fn private_data_tools_are_refused() {
        for name in HeadlessToolApprovalPolicy::private_data_tool_names() {
            assert!(HeadlessToolApprovalPolicy::is_refused(name));
        }
    }

    #[test]
    fn expert_write_tools_are_refused() {
        for name in HeadlessToolApprovalPolicy::expert_write_tool_names() {
            assert!(HeadlessToolApprovalPolicy::is_refused(name));
        }
    }

    #[test]
    fn install_tools_are_not_refused() {
        for name in HeadlessToolApprovalPolicy::install_tool_names() {
            assert!(!HeadlessToolApprovalPolicy::is_refused(name));
        }
    }

    #[test]
    fn refusal_envelope_contains_error_code() {
        let envelope = HeadlessToolApprovalPolicy::refusal_envelope("record_audio");
        assert!(envelope.is_some());
        let json: Value = serde_json::from_str(&envelope.unwrap()).unwrap();
        assert_eq!(json["error"], "tool_not_authorized");
        assert_eq!(json["tool"], "record_audio");
    }

    #[test]
    fn non_headless_never_refuses() {
        assert!(
            HeadlessToolApprovalPolicy::refusal_envelope_for("record_audio", false).is_none()
        );
    }

    #[test]
    fn headless_refuses_sensitive_tools() {
        assert!(
            HeadlessToolApprovalPolicy::refusal_envelope_for("take_screenshot", true).is_some()
        );
    }

    #[test]
    fn unknown_tool_is_not_refused() {
        assert!(!HeadlessToolApprovalPolicy::is_refused("read_file"));
        assert!(!HeadlessToolApprovalPolicy::is_refused("web_fetch"));
    }

    #[test]
    fn empty_name_is_not_refused() {
        assert!(!HeadlessToolApprovalPolicy::is_refused(""));
        assert!(!HeadlessToolApprovalPolicy::is_refused("   "));
    }
}
