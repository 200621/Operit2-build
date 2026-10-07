use serde_json::Value;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MCPToolParameter {
    pub name: String,
    pub parameter_type: String,
    pub description: String,
    pub required: bool,
    pub defaultValue: Option<String>,
}

impl MCPToolParameter {
    #[allow(non_snake_case)]
    /// Converts one parameter using its declared schema type.
    pub fn convertParameterValue(&self, value: Value) -> Value {
        match value {
            Value::String(text) => {
                Self::smartConvert(Value::String(text), Some(&self.parameter_type))
            }
            other => other,
        }
    }

    #[allow(non_snake_case)]
    /// Converts textual parameters while preserving declared strings and typed JSON values.
    pub fn smartConvert(value: Value, typeName: Option<&str>) -> Value {
        match value {
            Value::String(text) => match typeName.map(|value| value.to_ascii_lowercase()) {
                Some(value) if value == "string" => Value::String(text),
                Some(value) if value == "number" => parseNumberValue(&text),
                Some(value) if value == "boolean" => {
                    Value::Bool(text.to_ascii_lowercase() == "true")
                }
                Some(value) if value == "integer" => text
                    .parse::<i64>()
                    .map(|number| serde_json::json!(number))
                    .unwrap_or(Value::String(text)),
                Some(value) if value == "float" || value == "double" => text
                    .parse::<f64>()
                    .map(|number| serde_json::json!(number))
                    .unwrap_or(Value::String(text)),
                Some(value) if value == "array" => parseArrayValue(&text),
                Some(value) if value == "object" => parseObjectValue(&text),
                _ => guessValue(&text),
            },
            other => other,
        }
    }
}

#[allow(non_snake_case)]
/// Parses a textual numeric parameter.
fn parseNumberValue(text: &str) -> Value {
    if text.contains('.') {
        text.parse::<f64>()
            .map(|number| serde_json::json!(number))
            .unwrap_or_else(|_| Value::String(text.to_string()))
    } else {
        text.parse::<i64>()
            .map(|number| serde_json::json!(number))
            .unwrap_or_else(|_| Value::String(text.to_string()))
    }
}

#[allow(non_snake_case)]
/// Parses an array parameter without reinterpreting values inside valid JSON.
fn parseArrayValue(text: &str) -> Value {
    let trimmed = text.trim();
    if let Ok(Value::Array(items)) = serde_json::from_str::<Value>(trimmed) {
        return Value::Array(items);
    }
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        let content = trimmed[1..trimmed.len() - 1].trim();
        if content
            .chars()
            .all(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-' | ',' | ' '))
        {
            return Value::Array(
                content
                    .split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .map(|item| {
                        MCPToolParameter::smartConvert(Value::String(item.to_string()), None)
                    })
                    .collect(),
            );
        }
    }
    Value::String(text.to_string())
}

#[allow(non_snake_case)]
/// Parses an object parameter without reinterpreting its nested JSON values.
fn parseObjectValue(text: &str) -> Value {
    let trimmed = text.trim();
    if let Ok(Value::Object(object)) = serde_json::from_str::<Value>(trimmed) {
        return Value::Object(object);
    }
    Value::String(text.to_string())
}

#[allow(non_snake_case)]
/// Infers the type of textual parameters that do not declare a supported schema type.
fn guessValue(text: &str) -> Value {
    let trimmed = text.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') {
        return parseObjectValue(text);
    }
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        return parseArrayValue(text);
    }
    if trimmed
        .chars()
        .all(|ch| ch.is_ascii_digit() || matches!(ch, '-' | '.'))
        && trimmed.chars().any(|ch| ch.is_ascii_digit())
    {
        return parseNumberValue(trimmed);
    }
    if matches!(trimmed.to_ascii_lowercase().as_str(), "true" | "false") {
        return Value::Bool(trimmed.eq_ignore_ascii_case("true"));
    }
    Value::String(text.to_string())
}

#[cfg(test)]
mod tests {
    use super::MCPToolParameter;
    use serde_json::{json, Value};

    /// Preserves write content declared as string regardless of its textual appearance.
    #[test]
    fn declared_string_content_is_preserved() {
        for content in [
            "123",
            "00123",
            "true",
            "false",
            "{\"a\":1}",
            "[1,2]",
            " 123 ",
            "中文😀",
            "",
            "\n",
        ] {
            let value = Value::String(content.to_string());
            assert_eq!(
                MCPToolParameter::smartConvert(value.clone(), Some("string")),
                value
            );
        }
    }

    /// Preserves quoted numeric and boolean strings inside JSON array parameters.
    #[test]
    fn json_array_preserves_nested_string_types() {
        let value = json!(["123", "true", "{\"a\":1}", ["false"], {"content": "00123"}, 123, true]);
        assert_eq!(
            MCPToolParameter::smartConvert(Value::String(value.to_string()), Some("array")),
            value
        );
    }

    /// Preserves string fields inside object parameters used by write tools.
    #[test]
    fn json_object_preserves_nested_string_types() {
        let value = json!({"content": "123", "enabled": "false", "items": ["true", "00123"], "nested": {"text": "[1,2]"}});
        assert_eq!(
            MCPToolParameter::smartConvert(Value::String(value.to_string()), Some("object")),
            value
        );
    }

    /// Leaves already typed JSON arrays and objects unchanged.
    #[test]
    fn typed_json_values_are_preserved() {
        for value in [json!(["123", "false", ["true"]]), json!({"text": "00123"})] {
            assert_eq!(MCPToolParameter::smartConvert(value.clone(), None), value);
        }
    }

    /// Keeps numeric and boolean conversion for explicitly declared scalar parameters.
    #[test]
    fn declared_scalar_types_still_convert() {
        for (text, schema_type, expected) in [
            ("123", "integer", json!(123)),
            ("1.5", "number", json!(1.5)),
            ("true", "boolean", json!(true)),
        ] {
            assert_eq!(
                MCPToolParameter::smartConvert(Value::String(text.to_string()), Some(schema_type)),
                expected
            );
        }
    }
}
