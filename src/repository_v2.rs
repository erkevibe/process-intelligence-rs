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
    sync::Arc,
};

#[derive(Default, Clone)]
pub(crate) struct Baseline {
    logs: BTreeMap<String, StoredLog>,
    models: BTreeMap<String, Arc<StoredModel>>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Header {
    pub(crate) current: BTreeMap<String, String>,
    pub(crate) sequence: u64,
    pub(crate) user_views: BTreeMap<String, BTreeMap<String, UserView>>,
    pub(crate) durable_jobs: BTreeMap<String, JobSnapshot>,
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
        let logs: BTreeSet<_> = self.log_ids.iter().collect();
        let models: BTreeSet<_> = self.model_ids.iter().collect();
        if logs.len() != self.log_ids.len()
            || models.len() != self.model_ids.len()
            || logs.len() > 8
            || models.len() > 64
            || self.durable_jobs.len() > 10
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
        current: repo.current.clone(),
        sequence: repo.sequence,
        user_views: repo.user_views.clone(),
        durable_jobs: repo.durable_jobs.clone(),
        log_ids: repo.logs.keys().cloned().collect(),
        model_ids: repo.models.keys().cloned().collect(),
    }
}
fn log_state(log: &StoredLog) -> Value {
    json!({"id":log.id,"filename":log.filename,"analysis_version":log.analysis_version,"view_revision":log.view_revision,"threshold":log.threshold,"selected":log.selected,"selected_case":log.selected_case,"elapsed_ms":log.elapsed_ms,"source_sha256":log.source_sha256,"order":log.order,"filters":log.filters,"calendar":log.calendar,"project_id":log.project_id})
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
        if old.is_none_or(|old| log_state(old) != state) {
            puts.push(("log_state".into(), id.clone(), state));
        }
        if old.is_none_or(|old| !Arc::ptr_eq(&old.data, &log.data)) {
            puts.push((
                "log_data".into(),
                id.clone(),
                serde_json::to_value(log.data.as_ref()).map_err(|_| corrupt())?,
            ));
        }
        if old.is_none_or(|old| !Arc::ptr_eq(&old.source, &log.source)) {
            puts.push((
                "log_source".into(),
                id.clone(),
                serde_json::to_value(log.source.as_ref()).map_err(|_| corrupt())?,
            ));
        }
        if old.is_none_or(|old| !Arc::ptr_eq(&old.analysis, &log.analysis)) {
            puts.push((
                "log_analysis".into(),
                id.clone(),
                serde_json::to_value(log.analysis.as_ref()).map_err(|_| corrupt())?,
            ));
        }
    }
    for (id, model) in &next.models {
        if id != &model.id || crate::bpmn::validate(&model.model).is_err() {
            return Err(corrupt());
        }
        if next
            .persisted
            .models
            .get(id)
            .is_none_or(|old| !Arc::ptr_eq(old, model))
        {
            puts.push((
                "model".into(),
                id.clone(),
                serde_json::to_value(model).map_err(|_| corrupt())?,
            ));
        }
    }
    for id in next
        .persisted
        .logs
        .keys()
        .filter(|id| !next.logs.contains_key(*id))
    {
        for kind in ["log_state", "log_data", "log_source", "log_analysis"] {
            deletes.push((kind.into(), id.clone()));
        }
    }
    for id in next
        .persisted
        .models
        .keys()
        .filter(|id| !next.models.contains_key(*id))
    {
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
    repo.persisted = Arc::new(Baseline {
        logs: repo.logs.clone(),
        models: repo.models.clone(),
    });
}
pub(crate) fn load(database: &Database, project: &str) -> Result<Repository, ImportError> {
    let Some((revision, value)) = database.project_header(project)? else {
        return Ok(Repository::default());
    };
    let h = Header::parse(value)?;
    let expected: BTreeSet<_> = h
        .log_ids
        .iter()
        .flat_map(|id| {
            ["log_state", "log_data", "log_source", "log_analysis"]
                .map(|kind| (kind.to_string(), id.clone()))
        })
        .chain(h.model_ids.iter().map(|id| ("model".into(), id.clone())))
        .collect();
    let actual: BTreeSet<_> = database.record_keys(project)?.into_iter().collect();
    if actual != expected {
        return Err(corrupt());
    }
    let mut repo = Repository {
        current: h.current,
        sequence: h.sequence,
        user_views: h.user_views,
        durable_jobs: h.durable_jobs,
        storage_revision: revision,
        ..Default::default()
    };
    for id in h.log_ids {
        let Value::Object(mut state) = database
            .project_record(project, "log_state", &id)?
            .ok_or_else(corrupt)?
        else {
            return Err(corrupt());
        };
        for (field, kind) in [
            ("data", "log_data"),
            ("source", "log_source"),
            ("analysis", "log_analysis"),
        ] {
            if state
                .insert(
                    field.into(),
                    database
                        .project_record(project, kind, &id)?
                        .ok_or_else(corrupt)?,
                )
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
    for id in h.model_ids {
        let model: StoredModel = serde_json::from_value(
            database
                .project_record(project, "model", &id)?
                .ok_or_else(corrupt)?,
        )
        .map_err(|_| corrupt())?;
        if model.id != id || crate::platform::exportable_model(&model.model).is_err() {
            return Err(corrupt());
        }
        repo.models.insert(id, Arc::new(model));
    }
    mark_persisted(&mut repo);
    Ok(repo)
}

fn validate_view(
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
