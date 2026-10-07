use super::*;
use operit_host_api::*;
use std::collections::{HashMap, HashSet};

#[derive(Default)]
struct TestFiles {
    files: HashMap<String, String>,
    directories: HashSet<String>,
}

#[derive(Default)]
struct TestFileSystemHost {
    storage: Mutex<TestFiles>,
    fail_inspect: bool,
    fail_directory: bool,
    fail_write: Option<String>,
}

impl FileSystemHost for TestFileSystemHost {
    fn envLabel(&self) -> &str {
        "test"
    }

    fn environmentDescriptor(&self) -> HostEnvironmentDescriptor {
        HostEnvironmentDescriptor::linux()
    }

    fn fileExists(&self, path: &str) -> HostResult<FileExistence> {
        if self.fail_inspect {
            return Err(HostError::new("Permission denied inspecting file"));
        }
        let storage = self.storage.lock().unwrap();
        let is_directory = storage.directories.contains(path);
        let file = storage.files.get(path);
        Ok(FileExistence {
            exists: is_directory || file.is_some(),
            isDirectory: is_directory,
            size: file.map_or(0, |content| content.len() as i64),
        })
    }

    fn makeDirectory(&self, path: &str, createParents: bool) -> HostResult<()> {
        assert!(
            createParents,
            "first-launch logs require recursive creation"
        );
        if self.fail_directory {
            return Err(HostError::new("Permission denied creating directory"));
        }
        self.storage.lock().unwrap().directories.insert(path.into());
        Ok(())
    }

    fn writeFile(&self, path: &str, content: &str, append: bool) -> HostResult<()> {
        if self.fail_write.as_deref() == Some(path) {
            return Err(HostError::new("Permission denied writing file"));
        }
        let parent = std::path::Path::new(path).parent().unwrap();
        let mut storage = self.storage.lock().unwrap();
        if !storage.directories.contains(parent.to_str().unwrap()) {
            return Err(HostError::new("Parent directory does not exist"));
        }
        if append {
            storage
                .files
                .entry(path.into())
                .or_default()
                .push_str(content);
        } else {
            storage.files.insert(path.into(), content.into());
        }
        Ok(())
    }

