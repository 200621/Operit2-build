import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const providerDirectory = 'core/crates/provider/services/src/chat/llmprovider/';
const protocol = readFileSync(new URL(`${providerDirectory}model_list/mod.rs`, root), 'utf8');
const request = readFileSync(new URL(`${providerDirectory}model_list/request.rs`, root), 'utf8');
const endpoint = readFileSync(new URL(`${providerDirectory}model_list/endpoint.rs`, root), 'utf8');
const regressions = readFileSync(new URL(`${providerDirectory}model_list/tests.rs`, root), 'utf8');

/** Routes catalog model paths through structural endpoint derivation. */
test('catalog discovery no longer replaces the entire configured path', () => {
  assert.match(protocol, /mod endpoint;/);
  assert.match(request, /"list_models" => endpoint::models_path\(&url, &operation\.path\)\?/);
  assert.match(request, /url\.set_path\(&path\)/);
  assert.doesNotMatch(request, /url\.set_path\(&operation\.path\)/);
});

/** Limits endpoint suffix removal to explicit API resources. */
test('model discovery preserves gateway prefixes before known resource suffixes', () => {
  assert.match(endpoint, /\.path_segments\(\)/);
  assert.match(endpoint, /match segments\.as_slice\(\)/);
  assert.match(endpoint, /\[base @ \.\., "chat", "completions"\]/);
  assert.match(endpoint, /\[base @ \.\., "responses" \| "messages" \| "models"\]/);
  assert.match(endpoint, /let mut resource_segments = base\.to_vec\(\)/);
  assert.match(endpoint, /resource_segments\.push\("models"\)/);
  assert.doesNotMatch(endpoint, /\.contains\(|Regex|unwrap_or|\.or_else\(/);
});

/** Treats version tokens structurally rather than matching arbitrary prefix text. */
test('explicit numeric API versions retain their full parent path', () => {
  assert.match(endpoint, /\[\.\., version\] if is_api_version\(version\)/);
  assert.match(endpoint, /match segment\.as_bytes\(\)/);
  assert.match(endpoint, /\[b'v' \| b'V', number @ \.\.\]/);
  assert.match(endpoint, /!number\.is_empty\(\) && number\.iter\(\)\.all\(u8::is_ascii_digit\)/);
  assert.match(endpoint, /segments\.push\("models"\)/);
});

/** Merges provider route namespaces without dropping configured base segments. */
test('base paths retain provider catalog namespaces without duplicates', () => {
  assert.match(endpoint, /segments\[segments\.len\(\) - length\.\.\] == catalog_segments\[\.\.length\]/);
  assert.match(endpoint, /segments\.extend_from_slice\(&catalog_segments\[overlap\.\.\]\)/);
  assert.match(endpoint, /catalog model-list path must be an absolute URL path/);
  assert.match(endpoint, /catalog model-list path must end with the models resource/);
});

/** Keeps representative nested-path regressions in the Rust behavioral test suite. */
test('Rust regressions cover chat, Responses, provider namespaces, and encoded prefixes', () => {
  assert.match(regressions, /fn catalog_model_urls_preserve_nested_gateway_paths\(/);
  assert.match(regressions, /fn catalog_model_urls_preserve_provider_namespaces\(/);
  assert.match(regressions, /fn catalog_model_urls_reject_invalid_operation_paths\(/);
  for (const fixture of [
    '/a/b/c/v1/chat/completions',
    '/a/b/c/v1/responses',
    '/a/b/c/v1/models',
    '/a%20b/c%2Fd/v1/chat/completions',
    '/a/b/c/api/v1/chat/completions',
    '/api/coding/paas/v4/chat/completions',
    '/api/coding/v3/chat/completions',
    '/anthropic/v1/messages',
  ]) {
    assert.ok(regressions.includes(`"${fixture}"`), `Missing Rust fixture: ${fixture}`);
  }
});

/** Keeps endpoint derivation free of network clients and platform branches. */
test('endpoint path derivation only prepares URL data', () => {
  assert.doesNotMatch(endpoint, /reqwest|hyper::|ureq|TcpStream|executeHttpRequest|defaultHttpHost/);
  assert.doesNotMatch(endpoint, /target_arch|target_os|wasm32|allow\(non_snake_case\)/);
});
