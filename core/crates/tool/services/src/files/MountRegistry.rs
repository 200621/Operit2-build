//! Identity-local persistent mount catalog, independent of platform filesystem backends.
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use operit_host_api::FileSystemResource::FileSystemResource;

pub const MOUNT_SOURCE_PREFIX: &str = "operit-mount:";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MountSource {
    pub namespace: String,
    pub backend: String,
    pub root: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VfsMount {
    pub id: String,
    pub namespace: String,
    pub name: String,
    pub backend: String,
    pub root: String,
}

impl VfsMount {
    pub fn vfsPath(&self) -> String { format!("{}/{}", self.namespace, self.id) }
    fn validate(&self) -> Result<(), String> {
        let parts: Vec<_> = self.namespace.split('/').collect();
        if parts.len() != 4 || parts[0] != "" || parts[1] != "mnt"
            || !parts[2..].iter().all(|s| safeSegment(s))
            || !safeSegment(&self.id)
            || (parts[2] == "windows" && parts[3].len() == 1)
            || ["/mnt/android/root", "/mnt/android/sdcard"].contains(&self.namespace.as_str()) {
            return Err("Mount namespace must be /mnt/<platform>/<kind> and must not shadow a built-in mount".into());
        }
        FileSystemResource { backend: self.backend.clone(), root: self.root.clone(), path: String::new() }
            .validate().map_err(|e| e.to_string())?;
        if self.backend == "native" && !Path::new(&self.root).is_absolute() {
            return Err("Native mount root must be an absolute host path".into());
        }
        if self.backend == "android_documents" {
            let uri = url::Url::parse(&self.root).map_err(|e| e.to_string())?;
            if uri.scheme() != "content" || uri.host_str().is_none() || !uri.path().starts_with("/tree/")
                || uri.query().is_some() || uri.fragment().is_some() {
                return Err("Android document mount requires an authorized content tree URI".into());
            }
        }
        Ok(())
    }
}

fn safeSegment(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
}

#[derive(Serialize, Deserialize)]
struct Catalog { version: u32, mounts: Vec<VfsMount> }

#[derive(Clone, Debug)]
pub struct MountRegistry { catalog: PathBuf }

impl MountRegistry {
    pub fn new(runtimeRoot: &Path) -> Self { Self { catalog: runtimeRoot.join("config/vfs_mounts.json") } }
    pub fn list(&self) -> Result<Vec<VfsMount>, String> {
        // Web hosts have no native catalog filesystem. Built-in VFS paths must
        // remain usable; a future web catalog adapter can implement persistence.
        #[cfg(target_arch = "wasm32")]
        return Ok(Vec::new());
        let bytes = match fs::read(&self.catalog) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(format!("Cannot read VFS mounts: {e}")),
        };
        let catalog: Catalog = serde_json::from_slice(&bytes).map_err(|e| format!("Invalid VFS mount catalog: {e}"))?;
        if catalog.version != 1 { return Err("Unsupported VFS mount catalog version".into()) }
        let mut paths = std::collections::HashSet::new();
        for mount in &catalog.mounts {
            mount.validate()?;
            if !paths.insert(mount.vfsPath()) { return Err("Duplicate VFS mount path".into()) }
        }
        Ok(catalog.mounts)
    }
    pub fn register(&self, namespace: &str, backend: &str, root: &str, name: &str) -> Result<VfsMount, String> {
        let _guard = catalogLock().lock().map_err(|_| "VFS mount catalog lock is poisoned")?;
        let candidate = VfsMount { id: Uuid::new_v4().simple().to_string(), namespace: namespace.trim_end_matches('/').into(), name: name.into(), backend: backend.into(), root: root.into() };
        candidate.validate()?;
        let mut mounts = self.list()?;
        if let Some(existing) = mounts.iter().find(|m| m.namespace == candidate.namespace && m.backend == backend && m.root == root) {
            return Ok(existing.clone());
        }
        mounts.push(candidate.clone());
        self.save(mounts)?;
        Ok(candidate)
    }
    pub fn remove(&self, vfsPath: &str) -> Result<(), String> {
        let _guard = catalogLock().lock().map_err(|_| "VFS mount catalog lock is poisoned")?;
        let mut mounts = self.list()?;
        let before = mounts.len();
        mounts.retain(|m| m.vfsPath() != vfsPath.trim_end_matches('/'));
        if before == mounts.len() { return Err("VFS mount not found".into()) }
        self.save(mounts)
    }
    fn save(&self, mounts: Vec<VfsMount>) -> Result<(), String> {
        let parent = self.catalog.parent().ok_or("Invalid mount catalog path")?;
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        let temporary = parent.join(format!(".vfs-mounts-{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
            let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
            let bytes = serde_json::to_vec_pretty(&Catalog { version: 1, mounts }).map_err(|e| e.to_string())?;
            file.write_all(&bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            fs::rename(&temporary, &self.catalog).map_err(|e| e.to_string())
        })();
        if result.is_err() { let _ = fs::remove_file(temporary); }
        result
    }
}
fn catalogLock() -> &'static Mutex<()> { static LOCK: OnceLock<Mutex<()>> = OnceLock::new(); LOCK.get_or_init(|| Mutex::new(())) }

#[cfg(test)]
mod tests {
    use super::*;
    struct TempRoot(PathBuf);
    impl TempRoot {
        fn new() -> Self { Self(std::env::temp_dir().join(format!("operit-mount-test-{}", Uuid::new_v4()))) }
        fn registry(&self) -> MountRegistry { MountRegistry::new(&self.0) }
    }
    impl Drop for TempRoot { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    #[test]
    fn persistentCatalogIsStableAndIdentityLocal() {
        let first = TempRoot::new();
        let second = TempRoot::new();
        let mount = first.registry().register("/mnt/android/documents", "android_documents", "content://com.termux.documents/tree/opaque%2Fhome", "Project").unwrap();
        assert_eq!(first.registry().list().unwrap(), vec![mount.clone()]);
        assert!(second.registry().list().unwrap().is_empty());
        assert_eq!(first.registry().register("/mnt/android/documents", "android_documents", &mount.root, "New name").unwrap().id, mount.id);
        first.registry().remove(&mount.vfsPath()).unwrap();
        assert!(first.registry().list().unwrap().is_empty());
    }
    #[test]
    fn nativeAndFuturePlatformBackendsUseTheSameCatalog() {
        let temp = TempRoot::new();
        temp.registry().register("/mnt/local/folders", "native", std::env::temp_dir().to_str().unwrap(), "Local").unwrap();
        temp.registry().register("/mnt/macos/bookmarks", "macos_bookmark", "opaque bookmark", "Future").unwrap();
        assert_eq!(temp.registry().list().unwrap().len(), 2);
    }
    #[test]
    fn invalidSourcesAndNamespacesAreRejectedBeforePersistence() {
        let temp = TempRoot::new();
        for ns in ["/mnt", "/mnt/android", "/mnt/android/root", "/mnt/android/sdcard", "/mnt/windows/c", "/mnt/../documents", "/app/data/mounts"] {
            assert!(temp.registry().register(ns, "test", "opaque", "Bad").is_err(), "{ns}");
        }
        for uri in ["/data/data/com.termux", "content://provider/document/id", "https://provider/tree/id", "content://provider/tree/id?x=1"] {
            assert!(temp.registry().register("/mnt/android/documents", "android_documents", uri, "Bad").is_err(), "{uri}");
        }
        assert!(temp.registry().register("/mnt/local/folders", "native", "relative", "Bad").is_err());
        assert!(temp.registry().list().unwrap().is_empty());
    }
    #[test]
    fn corruptCatalogIsAnErrorNotAnEmptyList() {
        let temp = TempRoot::new();
        let registry = temp.registry();
        fs::create_dir_all(registry.catalog.parent().unwrap()).unwrap();
        fs::write(&registry.catalog, "broken").unwrap();
        assert!(registry.list().is_err());
        assert!(registry.register("/mnt/local/folders", "native", "/tmp", "Local").is_err());
    }
    #[test]
    fn concurrentRegistrationDoesNotLoseMounts() {
        let temp = TempRoot::new();
        let registry = temp.registry();
        let jobs: Vec<_> = (0..8).map(|index| {
            let registry = registry.clone();
            std::thread::spawn(move || registry.register("/mnt/test/resources", "test", &format!("root-{index}"), "Test").unwrap())
        }).collect();
        for job in jobs { job.join().unwrap(); }
        assert_eq!(registry.list().unwrap().len(), 8);
    }
}
