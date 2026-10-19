# ToolPkg v1 compatibility in Operit2

## Supported versions and platform scope

Operit2's supported ToolPkg API version is **2.0.0**. Its loading compatibility
for **1.0.0** and **1.0.1** is incomplete; accepting those version identifiers
does not imply complete implementation of their contracts.

Operit1 fully supports **1.0.0** and **1.0.1**. These are the older API forms
primarily designed for Android, not a promise of cross-platform behavior.

API **2.0.0** is designed for multiple platforms. Nearly all public interfaces
provide cross-platform compatibility through the shared host layer, so ordinary
features should use those interfaces without separate per-platform implementations.
Authors must still consider other platforms when using platform-specific
interfaces, document their scope, and verify installation, UI, and core behavior
on the other intended platforms. Migrating a legacy package requires checking
API, path, and platform semantics, not merely changing its version declaration.

New Operit2 ToolPkg manifests should explicitly declare `"api_version": "2.0.0"`
and use the current bundled declarations. Manifest `schema_version`, ToolPkg
`api_version`, and the plugin's release `version` identify different things.

## Contract ownership

- **v1:** `plugins/types-v1/*.d.ts`, copied without edits from the handwritten v1 SDK.
- **v2:** `core/crates/plugin/sdk/src/js_sdk/*.rs`, rendered to `plugins/types` by the existing code generator.
- **Adapters:** `core/crates/plugin/sdk/src/compat/v1/*.js`. JSDoc imports check the input/output contract against v1 and calls against v2 using `tsc --checkJs --noEmit`.

There are two contract families, not one declaration tree for every patch version.
Minor/patch availability remains documented by upstream version annotations.
No Flutter branches or alternative platform runtimes are introduced.

## Loading and dispatch

The archive parser accepts explicitly declared `api_version` values `1.0.0`,
`1.0.1`, and `2.0.0`. The original version is retained for registration and execution.
Unknown releases remain rejected until admitted explicitly.

Omitted `api_version` selects the original ToolPkg contract (`1.0.0`), including
its compatibility adapters and effective runtime prerequisites. Explicit `1.0.0`,
`1.0.1`, and `2.0.0` declarations retain their exact versions. New Operit2 packages
must declare `2.0.0`; versions are not inferred from filenames or source text.
Standalone scripts executed outside a ToolPkg context use the current SDK contract.

The runtime method builder supports:

```js
api.method()
    .between('1.0.0', '2.0.0', legacyImplementation)
    .since('2.0.0', currentImplementation)
```

`between` is lower-inclusive and upper-exclusive. `since` is bounded by the next
major API family. Shared implementations can bind multiple explicit ranges:

```js
api.method()
    .between('1.0.1', '2.0.0')
    .since('2.0.0')
    .implement(sharedImplementation)
```

An explicit range spanning multiple major families is possible but must be
intentional. Overlap, unbound ranges, and unmatched versions are errors. Dispatch
uses the active call, not the version present when the engine was constructed.
Adapter failures propagate; they never select a different implementation.

## Implemented adapters

The existing generator appends the handwritten adapters to `js_tools.js` after
emitting the canonical v2 bindings. Both inline and modular engine bootstrap paths
therefore install the same code. Adapters capture the canonical functions before
installing versioned entry points, so v1 cannot recursively invoke itself.

### SoftwareSettings environment variables and V2 domain resources

The copied V1 declarations remain unchanged. `readEnvironmentVariable` and
`writeEnvironmentVariable` retain their original signatures through an explicitly
versioned adapter for 1.0.0 and 1.0.1. JSDoc checks both the historical signatures
and the canonical V2 host calls. The adapter preserves complete host results and
original failures.

V2 exposes configured resources through `Tools.Models`, `Tools.Tts`, `Tools.Theme`
and `Tools.Catalog`. The seven domain methods are available since 2.0.0 and use
fully qualified native dispatch paths, including separate `Tts.listConfigs` and
`Theme.listConfigs` paths. These methods were never part of the copied V1
`SoftwareSettings` contract, so no historical aliases are installed for them.

### Files

All functions in the copied v1 `Files` namespace have signature adapters:

- Positional `environment`, `sourceEnvironment`, and `destEnvironment` arguments.
- `read` and `download` object overloads, without modifying caller-owned options.
- `zip`'s fourth `include_root_directory` argument and `download`'s fourth headers argument.
- `env` metadata on returned file results and nested apply/create/edit operations.
- Root and child paths returned by find/grep, including nullable grep context conversion.

Environment interpretation follows the old API, not the OS running Operit2:

- Omitted environment means the documented v1 `android` environment.
- Linux absolute paths map to `/mnt/linux`.
- Android `/sdcard` and `/data` use the existing VFS roots.
- `/storage/emulated/0` maps to `/sdcard`.
- `/app` and `/mnt` paths returned by current resource/config APIs remain VFS paths.
- Unmapped Android roots and unsupported environment names are explicit errors.

