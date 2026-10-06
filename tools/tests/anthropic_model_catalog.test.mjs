import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const fetcher = readFileSync(new URL(
  'core/crates/provider/services/src/chat/llmprovider/ModelListFetcher.rs', root,
), 'utf8');
const catalog = readFileSync(new URL(
  'core/crates/foundation/model/src/ModelCatalog.rs', root,
), 'utf8');

/** Extracts a Rust declaration through the next documented declaration. */
function section(text, start, end) {
  const first = text.indexOf(start);
  assert.notEqual(first, -1, `Missing declaration: ${start}`);
  const last = text.indexOf(end, first + start.length);
  assert.notEqual(last, -1, `Missing following declaration: ${end}`);
  return text.slice(first, last);
}

/** Keeps both Anthropic provider types out of generic Bearer authentication. */
test('official and generic Anthropic catalogs use protocol-specific headers', () => {
  const headers = section(fetcher, 'fn headers(', 'fn anthropicHeaders(');
  assert.match(headers, /ApiProviderType::ANTHROPIC \| ApiProviderType::ANTHROPIC_GENERIC/);
  assert.match(headers, /return anthropicHeaders\(provider, operation, object\);/);
  assert.ok(headers.indexOf('return anthropicHeaders(') < headers.indexOf('bearerAuthorization('));
  for (const providerType of ['ANTHROPIC', 'ANTHROPIC_GENERIC']) {
    assert.match(catalog, new RegExp(`^${providerType}\\|[^\\n]+list_models:GET:/v1/models:\\$\\.data:\\$\\.id`, 'm'));
  }
});

/** Requires the version and raw API key headers used by the Kotlin implementation. */
test('Anthropic model discovery supplies version and x-api-key headers', () => {
  const headers = section(fetcher, 'fn anthropicHeaders(', 'fn bearerAuthorization(');
  assert.match(headers, /\("anthropic-version"\.to_string\(\), "2023-06-01"\.to_string\(\)\)/);
  assert.match(headers, /if let Some\(apiKey\) = apiKey\(provider\)/);
  assert.match(headers, /headers\.push\(\("x-api-key"\.to_string\(\), apiKey\.to_string\(\)\)\)/);
  assert.doesNotMatch(headers, /bearerAuthorization|"Authorization"|\.contains\(/);
});

/** Preserves explicit header configuration without duplicate protocol headers. */
test('Anthropic custom headers replace names case-insensitively', () => {
  const headers = section(fetcher, 'fn anthropicHeaders(', 'fn bearerAuthorization(');
  assert.match(headers, /headers\.retain\(\|\(existingName, _\)\| !existingName\.eq_ignore_ascii_case\(name\)\)/);
  assert.match(headers, /headers\.push\(\(name\.clone\(\), headerValue\.to_string\(\)\)\)/);
  assert.match(headers, /customHeaders value for \{name\} is not a string/);
});

/** Requires configuration failures to be reported rather than sent to another protocol. */
test('invalid Anthropic credentials and version produce explicit errors', () => {
  const headers = section(fetcher, 'fn anthropicHeaders(', 'fn bearerAuthorization(');
  assert.match(headers, /return Err\("Anthropic anthropic-version header is required"\.to_string\(\)\)/);
  assert.match(headers, /operation\.requiresApiKey/);
  assert.match(headers, /return Err\("Anthropic x-api-key header is required"\.to_string\(\)\)/);
  assert.doesNotMatch(headers, /unwrap_or|\.or_else\(|retry|cfg\(/);
});

/** Keeps model discovery shared by all platforms through the existing HTTP host. */
test('model discovery still uses the shared HTTP host', () => {
  const request = section(fetcher, 'fn requestJson(', 'fn parseItem(');
  assert.match(request, /let requestHeaders = headers\(provider, operation\)\?/);
  assert.match(request, /defaultHttpHost\(\)\s*\.executeHttpRequest\(HttpRequestData/);
  assert.match(request, /headers: requestHeaders/);
  assert.doesNotMatch(request, /reqwest|cfg\(|target_arch|target_os/);
});
