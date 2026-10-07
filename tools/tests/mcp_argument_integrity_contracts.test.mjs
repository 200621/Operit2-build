import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const providerBase = 'core/crates/provider/services/src/chat/llmprovider/';
const parameterPath = 'core/crates/tool/services/src/tools/mcp/MCPToolParameter.rs';

/** Reads production code without compiling the Rust workspace. */
function source(path) {
  return readFileSync(new URL(path, root), 'utf8');
}

/** Requires declared string parameters to bypass content-based type inference. */
test('MCP schema string values remain strings', () => {
  assert.match(source(parameterPath), /Some\(value\) if value == "string" => Value::String\(text\)/);
});

/** Requires valid JSON arrays and objects to retain their nested value types. */
test('MCP parsed JSON preserves nested strings', () => {
  const parameters = source(parameterPath);
  assert.match(parameters, /return Value::Array\(items\);/);
  assert.match(parameters, /return Value::Object\(object\);/);
});

/** Rejects recursive inference on arrays that are already typed JSON values. */
test('MCP typed arrays are not recursively reinterpreted', () => {
  const parameters = source(parameterPath);
  const conversion = parameters.slice(parameters.indexOf('pub fn smartConvert('), parameters.indexOf('fn parseNumberValue('));
  assert.doesNotMatch(conversion, /Value::Array\(items\) =>/);
});

for (const provider of ['OpenAIProvider', 'ClaudeProvider', 'GeminiProvider']) {
  /** Requires every provider to decode complete lines, not individual HTTP chunks. */
  test(`${provider} uses the shared lossless streaming line decoder`, () => {
    const code = source(`${providerBase}${provider}.rs`);
    assert.match(code, /use super::StreamingResponseLines::\{decodeStreamingTail, takeNextStreamingLine\};/);
    assert.match(code, /extend_from_slice\(&bytes\)/);
    assert.match(code, /while let Some\(line\) = takeNextStreamingLine\(/);
    assert.match(code, /decodeStreamingTail\(/);
    assert.doesNotMatch(code, /String::from_utf8_lossy\(&bytes\)/);
  });
}

/** Checks that the shared production decoder uses strict decoding after line assembly. */
test('shared streaming decoder never inserts replacement characters', () => {
  const code = source(`${providerBase}StreamingResponseLines.rs`);
  assert.match(code, /pending_bytes\.iter\(\)\.position\(/);
  assert.match(code, /pending_bytes\.drain\(\.\.=newline_index\)/);
  assert.match(code, /String::from_utf8\(line_bytes\)/);
  assert.match(code, /String::from_utf8\(std::mem::take\(pending_bytes\)\)/);
  assert.match(code, /AiServiceError::ConnectionFailed/);
  assert.doesNotMatch(code, /from_utf8_lossy|unwrap_or/);
});

/** Reproduces the transport-byte issue independently; this does not execute Rust code. */
test('split-chunk UTF-8 reproduction corrupts content before JSON parsing', () => {
  const line = 'data: {"content":"中文😀"}\n';
  const bytes = Buffer.from(line);
  const split = bytes.indexOf(Buffer.from('中')) + 1;
  const chunks = [bytes.subarray(0, split), bytes.subarray(split)];
  const corrupted = chunks.map(chunk => chunk.toString('utf8')).join('');
  assert.equal(JSON.parse(corrupted.slice('data: '.length)).content, '���文😀');
  const complete = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks));
  assert.equal(complete, line);
});

/** Keeps the existing argument-integrity block in place rather than hiding corruption. */
test('MCP argument corruption is still reported before the server call', () => {
  const code = source('core/crates/tool/services/src/tools/mcp/MCPToolExecutor.rs');
  assert.match(code, /findArgumentIntegrityViolation\(tool\)/);
  assert.match(code, /the call was blocked before it reached the MCP server/);
});
