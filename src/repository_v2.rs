//! Small project headers and immutable, separately persisted heavy payloads.
use crate::{
    domain::ImportError,
    jobs::{JobSnapshot, JobState},
    normalized::{ProjectWrite, Record},
    platform::StoredModel,
    storage::Database,
    web::{Repository, StoredLog, UserView},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::{Arc, Weak},
};

#[derive(Default, Clone)]
pub(crate) struct Baseline {
    logs: BTreeMap<String, LogToken>,
    models: BTreeMap<String, Weak<StoredModel>>,
    conversions: BTreeMap<String, Weak<crate::conversion_workflow::ConversionArtifact>>,
    quality: BTreeMap<String, Weak<crate::quality_store::QualityArtifact>>,
    discovery: BTreeMap<String, Weak<crate::discovery_store::DiscoveryArtifact>>,
}
#[derive(Clone)]
struct LogToken {
    state: Value,
    data: Weak<crate::domain::EventLog>,
    source: Weak<crate::domain::EventLog>,
    analysis: Weak<crate::domain::Analysis>,
    provenance: Option<Weak<crate::import_provenance::ImportProvenance>>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Header {
    #[serde(
        default,
        skip_serializing_if = "crate::folders::Organization::is_empty"
    )]
    pub(crate) organization: crate::folders::Organization,
    #[serde(default, skip_serializing_if = "crate::audit::AuditTrail::is_empty")]
    pub(crate) audit: crate::audit::AuditTrail,
    pub(crate) current: BTreeMap<String, String>,
    pub(crate) sequence: u64,
    pub(crate) user_views: BTreeMap<String, BTreeMap<String, UserView>>,
    pub(crate) durable_jobs: BTreeMap<String, JobSnapshot>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) conversions: BTreeMap<String, crate::conversion_workflow::ConversionMeta>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) quality_jobs: BTreeMap<String, crate::quality_store::QualityMeta>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) quality_requests: BTreeMap<String, crate::quality_store::RequestReceipt>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) discovery_jobs: BTreeMap<String, crate::discovery_store::DiscoveryMeta>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) discovery_requests: BTreeMap<String, crate::quality_store::RequestReceipt>,
    pub(crate) log_ids: Vec<String>,
    pub(crate) model_ids: Vec<String>,
}
fn corrupt() -> ImportError {
    ImportError::new(
        "repository_corrupt",
        "Сохранённый проект повреждён или не поддерживается. Данные не изменены.",
    )
}
impl Header {
    pub(crate) fn parse(value: Value) -> Result<Self, ImportError> {
        let header: Self = serde_json::from_value(value).map_err(|_| corrupt())?;
        header.validate()?;
        Ok(header)
    }
    pub(crate) fn validate(&self) -> Result<(), ImportError> {
        self.audit.validate().map_err(|_| corrupt())?;
        crate::conversion_workflow::validate_metadata(&self.conversions)?;
        crate::quality_store::validate_metadata(&self.quality_jobs, &self.quality_requests)?;
        crate::discovery_store::validate_metadata(&self.discovery_jobs, &self.discovery_requests)?;
        if self.discovery_jobs.keys().any(|id| {
            self.durable_jobs.contains_key(id)
                || self.conversions.contains_key(id)
                || self.quality_jobs.contains_key(id)
        }) {
            return Err(corrupt());
        }
        if self
            .quality_jobs
            .keys()
            .any(|id| self.durable_jobs.contains_key(id) || self.conversions.contains_key(id))
        {
            return Err(corrupt());
        }
        self.organization
            .validate(
                &self
                    .log_ids
                    .iter()
                    .chain(&self.model_ids)
                    .cloned()
                    .collect(),
            )
            .map_err(|_| corrupt())?;
        let logs: BTreeSet<_> = self.log_ids.iter().collect();
        let models: BTreeSet<_> = self.model_ids.iter().collect();
        if logs.len() != self.log_ids.len()
            || models.len() != self.model_ids.len()
            || logs.len() > 8
            || models.len() > 64
            || self.durable_jobs.len() > 10
            || self
                .conversions
                .keys()
                .any(|id| self.durable_jobs.contains_key(id))
            || self.log_ids.iter().any(|id| !valid_id(id, "log-"))
            || self.model_ids.iter().any(|id| !valid_id(id, "model-"))
            || self.current.values().any(|id| !logs.contains(id))
            || self
                .user_views
                .values()
                .flat_map(|views| views.keys())
                .any(|id| !logs.contains(id))
            || self.durable_jobs.iter().any(|(id, j)| {
                id != &j.id
                    || !valid_id(id, "job-")
                    || (!j.is_terminal() && j.job_revision == u64::MAX)
                    || (j.state == JobState::Completed
                        && !j.result_id.as_ref().is_some_and(|id| logs.contains(id)))
                    || (j.state != JobState::Completed && j.result_id.is_some())
            })
        {
            return Err(corrupt());
        }
        Ok(())
    }
    pub(crate) fn value(&self) -> Result<Value, ImportError> {
        serde_json::to_value(self).map_err(|_| corrupt())
    }
    pub(crate) fn recover(&mut self) -> bool {
        let mut changed = false;
        for job in self.durable_jobs.values_mut() {
            if !job.is_terminal() {
                job.state = JobState::Failed;
                job.stage = "interrupted".into();
                job.result_id = None;
                job.error=Some(crate::jobs::JobError{code:"interrupted".into(),message:"Приложение было остановлено до подтверждения результата. Загрузите файл заново.".into()});
                job.job_revision += 1;
                changed = true;
            }
        }
        for meta in self.conversions.values_mut() {
            if !meta.snapshot.is_terminal() {
                meta.snapshot.state = JobState::Failed;
                meta.snapshot.stage = "interrupted".into();
                meta.snapshot.result_id = None;
                meta.snapshot.error = Some(crate::jobs::JobError {code:"interrupted".into(),message:"Операция прервана перезапуском. Исходный файл сохранён — нажмите «Повторить».".into()});
                meta.snapshot.job_revision += 1;
                changed = true;
            }
        }
        for meta in self.quality_jobs.values_mut() {
            if !meta.snapshot.is_terminal() {
                meta.snapshot.state = JobState::Failed;
                meta.snapshot.stage = "interrupted".into();
                meta.snapshot.result_id = None;
                meta.snapshot.error = Some(crate::jobs::JobError {
                    code: "interrupted".into(),
                    message: "Оценка прервана перезапуском. Входы сохранены — нажмите «Повторить»."
                        .into(),
                });
                meta.snapshot.job_revision += 1;
                changed = true;
            }
        }
        for meta in self.discovery_jobs.values_mut() {
            if !meta.snapshot.is_terminal() {
                meta.snapshot.state = JobState::Failed;
                meta.snapshot.stage = "interrupted".into();
                meta.snapshot.result_id = None;
                meta.snapshot.error = Some(crate::jobs::JobError {
                    code: "interrupted".into(),
                    message:
                        "Построение прервано перезапуском. Снимок сохранён — нажмите «Повторить»."
                            .into(),
                });
                meta.snapshot.job_revision += 1;
                changed = true
            }
        }
        changed
    }
}
fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix).is_some_and(|suffix| {
        !suffix.is_empty() && suffix.len() <= 32 && suffix.bytes().all(|b| b.is_ascii_digit())
    })
}
pub(crate) fn header(repo: &Repository) -> Header {
    Header {
        organization: repo.organization.clone(),
        audit: repo.audit.clone(),
        current: repo.current.clone(),
        sequence: repo.sequence,
        user_views: repo.user_views.clone(),
        durable_jobs: repo.durable_jobs.clone(),
        conversions: repo.conversions.clone(),
        quality_jobs: repo.quality_jobs.clone(),
        quality_requests: repo.quality_requests.clone(),
        discovery_jobs: repo.discovery_jobs.clone(),
        discovery_requests: repo.discovery_requests.clone(),
        log_ids: repo
            .log_ids
            .iter()
            .chain(repo.logs.keys())
            .filter(|id| !repo.deleted_log_ids.contains(*id))
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect(),
        model_ids: repo
            .model_ids
            .iter()
            .chain(repo.models.keys())
            .filter(|id| !repo.deleted_model_ids.contains(*id))
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect(),
    }
}
fn log_state(log: &StoredLog) -> Value {
    let mut state = json!({"id":log.id,"filename":log.filename,"analysis_version":log.analysis_version,"view_revision":log.view_revision,"threshold":log.threshold,"selected":log.selected,"selected_case":log.selected_case,"elapsed_ms":log.elapsed_ms,"source_sha256":log.source_sha256,"order":log.order,"filters":log.filters,"calendar":log.calendar,"project_id":log.project_id});
    if let Some(created_at) = log.created_at {
        state["created_at"] = json!(created_at);
    }
    state
}
pub(crate) fn prepare(
    project: &str,
    next: &Repository,
    importing: bool,
) -> Result<ProjectWrite, ImportError> {
    let h = header(next);
    h.validate()?;
    let metadata = h.value()?;
    crate::storage::validate_document_capacity(&metadata, importing)?;
    let mut puts: Vec<Record> = Vec::new();
    let mut deletes = Vec::new();
    for (id, log) in &next.logs {
        if id != &log.id || log.project_id.as_deref() != Some(project) {
            return Err(corrupt());
        }
        let old = next.persisted.logs.get(id);
        let state = log_state(log);
        if next.deleted_log_ids.contains(id) {
            return Err(corrupt());
        }
        if old.is_none_or(|old| old.state != state) {
            puts.push(("log_state".into(), id.clone(), state));
        }
        if old.is_none_or(|old| !Weak::ptr_eq(&old.data, &Arc::downgrade(&log.data))) {
            puts.push((
                "log_data".into(),
                id.clone(),
                serde_json::to_value(log.data.as_ref()).map_err(|_| corrupt())?,
            ));
        }
        if old.is_none_or(|old| {
            !Weak::ptr_eq(&old.source, &Arc::downgrade(&log.source))
                || !same_provenance(&old.provenance, &log.provenance)
        }) {
            puts.push((
                "log_source".into(),
                id.clone(),
                match &log.provenance {
                    Some(provenance) => json!({"source_envelope_version":1,"source":log.source.as_ref(),"provenance":provenance.as_ref()}),
                    None => serde_json::to_value(log.source.as_ref()).map_err(|_| corrupt())?,
                },
            ));
        }
        if old.is_none_or(|old| !Weak::ptr_eq(&old.analysis, &Arc::downgrade(&log.analysis))) {
            puts.push((
                "log_analysis".into(),
                id.clone(),
                serde_json::to_value(log.analysis.as_ref()).map_err(|_| corrupt())?,
            ));
        }
    }
    for (id, model) in &next.models {
        model.validate_training()?;
        if id != &model.id
            || next.deleted_model_ids.contains(id)
            || crate::bpmn::validate(&model.model).is_err()
        {
            return Err(corrupt());
        }
        if next
            .persisted
            .models
            .get(id)
            .is_none_or(|old| !Weak::ptr_eq(old, &Arc::downgrade(model)))
        {
            puts.push((
                "model".into(),
                id.clone(),
                serde_json::to_value(model).map_err(|_| corrupt())?,
            ));
        }
    }
    for (id, artifact) in &next.conversion_artifacts {
        let meta = next
            .conversions
            .values()
            .find(|m| &m.artifact_id == id)
            .ok_or_else(corrupt)?;
        crate::conversion_workflow::validate_artifact(meta, artifact)?;
        if next.deleted_conversion_ids.contains(id) {
            return Err(corrupt());
        }
        if next
            .persisted
            .conversions
            .get(id)
            .is_none_or(|old| !Weak::ptr_eq(old, &Arc::downgrade(artifact)))
        {
            puts.push((
                "conversion".into(),
                id.clone(),
                serde_json::to_value(artifact).map_err(|_| corrupt())?,
            ));
        }
    }
    for id in &next.deleted_conversion_ids {
        deletes.push(("conversion".into(), id.clone()));
    }
    for (id, artifact) in &next.quality_artifacts {
        let meta = next
            .quality_jobs
            .values()
            .find(|m| &m.artifact_id == id)
            .ok_or_else(corrupt)?;
        crate::quality_store::validate_artifact(meta, artifact)?;
        if next.deleted_quality_ids.contains(id) {
            return Err(corrupt());
        }
        if next
            .persisted
            .quality
            .get(id)
            .is_none_or(|old| !Weak::ptr_eq(old, &Arc::downgrade(artifact)))
        {
            puts.push((
                "quality".into(),
                id.clone(),
                serde_json::to_value(artifact).map_err(|_| corrupt())?,
            ));
        }
    }
    for id in &next.deleted_quality_ids {
        deletes.push(("quality".into(), id.clone()));
    }
    for (id, artifact) in &next.discovery_artifacts {
        let meta = next
            .discovery_jobs
            .values()
            .find(|m| &m.artifact_id == id)
            .ok_or_else(corrupt)?;
        crate::discovery_store::validate_artifact(meta, artifact)?;
        if next.deleted_discovery_ids.contains(id) {
            return Err(corrupt());
        }
        if next
            .persisted
            .discovery
            .get(id)
            .is_none_or(|old| !Weak::ptr_eq(old, &Arc::downgrade(artifact)))
        {
            puts.push((
                "discovery".into(),
                id.clone(),
                serde_json::to_value(artifact).map_err(|_| corrupt())?,
            ));
        }
    }
    for id in &next.deleted_discovery_ids {
        deletes.push(("discovery".into(), id.clone()));
    }
    for id in &next.deleted_log_ids {
        for kind in ["log_state", "log_data", "log_source", "log_analysis"] {
            deletes.push((kind.into(), id.clone()));
        }
    }
    for id in &next.deleted_model_ids {
        deletes.push(("model".into(), id.clone()));
    }
    for (_, _, value) in &puts {
        crate::storage::validate_document_capacity(value, importing)?;
    }
    Ok(ProjectWrite {
        project: project.into(),
        expected: next.storage_revision,
        metadata,
        puts,
        deletes,
    })
}
pub(crate) fn mark_persisted(repo: &mut Repository) {
    let h = header(repo);
    repo.log_ids = h.log_ids.into_iter().collect();
    repo.model_ids = h.model_ids.into_iter().collect();
    let baseline = Arc::make_mut(&mut repo.persisted);
    baseline.logs.retain(|id, _| repo.log_ids.contains(id));
    baseline.models.retain(|id, _| repo.model_ids.contains(id));
    baseline
        .conversions
        .retain(|id, _| repo.conversions.values().any(|m| &m.artifact_id == id));
    for (id, artifact) in &repo.conversion_artifacts {
        baseline
            .conversions
            .insert(id.clone(), Arc::downgrade(artifact));
    }
    baseline
        .quality
        .retain(|id, _| repo.quality_jobs.values().any(|m| &m.artifact_id == id));
    for (id, artifact) in &repo.quality_artifacts {
        baseline
            .quality
            .insert(id.clone(), Arc::downgrade(artifact));
    }
    baseline
        .discovery
        .retain(|id, _| repo.discovery_jobs.values().any(|m| &m.artifact_id == id));
    for (id, artifact) in &repo.discovery_artifacts {
        baseline
            .discovery
            .insert(id.clone(), Arc::downgrade(artifact));
    }
    for (id, log) in &repo.logs {
        baseline.logs.insert(id.clone(), token(log));
    }
    for (id, model) in &repo.models {
        baseline.models.insert(id.clone(), Arc::downgrade(model));
    }
    repo.deleted_log_ids.clear();
    repo.deleted_model_ids.clear();
    repo.deleted_conversion_ids.clear();
    repo.deleted_quality_ids.clear();
    repo.deleted_discovery_ids.clear();
    if repo.lazy_resources {
        repo.logs.clear();
        repo.models.clear();
        repo.conversion_artifacts.clear();
        repo.quality_artifacts.clear();
        repo.discovery_artifacts.clear();
    }
}
fn token(log: &StoredLog) -> LogToken {
    LogToken {
        state: log_state(log),
        data: Arc::downgrade(&log.data),
        source: Arc::downgrade(&log.source),
        analysis: Arc::downgrade(&log.analysis),
        provenance: log.provenance.as_ref().map(Arc::downgrade),
    }
}
fn same_provenance(
    old: &Option<Weak<crate::import_provenance::ImportProvenance>>,
    next: &Option<Arc<crate::import_provenance::ImportProvenance>>,
) -> bool {
    match (old, next) {
        (None, None) => true,
        (Some(old), Some(next)) => Weak::ptr_eq(old, &Arc::downgrade(next)),
        _ => false,
    }
}
pub(crate) fn track_log(repo: &mut Repository, log: &StoredLog) {
    Arc::make_mut(&mut repo.persisted)
        .logs
        .insert(log.id.clone(), token(log));
}
pub(crate) fn track_model(repo: &mut Repository, model: &Arc<StoredModel>) {
    Arc::make_mut(&mut repo.persisted)
        .models
        .insert(model.id.clone(), Arc::downgrade(model));
}
pub(crate) type Versions = Vec<(String, u64)>;
pub(crate) const LOG_KINDS: &[&str] = &["log_analysis", "log_data", "log_source", "log_state"];
pub(crate) const MODEL_KINDS: &[&str] = &["model"];
pub(crate) fn load_metadata(database: &Database, project: &str) -> Result<Repository, ImportError> {
    let Some((revision, value)) = database.project_header(project)? else {
        return Ok(Repository {
            lazy_resources: true,
            ..Default::default()
        });
    };
    let h = Header::parse(value)?;
    let expected: BTreeSet<_> = h
        .log_ids
        .iter()
        .flat_map(|id| {
            LOG_KINDS
                .iter()
                .map(move |kind| (kind.to_string(), id.clone()))
        })
        .chain(h.model_ids.iter().map(|id| ("model".into(), id.clone())))
        .chain(
            h.quality_jobs
                .values()
                .map(|m| ("quality".into(), m.artifact_id.clone())),
        )
        .chain(
            h.discovery_jobs
                .values()
                .map(|m| ("discovery".into(), m.artifact_id.clone())),
        )
        .chain(
            h.conversions
                .values()
                .map(|m| ("conversion".into(), m.artifact_id.clone())),
        )
        .collect();
    let actual: BTreeSet<_> = database.record_keys(project)?.into_iter().collect();
    if actual != expected {
        return Err(corrupt());
    }
    Ok(Repository {
        organization: h.organization,
        audit: h.audit,
        current: h.current,
        sequence: h.sequence,
        user_views: h.user_views,
        durable_jobs: h.durable_jobs,
        conversions: h.conversions,
        quality_jobs: h.quality_jobs,
        quality_requests: h.quality_requests,
        discovery_jobs: h.discovery_jobs,
        discovery_requests: h.discovery_requests,
        storage_revision: revision,
        log_ids: h.log_ids.into_iter().collect(),
        model_ids: h.model_ids.into_iter().collect(),
        lazy_resources: true,
        ..Default::default()
    })
}
pub(crate) fn load_log(
    database: &Database,
    project: &str,
    id: &str,
) -> Result<(StoredLog, Versions), ImportError> {
    let records = database.resource_records(project, id, LOG_KINDS)?;
    decode_log(project, id, records)
}
pub(crate) fn decode_log(
    project: &str,
    id: &str,
    records: Vec<(String, u64, Value)>,
) -> Result<(StoredLog, Versions), ImportError> {
    let mut pieces = BTreeMap::new();
    let mut versions = Vec::new();
    for (kind, version, value) in records {
        if version == 0
            || !LOG_KINDS.contains(&kind.as_str())
            || pieces.insert(kind.clone(), value).is_some()
        {
            return Err(corrupt());
        }
        versions.push((kind, version));
    }
    versions.sort();
    if pieces.len() != 4 {
        return Err(corrupt());
    }
    let Value::Object(mut state) = pieces.remove("log_state").ok_or_else(corrupt)? else {
        return Err(corrupt());
    };
    let source = pieces.get_mut("log_source").ok_or_else(corrupt)?;
    if source.get("source_envelope_version").is_some() {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Envelope {
            source_envelope_version: u32,
            source: crate::domain::EventLog,
            provenance: crate::import_provenance::ImportProvenance,
        }
        let envelope: Envelope = serde_json::from_value(source.clone()).map_err(|_| corrupt())?;
        if envelope.source_envelope_version != 1 || state.contains_key("provenance") {
            return Err(corrupt());
        }
        state.insert(
            "provenance".into(),
            serde_json::to_value(envelope.provenance).map_err(|_| corrupt())?,
        );
        *source = serde_json::to_value(envelope.source).map_err(|_| corrupt())?;
    } else if state.contains_key("provenance") {
        return Err(corrupt());
    }
    for (field, kind) in [
        ("data", "log_data"),
        ("source", "log_source"),
        ("analysis", "log_analysis"),
    ] {
        if state
            .insert(field.into(), pieces.remove(kind).ok_or_else(corrupt)?)
            .is_some()
        {
            return Err(corrupt());
        }
    }
    let log: StoredLog = serde_json::from_value(Value::Object(state)).map_err(|_| corrupt())?;
    if log.id != id
        || log.project_id.as_deref() != Some(project)
        || log.source_sha256.len() != 64
        || !log.source_sha256.bytes().all(|b| b.is_ascii_hexdigit())
        || log.analysis.cases != log.data.cases.len()
        || log.analysis.events != log.data.cases.iter().map(|c| c.events.len()).sum::<usize>()
    {
        return Err(corrupt());
    }
    for data in [&log.source, &log.data] {
        let mut ids = BTreeSet::new();
        if data.cases.len() > 20_000
            || data.cases.iter().map(|c| c.events.len()).sum::<usize>() > 100_000
            || data.cases.iter().any(|c| {
                c.id.is_empty()
                    || !ids.insert(&c.id)
                    || c.events
                        .iter()
                        .any(|e| e.activity.is_empty() || e.activity.len() > 4096)
            })
        {
            return Err(corrupt());
        }
    }
    validate_log(&log)?;
    Ok((log, versions))
}
pub(crate) fn load_model(
    database: &Database,
    project: &str,
    id: &str,
) -> Result<(Arc<StoredModel>, Versions), ImportError> {
    let mut records = database.resource_records(project, id, MODEL_KINDS)?;
    if records.len() != 1 {
        return Err(corrupt());
    }
    let (kind, version, value) = records.remove(0);
    if kind != "model" || version == 0 {
        return Err(corrupt());
    }
    let model: StoredModel = serde_json::from_value(value).map_err(|_| corrupt())?;
    if model.id != id || crate::platform::exportable_model(&model.model).is_err() {
        return Err(corrupt());
    }
    model.validate_training().map_err(|_| corrupt())?;
    Ok((Arc::new(model), vec![(kind, version)]))
}
// Complete semantic materialization is reserved for backup and tests.
pub(crate) fn load(database: &Database, project: &str) -> Result<Repository, ImportError> {
    let mut repo = load_metadata(database, project)?;
    repo.lazy_resources = false;
    for id in repo.log_ids.clone() {
        let (log, _) = load_log(database, project, &id)?;
        for view in repo.user_views.values().filter_map(|views| views.get(&id)) {
            validate_view(
                &log,
                view.threshold,
                view.selected.as_deref(),
                view.selected_case.as_deref(),
            )?;
        }
        repo.logs.insert(id, log);
    }
    for id in repo.model_ids.clone() {
        repo.models
            .insert(id.clone(), load_model(database, project, &id)?.0);
    }
    for meta in repo.conversions.values() {
        let artifact = crate::conversion_workflow::load_artifact(database, project, meta)?;
        repo.conversion_artifacts
            .insert(meta.artifact_id.clone(), artifact);
    }
    for meta in repo.quality_jobs.values() {
        let artifact = crate::quality_store::load_artifact(database, project, meta)?;
        repo.quality_artifacts
            .insert(meta.artifact_id.clone(), artifact);
    }
    for meta in repo.discovery_jobs.values() {
        let artifact = crate::discovery_store::load_artifact(database, project, meta)?;
        repo.discovery_artifacts
            .insert(meta.artifact_id.clone(), artifact);
    }
    mark_persisted(&mut repo);
    Ok(repo)
}

