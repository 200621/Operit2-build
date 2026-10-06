import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const android = 'apps/flutter/app/android/app/';

/** Reads a production file for cross-language host contract checks. */
function source(path) {
  return readFileSync(new URL(path, root), 'utf8');
}

/** Extracts synchronized scopes while ignoring braces in Kotlin strings and comments. */
function synchronizedScopes(content, lock) {
  const code = content.replace(
    /"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
    match => match.replace(/[^\n]/g, ' '),
  );
  const scopes = [];
  const pattern = new RegExp(`synchronized\\s*\\(\\s*${lock}\\s*\\)\\s*\\{`, 'g');
  for (const match of code.matchAll(pattern)) {
    const opening = match.index + match[0].length - 1;
    let end = opening + 1;
    let depth = 1;
    while (end < code.length && depth > 0) {
      if (code[end] === '{') depth++;
      if (code[end] === '}') depth--;
      end++;
    }
    assert.equal(depth, 0, `Unclosed synchronized scope for ${lock}`);
    scopes.push({ start: match.index, end, body: content.slice(opening + 1, end - 1) });
  }
  return scopes;
}

/** Keeps Android runtime tools on the existing owner channel rather than secret-store JNI. */
test('Android device information is implemented by the Flutter owner', () => {
  const host = source('hosts/android/src/system_operation.rs');
  assert.doesNotMatch(host, /readAndroidDeviceInfo|deviceInfoJson|jni::|serde_json::from_str/);
  assert.match(host, /fn getDeviceInfo\(&self\)[\s\S]*?Android get_device_info requires/);
  const adapters = source('apps/flutter/native/operit-flutter-bridge/src/FlutterOwnerCapabilities.rs');
  assert.match(adapters, /fn ownerDeviceInfo\(\)[\s\S]*?ownerSystemOperation\("get_device_info"/);
  assert.match(adapters, /requestOwnerSystemOperation\(/);
  assert.match(adapters, /serde_json::from_str\(&response.resultJson\)/);
  assert.doesNotMatch(adapters, /target_os|target_arch|target_env|jni::/);
  const dart = source('apps/flutter/app/lib/core/host/RuntimeHostInteractionSubscriber.dart');
  assert.match(dart, /'ownerSystemOperation',\s*payload.toJson\(\)/);
  const owner = source(`${android}src/main/kotlin/app/operit/OwnerSystemCapabilityChannel.kt`);
  assert.match(owner, /"get_device_info" -> mapOf\(\s*"resultJson" to AndroidHostDeviceInfo.read\(activity.applicationContext\)/);
  const runtime = source(`${android}src/main/kotlin/app/operit/AndroidRuntimeHost.kt`);
  assert.doesNotMatch(runtime, /deviceInfoJson|AndroidHostDeviceInfo/);
});

/** Extracts one required section for focused capability contract checks. */
function section(content, start, end) {
  const begin = content.indexOf(start);
  assert.notEqual(begin, -1, 'Missing section: ' + start);
  const finish = content.indexOf(end, begin + start.length);
  assert.notEqual(finish, -1, 'Missing section end: ' + end);
  return content.slice(begin, finish);
}

/** Requires Android settings callbacks at construction rather than unimplemented tool stubs. */
test('Android system settings have required owner bindings at host assembly', () => {
  const host = source('hosts/android/src/system_operation.rs');
  assert.match(host, /pub fn new\(\s*settingReader: AndroidSystemSettingReader,\s*settingWriter: AndroidSystemSettingWriter/);
  assert.match(host, /fn getSystemSetting[\s\S]*?\(self\.settingReader\)\(namespace, setting\)/);
  assert.match(host, /fn modifySystemSetting[\s\S]*?\(self\.settingWriter\)\(namespace, setting, value\)/);
  assert.doesNotMatch(host, /Android (get|modify)_system_setting requires|derive\([^)]*Default/);
  const factory = source('hosts/android/src/lib.rs');
  assert.match(factory, /systemOperationHost: Arc<dyn operit_host_api::SystemOperationHost>/);
  assert.match(factory, /Arc::new\(AndroidHttpHost::new\(\)\),\s*systemOperationHost,/);
  const platform = source('apps/flutter/native/operit-flutter-bridge/src/platform_runtime/android.rs');
  assert.match(platform, /createRuntimeHostManager\([\s\S]*?AndroidSystemOperationHost::new\(\s*Arc::new\(ownerGetSystemSetting\),\s*Arc::new\(ownerModifySystemSetting\)/);
  assert.doesNotMatch(host, /jni::|serde_json::from_str/);
});

/** Preserves exact settings parameters and requires the owner's complete typed response. */
test('shared owner settings adapters use the existing platform-independent system protocol', () => {
  const adapters = source('apps/flutter/native/operit-flutter-bridge/src/FlutterOwnerCapabilities.rs');
  const settings = section(adapters, '/// Reads a system setting', '/// Reads device information');
  assert.match(settings, /ownerGetSystemSetting\(namespace: &str, setting: &str\)/);
  assert.match(settings, /"get_system_setting",\s*serde_json::json!\(\{ "namespace": namespace, "setting": setting \}\)/);
  assert.match(settings, /"modify_system_setting",\s*serde_json::json!\(\{ "namespace": namespace, "setting": setting, "value": value \}\)/);
  assert.match(settings, /derive\(serde::Deserialize\)/);
  for (const field of ['namespace', 'setting', 'value']) {
    assert.match(settings, new RegExp('\\b' + field + ': String'));
    assert.match(settings, new RegExp('\\b' + field + ': response\\.' + field));
  }
  assert.match(settings, /let response: SettingResponse = ownerSystemOperation\(operation, params\)\?/);
  assert.doesNotMatch(settings, /target_os|target_arch|wasm|jni::|serde\(default|Option<|unwrap_or|or_else|\.contains\(/);
});

/** Reads brightness and other settings directly from their exact Android provider namespace. */
test('Android settings reads return provider values and reject absent or invalid settings', () => {
  const owner = source(android + 'src/main/kotlin/app/operit/OwnerSystemCapabilityChannel.kt');
  assert.match(owner, /"get_system_setting" -> systemGetSystemSetting\(JSONObject\(paramsJson\)\)/);
  const settings = section(owner, '/** Reads one exact Android settings namespace', '/** Writes one Android setting');
  for (const [namespace, provider] of [['system', 'System'], ['secure', 'Secure'], ['global', 'Global']]) {
    assert.match(settings, new RegExp('"' + namespace + '" -> Settings\\.' + provider + '\\.getString\\(resolver, setting\\)'));
  }
  assert.match(settings, /require\(setting\.isNotBlank\(\)\)/);
  assert.match(settings, /else -> throw IllegalArgumentException\("unsupported Android settings namespace:/);
  assert.match(settings, /\?: throw IllegalStateException\("Android system setting does not exist: \$namespace\/\$setting"\)/);
  assert.match(settings, /"resultJson" to JSONObject\(\)/);
  for (const field of ['namespace', 'setting', 'value']) {
    assert.match(settings, new RegExp('\\.put\\("' + field + '", ' + field + '\\)'));
  }
  assert.doesNotMatch(settings, /optString|\?:\s*""|getInt|ProcessBuilder|execute.*Command|\.contains\(/);
});

/** Requires authorized, acknowledged writes and returns the actual persisted setting value. */
test('Android settings writes check permission and provider success before readback', () => {
  const owner = source(android + 'src/main/kotlin/app/operit/OwnerSystemCapabilityChannel.kt');
  assert.match(owner, /"modify_system_setting" -> systemModifySystemSetting\(JSONObject\(paramsJson\)\)/);
  const settings = section(owner, '/** Writes one Android setting', '/** Posts one native Android notification');
  for (const provider of ['System', 'Secure', 'Global']) {
    assert.match(settings, new RegExp('Settings\\.' + provider + '\\.putString\\(resolver, setting, value\\)'));
  }
  assert.match(settings, /check\(Settings\.System\.canWrite\(activity\)\)/);
  assert.match(settings, /Android WRITE_SETTINGS permission is not granted/);
  assert.match(settings, /check\(written\) \{ "Android system setting write was rejected:/);
  assert.match(settings, /return systemGetSystemSetting\(params\)/);
  assert.doesNotMatch(settings, /catch\s*\(|optString|\?:\s*""|ProcessBuilder|execute.*Command|\.contains\(/);
});

/** Supplies only required startup identity before FFI and owner subscriptions become available. */
test('Android startup receives the device model without querying the owner', () => {
  const kotlin = source(`${android}src/main/kotlin/app/operit/AndroidRuntimeHost.kt`);
  assert.match(kotlin, /OperitRuntimeNative.create\(\s*paths.runtimeRoot.absolutePath,\s*paths.workspaceRoot.absolutePath,\s*Build.MODEL,\s*this,/);
  const native = source(`${android}src/main/kotlin/app/operit/OperitRuntimeNative.kt`);
  assert.match(native, /external fun create\(\s*runtimeRoot: String,\s*workspaceRoot: String,\s*deviceModel: String,\s*host: AndroidRuntimeHost,/);
  const jni = source('apps/flutter/native/operit-flutter-bridge/src/AndroidJni.rs');
  assert.match(jni, /workspace_root: JString,\s*device_model: JString,\s*host: JObject,/);
  assert.match(jni, /device_model.trim\(\).is_empty\(\)/);
  assert.match(jni, /new_with_storage_roots\(runtime_root, workspace_root, device_model\)/);
  const factory = source('apps/flutter/native/operit-flutter-bridge/src/PlatformRuntimeFactory.rs');
  const androidPlatform = source('apps/flutter/native/operit-flutter-bridge/src/platform_runtime/android.rs');
  assert.match(androidPlatform, /StartupMetadata::AndroidDevice \{ model \}/);
  assert.match(androidPlatform, /model.trim\(\).is_empty\(\)/);
  assert.match(androidPlatform, /model: model.clone\(\)/);
  assert.doesNotMatch(androidPlatform, /requestOwner|\.unwrap_or|\.or_else|getDeviceInfo/);
  assert.match(factory, /platform::create_host_context/);
  const bridge = source('apps/flutter/native/operit-flutter-bridge/src/BridgeRuntime.rs');
  assert.match(bridge, /CoreApplication::startWithSharedLocalClient/);
  assert.doesNotMatch(bridge, /target_os|target_arch|target_env/);
});

/** Keeps C-host startup separate from Android's model-bearing JNI constructor. */
test('Android cannot bypass its host-owned creation boundary', () => {
  const exports = source('apps/flutter/native/operit-flutter-bridge/src/BridgeExports.rs');
  for (const name of ['operit_flutter_bridge_create', 'operit_flutter_bridge_create_with_storage_roots']) {
    const declaration = exports.indexOf(`fn ${name}(`);
    assert.notEqual(declaration, -1);
    const annotation = exports.slice(exports.lastIndexOf('#[cfg(', declaration), declaration);
    assert.match(annotation, /not\(any\(target_env = "ohos", target_os = "android"\)\)/);
  }
});

/** Requires the Kotlin producer to supply every shared Rust device field. */
test('Android device JSON matches the required shared host schema', () => {
  const api = source('core/crates/foundation/host-api/src/lib.rs');
  const contract = api.match(/#\[derive\(([^\n]+)\)\]\s*pub struct DeviceInfoData \{([^}]+)\}/);
  assert.ok(contract);
  assert.match(contract[1], /Serialize, Deserialize/);
  const fields = [...contract[2].matchAll(/pub (\w+):/g)].map(match => match[1]);
  const kotlin = source(`${android}src/main/kotlin/app/operit/AndroidHostDeviceInfo.kt`);
  const json = kotlin.slice(kotlin.indexOf('return JSONObject()'), kotlin.indexOf('.put("brand"'));
  const keys = [...json.matchAll(/\.put\("(\w+)"/g)].map(match => match[1]);
  assert.deepEqual(keys.sort(), fields.sort());
  assert.doesNotMatch(contract[2], /serde\(default/);
  assert.match(kotlin, /ActivityManager\.MemoryInfo\(\)/);
  assert.match(kotlin, /StatFs\(context.filesDir.absolutePath\)/);
  assert.match(kotlin, /Settings\.Secure\.ANDROID_ID/);
  assert.match(kotlin, /BatteryManager\.BATTERY_PROPERTY_CAPACITY/);
  assert.doesNotMatch(kotlin, /MethodChannel|Build.VERSION.SDK_INT\s*[<>=]|catch\s*\(/);
});

/** Prevents native creation and asset preparation from blocking main-thread host callbacks. */
test('Android main-thread state lock excludes expensive runtime lifecycle work', () => {
  const host = source(`${android}src/main/kotlin/app/operit/AndroidRuntimeHost.kt`);
  const scopes = synchronizedScopes(host, 'runtimeLock');
  assert.ok(scopes.length > 0);
  for (const { body } of scopes) {
    assert.doesNotMatch(
      body,
      /prepareAndroidRuntimePaths\s*\(|AndroidRuntimeAssets\.prepare\s*\(|OperitRuntimeNative\.(?:create|destroy)\s*\(|\.mkdirs\s*\(|synchronized\s*\(runtimeCreationLock\)/,
      'The UI-shared lock must protect state only, not filesystem or native lifecycle work',
    );
  }
  const service = source(`${android}src/main/kotlin/app/operit/OperitCoreService.kt`);
  assert.match(service, /private fun ensureRuntimeStarted\(\)[\s\S]*?runtimeHost\.isStorageConfigured\(\)/);
  const application = source(`${android}src/main/kotlin/app/operit/OperitApplication.kt`);
  assert.match(application, /registerActivityLifecycleCallbacks/);
  assert.match(application, /\.emitRuntimeEvent\(RuntimeEvents\.androidLifecycle\(topic, payload\)\)/);
});

/** Serializes concurrent service and FFI startup while publishing the native handle atomically. */
test('Android runtime creation uses its own lock and short state publication scopes', () => {
  const host = source(`${android}src/main/kotlin/app/operit/AndroidRuntimeHost.kt`);
  const lifecycleScopes = synchronizedScopes(host, 'runtimeCreationLock');
  assert.equal(lifecycleScopes.length, 2, 'Creation and destruction must share a separate lifecycle lock');
  const creation = lifecycleScopes.find(({ body }) => /OperitRuntimeNative\.create\(/.test(body));
  assert.ok(creation);
  const states = synchronizedScopes(host, 'runtimeLock');
  const roots = states.find(({ body }) => /runtimeStarting = true/.test(body));
  const publish = states.find(({ body }) => /runtimeHandle = createdHandle/.test(body));
  assert.ok(roots);
  assert.ok(publish);
  assert.ok(creation.start < roots.start && roots.end < publish.start && publish.end < creation.end);
  assert.match(roots.body, /if \(runtimeHandle != 0L\)\s*\{\s*return runtimeHandle/);
  assert.match(roots.body, /val roots = configuredStorageRootsLocked\(\)\s*runtimeStarting = true\s*roots/);
  assert.match(creation.body, /prepareAndroidRuntimePaths\(storageRoots.first, storageRoots.second\)/);
  assert.match(publish.body, /runtimeHandle = createdHandle\s*runtimeStarting = false\s*flushPendingRuntimeEventsLocked\(\)/);
  const destroy = lifecycleScopes.find(({ body }) => /OperitRuntimeNative\.destroy\(/.test(body));
  assert.ok(destroy);
});

/** Keeps startup roots immutable and queues lifecycle events until native creation succeeds. */
test('Android in-flight startup preserves storage roots and pending lifecycle events', () => {
  const host = source(`${android}src/main/kotlin/app/operit/AndroidRuntimeHost.kt`);
  const states = synchronizedScopes(host, 'runtimeLock');
  const storage = states.find(({ body }) => /configuredRuntimeRoot = runtimeRoot/.test(body));
  assert.ok(storage);
  assert.match(storage.body, /if \(runtimeStarting \|\| runtimeHandle != 0L\)/);
  assert.match(storage.body, /configuredRuntimeRoot != runtimeRoot \|\|\s*configuredWorkspaceRoot != workspaceRoot/);
  assert.match(storage.body, /throw IllegalStateException/);
  const events = states.find(({ body }) => /pendingRuntimeEvents\.addLast\(eventJson\)/.test(body));
  assert.ok(events);
  assert.match(events.body, /if \(handle == 0L\)\s*\{\s*pendingRuntimeEvents\.addLast\(eventJson\)\s*return/);
  assert.match(host, /catch \(error: Throwable\)\s*\{\s*synchronized\(runtimeLock\)\s*\{\s*runtimeStarting = false\s*\}\s*updateRuntimeStartupStatus\("failed", "本地运行时启动失败"\)\s*throw error/);
});

/** Preserves the method names Rust resolves in minified release builds. */
test('release shrinking preserves the runtime host JNI methods', () => {
  const rules = source(`${android}proguard-rules.pro`);
  assert.match(rules, /-keepclassmembers class app\.operit\.AndroidRuntimeHost \{\s*public \*\*\* \*\(\.\.\.\);/);
});

/** Prevents the unfiltered main asset directory from reaching APK merge tasks. */
test('Android asset sources are generated from the selected ABI set', () => {
  const gradle = source(`${android}build.gradle.kts`);
  assert.match(gradle, /sourceSets.getByName\("main"\).assets.setSrcDirs\(emptyList<String>\(\)\)/);
  assert.match(gradle, /selectedAbis.set\(selectedOperitRustTargets.map \{ it.abi \}\)/);
  assert.match(gradle, /fileSystemOperations.sync \{/);
  assert.match(gradle, /exclude\("android-runtime\/\*\*"\)/);
  assert.match(gradle, /from\(sourceDirectory.dir\("android-runtime\/\$abi"\)\)/);
  assert.match(gradle, /into\("android-runtime\/\$abi"\)/);
  assert.match(gradle, /assets.addGeneratedSourceDirectory\(stagedAssets\) \{ it.outputDirectory \}/);
  assert.match(gradle, /"stageOperitAndroidAssets" \+ variant.name/);
});

/** Keeps release publication behind the actual APK asset validation. */
test('Android releases verify the final APK before copying it to dist', () => {
  const script = source('tools/build_scripts/build_flutter_android.py');
  const main = script.slice(script.indexOf('def main()'));
  assert.ok(main.indexOf('verify_android_runtime_assets(apk_path, "arm64-v8a")') <
    main.indexOf('copy_required_file('));
  assert.match(main, /"--target-platform",\s*"android-arm64"/);
});
