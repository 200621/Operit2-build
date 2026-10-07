use crate::HostResult;

/// Dispatches Linux guest VFS locators independently of the runtime host filesystem.
pub fn resolveLinuxGuestDirectory(
    workingDir: &str,
    resolveHostDirectory: &dyn Fn(&str) -> HostResult<String>,
) -> HostResult<String> {
    let path = workingDir.trim();
    match path.strip_prefix("/mnt/linux") {
        Some("") => Ok("/".to_string()),
        Some(relative) if relative.starts_with('/') => Ok(relative.to_string()),
        _ => resolveHostDirectory(path),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::HostError;
    use std::cell::Cell;

    /// Resolves guest roots without consulting an unavailable native Linux mount.
    #[test]
    fn guest_roots_do_not_require_host_mounts() {
        let resolveHost = |_: &str| Err(HostError::new("/mnt/linux is not mounted"));
        for path in ["/mnt/linux", "/mnt/linux/", " /mnt/linux "] {
            assert_eq!(resolveLinuxGuestDirectory(path, &resolveHost).unwrap(), "/");
        }
    }

    /// Keeps guest subdirectories in the selected Linux terminal namespace.
    #[test]
    fn guest_subdirectories_are_not_host_paths() {
        let calls = Cell::new(0);
        let resolveHost = |_: &str| {
            calls.set(calls.get() + 1);
            Err(HostError::new("host resolver must not receive guest paths"))
        };
        assert_eq!(
            resolveLinuxGuestDirectory("/mnt/linux/home/user/work space", &resolveHost).unwrap(),
            "/home/user/work space",
        );
        assert_eq!(calls.get(), 0);
    }

    /// Preserves runtime and host-mounted workspace mappings without replacing errors.
    #[test]
    fn host_namespace_errors_are_preserved() {
        let calls = Cell::new(0);
        let resolveHost = |path: &str| {
            calls.set(calls.get() + 1);
            Err(HostError::new(format!("not mounted: {path}")))
        };
        for path in [
            "/app/workspaces/project",
            "/mnt/android/sdcard/project",
            "/mnt/linuxish/project",
        ] {
            assert_eq!(
                resolveLinuxGuestDirectory(path, &resolveHost)
                    .unwrap_err()
                    .message,
                format!("not mounted: {path}"),
            );
        }
        assert_eq!(calls.get(), 3);
    }

    /// Preserves the physical directory chosen by the host VFS for shared storage.
    #[test]
    fn host_workspace_uses_its_resolved_physical_directory() {
        let resolveHost = |path: &str| {
            assert_eq!(path, "/app/workspaces/project");
            Ok("/data/user/0/app.operit/files/workspaces/project".to_string())
        };
        assert_eq!(
            resolveLinuxGuestDirectory("/app/workspaces/project", &resolveHost).unwrap(),
            "/data/user/0/app.operit/files/workspaces/project",
        );
    }
}