pub(crate) fn validate_view(
    log: &StoredLog,
    threshold: u64,
    selected: Option<&str>,
    selected_case: Option<&str>,
) -> Result<(), ImportError> {
    if threshold == 0
        || threshold > log.analysis.max_edge_frequency.saturating_add(1).max(1)
        || selected.is_some_and(|id| {
            !log.analysis.nodes.iter().any(|node| node.id == id)
                && !log.analysis.edges.iter().any(|edge| edge.id == id)
        })
        || selected_case.is_some_and(|id| !log.data.cases.iter().any(|case| case.id == id))
    {
        return Err(corrupt());
    }
    Ok(())
}
fn validate_log(log: &StoredLog) -> Result<(), ImportError> {
    if let Some(provenance) = &log.provenance {
        provenance
            .validate(&log.source, &log.source_sha256)
            .map_err(|_| corrupt())?;
        if log.order != crate::csv_io::NormalizationOrder::Source {
            return Err(corrupt());
        }
    }
    validate_view(
        log,
        log.threshold,
        log.selected.as_deref(),
        log.selected_case.as_deref(),
    )?;
    let now = chrono::Utc::now();
    crate::calendar::business_millis(now, now, &log.calendar).map_err(|_| corrupt())?;
    if log.order == crate::csv_io::NormalizationOrder::Timestamp
        && log.source.cases.iter().any(|case| {
            case.events.iter().any(|e| e.timestamp.is_none())
                || case.events.windows(2).any(|events| {
                    (events[0].timestamp, events[0].ordinal)
                        > (events[1].timestamp, events[1].ordinal)
                })
        })
    {
        return Err(corrupt());
    }
    let filtered = crate::filters::apply(&log.source, &log.filters).map_err(|_| corrupt())?;
    if filtered != *log.data {
        return Err(corrupt());
    }
    drop(filtered);
    if crate::mining::analyze(&log.data) != *log.analysis {
        return Err(corrupt());
    }
    Ok(())
}

