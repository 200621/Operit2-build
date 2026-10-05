/// Ported from rikkahub-agent-pure's AgentNamespace.kt (D9).
///
/// Pure slug / path arithmetic for an expert's private namespace.
/// No Room, no Android — pure functions, unit-testable on a bare JVM.

const NAMESPACE_ROOT: &str = "agents";
const COLD_MEMORY_FOLDER: &str = "memory";
pub const MAX_SLUG_LENGTH: usize = 48;

pub struct AgentNamespace;

impl AgentNamespace {
    /// Derives a slug from a human name: case-folded, every run of
    /// separators collapsed to a single dash, no leading/trailing dashes,
    /// truncated to MAX_SLUG_LENGTH. Returns "" when no usable character.
    pub fn slugify(name: &str) -> String {
        let lowered = name.trim().to_lowercase();
        let mut sb = String::with_capacity(lowered.len());
        let mut pending_sep = false;
        for ch in lowered.chars() {
            if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
                if pending_sep && !sb.is_empty() {
                    sb.push('-');
                }
                pending_sep = false;
                sb.push(ch);
            } else {
                pending_sep = true;
            }
        }
        Self::truncate(&sb)
    }

    /// True when slug is exactly what slugify / edit UI may store.
    pub fn is_valid_slug(slug: &str) -> bool {
        if slug.is_empty() || slug.len() > MAX_SLUG_LENGTH {
            return false;
        }
        if slug.starts_with('-') || slug.ends_with('-') {
            return false;
        }
        slug.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    }

    /// Normalises a user-typed slug, or None when nothing usable is left.
    pub fn normalize_slug(raw: &str) -> Option<String> {
        let trimmed = raw.trim().to_lowercase();
        if trimmed.is_empty() {
            return None;
        }
        let cleaned = Self::truncate(&trimmed);
        if Self::is_valid_slug(&cleaned) {
            Some(cleaned)
        } else {
            let slugged = Self::slugify(&cleaned);
            if slugged.is_empty() { None } else { Some(slugged) }
        }
    }

    /// agents/<slug> — the expert's private directory.
    pub fn namespace_dir_for(slug: &str) -> Option<String> {
        let valid = Self::normalize_slug(slug)?;
        Some(format!("{}/{}", NAMESPACE_ROOT, valid))
    }

    /// agents/<slug>/memory — cold-memory folder.
    pub fn cold_memory_dir_for(slug: &str) -> Option<String> {
        let dir = Self::namespace_dir_for(slug)?;
        Some(format!("{}/{}", dir, COLD_MEMORY_FOLDER))
    }

    fn truncate(value: &str) -> String {
        let truncated = if value.len() <= MAX_SLUG_LENGTH {
            value.to_string()
        } else {
            value[..MAX_SLUG_LENGTH].to_string()
        };
        truncated.trim_matches('-').to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_collapses_separators() {
        assert_eq!(AgentNamespace::slugify("Deep -- Research"), "deep-research");
        assert_eq!(AgentNamespace::slugify("My Agent"), "my-agent");
        assert_eq!(AgentNamespace::slugify("Agent 2!"), "agent-2");
    }

    #[test]
    fn slugify_empty_for_non_latin() {
        assert_eq!(AgentNamespace::slugify("你好"), "");
    }

    #[test]
    fn is_valid_slug_checks_format() {
        assert!(AgentNamespace::is_valid_slug("deep-research"));
        assert!(!AgentNamespace::is_valid_slug(""));
        assert!(!AgentNamespace::is_valid_slug("-leading"));
        assert!(!AgentNamespace::is_valid_slug("trailing-"));
        assert!(!AgentNamespace::is_valid_slug(&"a".repeat(MAX_SLUG_LENGTH + 1)));
    }

    #[test]
    fn normalize_slug_works() {
        assert_eq!(AgentNamespace::normalize_slug("My Agent"), Some("my-agent".to_string()));
        assert_eq!(AgentNamespace::normalize_slug(""), None);
        assert_eq!(AgentNamespace::normalize_slug("   "), None);
    }

    #[test]
    fn namespace_dir_for_builds_path() {
        assert_eq!(
            AgentNamespace::namespace_dir_for("researcher"),
            Some("agents/researcher".to_string())
        );
        assert_eq!(AgentNamespace::namespace_dir_for(""), None);
    }

    #[test]
    fn cold_memory_dir_for_builds_path() {
        assert_eq!(
            AgentNamespace::cold_memory_dir_for("researcher"),
            Some("agents/researcher/memory".to_string())
        );
    }

    #[test]
    fn truncate_drops_trailing_dash() {
        let long = format!("{}-", "a".repeat(MAX_SLUG_LENGTH));
        let result = AgentNamespace::slugify(&long);
        assert!(!result.ends_with('-'));
        assert!(result.len() <= MAX_SLUG_LENGTH);
    }
}
