use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn fixture() -> Value {
    let fixture_path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../shared/fixtures/search/basic.json");
    serde_json::from_str(&fs::read_to_string(fixture_path).expect("fixture should be readable"))
        .expect("fixture should be valid JSON")
}

pub(super) fn temporary_root(label: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    // Wall-clock nanoseconds alone repeat when parallel tests sample the same
    // clock tick, which once made two fixtures share one root; the per-process
    // sequence keeps every call unique.
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be valid")
        .as_nanos();
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "lithe-core-{label}-{}-{nonce}-{sequence}",
        std::process::id()
    ))
}

/// Removes a fixture root when the guard drops, including on panic unwind, so
/// a failing assertion cannot leave a temporary tree behind.
pub(super) struct TemporaryRootGuard {
    path: PathBuf,
}

impl TemporaryRootGuard {
    pub(super) fn keep(path: &std::path::Path) -> Self {
        Self {
            path: path.to_path_buf(),
        }
    }
}

impl Drop for TemporaryRootGuard {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
