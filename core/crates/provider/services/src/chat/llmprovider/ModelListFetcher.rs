use operit_host_api::HostManager::defaultHttpHost;
use operit_host_api::HttpRequestData;
use serde_json::Value;

use crate::chat::llmprovider::OpenCodeProvider::OpenCodeRouting;
use operit_model::BillingMode::BillingMode;
use operit_model::ModelConfigData::{
    ApiProviderType, AvailableProviderModel, AvailableProviderModelSource, ModelCapabilities,
    ModelContextSpec, ModelPricing, ModelRequestSpec, PricingCurrency, ProviderCatalogEntry,
    ProviderOperationSpec, ProviderProfile,
};

pub struct ModelListFetcher;

impl ModelListFetcher {
    /// Fetches provider models through the configured catalog operation.
    #[allow(non_snake_case)]
    pub fn fetch(
        provider: &ProviderProfile,
        providerCatalog: &ProviderCatalogEntry,
    ) -> Result<Vec<AvailableProviderModel>, String> {
        let operation = match providerCatalog
            .operations
            .iter()
            .find(|operation| operation.operationType == "list_models")
        {
            Some(operation) => operation,
            None => return Ok(Vec::new()),
        };

        let response = Self::requestJson(provider, operation)?;
        let items = selectJsonPath(
            &response,
            operation
                .result
                .itemsJsonPath
                .as_deref()
                .ok_or_else(|| "list_models operation missing itemsJsonPath".to_string())?,
        )
        .ok_or_else(|| "list_models response items not found".to_string())?
        .as_array()
        .ok_or_else(|| "list_models response items is not an array".to_string())?;

        items
            .iter()
            .map(|item| Self::parseItem(item, operation))
            .collect()
    }

    /// Executes the provider model list request through the configured HTTP host.
    #[allow(non_snake_case)]
    fn requestJson(
        provider: &ProviderProfile,
        operation: &ProviderOperationSpec,
    ) -> Result<Value, String> {
        if operation.handlerId != "http_json" {
            return Err(format!(
                "unsupported provider operation handler: {}",
                operation.handlerId
            ));
        }
        if operation.method != "GET" {
            return Err(format!(
                "unsupported provider operation method: {}",
                operation.method
            ));
        }

        let requestUrl = operationUrl(provider, operation)?;
        let requestHeaders = headers(provider, operation)?;

        let response = defaultHttpHost()
            .executeHttpRequest(HttpRequestData {
                url: requestUrl,
                method: operation.method.clone(),
                headers: requestHeaders,
                body: Vec::new(),
                formFields: Vec::new(),
                fileParts: Vec::new(),
                connectTimeoutSeconds: 30,
                readTimeoutSeconds: 120,
                followRedirects: true,
                ignoreSsl: false,
                proxyHost: String::new(),
                proxyPort: 0,
            })
            .map_err(|error| error.to_string())?;
        let body = String::from_utf8(response.body)
            .map_err(|error| format!("list_models response body is not UTF-8: {error}"))?;
        if response.statusCode < 200 || response.statusCode >= 300 {
            return Err(format!(
                "list_models request failed: {} {body}",
                response.statusCode
            ));
        }
        serde_json::from_str(&body).map_err(|error| error.to_string())
    }

    /// Parses one provider model item into a runtime model option.
    #[allow(non_snake_case)]
    fn parseItem(
        item: &Value,
        operation: &ProviderOperationSpec,
    ) -> Result<AvailableProviderModel, String> {
        let modelId = readRequiredString(
            item,
            operation
                .result
                .itemIdJsonPath
                .as_deref()
                .ok_or_else(|| "list_models operation missing itemIdJsonPath".to_string())?,
        )?;
        let capabilities = readCapabilities(item, operation)?;
        let request = readRequest(item, operation)?;
        Ok(AvailableProviderModel {
            modelId,
            source: AvailableProviderModelSource::Remote,
            pricing: readPricing(item, operation)?,
            context: readContext(item, operation)?,
            capabilities,
            builtinTools: Vec::new(),
            request: Some(request),
        })
    }
}

