//! Structural endpoint-path derivation for catalog model discovery.

use url::Url;

/// Derives a model-list path without discarding the configured gateway prefix.
pub(super) fn models_path(endpoint: &Url, catalog_path: &str) -> Result<String, String> {
    if !catalog_path.starts_with('/')
        || catalog_path.bytes().any(|byte| matches!(byte, b'?' | b'#'))
    {
        return Err("catalog model-list path must be an absolute URL path".to_string());
    }
    let catalog_segments: Vec<_> = catalog_path.split('/').skip(1).collect();
    if catalog_segments.last() != Some(&"models") {
        return Err("catalog model-list path must end with the models resource".to_string());
    }
    let mut segments: Vec<_> = endpoint
        .path_segments()
        .ok_or_else(|| "model-list endpoint must have URL path segments".to_string())?
        .collect();
    while segments.last() == Some(&"") {
        segments.pop();
    }
    match segments.as_slice() {
        [] => Ok(catalog_path.to_string()),
        [base @ .., "chat", "completions"] | [base @ .., "responses" | "messages" | "models"] => {
            let mut resource_segments = base.to_vec();
            resource_segments.push("models");
            Ok(format!("/{}", resource_segments.join("/")))
        }
        [.., version] if is_api_version(version) => {
            segments.push("models");
            Ok(format!("/{}", segments.join("/")))
        }
        _ => {
            // A configured base path scopes the catalog route. Merge shared path
            // segments so /gateway/api plus /api/v1/models does not duplicate /api.
            let mut overlap = 0;
            for length in 1..=segments.len().min(catalog_segments.len()) {
                if segments[segments.len() - length..] == catalog_segments[..length] {
                    overlap = length;
                }
            }
            segments.extend_from_slice(&catalog_segments[overlap..]);
            Ok(format!("/{}", segments.join("/")))
        }
    }
}

/// Recognizes a complete numeric API-version segment rather than a substring.
fn is_api_version(segment: &str) -> bool {
    match segment.as_bytes() {
        [b'v' | b'V', number @ ..] => !number.is_empty() && number.iter().all(u8::is_ascii_digit),
        _ => false,
    }
}
