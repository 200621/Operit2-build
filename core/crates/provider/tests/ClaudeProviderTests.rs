use super::ClaudeProvider;
use crate::chat::llmprovider::MediaLinkBuilder::MediaLinkBuilder;
use operit_util::ImagePoolManager::ImagePoolManager;

/// Creates a Claude provider for content-block conversion tests.
fn test_provider() -> ClaudeProvider {
    ClaudeProvider::new(
        "http://localhost".to_string(),
        String::new(),
        "claude-test".to_string(),
        "CLAUDE".to_string(),
        Vec::new(),
        true,
    )
}

/// Verifies image media links become Claude base64 image blocks.
#[test]
fn imageLinksBecomeClaudeImageBlocks() {
    let image_id = ImagePoolManager::add_image_bytes(
        b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01",
        Some("image/png"),
        None,
    );
    let prompt = format!("look {}", MediaLinkBuilder::image(&image_id));
    let provider = test_provider();

    let content = provider.build_content_array(&prompt);
    let blocks = content.as_array().expect("Claude content must be an array");

    assert_eq!(blocks.len(), 2);
    assert_eq!(blocks[0]["type"], "image");
    assert_eq!(blocks[0]["source"]["media_type"], "image/png");
    assert!(!blocks[0]["source"]["data"]
        .as_str()
        .unwrap_or_default()
        .is_empty());
    assert_eq!(blocks[1]["text"], "look");
    ImagePoolManager::remove_image(&image_id);
}