/// Builds the provider operation URL from the chat endpoint and operation path.
#[allow(non_snake_case)]
fn operationUrl(
    provider: &ProviderProfile,
    operation: &ProviderOperationSpec,
) -> Result<String, String> {
    let mut url = if provider.providerType == ApiProviderType::OPENCODE
        && operation.operationType == "list_models"
    {
        // Unlike root-relative catalog paths, OpenCode routes live below Zen or Go.
        // Reuse the same normalization as the inference provider and the Kotlin port.
        url::Url::parse(&OpenCodeRouting::models_endpoint(&provider.endpoint))
    } else {
        url::Url::parse(&provider.endpoint).map(|mut url| {
            url.set_path(&operation.path);
            url
        })
    }
    .map_err(|error| error.to_string())?;
    url.set_query(None);
    url.set_fragment(None);
    Ok(url.to_string())
}

/// Builds HTTP headers required by the provider operation.
#[allow(non_snake_case)]
fn headers(
    provider: &ProviderProfile,
    operation: &ProviderOperationSpec,
) -> Result<Vec<(String, String)>, String> {
    let customHeaders = serde_json::from_str::<serde_json::Value>(&provider.customHeaders)
        .map_err(|error| error.to_string())?;
    let object = customHeaders
        .as_object()
        .ok_or_else(|| "customHeaders is not a JSON object".to_string())?;
    if matches!(
        provider.providerType,
        ApiProviderType::ANTHROPIC | ApiProviderType::ANTHROPIC_GENERIC
    ) {
        return anthropicHeaders(provider, operation, object);
    }
    let mut headers = vec![("Content-Type".to_string(), "application/json".to_string())];
    let isOpenCode = provider.providerType == ApiProviderType::OPENCODE;
    let mut hasAuthorization = false;
    for (name, value) in object {
        let headerValue = value
            .as_str()
            .ok_or_else(|| format!("customHeaders value for {name} is not a string"))?;
        if isOpenCode && name.eq_ignore_ascii_case("User-Agent") {
            // OpenCode expects the agent-owned identity, not a generic HTTP client.
            continue;
        }
        if name.eq_ignore_ascii_case("Authorization") {
            if (operation.requiresApiKey || isOpenCode) && headerValue.trim().is_empty() {
                // An empty legacy custom header must not erase the generated API key.
                continue;
            }
            hasAuthorization = !headerValue.trim().is_empty();
        }
        headers.push((name.clone(), headerValue.to_string()));
    }
    if !hasAuthorization && (operation.requiresApiKey || isOpenCode) {
        if let Some(apiKey) = apiKey(provider) {
            headers.push(("Authorization".to_string(), bearerAuthorization(apiKey)));
        } else if operation.requiresApiKey {
            return Err("provider api key is required".to_string());
        }
    }
    if isOpenCode {
        headers.push((
            "User-Agent".to_string(),
            format!("Operit/{}", env!("CARGO_PKG_VERSION")),
        ));
    }
    Ok(headers)
}

/// Builds Anthropic protocol headers with explicit custom-header overrides.
#[allow(non_snake_case)]
fn anthropicHeaders(
    provider: &ProviderProfile,
    operation: &ProviderOperationSpec,
    customHeaders: &serde_json::Map<String, Value>,
) -> Result<Vec<(String, String)>, String> {
    // Match the Kotlin model-list request and the Claude inference protocol.
    // Anthropic requires its version header and authenticates with x-api-key.
    let mut headers = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        ("anthropic-version".to_string(), "2023-06-01".to_string()),
    ];
    if let Some(apiKey) = apiKey(provider) {
        headers.push(("x-api-key".to_string(), apiKey.to_string()));
    }
    for (name, value) in customHeaders {
        let headerValue = value
            .as_str()
            .ok_or_else(|| format!("customHeaders value for {name} is not a string"))?;
        headers.retain(|(existingName, _)| !existingName.eq_ignore_ascii_case(name));
        headers.push((name.clone(), headerValue.to_string()));
    }
    if !headers.iter().any(|(name, value)| {
        name.eq_ignore_ascii_case("anthropic-version") && !value.trim().is_empty()
    }) {
        return Err("Anthropic anthropic-version header is required".to_string());
    }
    if operation.requiresApiKey
        && !headers
            .iter()
            .any(|(name, value)| name.eq_ignore_ascii_case("x-api-key") && !value.trim().is_empty())
    {
        return Err("Anthropic x-api-key header is required".to_string());
    }
    Ok(headers)
}