    fn validatePath(&self, _path: &str, _paramName: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn listFiles(&self, _path: &str) -> HostResult<Vec<FileEntry>> {
        unreachable!("unrelated file-system operation")
    }

    fn readFile(&self, _path: &str) -> HostResult<String> {
        unreachable!("unrelated file-system operation")
    }

    fn readFileWithLimit(&self, _path: &str, _maxBytes: usize) -> HostResult<String> {
        unreachable!("unrelated file-system operation")
    }

    fn readFileBytes(&self, _path: &str) -> HostResult<Vec<u8>> {
        unreachable!("unrelated file-system operation")
    }

    fn writeFileBytes(&self, _path: &str, _content: &[u8]) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn deleteFile(&self, _path: &str, _recursive: bool) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn moveFile(&self, _source: &str, _destination: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn copyFile(&self, _source: &str, _destination: &str, _recursive: bool) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn findFiles(&self, _request: FindFilesRequest) -> HostResult<Vec<String>> {
        unreachable!("unrelated file-system operation")
    }

    fn fileInfo(&self, _path: &str) -> HostResult<FileInfo> {
        unreachable!("unrelated file-system operation")
    }

    fn grepCode(&self, _request: GrepCodeRequest) -> HostResult<GrepCodeResult> {
        unreachable!("unrelated file-system operation")
    }

    fn zipFiles(&self, _source: &str, _destination: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn unzipFiles(&self, _source: &str, _destination: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn openFile(&self, _path: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }

    fn shareFile(&self, _path: &str, _title: &str) -> HostResult<()> {
        unreachable!("unrelated file-system operation")
    }
}

#[test]
fn first_launch_creates_log_directory_before_file() {
    let host = Arc::new(TestFileSystemHost::default());
    let files: Arc<dyn FileSystemHost> = host.clone();
    ensure_log_file(&files, "/runtime/logs/operit.log").unwrap();
    let storage = host.storage.lock().unwrap();
    assert!(storage.directories.contains("/runtime/logs"));
    assert_eq!(storage.files.get("/runtime/logs/operit.log").unwrap(), "");
}

#[test]
fn existing_log_contents_are_preserved() {
    let host = Arc::new(TestFileSystemHost::default());
    host.storage.lock().unwrap().files.insert(
        "/runtime/logs/operit.log".into(),
        "previous session logs".into(),
    );
    let files: Arc<dyn FileSystemHost> = host.clone();
    ensure_log_file(&files, "/runtime/logs/operit.log").unwrap();
    assert_eq!(
        host.storage.lock().unwrap().files["/runtime/logs/operit.log"],
        "previous session logs"
    );
}

#[test]
fn directory_at_log_path_is_reported() {
    let host = Arc::new(TestFileSystemHost::default());
    host.storage
        .lock()
        .unwrap()
        .directories
        .insert("/runtime/logs/operit.log".into());
    let files: Arc<dyn FileSystemHost> = host;
    let error = ensure_log_file(&files, "/runtime/logs/operit.log").unwrap_err();
    assert_eq!(
        error,
        "Log file path is a directory: '/runtime/logs/operit.log'"
    );
}

#[test]
fn host_failures_include_operation_path_and_cause() {
    let cases = [
        (
            TestFileSystemHost {
                fail_inspect: true,
                ..Default::default()
            },
            "Cannot inspect log file '/runtime/logs/operit.log': Permission denied inspecting file",
        ),
        (
            TestFileSystemHost {
                fail_directory: true,
                ..Default::default()
            },
            "Cannot create log directory '/runtime/logs': Permission denied creating directory",
        ),
        (
            TestFileSystemHost {
                fail_write: Some("/runtime/logs/operit.log".into()),
                ..Default::default()
            },
            "Cannot create log file '/runtime/logs/operit.log': Permission denied writing file",
        ),
    ];
    for (host, expected) in cases {
        let files: Arc<dyn FileSystemHost> = Arc::new(host);
        assert_eq!(
            ensure_log_file(&files, "/runtime/logs/operit.log").unwrap_err(),
            expected
        );
    }
}

#[test]
fn failed_configuration_keeps_memory_logs_and_can_recover() {
    const LOG: &str = "/runtime/logs/operit.log";
    const PACKAGE_LOG: &str = "/runtime/logs/toolpkg.log";
    let first = Arc::new(TestFileSystemHost::default());
    AppLogger::configure_log_files(first.clone(), LOG.into(), PACKAGE_LOG.into()).unwrap();
    AppLogger::i("BootstrapTest", "before failure");
    let previous_log = first.storage.lock().unwrap().files[LOG].clone();

    // Fail on the second file: a partially prepared pair must not stay bound.
    let failing = Arc::new(TestFileSystemHost {
        fail_write: Some(PACKAGE_LOG.into()),
        ..Default::default()
    });
    let error =
        AppLogger::configure_log_files(failing, LOG.into(), PACKAGE_LOG.into()).unwrap_err();
    assert!(error.contains(PACKAGE_LOG));
    assert!(!AppLogger::enable_file_logging());
    assert!(AppLogger::get_log_file().is_none());
    assert!(AppLogger::get_package_log_file().is_none());
    AppLogger::w("BootstrapTest", "continuing without file logs");
    assert!(AppLogger::entries()
        .iter()
        .any(|entry| entry.message == "continuing without file logs"));
    assert_eq!(first.storage.lock().unwrap().files[LOG], previous_log);

    let recovered = Arc::new(TestFileSystemHost::default());
    AppLogger::configure_log_files(recovered.clone(), LOG.into(), PACKAGE_LOG.into()).unwrap();
    assert!(AppLogger::enable_file_logging());
    AppLogger::i("ToolPkg", "file logging recovered");
    let storage = recovered.storage.lock().unwrap();
    assert!(storage.files[LOG].contains("file logging recovered"));
    assert!(storage.files[PACKAGE_LOG].contains("file logging recovered"));
}