The conditional `v1_runtime` package executes the supported Linux file operations
in the same terminal filesystem used by legacy commands. Other VFS addresses are
handled by the existing host/VFS implementation. The adapter does not create
mounts, emulate Android/Linux filesystems, or bypass
host permissions. In particular, a Linux environment call on a host without that
mount fails. Legacy content-URI access is not implemented by this mapping.

### Chat.call (1.0.1)

- Nullable legacy `toolName` becomes the optional current field.
- Returned role and finish-reason values are checked against the closed v1 vocabulary.
- Metadata is validated as JSON rather than asserted to a wider type.
- Request objects and original turns are not mutated.
- `1.0.0` cannot invoke this API; `2.0.0` retains its existing implementation.

### Registration

`registerChatMessageMenuItem` and `registerChatRuntimeHook` explicitly cover
`1.0.1` and `2.0.0`. Their current registration normalizers are shared. Other
existing registration implementations remain unchanged.

### Workflow

`Tools.Workflow` now calls the public API of `com.operit.workflow` through the
existing dependency transport. It covers list/create/get/update/patch/enable/disable/
delete/trigger. Every v1 package receives the workflow prerequisite (`>= 0.2.0`)
in its effective runtime `requires` during archive loading; old manifests need
no edits. Explicit stricter bounds remain in effect. Both packages must be enabled. The workflow plugin owns all state
and validates legacy graph inputs. See `PUBLIC_API.md` for the distributed typed
client and provider capability limits. No historical database migration is implicit.

### Caller identity after the role-provider migration

API 2.0.0 exposes `getCallerParticipantId()` consistently in the runtime and
current declarations. Its value belongs to the authenticated configuration
provider and is not a runtime-wide character-card identity.

For API 1.0.0 and 1.0.1, `getCallerCardId()` projects the execution participant
only when the authenticated owner is `com.operit.character_cards`. A call without
an execution participant returns the documented `undefined`; another provider's
participant is rejected. The legacy getter is absent from the 2.0.0 surface, and
a retained legacy function still checks the version of the active call.
Core transports the generic owner identity without exposing the owner's message
extension or restoring any character-card fields to the core model.

### Chat and memory after the role-provider migration

Every v1 archive now declares the effective character-provider prerequisite
`com.operit.character_cards >= 0.1.0` alongside its workflow prerequisite.
Explicit stricter bounds remain in effect; incompatible upper bounds are errors.

- `Chat.listCharacterCards` reads the provider's real role directory, including
  roles with fixed models or shared memory, without translating settings bindings.
- Positional `Chat.createNew(group, setAsCurrentChat, characterCardId)` becomes
  current creation options with the provider's namespaced selection input.
  The requested role is validated before creation; folder membership uses the
  existing generic chat folder API.
- Ordinary `Chat.sendMessage` uses the native send tool, translating the explicit
  role into `participant_id` and retaining sender and legacy turn controls.
- `Chat.sendMessageStreaming` converts growing visible-text snapshots into
  legacy start/chunk callbacks and returns the actual completion receipt.
  Snapshot rewrites cannot be expressed by the old append-only callback and are
  explicit errors. Waifu aggregation, custom timeouts, sender overrides and
  non-default persistence/visibility/warning controls remain outside this stream
  adapter. Calls without a completion receipt fail.
- `Memory` methods invoke the provider's actual executable memory tools and
  decode the package executor's serialized results. Both positional and object
  overloads preserve explicitly supplied caller scope and option values;
  `Memory.query` retains its legacy default limit of 20 and structured result.
- Relationship IDs are canonical decimal strings in the provider, not UUIDs.
  Positive safe integer IDs round-trip losslessly; IDs outside JavaScript's safe
  integer range are rejected. Single-link updates use the legacy result envelope.
- Memory move title arrays must be representable by the executable tool's title
  delimiters. Non-document `Memory.getByTitle` encodes the validated legacy query
  projection as JSON text; document reads retain the provider's text result.

Legacy `SoftwareSettings` management is explicitly excluded from this repair.
Role/model configuration and memory-profile binding adapters are not installed.

### Terminal and runtime script packages

`compat/v1/runtime.js` installs after the public structured `toolCall` bridge.
It uses the existing per-call API dispatcher and the built-in `v1_runtime` script
package. Rust selects the package state using its host condition capabilities;
`platform.ohos` is exposed alongside the other platform booleans.

| Package state | Legacy terminal | Node tool | Package commands |
| --- | --- | --- | --- |
| Windows | Existing Git Bash host (`bash`) | Existing PowerShell host | Native; no APK shim |
| Linux | Native Bash | Native Bash | Native; no APK shim |
| macOS | Native Bash | Native Bash | Native; no APK shim |
| Android | Existing proot Bash | Existing proot Bash | Explicit apt/apt-get to APK mapping |
| iOS | Existing iSH shell | Existing iSH shell | Explicit apt/apt-get to APK mapping |
| OHOS | Existing QEMU-vroot shell | Existing QEMU-vroot shell | Explicit apt/apt-get to APK mapping |
| Web | Existing Buildroot V86 shell | Existing Buildroot V86 shell | Native; no APK shim |

