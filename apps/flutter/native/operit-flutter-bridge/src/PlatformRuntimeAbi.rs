//! ABI module selection is kept outside the platform construction pipeline.
//! The selected ABI files keep their existing exported symbols and wire formats.

#[cfg(target_os = "android")]
#[path = "AndroidJni.rs"]
pub(crate) mod AndroidJni;
#[cfg(not(target_arch = "wasm32"))]
#[path = "FfiTransport.rs"]
pub(crate) mod FfiTransport;
#[cfg(not(target_arch = "wasm32"))]
#[path = "RuntimeBootstrapStore.rs"]
pub(crate) mod RuntimeBootstrapStore;
