//! Explicit finite-resource admission for cyclic Petri semantics, not finite trace enumeration.
pub mod bridge;
pub mod metrics;
pub mod pipeline;
pub mod state;
pub use process_intelligence_rs::bpmn_quality::{Issue, Limits, Result, array, integer, sha, text};
use serde::Serialize;
use serde_json::Value;
use std::{io::Write, path::Path};
pub const CORPUS: &str = include_str!("../../fixtures/quality/corpus.json");
pub fn bytes<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    serde_json::to_vec_pretty(value).map_err(|_| Issue::refused("json_encoding"))
}
pub fn read(path: &Path) -> Result<Vec<u8>> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| Issue::refused("artifact_missing"))?;
    if !metadata.is_file() || metadata.len() > 16 * 1024 * 1024 {
        return Err(Issue::refused("artifact_type_or_size"));
    }
    let result = std::fs::read(path).map_err(|_| Issue::refused("artifact_read"))?;
    if result.len() > 16 * 1024 * 1024 {
        return Err(Issue::refused("artifact_grew"));
    }
    Ok(result)
}
pub fn write(path: &Path, data: &[u8]) -> Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|_| Issue::refused("create_new_artifact"))?;
    file.write_all(data)
        .and_then(|()| file.sync_all())
        .map_err(|_| Issue::refused("artifact_write"))
}
pub fn fixture() -> Value {
    serde_json::from_str(CORPUS).expect("frozen_json")
}