For API 1.0.0 and 1.0.1, `Tools.System.terminal.create/exec` dispatch to that
package. These exact historical tool identities also dispatch there:

- `super_admin:terminal`
- `code_runner:run_javascript_node`
- `ffmpeg:ffmpeg_execute`
- `ffmpeg:ffmpeg_info`

API 2.0.0 retains canonical host calls and tool identities. Native host errors,
nonzero exit codes and timeouts are retained. Program helpers reject unsuccessful
execution. Node source uses UTF-8 hex encoding before native invocation because
Windows PowerShell 5.1 strips embedded double quotes in native arguments.

Alpine states install command shims in the existing home directory. The supported
apt grammar is `update`, `install`, `remove`, and `purge`, with explicit options
and package-name mappings, including `python3-pip` to `py3-pip`,
`build-essential` to `build-base`, and `libssl-dev` to `openssl-dev`. The shims
execute real APK commands; unsupported options/packages are errors. Native
Linux/Windows commands and Web Buildroot never run this APK shim.

The managed-filesystem bridge covers text/binary read/write, existence checks,
mkdir, delete, move, copy and unzip. Cross-environment file copies transfer
actual Base64 bytes through the canonical host filesystem and the selected
terminal filesystem. Writes are bounded to avoid native argument limits and
preserve Unicode surrogate pairs. ZIP extraction rejects escaping entries and
symbolic links. The marketplace questionnaire spelling `Files.makeDirectory`
binds to the existing v1 `mkdir` adapter.

Required executables remain real host requirements: Windows legacy shell tools
need the existing Git Bash host; managed file operations need Python, Node tools
need Node, and FFmpeg tools need FFmpeg. This layer does not translate arbitrary
Bash source into PowerShell, add Ubuntu, install new runtime images, or reproduce
Linux `/proc` on Windows. Hardcoded `/root` paths remain subject to native write
permissions. Web Buildroot has no Bash or dynamic npm/pip package installation.

### Marketplace archive audit (2026-10-19)

The downloaded marketplace archives for TA's pocket phone 1.5.2, questionnaire
0.1.0, enhanced questionnaire 1.8.0, and WeChat iLink bridge 2.5.3 all omit
`api_version`, so their loading contract is 1.0.0. Actual entry registration,
initial Compose rendering, and the original questionnaire submit callback were
checked using the production dispatcher and registration scripts for both
1.0.0 and 1.0.1. These checks do not establish full host execution equivalence.

The pocket phone uses the terminal and explicit Linux Files APIs covered above.
The iLink bridge uses the legacy terminal, Node and FFmpeg tool identities now
routed by this adapter. Its old Android installed-package search directory and
`/proc` process scanning remain package-specific portability issues. The
enhanced questionnaire also uses an Android Java clipboard API. A separately
audited two-person phone archive 1.1.4 is missing its registered
`ui/phone.ui.js`; runtime adaptation cannot restore an absent archive member.

## Scope and outstanding work

This is not a claim that every historical plugin runs unchanged. Copying the
complete type tree preserves the upstream contract; it does not implement all of
its capabilities. The following are not yet covered by compatibility adapters:

- Removed v1 SoftwareSettings model/character/speech/sandbox management methods.
- FFmpeg and Tasker namespaces absent from the current generated Tools surface.
- Workflow engine features not supported by the prerequisite plugin (Tasker/intent/speech triggers and non-empty extract.defaultValue).
- A complete audit/conversion of every ToolPkg hook input, return value, and stream callback.
- Direct low-level `toolCall` requests using legacy environment parameters (the current Files adapters operate on `Tools.Files`).
- Exact legacy formatted `toString()` output for all result types.
- End-to-end equivalence of underlying v2 services; for example the current zip executor does not consume `include_root_directory`, even though the binding and adapter accept it.

These capabilities must be implemented or explicitly reported, never simulated
with successful empty results. Future work belongs in bounded adapter modules and
contract fixtures, not in a second loader or platform-specific Flutter code.

## Checks

```powershell
.venv/Scripts/python.exe plugins/tools/sync_v1_types.py check
tsc -p core/crates/plugin/sdk/src/compat/v1/tsconfig.json
node --test tools/tests/toolpkg_api_compatibility.test.mjs tools/tests/toolpkg_v1_adapters.test.mjs tools/tests/toolpkg_v1_runtime.test.mjs tools/tests/plugin_bridge_contracts.test.mjs
```

The TypeScript check intentionally skips checking upstream declaration bodies,
while checking adapter use of both contracts under strict mode. This isolates
upstream global declaration conventions from adapter implementation checking.
Rust archive-loading and version-admission tests are included in the SDK source;
they require a separate Rust test run and are not exercised by the Node checks.

The runtime compatibility tests additionally execute Node through real Windows
PowerShell/Git Bash, test APK argument mapping with an argv-recording executable,
and exercise Python file operations and bounded resource writes in temporary
directories. They do not boot Android, iOS, OHOS or V86 runtimes.
