use super::AIService::AiServiceError;

/// Extracts one complete UTF-8 line without decoding partial transport chunks.
#[allow(non_snake_case)]
pub(super) fn takeNextStreamingLine(
    pending_bytes: &mut Vec<u8>,
) -> Result<Option<String>, AiServiceError> {
    let Some(newline_index) = pending_bytes.iter().position(|byte| *byte == b'\n') else {
        return Ok(None);
    };
    let line_bytes = pending_bytes.drain(..=newline_index).collect::<Vec<u8>>();
    String::from_utf8(line_bytes)
        .map(|line| Some(line.trim().to_string()))
        .map_err(|error| AiServiceError::ConnectionFailed(error.to_string()))
}

/// Strictly decodes the remaining line when the response stream ends.
#[allow(non_snake_case)]
pub(super) fn decodeStreamingTail(pending_bytes: &mut Vec<u8>) -> Result<String, AiServiceError> {
    String::from_utf8(std::mem::take(pending_bytes))
        .map(|line| line.trim().to_string())
        .map_err(|error| AiServiceError::ConnectionFailed(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::{decodeStreamingTail, takeNextStreamingLine};
    use crate::chat::llmprovider::AIService::AiServiceError;

    /// Preserves multilingual tool content at every possible transport split.
    #[test]
    fn every_transport_split_preserves_tool_content() {
        let line = "data: {\"content\":\"协同空间 中文 👩‍💻 & <tag>\"}";
        let encoded = format!("{line}\r\n").into_bytes();
        for split in 0..encoded.len() {
            let mut pending = encoded[..split].to_vec();
            assert_eq!(takeNextStreamingLine(&mut pending).unwrap(), None);
            pending.extend_from_slice(&encoded[split..]);
            assert_eq!(
                takeNextStreamingLine(&mut pending).unwrap(),
                Some(line.to_string())
            );
            assert!(pending.is_empty());
        }
    }

    /// Preserves text even when every byte arrives in a separate network chunk.
    #[test]
    fn single_byte_chunks_preserve_tool_content() {
        let line = "data: {\"content\":\"你好😀\"}";
        let mut pending = Vec::new();
        let mut lines = Vec::new();
        for byte in format!("{line}\n").bytes() {
            pending.push(byte);
            while let Some(decoded) = takeNextStreamingLine(&mut pending).unwrap() {
                lines.push(decoded);
            }
        }
        assert_eq!(lines, vec![line.to_string()]);
        assert_eq!(decodeStreamingTail(&mut pending).unwrap(), "");
    }

    /// Retains an unfinished final line after extracting complete SSE lines.
    #[test]
    fn multiple_lines_retain_the_unterminated_tail() {
        let mut pending = "data: 一\n\ndata: 二".as_bytes().to_vec();
        assert_eq!(
            takeNextStreamingLine(&mut pending).unwrap(),
            Some("data: 一".to_string())
        );
        assert_eq!(
            takeNextStreamingLine(&mut pending).unwrap(),
            Some(String::new())
        );
        assert_eq!(takeNextStreamingLine(&mut pending).unwrap(), None);
        assert_eq!(decodeStreamingTail(&mut pending).unwrap(), "data: 二");
        assert!(pending.is_empty());
    }

    /// Rejects invalid UTF-8 instead of injecting replacement characters.
    #[test]
    fn invalid_utf8_line_returns_a_transport_error() {
        let mut pending = vec![b'd', 0xff, b'\n'];
        assert!(matches!(
            takeNextStreamingLine(&mut pending),
            Err(AiServiceError::ConnectionFailed(_))
        ));
    }

    /// Rejects a stream that ends before completing a multibyte character.
    #[test]
    fn truncated_utf8_tail_returns_a_transport_error() {
        let encoded = "中".as_bytes();
        let mut pending = encoded[..2].to_vec();
        assert_eq!(takeNextStreamingLine(&mut pending).unwrap(), None);
        assert!(matches!(
            decodeStreamingTail(&mut pending),
            Err(AiServiceError::ConnectionFailed(_))
        ));
    }
}