#[cfg(test)]
mod lazy_tests {
    use super::*;
    #[test]
    fn restored_provenance_uses_same_immutable_encoding_as_new_import() {
        let raw = include_str!("../fixtures/oracle-service/mixed.xes");
        let preview = crate::service_preview::preview_xes(raw.as_bytes()).unwrap();
        let provenance = Arc::new(
            crate::import_provenance::ImportProvenance::capture(
                raw.into(),
                &preview,
                "historical-user".into(),
                "historical-project".into(),
                uuid::Uuid::new_v4().to_string(),
            )
            .unwrap(),
        );
        let mut base = log();
        base.source = Arc::new(preview.log.clone());
        base.data = base.source.clone();
        base.analysis = Arc::new(crate::mining::analyze(&base.data));
        base.source_sha256 = provenance.source_sha256.clone();
        base.provenance = Some(provenance);
        base.project_id = Some("restored-project".into());
        let mut repo = Repository::default();
        repo.logs.insert(base.id.clone(), base);
        let expected = prepare("restored-project", &repo, false).unwrap();
        let (metadata, records) = crate::normalized::split_repository(
            "restored-project",
            serde_json::to_value(&repo).unwrap(),
        )
        .unwrap();
        assert_eq!(metadata, expected.metadata);
        let actual_source = records
            .iter()
            .find(|(kind, _, _)| kind == "log_source")
            .unwrap();
        let expected_source = expected
            .puts
            .iter()
            .find(|(kind, _, _)| kind == "log_source")
            .unwrap();
        assert_eq!(
            actual_source, expected_source,
            "restore must use exactly the confirmed-import immutable source envelope"
        );
        assert!(
            records
                .iter()
                .find(|(kind, _, _)| kind == "log_state")
                .unwrap()
                .2
                .get("provenance")
                .is_none()
        );
        let pieces = records
            .into_iter()
            .filter(|(_, id, _)| id == "log-1")
            .map(|(kind, _, value)| (kind, 1, value))
            .collect();
        let (loaded, _) = decode_log("restored-project", "log-1", pieces).unwrap();
        let history = loaded.provenance.unwrap();
        assert_eq!(history.original_utf8, raw);
        assert_eq!(history.origin_project_id, "historical-project");
    }
    #[test]
    fn immutable_provenance_envelope_changes_no_heavy_records_on_view_edit() {
        let raw = include_str!("../fixtures/oracle-service/mixed.xes");
        let preview = crate::service_preview::preview_xes(raw.as_bytes()).unwrap();
        let provenance = Arc::new(
            crate::import_provenance::ImportProvenance::capture(
                raw.into(),
                &preview,
                "u".into(),
                "p".into(),
                uuid::Uuid::new_v4().to_string(),
            )
            .unwrap(),
        );
        let mut base = log();
        base.source = Arc::new(preview.log.clone());
        base.data = base.source.clone();
        base.analysis = Arc::new(crate::mining::analyze(&base.data));
        base.provenance = Some(provenance.clone());
        base.source_sha256 = provenance.source_sha256.clone();
        let mut repo = Repository::default();
        repo.logs.insert(base.id.clone(), base.clone());
        let initial = prepare("p", &repo, true).unwrap();
        let source_record = initial
            .puts
            .iter()
            .find(|(kind, _, _)| kind == "log_source")
            .unwrap();
        assert_eq!(source_record.2["source_envelope_version"], 1);
        assert!(
            initial
                .puts
                .iter()
                .find(|(k, _, _)| k == "log_state")
                .unwrap()
                .2
                .get("provenance")
                .is_none()
        );
        let records = initial
            .puts
            .iter()
            .map(|(k, _, v)| (k.clone(), 1, v.clone()))
            .collect();
        let (loaded, _) = decode_log("p", "log-1", records).unwrap();
        assert_eq!(loaded.provenance.as_ref().unwrap().original_utf8, raw);
        track_log(&mut repo, &base);
        repo.logs.get_mut("log-1").unwrap().view_revision += 1;
        let delta = prepare("p", &repo, false).unwrap();
        assert_eq!(delta.puts.len(), 1);
        assert_eq!(delta.puts[0].0, "log_state");
        assert!(delta.puts[0].2.get("original_utf8").is_none());
        let weak = Arc::downgrade(&provenance);
        drop(loaded);
        drop(provenance);
        drop(base);
        repo.logs.clear();
        assert!(weak.upgrade().is_none());
    }
    fn log() -> StoredLog {
        let data = Arc::new(crate::domain::EventLog {
            name: None,
            cases: vec![],
            warnings: vec![],
        });
        StoredLog {
            id: "log-1".into(),
            filename: "empty.xes".into(),
            created_at: None,
            analysis_version: 1,
            view_revision: 1,
            threshold: 1,
            selected: None,
            selected_case: None,
            analysis: Arc::new(crate::mining::analyze(&data)),
            source: data.clone(),
            data,
            elapsed_ms: 0,
            source_sha256: "0".repeat(64),
            order: crate::csv_io::NormalizationOrder::Source,
            filters: Default::default(),
            calendar: Default::default(),
            project_id: Some("p".into()),
            provenance: None,
        }
    }
    #[test]
    fn metadata_delta_preserves_unloaded_catalog_and_only_explicit_deletion_removes() {
        let mut repo = Repository {
            lazy_resources: true,
            log_ids: BTreeSet::from(["log-1".into(), "log-2".into()]),
            ..Default::default()
        };
        let base = log();
        track_log(&mut repo, &base);
        repo.logs.insert(base.id.clone(), base);
        repo.sequence += 1;
        let write = prepare("p", &repo, false).unwrap();
        assert!(write.puts.is_empty());
        assert!(write.deletes.is_empty());
        assert_eq!(
            Header::parse(write.metadata).unwrap().log_ids,
            vec!["log-1", "log-2"]
        );
        mark_persisted(&mut repo);
        assert!(repo.logs.is_empty());
        assert_eq!(repo.log_ids.len(), 2);
        repo.deleted_log_ids.insert("log-1".into());
        let write = prepare("p", &repo, false).unwrap();
        assert_eq!(write.deletes.len(), 4);
        assert_eq!(
            Header::parse(write.metadata).unwrap().log_ids,
            vec!["log-2"]
        );
    }
    #[test]
    fn comparison_tokens_do_not_keep_heavy_owners_alive() {
        let mut repo = Repository::default();
        let base = log();
        let weak = Arc::downgrade(&base.data);
        track_log(&mut repo, &base);
        assert_eq!(Arc::strong_count(&base.data), 2);
        drop(base);
        assert!(weak.upgrade().is_none());
        assert!(repo.persisted.logs["log-1"].data.upgrade().is_none());
    }
    #[test]
    fn c06_saved_date_survives_state_delta_without_heavy_rewrite() {
        let mut base = log();
        assert!(log_state(&base).get("created_at").is_none());
        let date = chrono::DateTime::parse_from_rfc3339("2025-01-02T03:04:05.123Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        base.created_at = Some(date);
        let mut repo = Repository::default();
        track_log(&mut repo, &base);
        base.view_revision += 1;
        repo.logs.insert(base.id.clone(), base);
        let write = prepare("p", &repo, false).unwrap();
        assert_eq!(write.puts.len(), 1);
        assert_eq!(write.puts[0].0, "log_state");
        assert_eq!(write.puts[0].2["created_at"], "2025-01-02T03:04:05.123Z");
    }
}