/// Keeps an already-prefixed API key usable while normalizing raw keys.
#[allow(non_snake_case)]
fn bearerAuthorization(apiKey: &str) -> String {
    let apiKey = apiKey.trim();
    let mut parts = apiKey.split_whitespace();
    if matches!(
        (parts.next(), parts.next()),
        (Some(scheme), Some(_)) if scheme.eq_ignore_ascii_case("Bearer")
    ) {
        return apiKey.to_string();
    }
    format!("Bearer {apiKey}")
}

/// Selects the API key used by the provider model list request.
#[allow(non_snake_case)]
fn apiKey(provider: &ProviderProfile) -> Option<&str> {
    if provider.useMultipleApiKeys {
        let apiKeys: Vec<&str> = provider
            .apiKeyPool
            .iter()
            .filter(|info| info.isEnabled && !info.key.trim().is_empty())
            .map(|info| info.key.trim())
            .collect();
        if apiKeys.is_empty() {
            return None;
        }
        let index = provider.currentKeyIndex.rem_euclid(apiKeys.len() as i32) as usize;
        return Some(apiKeys[index]);
    }
    let apiKey = provider.apiKey.trim();
    if apiKey.is_empty() {
        return None;
    }
    Some(apiKey)
}

/// Reads pricing metadata from one provider model item.
#[allow(non_snake_case)]
fn readPricing(
    item: &Value,
    operation: &ProviderOperationSpec,
) -> Result<Option<ModelPricing>, String> {
    let input = readOptionalF64(item, operation.result.inputPricePerTokenJsonPath.as_deref())?;
    let output = readOptionalF64(
        item,
        operation.result.outputPricePerTokenJsonPath.as_deref(),
    )?;
    let currency = readOptionalString(item, operation.result.currencyJsonPath.as_deref())?;
    match (input, output, currency) {
        (Some(input), Some(output), Some(currency)) => Ok(Some(ModelPricing {
            billingMode: BillingMode::TOKEN,
            inputPricePerMillion: input * 1_000_000.0,
            cachedInputPricePerMillion: readOptionalF64(
                item,
                operation.result.cachedInputPricePerTokenJsonPath.as_deref(),
            )?
            .map(|value| value * 1_000_000.0),
            cacheWritePricePerMillion: None,
            outputPricePerMillion: output * 1_000_000.0,
            pricePerRequest: readOptionalF64(
                item,
                operation.result.pricePerRequestJsonPath.as_deref(),
            )?
            .unwrap_or(0.0),
            currency: parseCurrency(&currency)?,
        })),
        _ => Ok(None),
    }
}

/// Reads context-window metadata from one provider model item.
#[allow(non_snake_case)]
fn readContext(
    item: &Value,
    operation: &ProviderOperationSpec,
) -> Result<Option<ModelContextSpec>, String> {
    let maxContextLength =
        readOptionalF32(item, operation.result.maxContextLengthJsonPath.as_deref())?;
    match maxContextLength {
        Some(maxContextLength) => Ok(Some(ModelContextSpec {
            maxContextLength: maxContextLength / 1000.0,
        })),
        None => Ok(None),
    }
}

/// Reads model capability metadata from one provider model item.
#[allow(non_snake_case)]
fn readCapabilities(
    item: &Value,
    operation: &ProviderOperationSpec,
) -> Result<Option<ModelCapabilities>, String> {
    let values = [
        readOptionalBool(item, operation.result.directImageJsonPath.as_deref())?,
        readOptionalBool(item, operation.result.directAudioJsonPath.as_deref())?,
        readOptionalBool(item, operation.result.directVideoJsonPath.as_deref())?,
        readOptionalBool(item, operation.result.toolCallJsonPath.as_deref())?,
    ];
    if values.iter().all(Option::is_none) {
        return Ok(None);
    }
    Ok(Some(ModelCapabilities {
        directImage: values[0].unwrap_or(false),
        directAudio: values[1].unwrap_or(false),
        directVideo: values[2].unwrap_or(false),
        toolCall: values[3].unwrap_or(false),
    }))
}

