# Flutter Core FFI transport

Each Flutter isolate calls the platform host's `connectCoreFfi` once. The host
initializes its existing runtime and returns the JSON descriptor from
`operit_flutter_bridge_ffi_connect`. The descriptor contains ABI version `1`, an
owned session pointer, and `attach`, `allocate`, `free`, `submit`, and `release`
function addresses. Pointer and function address fields are decimal strings so
64-bit addresses retain their exact value through JSON decoding. Platform hosts
keep the loaded library mapped until process exit so outstanding FFI calls and
VM finalizers always reference live code.

Address strings contain unsigned native pointer values. Dart parses them with
`BigInt`, validates the native pointer width, and uses `toSigned(64).toInt()`
before `Pointer.fromAddress`. This preserves every bit, including high-byte
pointer tags. Decimal `int.parse` rejects values above `2^63 - 1`, and calling
`BigInt.toInt` directly clamps those values instead of preserving their bits.

Dart calls `attach(session, NativeApi.postCObject, SendPort.nativePort)` once.
The host adapter supports Dart native API major version 2. Its C object layout
follows `dart_native_api.h`. No library names or OS decisions enter business Dart.
Browser registration continues to use the existing JS/WASM CoreProxy contract.

`allocate(length)` returns a Rust-owned byte buffer. `submit(session, operation,
requestId, pointer, length)` consumes that buffer synchronously, then schedules
work through the host task scheduler. Dart calls `free(pointer, length)` only
when the allocated buffer has not been submitted. Every submitted request has
one asynchronous reply; control calls can execute while another call is waiting
for host interaction.

| Operation | Number | Input |
| --- | ---: | --- |
| call | 0 | Existing compact MessagePack call tuple |
| pushOpen | 1 | Existing compact MessagePack push tuple |
| pushItem | 2 | Existing compact MessagePack item tuple |
| pushClose | 3 | UTF-8 push id |
| watchSnapshot | 4 | Existing compact MessagePack snapshot tuple |
| watchStream | 5 | Existing compact MessagePack stream tuple |
| closeWatchStream | 6 | UTF-8 subscription id |

VM messages are copied `Uint8List` values containing a one-byte kind, an eight-byte
little-endian request id, and the payload. Kind `0` is a compact Core result.
Kinds `1`, `2`, and `3` use the original watch-open request id and carry a watch
frame, a compact Core error, and an empty stream-end payload respectively. Events
may precede the open acknowledgement; Dart attaches the receiver before submitting.
Events from one watch retain source order. Replies for independent calls may arrive
in any order. Source errors and panics are delivered to the stream listener.

Runtime handles use `Arc` ownership. Each session retains the existing runtime,
owns its watches and push ids, and has a dedicated Dart receive port. `release`
closes the connection, cancels subscriptions, and releases its reference after
in-flight requests finish. Dart registers it as a `NativeFinalizer` and also
supports explicit transport closure. Closing one window's connection does not
cancel another window's subscriptions. A closed VM port stops native delivery.

The platform channel still owns bootstrap storage, application lifecycle,
notifications, and system capabilities. Android's JNI remains for Java host APIs
and the connection bootstrap; ordinary Core calls and streams bypass JNI.

Validation: the Flutter transport tests invoke real FFI function pointers and
`NativeApi.postCObject` using a test host, covering buffer ownership, concurrent
responses, early events, source errors, cancellation, isolated connections,
protocol failures, and ordered push cleanup. They do not replace device testing
of the Rust library and platform host together.

## Host and bridge ownership

The crate entry point only declares modules and exports the public ABI. The
responsibilities below are intentionally not duplicated between platforms:

| Module | Responsibility |
| --- | --- |
| `BridgeRuntime` | One local Core lifecycle, permission requester, and runtime-owned scheduler |
| `BridgeTransport` | Shared push registration, sequence validation, watch opening, cancellation, and registration generations |
| `BridgeCodec` | Existing compact MessagePack requests, results, and event frames |
| `FlutterHostAdapters` | Browser automation, browser sessions, web visits, and Compose owner boundaries |
| `FlutterOwnerCapabilities` | Typed audio, music, TTS, inference, system, and terminal host adapters |
| `PlatformRuntimeFactory` | One common startup pipeline with no target conditions in the file itself |
| `platform_runtime/*` | One complete host assembly module per target, selected in one small selector |
| `PlatformRuntimeExecution` | Blocking-vs-Promise execution and native watch queue delivery |
| `PlatformRuntimeAbi` | ABI module selection, separate from host construction |
| `BridgeExports` / `FfiTransport` / `AndroidJni` | Public ABI decoding, pointer ownership, and frontend connection delivery |

Platform-specific dependencies and conditional compilation stay at the host or
ABI dispatch boundary. Shared runtime and stream code do not import platform
host implementations or JavaScript types. The bridge does not allocate an unused
second Tokio runtime. Each connection schedules work through the scheduler
installed on its own Core host manager.

System callback routing is selected once during assembly. Android identity is
supplied by JNI before owner UI subscriptions exist. Apple identity comes from
the native system host. macOS screenshot requests use the real system screenshot
host; they do not call the owner channel that explicitly rejects that operation.
Media adapters implement the host traits directly rather than converting to
platform command enums and parsing string-valued commands again.

Duplicate push ids are rejected without replacing the original session. Every
watch owns a registration generation, so an old completing task cannot remove a
new subscription that reuses its id. Source-open failures are reported before a
legacy C watch-open acknowledgement. The public function names and MessagePack
layouts are unchanged.

Architecture contracts can be checked without building the application:

```powershell
node --test tools/tests/flutter_bridge_architecture.test.mjs tools/tests/android_runtime_contracts.test.mjs
```
