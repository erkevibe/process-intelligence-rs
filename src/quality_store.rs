//! Bounded immutable quality inputs/results and their durable job metadata.
use crate::{
    bpmn::ProcessModel,
    domain::ImportError,
    jobs::{JobSnapshot, JobState},
    web::Repository,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, Write},
    sync::{Arc, OnceLock},
};

pub(crate) const MAX_RETAINED: usize = 8;
pub(crate) const MAX_RECEIPTS: usize = 64;
pub(crate) const KEY_SECONDS: i64 = 3600;
pub(crate) const MAX_ARTIFACT: usize = 2 * 1024 * 1024 + 128 * 1024;
pub(crate) const MAX_REPORT: usize = 80 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct QualityMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub snapshot: JobSnapshot,
    pub artifact_id: String,
    pub owner: String,
    pub source_project_id: String,
    pub request_key: String,
    pub form_sha256: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub retry_of: Option<String>,
    pub model_id: String,
    pub model_name: String,
    pub model_revision: u64,
    pub log_id: String,
    pub log_name: String,
    pub analysis_version: u64,
    pub source_sha256: String,
    pub on_construction_log: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub training_relation: Option<String>,
    pub model_sha256: String,
    pub variants_sha256: String,
    pub method_sha256: String,
    pub report_sha256: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct QualityInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub model: ProcessModel,
    pub variants: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct QualityArtifact {
    pub id: String,
    pub input: QualityInput,
    pub report: Option<Value>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RequestReceipt {
    pub owner: String,
    pub job_id: String,
    pub form_sha256: String,
    pub expires_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_of: Option<String>,
}
pub(crate) fn corrupt() -> ImportError {
    ImportError::new(
        "quality_corrupt",
        "Сохранённая оценка повреждена или не поддерживается. Данные не изменены.",
    )
}
pub(crate) fn hash_valid(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn id_valid(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .is_some_and(|n| !n.is_empty() && n.len() <= 32 && n.bytes().all(|b| b.is_ascii_digit()))
}
fn label_valid(value: &str, max: usize) -> bool {
    value.len() <= max && !value.chars().any(char::is_control)
}
pub(crate) fn key_time(key: &str) -> Option<i64> {
    if key.len() > 64 {
        return None;
    }
    let (time, nonce) = key.split_once('.')?;
    if time.len() != 10 || !time.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let uuid = uuid::Uuid::parse_str(nonce).ok()?;
    if uuid.get_version_num() != 4 || uuid.to_string() != nonce {
        return None;
    }
    time.parse().ok()
}
pub(crate) fn request_key() -> String {
    format!(
        "{}.{}",
        chrono::Utc::now().timestamp(),
        uuid::Uuid::new_v4()
    )
}
pub(crate) fn method_sha256() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(|| {
        // Own application release metadata does not change the evaluator or
        // dependency graph. Preserve the original0.9 fingerprint across only
        // this package-version change; every other lock/source byte is hashed.
        let lock = include_str!("../Cargo.lock").replace("\r\n", "\n");
        let own = format!(
            "name = \"process-intelligence-rs\"\nversion = \"{}\"",
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(
            lock.matches(&own).count(),
            1,
            "one own package in dependency lock"
        );
        let lock = lock.replace(
            &own,
            "name = \"process-intelligence-rs\"\nversion = \"0.9.0\"",
        );
        let sources: &[&str] = &[
            include_str!("bpmn_quality/facade.rs"),
            include_str!("bpmn_quality/bridge.rs"),
            include_str!("bpmn_quality/state.rs"),
            include_str!("bpmn_quality/metrics.rs"),
            include_str!("bpmn.rs"),
            &lock,
            include_str!("bpmn_quality/saved.rs"),
        ];
        let mut bytes = Vec::new();
        for source in sources {
            let normalized = source.replace("\r\n", "\n");
            bytes.extend_from_slice(&(normalized.len() as u64).to_le_bytes());
            bytes.extend_from_slice(normalized.as_bytes());
        }
        crate::storage::sha256(&bytes)
    })
}
struct Bounded {
    bytes: Vec<u8>,
    limit: usize,
}
impl Write for Bounded {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(io::Error::other("quality_size_limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
pub(crate) fn bytes(value: &impl Serialize, limit: usize) -> Result<Vec<u8>, ImportError> {
    let mut writer = Bounded {
        bytes: Vec::new(),
        limit,
    };
    serde_json::to_writer(&mut writer, value).map_err(|_| {
        ImportError::new("quality_size_limit", "Превышен размер сохраняемой оценки.")
    })?;
    Ok(writer.bytes)
}
pub(crate) fn input_hashes(input: &QualityInput) -> Result<(String, String), ImportError> {
    if input.model.nodes.len() > 128 || input.model.flows.len() > 256 {
        return Err(corrupt());
    }
    crate::bpmn::validate(&input.model).map_err(|_| corrupt())?;
    // Store one canonical row per variant, not arbitrary duplicate/reordered rows.
    let variants = crate::dfg_discovery::variants_for(&input.variants, input.profile.as_deref())
        .map_err(|_| corrupt())?;
    let canonical: Vec<_> = variants
        .iter()
        .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
        .collect();
    if input.variants != json!(canonical) {
        return Err(corrupt());
    }
    Ok((
        crate::storage::sha256(&bytes(&input.model, 1024 * 1024)?),
        crate::storage::sha256(&bytes(&input.variants, 1024 * 1024)?),
    ))
}
pub(crate) fn validate_metadata(
    all: &BTreeMap<String, QualityMeta>,
    receipts: &BTreeMap<String, RequestReceipt>,
) -> Result<(), ImportError> {
    if all.len() > MAX_RETAINED || receipts.len() > MAX_RECEIPTS {
        return Err(corrupt());
    }
    let mut artifacts = BTreeSet::new();
    for (id, m) in all {
        if !crate::dfg_discovery::profile_valid(m.profile.as_deref()) {
            return Err(corrupt());
        }
        if id != &m.snapshot.id
            || !id_valid(id, "job-")
            || !id_valid(&m.artifact_id, "quality-")
            || !artifacts.insert(&m.artifact_id)
            || m.owner.is_empty()
            || m.source_project_id.is_empty()
            || !label_valid(&m.source_project_id, 128)
            || !label_valid(&m.owner, 128)
            || key_time(&m.request_key).is_none()
            || !hash_valid(&m.form_sha256)
            || !id_valid(&m.model_id, "model-")
            || !id_valid(&m.log_id, "log-")
            || !label_valid(&m.model_name, 1024)
            || !label_valid(&m.log_name, 1024)
            || !hash_valid(&m.model_sha256)
            || !hash_valid(&m.variants_sha256)
            || !hash_valid(&m.method_sha256)
            || !hash_valid(&m.source_sha256)
            || m.model_revision == 0
            || m.training_relation.as_deref().is_some_and(|v| {
                !matches!(
                    v,
                    "training_snapshot"
                        | "same_log_changed"
                        | "same_variants_other_log"
                        | "different_log_unverified"
                        | "same_log_unknown"
                        | "training_unknown"
                )
            })
            || m.analysis_version == 0
            || m.retry_of.as_ref().is_some_and(|id| !id_valid(id, "job-"))
            || !label_valid(&m.snapshot.stage, 64)
            || (!m.snapshot.is_terminal() && m.snapshot.job_revision == u64::MAX)
            || m.snapshot
                .error
                .as_ref()
                .is_some_and(|e| !label_valid(&e.code, 128) || !label_valid(&e.message, 4096))
            || (m.snapshot.state == JobState::Queued
                && (m.snapshot.job_revision != 0
                    || m.snapshot.stage != "queued"
                    || m.snapshot.cancel_requested
                    || m.snapshot.error.is_some()))
            || (m.snapshot.state == JobState::Running
                && (m.snapshot.job_revision == 0
                    || m.snapshot.cancel_requested
                    || m.snapshot.error.is_some()))
            || (m.snapshot.state == JobState::Completed
                && (m.snapshot.error.is_some()
                    || m.snapshot.cancel_requested
                    || m.snapshot.stage != "completed"
                    || m.snapshot.job_revision == 0))
            || (m.snapshot.state == JobState::Failed
                && (m.snapshot.error.is_none()
                    || m.snapshot.job_revision == 0
                    || !matches!(m.snapshot.stage.as_str(), "failed" | "interrupted")))
            || (m.snapshot.state == JobState::Cancelled
                && (!m.snapshot.cancel_requested
                    || m.snapshot.error.is_some()
                    || m.snapshot.stage != "cancelled"
                    || m.snapshot.job_revision == 0))
            || (m.snapshot.state == JobState::Completed
                && (m.snapshot.result_id.as_ref() != Some(&m.artifact_id)
                    || m.report_sha256.as_ref().is_none_or(|s| !hash_valid(s))))
            || (m.snapshot.state != JobState::Completed
                && (m.snapshot.result_id.is_some() || m.report_sha256.is_some()))
        {
            return Err(corrupt());
        }
        if let Some(receipt) = receipts.get(&m.request_key)
            && (receipt.job_id != *id
                || receipt.owner != m.owner
                || receipt.form_sha256 != m.form_sha256
                || receipt.retry_of != m.retry_of)
        {
            return Err(corrupt());
        }
    }
    for (key, receipt) in receipts {
        let issued = key_time(key).ok_or_else(corrupt)?;
        if !id_valid(&receipt.job_id, "job-")
            || receipt
                .retry_of
                .as_ref()
                .is_some_and(|id| !id_valid(id, "job-"))
            || receipt.owner.is_empty()
            || !label_valid(&receipt.owner, 128)
            || !hash_valid(&receipt.form_sha256)
            || receipt.expires_at != issued + KEY_SECONDS + 30
        {
            return Err(corrupt());
        }
    }
    Ok(())
}
pub(crate) fn envelope(m: &QualityMeta, report: Value) -> Value {
    let mut value = json!({"schema_version":1,"source_project_id":m.source_project_id,"model_id":m.model_id,"model_name":m.model_name,"model_revision":m.model_revision,
        "log_id":m.log_id,"log_name":m.log_name,"analysis_version":m.analysis_version,"source_sha256":m.source_sha256,
        "on_construction_log":m.on_construction_log,"saved_history":true,"method_sha256":m.method_sha256,
        "input_model_sha256":m.model_sha256,"input_variants_sha256":m.variants_sha256,"created_at":m.created_at,"report":report});
    if let Some(relation) = &m.training_relation {
        value["training_relation"] = json!(relation)
    }
    value
}
pub(crate) fn training_relation(
    model: &crate::platform::StoredModel,
    project: &str,
    log: &str,
    version: u64,
    source: &str,
    variants: &str,
) -> &'static str {
    if let Some(t) = &model.training {
        if t.source_project_id == project && t.log_id == log {
            if t.analysis_version == version
                && t.source_sha256 == source
                && t.variants_sha256 == variants
            {
                "training_snapshot"
            } else {
                "same_log_changed"
            }
        } else if t.variants_sha256 == variants {
            "same_variants_other_log"
        } else {
            "different_log_unverified"
        }
    } else if model.source_log.as_deref() == Some(log) {
        "same_log_unknown"
    } else {
        "training_unknown"
    }
}
pub(crate) fn validate_artifact(m: &QualityMeta, a: &QualityArtifact) -> Result<(), ImportError> {
    if a.input.profile != m.profile || a.id != m.artifact_id || bytes(a, MAX_ARTIFACT).is_err() {
        return Err(corrupt());
    }
    let (model, variants) = input_hashes(&a.input)?;
    if model != m.model_sha256 || variants != m.variants_sha256 {
        return Err(corrupt());
    }
    if let Some(report) = &a.report {
        if m.snapshot.state != JobState::Completed
            || Some(crate::storage::sha256(&bytes(report, MAX_REPORT)?)) != m.report_sha256
            || report != &envelope(m, report["report"].clone())
            || report["report"]["schema_version"] != 1
            || report["report"]["profile"]
                != if m.profile.is_some() {
                    crate::dfg_discovery::PROFILE
                } else {
                    "application_bounded_v1"
                }
        {
            return Err(corrupt());
        }
        let core = &report["report"];
        if core
            .get("model_sha256")
            .is_some_and(|s| s != &m.model_sha256)
            || core
                .get("variants_sha256")
                .is_some_and(|s| s != &m.variants_sha256)
        {
            return Err(corrupt());
        }
        for (metric, pointer) in [
            ("fitness", "/fitness/log_fitness"),
            ("precision", "/scalar"),
            ("simplicity", "/scalar"),
        ] {
            let value = &core["metrics"][metric];
            if !matches!(
                value["status"].as_str(),
                Some(
                    "measured"
                        | "no_data"
                        | "inconclusive"
                        | "refused"
                        | "requires_fitting_log"
                        | "not_applicable_no_activated_labels"
                        | "quality_unsupported_semantics"
                )
            ) {
                return Err(corrupt());
            }
            if value["status"] == "measured"
                && value
                    .pointer(pointer)
                    .and_then(Value::as_f64)
                    .is_none_or(|v| !v.is_finite() || !(0.0..=1.0).contains(&v))
            {
                return Err(corrupt());
            }
            if value["status"] != "measured" && value.pointer(pointer).is_some_and(|v| !v.is_null())
            {
                return Err(corrupt());
            }
        }
    } else if m.snapshot.state == JobState::Completed || m.report_sha256.is_some() {
        return Err(corrupt());
    }
    Ok(())
}
pub(crate) fn load_artifact(
    db: &crate::storage::Database,
    project: &str,
    m: &QualityMeta,
) -> Result<Arc<QualityArtifact>, ImportError> {
    let rows = db.resource_records(project, &m.artifact_id, &["quality"])?;
    if rows.len() != 1 || rows[0].0 != "quality" || rows[0].1 == 0 {
        return Err(corrupt());
    }
    let a: QualityArtifact = serde_json::from_value(rows[0].2.clone()).map_err(|_| corrupt())?;
    validate_artifact(m, &a)?;
    Ok(Arc::new(a))
}
pub(crate) fn validate_full(repo: &Repository) -> Result<(), ImportError> {
    validate_metadata(&repo.quality_jobs, &repo.quality_requests)?;
    let ids: BTreeSet<_> = repo.quality_jobs.values().map(|m| &m.artifact_id).collect();
    if ids != repo.quality_artifacts.keys().collect() {
        return Err(corrupt());
    }
    for m in repo.quality_jobs.values() {
        validate_artifact(m, &repo.quality_artifacts[&m.artifact_id])?;
    }
    Ok(())
}
#[cfg(test)]
mod release_compatibility_tests {
    #[test]
    fn own_release_version_preserves_the_accepted_quality_method() {
        assert_eq!(
            super::method_sha256(),
            "be4a5a27bb061b0e4fc3a35a365061b4541281d613fd9bde3742572c6defea88",
            "A quality kernel/dependency change requires explicit new method acceptance; changing only the application version does not."
        );
    }
}