/// Reads request-shape metadata from one provider model item.
#[allow(non_snake_case)]
fn readRequest(
    item: &Value,
    operation: &ProviderOperationSpec,
) -> Result<ModelRequestSpec, String> {
    let supportsStructuredTools = readOptionalBool(
        item,
        operation.result.supportsStructuredToolsJsonPath.as_deref(),
    )?
    .unwrap_or(false);
    Ok(ModelRequestSpec {
        supportsStructuredTools,
    })
}

/// Reads a required string from one JSON path or literal spec.
#[allow(non_snake_case)]
fn readRequiredString(item: &Value, spec: &str) -> Result<String, String> {
    readOptionalString(item, Some(spec))?.ok_or_else(|| format!("required value not found: {spec}"))
}

/// Reads an optional string from one JSON path or literal spec.
#[allow(non_snake_case)]
fn readOptionalString(item: &Value, spec: Option<&str>) -> Result<Option<String>, String> {
    let Some(spec) = spec else {
        return Ok(None);
    };
    if !spec.starts_with('$') {
        return Ok(Some(spec.to_string()));
    }
    Ok(selectJsonPath(item, spec).and_then(jsonValueString))
}

/// Reads an optional f64 value from one JSON path or literal spec.
#[allow(non_snake_case)]
fn readOptionalF64(item: &Value, spec: Option<&str>) -> Result<Option<f64>, String> {
    let Some(value) = readOptionalString(item, spec)? else {
        return Ok(None);
    };
    value
        .parse::<f64>()
        .map(Some)
        .map_err(|error| error.to_string())
}

/// Reads an optional f32 value from one JSON path or literal spec.
#[allow(non_snake_case)]
fn readOptionalF32(item: &Value, spec: Option<&str>) -> Result<Option<f32>, String> {
    let Some(value) = readOptionalString(item, spec)? else {
        return Ok(None);
    };
    value
        .parse::<f32>()
        .map(Some)
        .map_err(|error| error.to_string())
}

/// Reads an optional boolean from one JSON path, literal spec, or containment spec.
#[allow(non_snake_case)]
fn readOptionalBool(item: &Value, spec: Option<&str>) -> Result<Option<bool>, String> {
    let Some(spec) = spec else {
        return Ok(None);
    };
    if let Some((path, expected)) = spec.split_once('~') {
        let Some(value) = selectJsonPath(item, path) else {
            return Ok(Some(false));
        };
        return Ok(Some(jsonContains(value, expected)));
    }
    if !spec.starts_with('$') {
        return spec
            .parse::<bool>()
            .map(Some)
            .map_err(|error| error.to_string());
    }
    Ok(selectJsonPath(item, spec).and_then(Value::as_bool))
}

/// Selects a JSON value using the catalog's dot-and-index path syntax.
#[allow(non_snake_case)]
fn selectJsonPath<'a>(value: &'a Value, path: &str) -> Option<&'a Value> {
    if path == "$" {
        return Some(value);
    }
    let mut current = value;
    let path = path.strip_prefix("$.")?;
    for segment in path.split('.') {
        current = selectSegment(current, segment)?;
    }
    Some(current)
}

/// Selects one named or indexed segment from a JSON value.
#[allow(non_snake_case)]
fn selectSegment<'a>(value: &'a Value, segment: &str) -> Option<&'a Value> {
    let mut current = value;
    let mut rest = segment;
    let nameEnd = rest.find('[').unwrap_or(rest.len());
    let name = &rest[..nameEnd];
    if !name.is_empty() {
        current = current.get(name)?;
    }
    rest = &rest[nameEnd..];
    while !rest.is_empty() {
        let end = rest.find(']')?;
        let index = rest[1..end].parse::<usize>().ok()?;
        current = current.as_array()?.get(index)?;
        rest = &rest[end + 1..];
    }
    Some(current)
}

