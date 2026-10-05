//! Direct Dart transport, selected only by the platform host dispatcher.
//! Each connection retains the host runtime and owns its subscriptions.

use crate::BridgeCodec::*;
use crate::BridgeExports;
use crate::BridgeExports::{bridge_native_call, bridge_push_item, bridge_watch_snapshot};
use crate::OperitFlutterBridge;
use futures_util::FutureExt;
use operit_host_native_common::DartPort::{DartPort, PostCObject};
use operit_link::{CoreEventKind, CoreLinkError, CoreLinkSharedClient};
use std::collections::HashSet;
use std::collections::{hash_map::Entry, HashMap};
use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

pub struct FfiSession {
    bridge: Arc<OperitFlutterBridge>,
    port: OnceLock<DartPort>,
    delivery: Mutex<()>,
    watches: Mutex<HashMap<String, tokio::sync::oneshot::Sender<()>>>,
    pushes: Mutex<HashSet<String>>,
    closed: AtomicBool,
}

impl FfiSession {
    /// Sends a framed response without retaining pointers into Rust-owned storage.
    fn post(&self, kind: u8, request: i64, payload: &[u8]) {
        let delivery = self.delivery.lock().expect("FFI delivery lock");
        if self.closed.load(Ordering::Acquire) {
            return;
        }
        let mut frame = Vec::with_capacity(9 + payload.len());
        frame.push(kind);
        frame.extend_from_slice(&request.to_le_bytes());
        frame.extend_from_slice(payload);
        if !self
            .port
            .get()
            .expect("FFI session must be connected")
            .send(&frame)
        {
            drop(delivery);
            self.close();
        }
    }

    /// Cancels this connection's streams while leaving the host runtime alive.
    fn close(&self) {
        let _delivery = self.delivery.lock().expect("FFI delivery lock");
        self.closed.store(true, Ordering::Release);
        self.watches.lock().expect("FFI watches lock").clear();
    }

    /// Opens a watch on the host scheduler and reports source errors to Dart.
    fn watch(self: &Arc<Self>, request_id: i64, bytes: &[u8]) -> Vec<u8> {
        let result = (|| {
            let (id, request) = decode_native_watch_stream_request(bytes)?;
            let (cancel, mut cancelled) = tokio::sync::oneshot::channel();
            {
                let mut watches = self.watches.lock().expect("FFI watches lock");
                if self.closed.load(Ordering::Acquire) {
                    return Err(CoreLinkError::new("FFI_CLOSED", "FFI connection is closed"));
                }
                match watches.entry(id.clone()) {
                    Entry::Vacant(entry) => {
                        entry.insert(cancel);
                    }
                    Entry::Occupied(_) => {
                        return Err(CoreLinkError::new(
                            "WATCH_ALREADY_EXISTS",
                            "watch subscription already exists",
                        ))
                    }
                }
            }
            let weak = Arc::downgrade(self);
            let core = self.bridge.localCore.clone();
            let task_id = id.clone();
            let scheduled = self
                .bridge
                .runtimeTaskScheduler()
                .scheduleHostRuntimeAsyncTask(
                    "operit-ffi-watch",
                    Box::new(move || {
                        Box::pin(async move {
                            let outcome = std::panic::AssertUnwindSafe(async {
                        let source = tokio::select! {
                            _ = &mut cancelled => return,
                            result = CoreLinkSharedClient::watch(core.as_ref(), request) => result,
                        };
                        match source {
                            Ok(mut events) => loop {
                                let event = tokio::select! {
                                    _ = &mut cancelled => break,
                                    event = events.recv() => event,
                                };
                                let Some(event) = event else {
                                    break;
                                };
                                let completed = event.kind == CoreEventKind::Completed;
                                let Some(session) = weak.upgrade() else {
                                    break;
                                };
                                session.post(
                                    1,
                                    request_id,
                                    &native_watch_event_vec(&task_id, event),
                                );
                                if completed {
                                    break;
                                }
                            },
                            Err(error) => {
                                if let Some(session) = weak.upgrade() {
                                    session.post(
                                        2,
                                        request_id,
                                        &native_result_vec(Err::<(), _>(error)),
                                    );
                                }
                            }
                        }
                        }).catch_unwind().await;
                            if let Err(payload) = outcome {
                                if let Some(session) = weak.upgrade() {
                                    session.post(
                                        2,
                                        request_id,
                                        &native_result_error_vec(
                                            "FATAL_CORE_PANIC",
                                            BridgeExports::panic_payload_message(payload.as_ref()),
                                        ),
                                    );
                                }
                            }
                            if let Some(session) = weak.upgrade() {
                                session
                                    .watches
                                    .lock()
                                    .expect("FFI watches lock")
                                    .remove(&task_id);
                                session.post(3, request_id, &[]);
                            }
                        })
                    }),
                );
            if let Err(error) = scheduled {
                self.watches.lock().expect("FFI watches lock").remove(&id);
                return Err(CoreLinkError::internal(error.to_string()));
            }
            Ok(id)
        })();
        native_result_vec(result)
    }

