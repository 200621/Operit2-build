//! OpenHarmony host assembly for the Flutter bridge.

use std::path::PathBuf;
use std::sync::Arc;

use operit_host_api::HostManager::HostManager;
use operit_host_api::SystemOperationHost;
use operit_host_ohos_native::{
    createRuntimeHostManager, OhosBluetoothHost, OhosManagedRuntimeHost, OhosRuntimeStorageHost,
    OhosTerminalHost,
};
use operit_link::LinkDeviceInfo;

use super::{install_owner_media, BridgeStartup, StartupMetadata};
use crate::FlutterHostAdapters::FlutterWebVisitBridge;
use crate::FlutterOwnerCapabilities::{
    ownerBluetooth, ownerFileOpen, ownerFileShare, ownerRecognizeText, ownerScreenshot,
    ownerSystemOperation,
};

/// Creates OpenHarmony hosts with every owner callback fixed during assembly.
pub(crate) fn create_host_context(startup: &BridgeStartup) -> Result<HostManager, String> {
    let StartupMetadata::OpenHarmonyLanguage { code } = &startup.metadata else {
        return Err("OpenHarmony startup requires its owner system language".to_string());
    };
    if code.trim().is_empty() {
        return Err("OpenHarmony owner system language is empty".to_string());
    }
    let language = code.clone();
    let terminal = Arc::new(
        OhosTerminalHost::new(startup.runtimeRoot.clone(), startup.workspaceRoot.clone())
            .map_err(|error| error.message)?,
    );
    let managed = Arc::new(OhosManagedRuntimeHost::new(
        terminal.clone(),
        startup.workspaceRoot.clone(),
    ));
    let context = createRuntimeHostManager(
        startup.runtimeRoot.clone(),
        startup.workspaceRoot.clone(),
        Arc::new(FlutterWebVisitBridge::new()),
        Arc::new(ownerFileOpen),
        Arc::new(ownerFileShare),
        Arc::new(move || Ok(language.clone())),
        Arc::new(ownerScreenshot),
        Arc::new(ownerRecognizeText),
        Arc::new(ownerSystemOperation::<serde_json::Value>),
        managed,
    )
    .withTerminalHost(terminal)
    .withBluetoothHost(Arc::new(OhosBluetoothHost::fromController(Arc::new(
        ownerBluetooth,
    ))));
    Ok(install_owner_media(context, false))
}

/// Reads OpenHarmony identity through its owner-backed system host.
pub(crate) fn startup_device_info(
    context: &HostManager,
    _metadata: &StartupMetadata,
) -> Result<LinkDeviceInfo, String> {
    let system = context
        .systemOperationHost
        .as_ref()
        .ok_or_else(|| "Runtime identity requires its OpenHarmony system host".to_string())?;
    Ok(LinkDeviceInfo {
        platform: context.hostEnvironment.id.clone(),
        model: system
            .getDeviceInfo()
            .map_err(|error| error.to_string())?
            .model,
    })
}

/// OpenHarmony receives storage roots from its application owner.
pub(crate) fn default_native_storage_roots() -> Result<(PathBuf, PathBuf), String> {
    Err("The OpenHarmony owner must supply its application storage roots".to_string())
}

/// OpenHarmony has no process-global bridge registration to release here.
pub(crate) fn release_host() {}

impl crate::OperitFlutterBridge {
    /// Starts OpenHarmony using storage roots and language supplied by its owner.
    pub(crate) fn new_with_storage_roots(
        runtimeRoot: PathBuf,
        workspaceRoot: PathBuf,
        code: String,
    ) -> Result<Self, String> {
        crate::PlatformRuntimeFactory::startBridge(BridgeStartup {
            runtimeRoot,
            workspaceRoot,
            metadata: StartupMetadata::OpenHarmonyLanguage { code },
        })
    }
}
