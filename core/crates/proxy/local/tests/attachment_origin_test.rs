use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use operit_host_api::HostManager::HostManager;
use operit_host_native_common::{
    NativeHostJavaScriptRuntimeHost, NativeHostRuntimeTaskSchedulerHost, NativeRuntimeStorageHost,
    PosixFileSystemHost,
};
use operit_link::{fromCoreValue, toCoreValue, CoreCallRequest, CoreLinkSharedClient};
use operit_model::AttachmentInfo::AttachmentInfo;
use operit_proxy_local::LocalCoreProxy;
use operit_runtime::core::application::OperitApplication::OperitApplication;
use operit_store::CoreNodeIdentityStore::CoreNodeIdentityStore;
use operit_util::RuntimeStorageLayout::{runtimeStorageOwnership, RuntimeStorageOwnership};
use operit_util::RuntimeStoreRoot::{setDefaultRuntimeStoreRootConfig, RuntimeStoreRootConfig};
use serde_json::json;

/// Exercise the same generated import boundary that Flutter uses, before chat-send routing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn imported_attachment_keeps_its_actual_node_and_ephemeral_storage() {
    tokio::task::LocalSet::new()
        .run_until(async {
            let root = std::env::temp_dir().join(format!(
                "operit-attachment-origin-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let runtime_root = root.join("runtime");
            let workspace_root = root.join("workspaces");
            std::fs::create_dir_all(&runtime_root).unwrap();
            std::fs::create_dir_all(&workspace_root).unwrap();
            setDefaultRuntimeStoreRootConfig(RuntimeStoreRootConfig::new(
                runtime_root.clone(),
                workspace_root.clone(),
            ));
            let storage = Arc::new(NativeRuntimeStorageHost::new(
                runtime_root.clone(),
                workspace_root,
            ));
            CoreNodeIdentityStore::new(storage.clone())
                .writeNodeId("core-source-b".into())
                .unwrap();
            let host_manager = HostManager {
                fileSystemHost: Some(Arc::new(PosixFileSystemHost::new())),
                runtimeStorageHost: Some(storage.clone()),
                runtimeSqliteHost: Some(storage),
                hostJavaScriptRuntimeHost: Some(Arc::new(NativeHostJavaScriptRuntimeHost::new())),
                hostRuntimeTaskSchedulerHost: Some(Arc::new(
                    NativeHostRuntimeTaskSchedulerHost::new(),
                )),
                ..HostManager::default()
            };
            let proxy = LocalCoreProxy::new(OperitApplication::newWithContext(host_manager));
            let target = LocalCoreProxy::generatedTargetForSchema("chatRuntimeHolderMain").unwrap();
            let payload = format!(
                "transferred_file:{}",
                json!({
                    "fileName": "文档.pdf", "fileSize": 3, "base64Content": "AAH/",
                })
            );
            CoreLinkSharedClient::call(
                &proxy,
                CoreCallRequest::new(
                    "import-file",
                    target,
                    "handleAttachment",
                    toCoreValue(json!({"_filePath": payload})).unwrap(),
                ),
            )
            .await
            .result
            .expect("file import through the generated proxy must succeed");
            let attachments = {
                let holder = proxy.chatRuntimeHolder();
                let mut holder = holder.lock().await;
                holder.coreForTarget(target).unwrap().attachments()
            };
            assert_eq!(attachments.len(), 1);
            let attachment = &attachments[0];
            assert_eq!(attachment.nodeId.as_deref(), Some("core-source-b"));
            assert_eq!(std::fs::read(&attachment.filePath).unwrap(), [0, 1, 255]);
            assert!(std::path::Path::new(&attachment.filePath)
                .starts_with(runtime_root.join("temp/clean_on_exit")));
            assert!(attachment
                .fileToolPath()
                .starts_with("/app/data/temp/clean_on_exit/"));
            assert_eq!(
                runtimeStorageOwnership("runtime/temp/clean_on_exit/file.pdf").unwrap(),
                RuntimeStorageOwnership::Ephemeral
            );

            // A later identity/send context must not rewrite B's attachment to the receiving node.
            CoreNodeIdentityStore::native()
                .writeNodeId("core-execution-a".into())
                .unwrap();
            let forwarded: Vec<AttachmentInfo> =
                fromCoreValue(toCoreValue(&attachments).unwrap()).unwrap();
            assert_eq!(forwarded[0].nodeId.as_deref(), Some("core-source-b"));
            assert!(!forwarded[0].isLocalToNode(CoreNodeIdentityStore::localNodeId().as_deref()));

            CoreLinkSharedClient::call(
                &proxy,
                CoreCallRequest::new(
                    "import-text",
                    target,
                    "handleAttachment",
                    toCoreValue(json!({"_filePath": "pasted_text:inline content"})).unwrap(),
                ),
            )
            .await
            .result
            .expect("inline attachment import must succeed");
            let holder = proxy.chatRuntimeHolder();
            let mut holder = holder.lock().await;
            let attachments = holder.coreForTarget(target).unwrap().attachments();
            assert_eq!(attachments[1].nodeId, None);
            assert_eq!(attachments[1].content, "inline content");
            let _ = std::fs::remove_dir_all(root);
        })
        .await;
}