/// Converts scalar JSON values into strings used by catalog readers.
#[allow(non_snake_case)]
fn jsonValueString(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(value.clone()),
        Value::Number(value) => Some(value.to_string()),
        Value::Bool(value) => Some(value.to_string()),
        _ => None,
    }
}

/// Tests whether a JSON scalar or array contains the expected catalog value.
#[allow(non_snake_case)]
fn jsonContains(value: &Value, expected: &str) -> bool {
    match value {
        Value::Array(items) => items
            .iter()
            .filter_map(jsonValueString)
            .any(|value| value == expected),
        _ => jsonValueString(value)
            .map(|value| value == expected)
            .unwrap_or(false),
    }
}

/// Parses a provider pricing currency literal.
#[allow(non_snake_case)]
fn parseCurrency(value: &str) -> Result<PricingCurrency, String> {
    match value.trim().to_ascii_uppercase().as_str() {
        "CNY" => Ok(PricingCurrency::CNY),
        "USD" => Ok(PricingCurrency::USD),
        other => Err(format!("invalid pricing currency: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use operit_model::ModelConfigData::{ApiProviderType, ProviderOperationResultSpec};

    /// Creates a provider profile for model-list request tests.
    fn testProvider(apiKey: &str, customHeaders: &str) -> ProviderProfile {
        let mut provider = ProviderProfile::new(
            "test-provider".to_string(),
            "Test Provider".to_string(),
            ApiProviderType::MINIMAX,
            "https://example.com/v1/chat/completions".to_string(),
        );
        provider.apiKey = apiKey.to_string();
        provider.customHeaders = customHeaders.to_string();
        provider
    }

    /// Creates a model-list operation with configurable authentication requirements.
    fn testOperation(requiresApiKey: bool) -> ProviderOperationSpec {
        ProviderOperationSpec {
            operationType: "list_models".to_string(),
            handlerId: "http_json".to_string(),
            method: "GET".to_string(),
            path: "/v1/models".to_string(),
            requiresApiKey,
            result: ProviderOperationResultSpec {
                itemsJsonPath: None,
                itemIdJsonPath: None,
                inputPricePerTokenJsonPath: None,
                cachedInputPricePerTokenJsonPath: None,
                outputPricePerTokenJsonPath: None,
                pricePerRequestJsonPath: None,
                currencyJsonPath: None,
                maxContextLengthJsonPath: None,
                directImageJsonPath: None,
                directAudioJsonPath: None,
                directVideoJsonPath: None,
                toolCallJsonPath: None,
                supportsStructuredToolsJsonPath: None,
                amountJsonPath: None,
                amountCurrencyJsonPath: None,
            },
        }
    }

    /// Keeps official and generic Anthropic model requests on the same protocol.
    #[test]
    fn anthropic_model_list_uses_version_and_api_key_headers() {
        for providerType in [
            ApiProviderType::ANTHROPIC,
            ApiProviderType::ANTHROPIC_GENERIC,
        ] {
            let mut provider = testProvider("sk-ant-test", "{}");
            provider.providerType = providerType;
            let headers = headers(&provider, &testOperation(true)).unwrap();
            assert_eq!(
                headers,
                vec![
                    ("Content-Type".to_string(), "application/json".to_string()),
                    ("anthropic-version".to_string(), "2023-06-01".to_string()),
                    ("x-api-key".to_string(), "sk-ant-test".to_string()),
                ]
            );
        }
    }

    /// Applies explicit Anthropic header overrides without duplicate header names.
    #[test]
    fn anthropic_custom_headers_override_protocol_headers_case_insensitively() {
        let mut provider = testProvider(
            "sk-ant-test",
            r#"{"X-Api-Key":"custom-key","Anthropic-Version":"2023-06-01","X-Test":"keep-me"}"#,
        );
        provider.providerType = ApiProviderType::ANTHROPIC_GENERIC;
        let headers = headers(&provider, &testOperation(true)).unwrap();
        for (name, expected) in [
            ("x-api-key", "custom-key"),
            ("anthropic-version", "2023-06-01"),
            ("x-test", "keep-me"),
        ] {
            let values: Vec<_> = headers
                .iter()
                .filter(|(headerName, _)| headerName.eq_ignore_ascii_case(name))
                .map(|(_, value)| value.as_str())
                .collect();
            assert_eq!(values, vec![expected]);
        }
        assert!(!headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("Authorization")));
    }

    /// Rejects missing or explicitly emptied Anthropic protocol headers.
    #[test]
    fn anthropic_invalid_authentication_and_version_are_reported() {
        for (apiKey, customHeaders) in [
            ("", "{}"),
            ("", r#"{"Authorization":"Bearer custom"}"#),
            ("sk-ant-test", r#"{"X-Api-Key":" "}"#),
            ("sk-ant-test", r#"{"Anthropic-Version":" "}"#),
            ("sk-ant-test", r#"{"X-Api-Key":123}"#),
        ] {
            let mut provider = testProvider(apiKey, customHeaders);
            provider.providerType = ApiProviderType::ANTHROPIC;
            assert!(headers(&provider, &testOperation(true)).is_err());
        }
    }

    /// Authenticates Anthropic requests with the enabled key selected by rotation.
    #[test]
    fn anthropic_model_list_uses_the_selected_api_key_pool_entry() {
        use operit_model::ApiKeyInfo::ApiKeyInfo;
        let mut provider = testProvider("unused", "{}");
        provider.providerType = ApiProviderType::ANTHROPIC;
        provider.useMultipleApiKeys = true;
        let mut disabled = ApiKeyInfo::new("disabled".to_string(), "disabled-key".to_string());
        disabled.isEnabled = false;
        provider.apiKeyPool = vec![
            disabled,
            ApiKeyInfo::new("blank".to_string(), " ".to_string()),
            ApiKeyInfo::new("first".to_string(), "sk-ant-first".to_string()),
            ApiKeyInfo::new("second".to_string(), "sk-ant-second".to_string()),
        ];
        provider.currentKeyIndex = -1;
        let headers = headers(&provider, &testOperation(true)).unwrap();
        assert!(headers
            .iter()
            .any(|(name, value)| name == "x-api-key" && value == "sk-ant-second"));
        provider.apiKeyPool.clear();
        assert!(super::headers(&provider, &testOperation(true)).is_err());
    }

    #[test]
    fn generated_authorization_survives_empty_custom_header() {
        let provider = testProvider("sk-test", r#"{"Authorization":""}"#);
        let headers = headers(&provider, &testOperation(true)).expect("headers should build");
        let authorization = headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("authorization"))
            .map(|(_, value)| value.as_str());
        assert_eq!(authorization, Some("Bearer sk-test"));
        assert_eq!(
            headers
                .iter()
                .filter(|(name, _)| name.eq_ignore_ascii_case("authorization"))
                .count(),
            1
        );
    }

    #[test]
    fn bearer_prefix_is_not_duplicated() {
        assert_eq!(bearerAuthorization("Bearer sk-test"), "Bearer sk-test");
        assert_eq!(bearerAuthorization("sk-test"), "Bearer sk-test");
    }

    #[test]
    fn non_empty_custom_authorization_is_preserved() {
        let provider = testProvider("sk-test", r#"{"authorization":"Token custom"}"#);
        let headers = headers(&provider, &testOperation(true)).expect("headers should build");
        let authorization = headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("authorization"))
            .map(|(_, value)| value.as_str());
        assert_eq!(authorization, Some("Token custom"));
    }

    fn openCodeProvider(endpoint: &str, apiKey: &str, customHeaders: &str) -> ProviderProfile {
        let mut provider = testProvider(apiKey, customHeaders);
        provider.providerType = ApiProviderType::OPENCODE;
        provider.providerTypeId = "OPENCODE".to_string();
        provider.endpoint = endpoint.to_string();
        provider
    }

    fn openCodeOperation() -> ProviderOperationSpec {
        operit_model::ModelCatalog::ModelCatalog::provider("OPENCODE")
            .expect("OpenCode catalog should exist")
            .operations
            .into_iter()
            .find(|operation| operation.operationType == "list_models")
            .expect("OpenCode should support model listing")
    }

    #[test]
    fn opencode_model_urls_preserve_zen_and_go_base_paths() {
        for (endpoint, expected) in [
            (
                "https://opencode.ai/zen",
                "https://opencode.ai/zen/v1/models",
            ),
            (
                "https://opencode.ai/zen/",
                "https://opencode.ai/zen/v1/models",
            ),
            (
                "https://opencode.ai/zen/v1",
                "https://opencode.ai/zen/v1/models",
            ),
            (
                "https://opencode.ai/zen/v1/",
                "https://opencode.ai/zen/v1/models",
            ),
            (
                "https://opencode.ai/zen/go",
                "https://opencode.ai/zen/go/v1/models",
            ),
            (
                "https://opencode.ai/zen/go/v1/",
                "https://opencode.ai/zen/go/v1/models",
            ),
            (
                "https://gateway.example/proxy/zen/go",
                "https://gateway.example/proxy/zen/go/v1/models",
            ),
        ] {
            let provider = openCodeProvider(endpoint, "sk-test", "{}");
            assert_eq!(
                operationUrl(&provider, &openCodeOperation()).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn opencode_model_listing_sets_agent_user_agent() {
        let provider = openCodeProvider(
            "https://opencode.ai/zen/go",
            "sk-test",
            r#"{"user-agent":"custom-client","X-Test":"keep-me"}"#,
        );
        let headers = headers(&provider, &openCodeOperation()).unwrap();
        let userAgents: Vec<_> = headers
            .iter()
            .filter(|(name, _)| name.eq_ignore_ascii_case("User-Agent"))
            .map(|(_, value)| value.as_str())
            .collect();
        assert_eq!(
            userAgents,
            vec![concat!("Operit/", env!("CARGO_PKG_VERSION"))]
        );
        assert!(headers.contains(&("X-Test".to_string(), "keep-me".to_string())));
        assert!(headers.contains(&("Authorization".to_string(), "Bearer sk-test".to_string())));
    }

    #[test]
    fn opencode_public_model_catalog_does_not_require_an_api_key() {
        let provider = openCodeProvider("https://opencode.ai/zen", "", "{}");
        let headers = headers(&provider, &openCodeOperation()).unwrap();
        assert!(!headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("Authorization")));
    }

    #[test]
    fn ordinary_provider_operations_keep_their_catalog_paths() {
        let provider = testProvider("sk-test", "{}");
        assert_eq!(
            operationUrl(&provider, &testOperation(true)).unwrap(),
            "https://example.com/v1/models"
        );
        assert!(headers(&testProvider("", "{}"), &testOperation(true)).is_err());
    }

    #[test]
    fn opencode_optional_auth_preserves_custom_authorization() {
        let provider = openCodeProvider(
            "https://opencode.ai/zen",
            "sk-test",
            r#"{"authorization":"Bearer custom"}"#,
        );
        let headers = headers(&provider, &openCodeOperation()).unwrap();
        let authorization: Vec<_> = headers
            .iter()
            .filter(|(name, _)| name.eq_ignore_ascii_case("Authorization"))
            .map(|(_, value)| value.as_str())
            .collect();
        assert_eq!(authorization, vec!["Bearer custom"]);
    }

    #[test]
    fn opencode_optional_auth_uses_enabled_key_pool_and_rotation() {
        use operit_model::ApiKeyInfo::ApiKeyInfo;
        let mut provider = openCodeProvider("https://opencode.ai/zen/go", "unused", "{}");
        provider.useMultipleApiKeys = true;
        let mut disabled = ApiKeyInfo::new("disabled".to_string(), "disabled-key".to_string());
        disabled.isEnabled = false;
        provider.apiKeyPool = vec![
            disabled,
            ApiKeyInfo::new("blank".to_string(), "  ".to_string()),
            ApiKeyInfo::new("first".to_string(), "sk-first".to_string()),
            ApiKeyInfo::new("second".to_string(), "Bearer sk-second".to_string()),
        ];
        provider.currentKeyIndex = -1;
        let headers = headers(&provider, &openCodeOperation()).unwrap();
        assert!(headers.contains(&("Authorization".to_string(), "Bearer sk-second".to_string())));
        provider.apiKeyPool.clear();
        let headers = super::headers(&provider, &openCodeOperation()).unwrap();
        assert!(!headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("Authorization")));
    }
}
