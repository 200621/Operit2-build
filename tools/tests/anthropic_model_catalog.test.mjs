import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const providerDirectory = 'core/crates/provider/services/src/chat/llmprovider/';
const fetcher = readFileSync(new URL(`${providerDirectory}ModelListFetcher.rs`, root), 'utf8');
const protocol = readFileSync(new URL(`${providerDirectory}model_list/mod.rs`, root), 'utf8');
const request = readFileSync(new URL(`${providerDirectory}model_list/request.rs`, root), 'utf8');
const catalog = readFileSync(new URL('core/crates/foundation/model/src/ModelCatalog.rs', root), 'utf8');

/** Extracts a Rust declaration through the next documented declaration. */
function section(text, start, end) {
  const first = text.indexOf(start);
  assert.notEqual(first, -1, `Missing declaration: ${start}`);
  const last = text.indexOf(end, first + start.length);
  assert.notEqual(last, -1, `Missing following declaration: ${end}`);
  return text.slice(first, last);
}

/** Routes both Anthropic provider types to protocol-specific authentication. */
test('official and generic Anthropic catalogs use protocol-specific headers', () => {
  assert.match(protocol, /ApiProviderType::ANTHROPIC \| ApiProviderType::ANTHROPIC_GENERIC => Self::Anthropic/);
  assert.match(protocol, /Self::Anthropic => request::anthropic_headers\(provider, operation, &custom_headers\)/);
  for (const providerType of ['ANTHROPIC', 'ANTHROPIC_GENERIC']) {
    assert.match(catalog, new RegExp(`^${providerType}\\|[^\\n]+list_models:GET:/v1/models:\\$\\.data:\\$\\.id`, 'm'));
  }
});

/** Requires Kotlin's version and raw API key headers. */
test('Anthropic model discovery supplies version and x-api-key headers', () => {
  const headers = section(request, 'fn anthropic_headers(', 'fn bearer_authorization(');
  assert.match(headers, /"anthropic-version"\.to_string\(\), "2023-06-01"\.to_string\(\)/);
  assert.match(headers, /if let Some\(api_key\) = selected_api_key\(provider\)/);
  assert.match(headers, /headers\.push\(\("x-api-key"\.to_string\(\), api_key\.to_string\(\)\)\)/);
  assert.doesNotMatch(headers, /bearer_authorization|"Authorization"|\.contains\(/);
});

/** Preserves explicit custom headers by replacing matching names case-insensitively. */
test('Anthropic custom headers replace names case-insensitively', () => {
  const headers = section(request, 'fn anthropic_headers(', 'fn bearer_authorization(');
  const merge = section(request, 'fn merge_custom_headers(', 'fn bearer_headers(');
  assert.match(headers, /merge_custom_headers\(headers, custom_headers\)\?/);
  assert.match(merge, /headers\.retain\(\|\(existing_name, _\)\| !existing_name\.eq_ignore_ascii_case\(name\)\)/);
  assert.match(merge, /headers\.push\(\(name\.clone\(\), header_value\.to_string\(\)\)\)/);
  assert.match(merge, /customHeaders value for \{name\} is not a string/);
});

/** Reports invalid configuration without changing authentication protocols. */
test('invalid Anthropic credentials and version produce explicit errors', () => {
  const headers = section(request, 'fn anthropic_headers(', 'fn bearer_authorization(');
  assert.match(headers, /return Err\("Anthropic anthropic-version header is required"\.to_string\(\)\)/);
  assert.match(headers, /operation\.requiresApiKey/);
  assert.match(headers, /return Err\("Anthropic x-api-key header is required"\.to_string\(\)\)/);
  assert.doesNotMatch(headers, /unwrap_or|\.or_else\(|retry|cfg\(/);
});

/** Enforces the shared HTTP host for model discovery on every platform. */
test('model discovery still uses the shared HTTP host', () => {
  assert.match(fetcher, /let request_headers = protocol\.request_headers\(provider, operation\)\?/);
  assert.match(fetcher, /defaultHttpHost\(\)\s*\.executeHttpRequest\(HttpRequestData/);
  assert.match(fetcher, /headers: request_headers/);
  assert.doesNotMatch(fetcher, /reqwest|cfg\(|target_arch|target_os/);
});
