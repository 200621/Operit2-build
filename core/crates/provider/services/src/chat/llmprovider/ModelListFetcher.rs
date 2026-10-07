use operit_host_api::HostManager::defaultHttpHost;
use operit_host_api::HttpRequestData;
use operit_model::ModelConfigData::{
    AvailableProviderModel, ProviderCatalogEntry, ProviderOperationSpec, ProviderProfile,
};
use serde_json::Value;

#[path = "model_list/mod.rs"]
mod model_list;

use model_list::DiscoveryProtocol;

pub struct ModelListFetcher;

impl ModelListFetcher {
    /// Fetches provider models through the catalog operation and selected discovery protocol.
    pub fn fetch(
        provider: &ProviderProfile,
        provider_catalog: &ProviderCatalogEntry,
    ) -> Result<Vec<AvailableProviderModel>, String> {
        let operation = match provider_catalog
            .operations
            .iter()
            .find(|operation| operation.operationType == "list_models")
        {
            Some(operation) => operation,
            None => return Ok(Vec::new()),
        };
        let protocol = DiscoveryProtocol::for_provider(&provider.providerType);
        let response = Self::request_json(provider, operation, protocol)?;
        protocol.parse_response(&response, operation)
    }

    /// Executes model discovery exclusively through the shared HTTP host.
    fn request_json(
        provider: &ProviderProfile,
        operation: &ProviderOperationSpec,
        protocol: DiscoveryProtocol,
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
        let request_url = protocol.request_url(provider, operation)?;
        let request_headers = protocol.request_headers(provider, operation)?;
        let response = defaultHttpHost()
            .executeHttpRequest(HttpRequestData {
                url: request_url,
                method: operation.method.clone(),
                headers: request_headers,
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
}