    /// Executes one protocol operation using shared references to the retained runtime.
    fn dispatch(self: &Arc<Self>, operation: u32, request: i64, bytes: &[u8]) -> Vec<u8> {
        if self.closed.load(Ordering::Acquire) {
            return native_result_error_vec("FFI_CLOSED", "FFI connection is closed");
        }
        match operation {
            0 => bridge_native_call(&self.bridge, bytes),
            1 => {
                let result = decode_native_push_open_request(bytes).and_then(|request| {
                    let id = self.bridge.pushOpen(request)?;
                    self.pushes
                        .lock()
                        .expect("FFI pushes lock")
                        .insert(id.clone());
                    Ok(id)
                });
                native_result_vec(result)
            }
            2 => {
                let item = match decode_native_push_item(bytes) {
                    Ok(item) => item,
                    Err(error) => return native_result_vec(Err::<(), _>(error)),
                };
                if !self
                    .pushes
                    .lock()
                    .expect("FFI pushes lock")
                    .contains(&item.pushId)
                {
                    return native_result_error_vec(
                        "PUSH_NOT_FOUND",
                        "push is not owned by this connection",
                    );
                }
                bridge_push_item(&self.bridge, bytes)
            }
            3 => native_result_vec(
                std::str::from_utf8(bytes)
                    .map_err(|error| CoreLinkError::internal(error.to_string()))
                    .and_then(|id| {
                        if !self.pushes.lock().expect("FFI pushes lock").remove(id) {
                            return Err(CoreLinkError::new(
                                "PUSH_NOT_FOUND",
                                "push is not owned by this connection",
                            ));
                        }
                        let result = self.bridge.pushClose(id);
                        result
                    }),
            ),
            4 => bridge_watch_snapshot(&self.bridge, bytes),
            5 => self.watch(request, bytes),
            6 => native_result_vec(
                std::str::from_utf8(bytes)
                    .map_err(|error| CoreLinkError::internal(error.to_string()))
                    .map(|id| {
                        self.watches.lock().expect("FFI watches lock").remove(id);
                    }),
            ),
            _ => native_result_error_vec("FFI_OPERATION", "unknown FFI operation"),
        }
    }
}

impl Drop for FfiSession {
    /// Releases only resources created by this Dart connection.
    fn drop(&mut self) {
        self.close();
        let owned = self.pushes.get_mut().expect("FFI pushes lock");
        let mut streams = self.bridge.pushStreams.lock().expect("push streams lock");
        for id in owned.drain() {
            streams.remove(&id);
        }
    }
}

/// Creates a retained connection and returns its versioned function table to the host.
/// The host must pass a live handle returned by the bridge creation exports.
#[no_mangle]
pub unsafe extern "C" fn operit_flutter_bridge_ffi_connect(
    handle: *const OperitFlutterBridge,
) -> *mut c_char {
    assert!(!handle.is_null(), "FFI requires a live host runtime");
    Arc::increment_strong_count(handle);
    let session = Arc::new(FfiSession {
        bridge: Arc::from_raw(handle),
        port: OnceLock::new(),
        delivery: Mutex::new(()),
        watches: Mutex::new(HashMap::new()),
        pushes: Mutex::new(HashSet::new()),
        closed: AtomicBool::new(false),
    });
    let descriptor = serde_json::json!({
        "version": 1,
        // Addresses cross JSON as strings because JSON numbers cannot represent every
        // 64-bit pointer exactly on Dart's decoder.
        "session": (Arc::into_raw(session) as usize).to_string(),
        "attach": (ffi_attach as *const () as usize).to_string(),
        "submit": (ffi_submit as *const () as usize).to_string(),
        "allocate": (ffi_allocate as *const () as usize).to_string(),
        "free": (ffi_free as *const () as usize).to_string(),
        "release": (ffi_release as *const () as usize).to_string(),
    });
    CString::new(descriptor.to_string())
        .expect("FFI descriptor JSON")
        .into_raw()
}

/// Installs a VM-owned send port exactly once for this connection.
unsafe extern "C" fn ffi_attach(session: *const FfiSession, post: PostCObject, port: i64) -> bool {
    (*session).port.set(DartPort::new(post, port)).is_ok()
}

/// Allocates initialized request storage for transfer to submit or explicit release by free.
unsafe extern "C" fn ffi_allocate(length: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; length].into_boxed_slice()) as *mut u8
}

/// Releases exactly one buffer allocated by the connection's allocator.
unsafe extern "C" fn ffi_free(pointer: *mut u8, length: usize) {
    drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
        pointer, length,
    )));
}

/// Takes ownership of an allocated request and schedules it off the calling Dart isolate.
unsafe extern "C" fn ffi_submit(
    pointer: *const FfiSession,
    operation: u32,
    request: i64,
    bytes: *mut u8,
    length: usize,
) {
    Arc::increment_strong_count(pointer);
    let session = Arc::from_raw(pointer);
    let bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length));
    let worker_session = session.clone();
    let result = session
        .bridge
        .runtimeTaskScheduler()
        .scheduleHostRuntimeTask(
            "operit-ffi-request",
            Box::new(move || {
                let response = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    worker_session.dispatch(operation, request, &bytes)
                }));
                let response = match response {
                    Ok(response) => response,
                    Err(payload) => native_result_error_vec(
                        "FATAL_CORE_PANIC",
                        BridgeExports::panic_payload_message(payload.as_ref()),
                    ),
                };
                worker_session.post(0, request, &response);
            }),
        );
    if let Err(error) = result {
        session.post(
            0,
            request,
            &native_result_error_vec("FFI_SCHEDULE", error.to_string()),
        );
    }
}

/// Detaches Dart and releases its retained runtime reference after in-flight work ends.
unsafe extern "C" fn ffi_release(pointer: *mut c_void) {
    let session = Arc::from_raw(pointer.cast::<FfiSession>());
    session.close();
}
