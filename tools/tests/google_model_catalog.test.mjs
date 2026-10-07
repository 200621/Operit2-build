import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const providerDirectory = 'core/crates/provider/services/src/chat/llmprovider/';
const fetcher = readFileSync(new URL(`${providerDirectory}ModelListFetcher.rs`, root), 'utf8');
const protocol = readFileSync(new URL(`${providerDirectory}model_list/mod.rs`, root), 'utf8');
const request = readFileSync(new URL(`${providerDirectory}model_list/request.rs`, root), 'utf8');
const response = readFileSync(new URL(`${providerDirectory}model_list/response.rs`, root), 'utf8');
const gemini = readFileSync(new URL(`${providerDirectory}model_list/gemini.rs`, root), 'utf8');
const endpoint = readFileSync(new URL(`${providerDirectory}model_list/endpoint.rs`, root), 'utf8');
const catalog = readFileSync(new URL('core/crates/foundation/model/src/ModelCatalog.rs', root), 'utf8');

/** Keeps discovery orchestration separate from protocol-specific implementation. */
test('model discovery selects a protocol once at the shared entry point', () => {
  assert.equal(Array.from(fetcher.matchAll(/DiscoveryProtocol::for_provider\(/g)).length, 1);
  assert.match(protocol, /ApiProviderType::GOOGLE \| ApiProviderType::GEMINI_GENERIC => Self::Gemini/);
  assert.match(protocol, /Self::Gemini => gemini::request_url\(provider, operation\)/);
  assert.match(protocol, /Self::Gemini => gemini::parse_items\(items, operation\)/);
  assert.doesNotMatch(fetcher, /ApiProviderType|baseModelId|supportedGenerationMethods|anthropic-version/);
  for (const source of [fetcher, protocol, request, response, gemini, endpoint]) {
    assert.doesNotMatch(source, /isGoogleProvider|allow\(non_snake_case\)/);
    assert.doesNotMatch(source, /\bfn\s+[a-z_]*[A-Z]/);
  }
});

/** Adds one URL-encoded key from the shared provider key selector. */
test('Gemini discovery authenticates with a required query key', () => {
  assert.match(gemini, /request::selected_api_key\(provider\)/);
  assert.match(gemini, /Google model-list api key is required/);
  assert.match(gemini, /url\.query_pairs_mut\(\)\.append_pair\("key", api_key\)/);
  assert.ok(gemini.indexOf('url.set_query(None)') < gemini.indexOf('url.query_pairs_mut()'));
  assert.doesNotMatch(gemini, /format!\([^\n]*key=|bearer_authorization|unwrap_or|\.or_else\(/);
  for (const providerType of ['GOOGLE', 'GEMINI_GENERIC']) {
    assert.match(catalog, new RegExp(`^${providerType}\\|[^\\n]+list_models:GET:/v1beta/models:\\$\\.models:\\$\\.name`, 'm'));
  }
});

/** Uses parsed path segments while retaining the configured origin and API version. */
test('Gemini discovery preserves explicit endpoint versions', () => {
  assert.match(gemini, /\.path_segments\(\)/);
  assert.match(gemini, /match segments\.as_slice\(\)/);
  assert.match(gemini, /"v1" \| "v1beta"/);
  assert.match(gemini, /format!\("\/\{version\}\/models"\)/);
  assert.match(gemini, /unsupported Google model-list endpoint path/);
  assert.doesNotMatch(gemini, /\.contains\(|set_host|generativelanguage\.googleapis\.com/);
});

/** Keeps explicit custom headers out of automatic Bearer authentication. */
test('Gemini discovery headers only use content type and explicit overrides', () => {
  assert.match(protocol, /Self::Gemini => request::merge_custom_headers\(request::json_headers\(\), &custom_headers\)/);
  assert.match(request, /headers\.retain\(\|\(existing_name, _\)\| !existing_name\.eq_ignore_ascii_case\(name\)\)/);
  assert.match(request, /customHeaders value for \{name\} is not a string/);
});

/** Filters declared generation methods and exposes Kotlin's base model identities. */
test('Gemini discovery lists declared generation models with normalized IDs', () => {
  assert.match(gemini, /if !supports_generation\(item\)\?\s*\{\s*continue;/);
  assert.match(gemini, /\.get\("supportedGenerationMethods"\)/);
  assert.match(gemini, /method == "generateContent"/);
  assert.match(gemini, /\.get\("baseModelId"\)/);
  assert.match(gemini, /model\.modelId = base_model_id\.to_string\(\)/);
  assert.match(gemini, /models\.sort_by\(/);
});

/** Requires malformed model metadata to be reported explicitly. */
test('Gemini discovery rejects missing and invalid metadata', () => {
  assert.match(gemini, /supportedGenerationMethods must be an array/);
  assert.match(gemini, /supportedGenerationMethods entries must be strings/);
  assert.match(gemini, /baseModelId must be a non-empty string/);
  assert.match(gemini, /\.filter\(\|id\| !id\.trim\(\)\.is_empty\(\)\)/);
});

/** Enforces the shared HTTP host as the only network execution boundary. */
test('all discovery network requests execute exclusively through the HTTP host', () => {
  assert.equal(Array.from(fetcher.matchAll(/\.executeHttpRequest\(/g)).length, 1);
  assert.match(fetcher, /defaultHttpHost\(\)\s*\.executeHttpRequest\(HttpRequestData/);
  assert.match(fetcher, /url: request_url/);
  assert.match(fetcher, /headers: request_headers/);
  assert.match(fetcher, /list_models request failed: \{\} \{body\}/);
  for (const source of [fetcher, protocol, request, response, gemini, endpoint]) {
    assert.doesNotMatch(source, /reqwest|hyper::|ureq|TcpStream|target_arch|target_os|wasm32/);
  }
  for (const source of [protocol, request, response, gemini, endpoint]) {
    assert.doesNotMatch(source, /executeHttpRequest|defaultHttpHost|HttpRequestData/);
  }
});
