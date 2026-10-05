pub struct ToolExecutionLimits;

impl ToolExecutionLimits {
    pub const MAX_FILE_READ_BYTES: usize = 32_000;
    pub const DEFAULT_FILE_READ_PART_LINES: usize = 200;
    pub const MAX_TEXT_RESULT_LENGTH: usize = 5_000;
    pub const MAX_FINAL_TOOL_RESULT_MESSAGE_CHARS: usize = Self::MAX_FILE_READ_BYTES * 2;

    // --- Pure port: long-run survival limits ---

    /// Default per-turn wall-clock budget in milliseconds.
    /// 0 means no limit. Ported from rikkahub-agent-pure's ToolRuntimeLimits.kt.
    pub const DEFAULT_TURN_BUDGET_MS: u64 = 0;

    /// Default maximum tool-call iterations per turn.
    /// Ported from rikkahub-agent-pure's ToolRuntimeLimits.kt (was hardcoded at 32).
    pub const DEFAULT_MAX_TOOL_STEPS: u32 = 32;

    /// Default tool result token budget for truncation.
    /// None means no truncation. When set, oversized tool results keep head + tail.
    /// Ported from rikkahub-agent-pure's ToolResultTruncation.kt.
    pub const DEFAULT_TOOL_RESULT_TOKEN_BUDGET: Option<usize> = None;

    /// Spill directory for full tool outputs that were truncated.
    /// The model can read back from this path on demand.
    pub const TOOL_OUTPUTS_DIR: &'static str = "/tool_outputs/";
}
