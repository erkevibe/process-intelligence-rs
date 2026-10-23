//! Durable project-scoped conversion jobs. A job's cancellation mutex is also
//! its publication fence; PostgreSQL commits the pair and terminal state first.
use crate::{
    domain::ImportError,
    jobs::{JobSnapshot, JobState},
    web::{AppState, Repository, Workspace},
};
use axum::{
    Json, Router,
    extract::{FromRequest, Multipart, Path, Request},
    http::{StatusCode, header},
    response::{IntoResponse, Redirect, Response, Sse, sse::Event},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    convert::Infallible,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

const MAX_RETAINED: usize = 8;
#[cfg(test)]
static HEAVY_FETCHES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
const MAX_REPORT: usize = 4 * 1024 * 1024;
#[cfg(test)]
#[path = "conversion_adversarial_tests.rs"]
mod adversarial_tests;
#[cfg(test)]
#[path = "conversion_capacity_tests.rs"]
mod capacity_tests;
#[cfg(test)]
#[path = "conversion_workflow_tests.rs"]
mod regression_tests;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ConversionMeta {
    pub snapshot: JobSnapshot,
    pub artifact_id: String,
    pub from: String,
    pub to: String,
    pub filename: String,
    pub owner: String,
    pub source_sha256: String,
    pub input_bytes: usize,
    pub allow_loss: bool,
    // Absent on legacy jobs. Old binaries deny unknown metadata fields before recovery.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report_profile: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub retry_of: Option<String>,
    pub payload_sha256: Option<String>,
    pub report_sha256: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ConversionArtifact {
    pub id: String,
    pub input: Arc<str>,
    pub payload: Option<Arc<str>>,
    pub report: Option<Arc<str>>,
}
fn error(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
fn corrupt() -> ImportError {
    error(
        "repository_corrupt",
        "Сохранённое преобразование повреждено. Данные не изменены.",
    )
}
fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .is_some_and(|s| !s.is_empty() && s.len() <= 32 && s.bytes().all(|b| b.is_ascii_digit()))
}
fn hash_valid(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn direction(from: &str, to: &str) -> bool {
    matches!(
        (from, to),
        ("xes", "csv") | ("csv", "xes") | ("petri-json", "pnml") | ("pnml", "petri-json")
    )
}
pub(crate) fn validate_metadata(all: &BTreeMap<String, ConversionMeta>) -> Result<(), ImportError> {
    let mut ids = BTreeSet::new();
    if all.len() > MAX_RETAINED {
        return Err(corrupt());
    }
    for (id, m) in all {
        if id != &m.snapshot.id
            || !valid_id(id, "job-")
            || !valid_id(&m.artifact_id, "conversion-")
            || !ids.insert(&m.artifact_id)
            || !direction(&m.from, &m.to)
            || m.report_profile.as_deref().is_some_and(|profile| profile != crate::conversion::compact::PROFILE || !matches!((m.from.as_str(),m.to.as_str()),("xes","csv")|("csv","xes")))
            || m.filename.len() > 256
            || m.filename.chars().any(char::is_control)
            || m.owner.is_empty()
            || m.owner.len() > 128
            || m.owner.chars().any(char::is_control)
            || m.snapshot.stage.len() > 64
            || m.snapshot.stage.chars().any(char::is_control)
            // Every persisted nonterminal snapshot is recovered before it can
            // enter a live JobStore. Recovery needs exactly one new revision.
            || (!m.snapshot.is_terminal() && m.snapshot.job_revision == u64::MAX)
            || m.snapshot.error.as_ref().is_some_and(|e| {
                e.code.len() > 128
                    || e.message.len() > 4096
                    || e.code.contains('\0')
                    || e.message.contains('\0')
            })
            || !hash_valid(&m.source_sha256)
            || m.input_bytes > crate::conversion::MAX_BYTES
            || m.retry_of.as_ref().is_some_and(|id| !valid_id(id, "job-"))
            || m.payload_sha256.as_ref().is_some_and(|s| !hash_valid(s))
            || m.report_sha256.as_ref().is_some_and(|s| !hash_valid(s))
            || (m.snapshot.state == JobState::Completed
                && (m.snapshot.result_id.as_ref() != Some(&m.artifact_id)
                    || m.payload_sha256.is_none()
                    || m.report_sha256.is_none()))
            || (m.snapshot.state != JobState::Completed
                && (m.snapshot.result_id.is_some() || m.payload_sha256.is_some()))
            || (!matches!(m.snapshot.state, JobState::Completed | JobState::Failed)
                && m.report_sha256.is_some())
        {
            return Err(corrupt());
        }
    }
    Ok(())
}
pub(crate) fn validate_artifact(
    m: &ConversionMeta,
    a: &ConversionArtifact,
) -> Result<(), ImportError> {
    if a.id != m.artifact_id
        || a.input.len() != m.input_bytes
        || a.input.len() > crate::conversion::MAX_BYTES
        || a.input.contains('\0')
        || crate::conversion::sha(a.input.as_bytes()) != m.source_sha256
        || a.payload
            .as_ref()
            .map(|p| crate::conversion::sha(p.as_bytes()))
            != m.payload_sha256
        || a.report
            .as_ref()
            .map(|p| crate::conversion::sha(p.as_bytes()))
            != m.report_sha256
        || a.payload
            .as_ref()
            .is_some_and(|p| p.len() > crate::conversion::MAX_BYTES || p.contains('\0'))
        || a.report.as_ref().is_some_and(|p| p.len() > MAX_REPORT)
    {
        return Err(corrupt());
    }
    if let Some(report) = &a.report {
        let r: serde_json::Value = match m.report_profile.as_deref() {
            Some(crate::conversion::compact::PROFILE)
                if matches!(
                    (m.from.as_str(), m.to.as_str()),
                    ("xes", "csv") | ("csv", "xes")
                ) =>
            {
                crate::conversion::compact::decode(report.as_bytes()).map_err(|_| corrupt())?
            }
            None => serde_json::from_str(report).map_err(|_| corrupt())?,
            _ => return Err(corrupt()),
        };
        if r["schema_version"] != 1
            || r["method_sha256"] != crate::conversion::METHOD
            || r["from"] != m.from
            || r["to"] != m.to
            || r["input_sha256"] != m.source_sha256
            || r["input_bytes"].as_u64() != Some(m.input_bytes as u64)
            || r["allow_metadata_loss"].as_bool() != Some(m.allow_loss)
        {
            return Err(corrupt());
        }
        if m.snapshot.state == JobState::Completed {
            if r["status"] != "converted"
                || r["target_sha256"].as_str() != m.payload_sha256.as_deref()
                || r["target_bytes"].as_u64() != a.payload.as_ref().map(|p| p.len() as u64)
            {
                return Err(corrupt());
            }
        } else if m.snapshot.state != JobState::Failed
            || !matches!(
                r["status"].as_str(),
                Some("refused" | "loss_refused" | "inconclusive")
            )
            || !r["target_sha256"].is_null()
            || !r["target_bytes"].is_null()
            || r["reason"].as_str() != m.snapshot.error.as_ref().map(|e| e.code.as_str())
        {
            return Err(corrupt());
        }
    }
    Ok(())
}
pub(crate) fn validate_full(repo: &Repository) -> Result<(), ImportError> {
    validate_metadata(&repo.conversions)?;
    let ids = repo
        .conversions
        .values()
        .map(|m| m.artifact_id.as_str())
        .collect::<BTreeSet<_>>();
    if ids
        != repo
            .conversion_artifacts
            .keys()
            .map(String::as_str)
            .collect()
    {
        return Err(corrupt());
    }
    for m in repo.conversions.values() {
        validate_artifact(m, &repo.conversion_artifacts[&m.artifact_id])?;
    }
    Ok(())
}
pub(crate) fn load_artifact(
    db: &crate::storage::Database,
    project: &str,
    m: &ConversionMeta,
) -> Result<Arc<ConversionArtifact>, ImportError> {
    #[cfg(test)]
    HEAVY_FETCHES.fetch_add(1, Ordering::SeqCst);
    let records = db.resource_records(project, &m.artifact_id, &["conversion"])?;
    if records.len() != 1 || records[0].0 != "conversion" || records[0].1 == 0 {
        return Err(corrupt());
    }
    let a: ConversionArtifact =
        serde_json::from_value(records[0].2.clone()).map_err(|_| corrupt())?;
    validate_artifact(m, &a)?;
    Ok(Arc::new(a))
}
fn artifact(
    state: &AppState,
    repo: &Repository,
    m: &ConversionMeta,
) -> Result<Arc<ConversionArtifact>, ImportError> {
    state.validate_resource_actor()?;
    if let Some(a) = repo.conversion_artifacts.get(&m.artifact_id) {
        validate_artifact(m, a)?;
        return Ok(a.clone());
    }
    let p = state.platform.as_ref().ok_or_else(corrupt)?;
    let actor = state.actor.as_ref().ok_or_else(corrupt)?;
    load_artifact(&p.database, &actor.project_id, m)
}
fn write_access(state: &AppState) -> Result<(), ImportError> {
    state.validate_resource_actor()?;
    if state.actor.as_ref().is_none_or(|a| !a.role.can_write()) {
        return Err(error(
            "access_denied",
            "Для этой операции нужны права редактора.",
        ));
    }
    Ok(())
}
fn response_error(e: ImportError) -> Response {
    let status = match e.code.as_str() {
        "access_denied" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "job_queue_full" => StatusCode::TOO_MANY_REQUESTS,
        "job_reservation_pool" | "job_admission_failed" => StatusCode::INTERNAL_SERVER_ERROR,
        "project_capacity" | "byte_limit" => StatusCode::PAYLOAD_TOO_LARGE,
        "storage_unavailable" | "storage_busy" => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::UNPROCESSABLE_ENTITY,
    };
    (
        status,
        Json(serde_json::json!({"code":e.code,"message":e.message})),
    )
        .into_response()
}
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, ImportError> + Send + 'static,
) -> Result<T, ImportError> {
    tokio::task::spawn_blocking(f).await.map_err(|_| {
        error(
            "worker_failed",
            "Операция прервалась. Результат не подтверждён.",
        )
    })?
}
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/conversions", get(index).post(upload))
        .route("/conversions/jobs/{id}", get(snapshot))
        .route("/conversions/jobs/{id}/events", get(events))
        .route("/conversions/jobs/{id}/cancel", post(cancel))
        .route("/conversions/jobs/{id}/retry", post(retry))
        .route("/conversions/jobs/{id}/delete", post(delete))
        .route("/conversions/jobs/{id}/{part}", get(download))
}
fn persist(
    state: &AppState,
    snapshot: &JobSnapshot,
    result: Option<(Option<String>, String)>,
) -> Result<(), ImportError> {
    let mut repo = state.repository.lock().expect("repository mutex");
    let mut next = repo.clone();
    let old = next
        .conversions
        .get(&snapshot.id)
        .ok_or_else(|| error("not_found", "Задача удалена."))?
        .clone();
    if old.snapshot.job_revision > snapshot.job_revision {
        return Ok(());
    }
    let m = next.conversions.get_mut(&snapshot.id).expect("checked");
    m.snapshot = snapshot.clone();
    if let Some((payload, report)) = result {
        let mut a = (*artifact(state, &repo, &old)?).clone();
        m.payload_sha256 = payload
            .as_ref()
            .map(|p| crate::conversion::sha(p.as_bytes()));
        m.report_sha256 = Some(crate::conversion::sha(report.as_bytes()));
        a.payload = payload.map(Arc::from);
        a.report = Some(Arc::from(report));
        next.conversion_artifacts.insert(a.id.clone(), Arc::new(a));
    }
    state.commit_with_action(
        &mut next,
        false,
        "conversion_job_updated",
        vec![snapshot.id.clone()],
    )?;
    *repo = next;
    Ok(())
}
struct Submission {
    from: String,
    to: String,
    input: Arc<str>,
    filename: String,
    allow_loss: bool,
    report_profile: Option<String>,
    retry_of: Option<String>,
}

fn reserve_conversion(state: &AppState) -> Result<crate::jobs::JobReservation, ImportError> {
    write_access(state)?;
    if state
        .repository
        .lock()
        .expect("repository mutex")
        .conversions
        .len()
        >= MAX_RETAINED
    {
        return Err(error(
            "conversion_capacity",
            "Сохранено восемь преобразований. Удалите ненужное завершённое преобразование перед новым запуском.",
        ));
    }
    state.conversion_jobs.reserve().map_err(|_| error("job_queue_full", "Уже приняты две операции. Новая задача не создана. Дождитесь свободного места и повторите отправку."))
}

struct RequestLifetime(Arc<AtomicBool>);
impl Drop for RequestLifetime {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn accept_and_launch(
    state: AppState,
    reservation: crate::jobs::JobReservation,
    submission: Submission,
    live: Arc<AtomicBool>,
    runtime: tokio::runtime::Handle,
) -> Result<(), ImportError> {
    if !live.load(Ordering::Acquire) {
        return Err(error(
            "request_cancelled",
            "Загрузка прервана до принятия задачи.",
        ));
    }
    // From this boundary the complete validated request is owned by acceptance.
    // Dropping the HTTP waiter cannot drop a committed job before launch.
    let input = submission.input.clone();
    let (lease, meta) = accept_reserved(&state, reservation, submission)?;
    let _entered = runtime.enter();
    launch(state, lease, meta, input);
    Ok(())
}

#[cfg(test)]
fn accept(
    state: &AppState,
    from: String,
    to: String,
    input: Arc<str>,
    filename: String,
    allow_loss: bool,
    retry_of: Option<String>,
) -> Result<(crate::jobs::JobLease, ConversionMeta), ImportError> {
    let reservation = reserve_conversion(state)?;
    accept_reserved(
        state,
        reservation,
        Submission {
            from,
            to,
            input,
            filename,
            allow_loss,
            report_profile: None,
            retry_of,
        },
    )
}

fn accept_reserved(
    state: &AppState,
    reservation: crate::jobs::JobReservation,
    submission: Submission,
) -> Result<(crate::jobs::JobLease, ConversionMeta), ImportError> {
    let Submission {
        from,
        to,
        input,
        filename,
        allow_loss,
        report_profile,
        retry_of,
    } = submission;
    write_access(state)?;
    if !direction(&from, &to) {
        return Err(error(
            "unsupported_direction",
            "Выберите одно из четырёх направлений.",
        ));
    }
    if report_profile.as_deref().is_some_and(|p| {
        p != crate::conversion::compact::PROFILE
            || !matches!(
                (from.as_str(), to.as_str()),
                ("xes", "csv") | ("csv", "xes")
            )
    }) {
        return Err(error(
            "compact_log_direction_required",
            "Компактный отчёт доступен только для XES ↔ CSV.",
        ));
    }
    if input.len() > crate::conversion::MAX_BYTES {
        return Err(error("byte_limit", "Файл превышает 20 MiB."));
    }
    // PostgreSQL JSONB cannot represent U+0000. Refuse before durable admission,
    // rather than poisoning the database worker while retaining an invalid input.
    if input.as_bytes().contains(&0) {
        return Err(error(
            "nul_forbidden",
            "Исходный файл содержит недопустимый нулевой символ.",
        ));
    }
    let mut repo = state.repository.lock().expect("repository mutex");
    if repo.conversions.len() >= MAX_RETAINED {
        return Err(error(
            "conversion_capacity",
            "Сохранено восемь преобразований. Удалите ненужное завершённое преобразование перед новым запуском.",
        ));
    }
    let artifact_sequence = repo.sequence.checked_add(2).ok_or_else(|| {
        error(
            "sequence_exhausted",
            "Исчерпан диапазон идентификаторов. Задача не создана.",
        )
    })?;
    let id = format!("job-{}", state.next_id(artifact_sequence - 1)?);
    let artifact_id = format!("conversion-{}", state.next_id(artifact_sequence)?);
    let lease = state
        .conversion_jobs
        .create_reserved(reservation, Some(id.clone()))
        .map_err(|code| match code {
            "job_sequence_exhausted" => error("sequence_exhausted", "Исчерпан диапазон идентификаторов. Задача не создана; обратитесь к администратору."),
            "job_queue_full" => error("job_queue_full", "Уже приняты две задачи. Дождитесь освобождения обработчика."),
            "job_reservation_pool" => error("job_reservation_pool", "Ошибка принадлежности резерва обработчика. Задача не создана."),
            _ => error("job_admission_failed", "Не удалось передать резерв обработчику. Задача не создана."),
        })?;
    let meta = ConversionMeta {
        snapshot: lease.job.snapshot(),
        artifact_id: artifact_id.clone(),
        from,
        to,
        filename,
        owner: state.actor_id().into(),
        source_sha256: crate::conversion::sha(input.as_bytes()),
        input_bytes: input.len(),
        allow_loss,
        report_profile,
        created_at: chrono::Utc::now(),
        retry_of,
        payload_sha256: None,
        report_sha256: None,
    };
    let mut next = repo.clone();
    next.sequence = artifact_sequence;
    next.conversions.insert(id, meta.clone());
    next.conversion_artifacts.insert(
        artifact_id.clone(),
        Arc::new(ConversionArtifact {
            id: artifact_id,
            input,
            payload: None,
            report: None,
        }),
    );
    if let Err(e) = state.commit_action_resources(
        &mut next,
        "conversion_accepted",
        vec![meta.snapshot.id.clone()],
    ) {
        lease.job.fail(&e.code, &e.message);
        state.conversion_jobs.remove_terminal(&meta.snapshot.id);
        return Err(e);
    }
    *repo = next;
    Ok((lease, meta))
}
fn launch(
    mut state: AppState,
    lease: crate::jobs::JobLease,
    meta: ConversionMeta,
    input: Arc<str>,
) {
    state.payload_permit = None;
    tokio::spawn(async move {
        let permit = match state.cpu.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => return,
        };
        let job = lease.job.clone();
        let id = meta.snapshot.id.clone();
        let result = tokio::task::spawn_blocking(move || -> Result<(), ImportError> {
            let _lease = lease;
            let _permit = permit;
            if !job.start("converting") {
                return Ok(());
            }
            persist(&state, &job.snapshot(), None)?;
            let control = job.control();
            let converted = crate::conversion::convert_with_cancel(
                &meta.from,
                &meta.to,
                input.as_bytes(),
                meta.allow_loss,
                control.cancellation_token(),
            );
            if control.is_cancelled() {
                return Ok(());
            }
            let report = match crate::conversion::report_bytes_profile_with_cancel(
                &meta.from,
                &meta.to,
                input.as_bytes(),
                meta.allow_loss,
                &converted,
                meta.report_profile.is_some(),
                control.cancellation_token(),
            )
            .and_then(|b| {
                String::from_utf8(b).map_err(|_| crate::conversion::Failure::new("report_utf8"))
            }) {
                Ok(report) => report,
                Err(failure) => {
                    job.try_fail_with(
                        &failure.reason,
                        "Не удалось подготовить ограниченный отчёт. Исходный файл сохранён.",
                        |failed| persist(&state, failed, None),
                    )?;
                    return Ok(());
                }
            };
            match converted {
                Ok(value) => {
                    let payload = match String::from_utf8(value.payload) {
                        Ok(p) => p,
                        Err(_) => {
                            job.try_fail_with(
                                "payload_utf8",
                                "Не удалось подготовить файл. Исходник сохранён.",
                                |failed| persist(&state, failed, None),
                            )?;
                            return Ok(());
                        }
                    };
                    job.try_complete_durable_with(
                        |before| {
                            let mut done = before.clone();
                            done.state = JobState::Completed;
                            done.stage = "completed".into();
                            done.result_id = Some(meta.artifact_id.clone());
                            done.job_revision += 1;
                            persist(&state, &done, Some((Some(payload), report)))?;
                            Ok(meta.artifact_id)
                        },
                        |failed| persist(&state, failed, None),
                    )?;
                }
                Err(failure) => {
                    job.try_fail_with(
                        &failure.reason,
                        "Преобразование отклонено. Скачайте отчёт с причиной.",
                        |failed| persist(&state, failed, Some((None, report))),
                    )?;
                }
            }
            Ok(())
        })
        .await;
        if !matches!(result, Ok(Ok(()))) {
            tracing::error!(job_id=%id,"conversion_persistence_failed");
        }
    });
}
fn multipart_failure(cause: axum::extract::multipart::MultipartError) -> Response {
    if cause.status() == StatusCode::PAYLOAD_TOO_LARGE {
        response_error(error(
            "byte_limit",
            "Загрузка вместе с полями формы превышает допустимый размер.",
        ))
    } else {
        response_error(error(
            "multipart",
            "Загрузка прервана или имеет неверный формат.",
        ))
    }
}
async fn upload(Workspace(state): Workspace, request: Request) -> Response {
    if let Err(e) = write_access(&state) {
        return response_error(e);
    }
    let form_limit = crate::event_io::Limits::default().max_bytes + 64 * 1024;
    if request
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .is_some_and(|n| n > form_limit as u64)
    {
        return response_error(error(
            "byte_limit",
            "Загрузка вместе с полями формы превышает допустимый размер.",
        ));
    }
    let reservation = match reserve_conversion(&state) {
        Ok(p) => p,
        Err(e) => return response_error(e),
    };
    let _upload = match state.uploads.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => {
            return response_error(error("job_queue_full", "Другие загрузки ещё выполняются."));
        }
    };
    let mut multipart = match Multipart::from_request(request, &()).await {
        Ok(m) => m,
        Err(_) => return response_error(error("multipart", "Нужна загрузка multipart/form-data.")),
    };
    let mut from = None;
    let mut to = None;
    let mut file = None;
    let mut filename = String::from("input");
    let mut allow = false;
    let mut compact = false;
    let mut seen = BTreeSet::new();
    loop {
        let field = match multipart.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(cause) => return multipart_failure(cause),
        };
        let name = field.name().unwrap_or("").to_string();
        if !seen.insert(name.clone())
            || !matches!(
                name.as_str(),
                "file" | "from" | "to" | "allow_loss" | "compact_report"
            )
        {
            return response_error(error("multipart", "Повторное или неизвестное поле."));
        }
        if name == "file" {
            filename = field
                .file_name()
                .unwrap_or("input")
                .chars()
                .filter(|c| !c.is_control())
                .take(64)
                .collect();
            let bytes = match field.bytes().await {
                Ok(b) if b.len() <= crate::conversion::MAX_BYTES => b,
                Ok(_) => return response_error(error("byte_limit", "Файл превышает 20 MiB.")),
                Err(cause) => return multipart_failure(cause),
            };
            file = match std::str::from_utf8(&bytes) {
                Ok(s) => Some(Arc::<str>::from(s)),
                Err(_) => {
                    return response_error(error("utf8_required", "Нужен файл в кодировке UTF-8."));
                }
            };
        } else {
            let value = match field.text().await {
                Ok(v) if v.len() <= 32 => v,
                Ok(_) => return response_error(error("multipart", "Неверное поле формы.")),
                Err(cause) => return multipart_failure(cause),
            };
            match name.as_str() {
                "from" => from = Some(value),
                "to" => to = Some(value),
                "allow_loss" => allow = value == "on",
                "compact_report" if value == "on" => compact = true,
                "compact_report" => {
                    return response_error(error("multipart", "Неверный формат отчёта."));
                }
                _ => {}
            }
        }
    }
    let (Some(from), Some(to), Some(input)) = (from, to, file) else {
        return response_error(error("multipart", "Выберите направление и файл."));
    };
    let live = Arc::new(AtomicBool::new(true));
    let _request_lifetime = RequestLifetime(live.clone());
    let runtime = tokio::runtime::Handle::current();
    match blocking(move || {
        accept_and_launch(
            state,
            reservation,
            Submission {
                from,
                to,
                input,
                filename,
                allow_loss: allow,
                report_profile: compact.then(|| crate::conversion::compact::PROFILE.into()),
                retry_of: None,
            },
            live,
            runtime,
        )
    })
    .await
    {
        Ok(()) => Redirect::to("/conversions").into_response(),
        Err(e) => response_error(e),
    }
}
fn esc(s: &str) -> String {
    crate::platform_render::html_escape(s)
}
fn panel(m: &ConversionMeta, editable: bool, watch: bool) -> String {
    let id = &m.snapshot.id;
    let status = match m.snapshot.state {
        JobState::Queued => "В очереди",
        JobState::Running => "Преобразование",
        JobState::Completed => "Готово",
        JobState::Cancelled => "Отменено",
        JobState::Failed if m.snapshot.stage == "interrupted" => "Прервано перезапуском",
        JobState::Failed => "Не выполнено",
    };
    let watch = if watch && !m.snapshot.is_terminal() {
        format!(" data-init=\"@get('/conversions/jobs/{id}/events', {{retry: 'never'}})\"")
    } else {
        String::new()
    };
    let mut html = format!(
        "<article id=\"conversion-{id}\" class=\"card\" data-revision=\"{}\"{watch}><h2>{} → {} · {}</h2><p role=\"status\">{status} · {id}</p>",
        m.snapshot.job_revision,
        esc(&m.from),
        esc(&m.to),
        esc(&m.filename)
    );
    if let Some(e) = &m.snapshot.error {
        html.push_str(&format!(
            "<p>{} <code>{}</code></p>",
            esc(&e.message),
            esc(&e.code)
        ));
    }
    if m.report_profile.is_some() {
        html.push_str("<p>Компактный отчёт · схема 2 · полные свидетельства. Для чтения нужен декодер gzip-hex-report-v1.</p>");
    }
    if let Some(retry) = &m.retry_of {
        html.push_str(&format!("<p>Новая попытка для {}</p>", esc(retry)));
    }
    if m.payload_sha256.is_some() {
        html.push_str(&format!(
            "<a href=\"/conversions/jobs/{id}/payload\">Скачать результат</a> · "
        ));
    }
    if m.report_sha256.is_some() {
        html.push_str(&format!(
            "<a href=\"/conversions/jobs/{id}/report\">Скачать отчёт JSON</a>"
        ));
    }
    if editable {
        if m.snapshot.is_terminal() {
            html.push_str(&format!("<form method=\"post\" action=\"/conversions/jobs/{id}/retry\" data-conversion-submit><button>Повторить из сохранённого исходника</button></form><form method=\"post\" action=\"/conversions/jobs/{id}/delete\"><button>Удалить преобразование и файлы</button></form>"));
        } else {
            html.push_str(&format!("<form method=\"post\" action=\"/conversions/jobs/{id}/cancel\"><button>Отменить</button></form>"));
        }
    }
    html.push_str("</article>");
    html
}
async fn index(Workspace(state): Workspace) -> Response {
    match blocking(move||{
        state.validate_resource_actor()?;
        let repo=state.repository.lock().expect("repository mutex");
        let editable=state.actor.as_ref().is_some_and(|a|a.role.can_write());
        let mut body=String::from("<h1>Преобразования файлов</h1><p>Исходник и результат — до 20 MiB каждый; отчёт — до 4 MiB. В проекте сохраняется до восьми преобразований. Старые результаты автоматически не удаляются. Отмена запрещает публикацию; обработчик может завершить текущий шаг позже. После сбоя повторите операцию из сохранённого исходника. Если ответ на отправку потерян, сначала проверьте список: задача могла быть принята.</p>");
        if editable{body.push_str("<form class=\"platform-form platform-card\" method=\"post\" action=\"/conversions\" data-conversion-submit enctype=\"multipart/form-data\"><label>Из <select name=\"from\" aria-label=\"Из\"><option>xes</option><option>csv</option><option>petri-json</option><option>pnml</option></select></label><label>В <select name=\"to\" aria-label=\"В\"><option>csv</option><option>xes</option><option>pnml</option><option>petri-json</option></select></label><label>Исходный файл <input required type=\"file\" name=\"file\"></label><label class=\"inline-check\"><input type=\"checkbox\" name=\"allow_loss\"> Разрешить перечисленные в отчёте потери атрибутов XES/CSV</label><p>Поддерживаются только XES ↔ CSV и Petri JSON ↔ PNML. Потери без явного согласия отклоняются. Каждая отправка — новая задача.</p><label class=\"inline-check\"><input type=\"checkbox\" name=\"compact_report\"> Компактный отчёт без потери свидетельств (только XES ↔ CSV)</label><p>По умолчанию используется обычный JSON схемы 1. Компактный JSON схемы 2 требует декодера. До включения сделайте полную резервную копию БД: старые версии приложения после принятия компактного задания не запустят эту установку. Для отката понадобится восстановить копию до включения формата.</p><button class=\"button\">Запустить преобразование</button></form>");}
        if editable && repo.conversions.len() >= MAX_RETAINED { body.push_str("<p class=\"platform-alert\">Сохранены все восемь попыток. Для нового запуска удалите ненужное завершённое преобразование. Сначала скачайте файлы, которые хотите сохранить.</p>"); }
        body.push_str(&format!("<p>Сохранено: {} / 8</p>",repo.conversions.len()));
        let mut ordered=repo.conversions.values().collect::<Vec<_>>();
        ordered.sort_by(|left,right| right.created_at.cmp(&left.created_at).then_with(|| {
            let sequence=|m:&ConversionMeta| m.snapshot.id.strip_prefix("job-").and_then(|n|n.parse::<u128>().ok()).unwrap_or(0);
            sequence(right).cmp(&sequence(left))
        }));
        for m in ordered{
            if !m.snapshot.is_terminal(){body.push_str(&format!("<div data-init=\"@get('/conversions/jobs/{}/events', {{retry: 'never'}})\">",m.snapshot.id));}
            body.push_str(&panel(m,editable,false));
            body.push_str(&format!("<div hidden aria-hidden=\"true\" id=\"conversion-transport-{}\"></div>",m.snapshot.id));
            if !m.snapshot.is_terminal(){body.push_str("</div>");}
        }
        Ok(crate::platform::page("Преобразования",body))
    }).await {Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn snapshot(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        state
            .repository
            .lock()
            .expect("repository mutex")
            .conversions
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))
    })
    .await
    {
        Ok(m) => Json(m).into_response(),
        Err(e) => response_error(e),
    }
}
async fn cancel(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        write_access(&state)?;
        let job = state
            .conversion_jobs
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        job.try_cancel_with(|s| persist(&state, s, None))
    })
    .await
    {
        Ok(_) => Redirect::to("/conversions").into_response(),
        Err(e) => response_error(e),
    }
}
async fn retry(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let saved = state.clone();
    let live = Arc::new(AtomicBool::new(true));
    let _request_lifetime = RequestLifetime(live.clone());
    let runtime = tokio::runtime::Handle::current();
    match blocking(move || {
        write_access(&saved)?;
        let m = {
            let repo = saved.repository.lock().expect("repository mutex");
            let m = repo
                .conversions
                .get(&id)
                .cloned()
                .ok_or_else(|| error("not_found", "Задача не найдена."))?;
            if !m.snapshot.is_terminal() {
                return Err(error(
                    "job_running",
                    "Дождитесь завершения или отмены задачи.",
                ));
            }
            m
        };
        let reservation = reserve_conversion(&saved)?;
        let input = {
            let repo = saved.repository.lock().expect("repository mutex");
            artifact(&saved, &repo, &m)?.input.clone()
        };
        accept_and_launch(
            saved,
            reservation,
            Submission {
                from: m.from,
                to: m.to,
                input,
                filename: m.filename,
                allow_loss: m.allow_loss,
                report_profile: m.report_profile,
                retry_of: Some(id),
            },
            live,
            runtime,
        )
    })
    .await
    {
        Ok(()) => Redirect::to("/conversions").into_response(),
        Err(e) => response_error(e),
    }
}
async fn delete(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        write_access(&state)?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let m = repo
            .conversions
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        if !m.snapshot.is_terminal() {
            return Err(error("job_running", "Сначала отмените задачу."));
        }
        let mut next = repo.clone();
        next.conversions.remove(&id);
        next.conversion_artifacts.remove(&m.artifact_id);
        next.deleted_conversion_ids.insert(m.artifact_id);
        state.commit_action_resources(&mut next, "conversion_deleted", vec![id.clone()])?;
        *repo = next;
        drop(repo);
        state.conversion_jobs.remove_terminal(&id);
        Ok(())
    })
    .await
    {
        Ok(()) => Redirect::to("/conversions").into_response(),
        Err(e) => response_error(e),
    }
}
async fn download(
    Workspace(state): Workspace,
    Path((id, part)): Path<(String, String)>,
) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo = state.repository.lock().expect("repository mutex");
        let m = repo
            .conversions
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        let a = artifact(&state, &repo, m)?;
        let (data, name) = match part.as_str() {
            "payload" => {
                let ext = match m.to.as_str() {
                    "petri-json" => "json",
                    v => v,
                };
                (a.payload.clone(), format!("payload.{ext}"))
            }
            "report" => (a.report.clone(), "conversion-report.json".into()),
            _ => return Err(error("not_found", "Файл не найден.")),
        };
        let data =
            data.ok_or_else(|| error("not_found", "Подтверждённый файл пока отсутствует."))?;
        let mut response = data.as_bytes().to_vec().into_response();
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            "application/octet-stream".parse().expect("constant"),
        );
        response.headers_mut().insert(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{name}\"")
                .parse()
                .expect("safe name"),
        );
        Ok(response)
    })
    .await
    {
        Ok(r) => r,
        Err(e) => response_error(e),
    }
}
async fn events(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let Some(job) = state.conversion_jobs.get(&id) else {
        return response_error(error("not_found", "Задача не найдена."));
    };
    let receiver = job.subscribe();
    let stream = futures_util::stream::unfold(
        (state, id, receiver, true, false),
        |(state, id, mut receiver, first, done)| async move {
            if done {
                return None;
            }
            if !first {
                let changed =
                    tokio::time::timeout(std::time::Duration::from_secs(5), receiver.changed())
                        .await;
                if matches!(changed, Ok(Err(_))) {
                    return None;
                }
            }
            let saved = state.clone();
            let key = id.clone();
            let m = blocking(move || {
                saved.validate_resource_actor()?;
                saved
                    .repository
                    .lock()
                    .expect("repository mutex")
                    .conversions
                    .get(&key)
                    .cloned()
                    .ok_or_else(|| error("not_found", "Задача удалена."))
            })
            .await
            .ok()?;
            let terminal = m.snapshot.is_terminal();
            let html = panel(
                &m,
                state.actor.as_ref().is_some_and(|a| a.role.can_write()),
                false,
            );
            let envelope = format!(
                "<div hidden aria-hidden=\"true\" id=\"conversion-transport-{id}\"><template data-conversion-update data-job-id=\"{id}\">{html}</template></div>"
            );
            let elements = envelope
                .lines()
                .map(|line| format!("elements {line}"))
                .collect::<Vec<_>>()
                .join("\n");
            let event = Event::default()
                .event("datastar-patch-elements")
                .data(format!(
                    "selector #conversion-transport-{id}\nmode outer\n{elements}"
                ));
            if terminal {
                return Some((
                    Ok::<_, Infallible>(event),
                    (state, id, receiver, false, true),
                ));
            }
            Some((Ok(event), (state, id, receiver, false, false)))
        },
    );
    Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::default())
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn meta() -> (ConversionMeta, ConversionArtifact) {
        let store = crate::jobs::JobStore::new();
        let lease = store.create().unwrap();
        let input: Arc<str> = Arc::from("case,activity\na,A\n");
        let m = ConversionMeta {
            snapshot: lease.job.snapshot(),
            artifact_id: "conversion-2".into(),
            from: "csv".into(),
            to: "xes".into(),
            filename: "input.csv".into(),
            owner: "user".into(),
            source_sha256: crate::conversion::sha(input.as_bytes()),
            input_bytes: input.len(),
            allow_loss: false,
            report_profile: None,
            created_at: chrono::Utc::now(),
            retry_of: None,
            payload_sha256: None,
            report_sha256: None,
        };
        let a = ConversionArtifact {
            id: m.artifact_id.clone(),
            input,
            payload: None,
            report: None,
        };
        (m, a)
    }
    #[test]
    fn artifact_pair_cannot_be_forged_or_exposed_before_completion() {
        let (mut m, mut a) = meta();
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_ok());
        assert!(validate_artifact(&m, &a).is_ok());
        a.payload = Some(Arc::from("forged"));
        assert!(validate_artifact(&m, &a).is_err());
        a.payload = None;
        m.snapshot.state = JobState::Completed;
        m.snapshot.result_id = Some(m.artifact_id.clone());
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_err());
        a.payload = Some(Arc::from("output"));
        let report = crate::conversion::report_bytes(
            &m.from,
            &m.to,
            a.input.as_bytes(),
            false,
            &Ok(crate::conversion::Converted {
                payload: b"output".to_vec(),
                extension: "xes",
                evidence: serde_json::Value::Null,
            }),
        )
        .unwrap();
        a.report = Some(Arc::from(String::from_utf8(report).unwrap()));
        m.payload_sha256 = Some(crate::conversion::sha(b"output"));
        m.report_sha256 = Some(crate::conversion::sha(
            a.report.as_ref().unwrap().as_bytes(),
        ));
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_ok());
        assert!(validate_artifact(&m, &a).is_ok());
        let original = a.report.clone().unwrap();
        for (field, value) in [
            ("input_sha256", serde_json::json!("0".repeat(64))),
            ("to", serde_json::json!("csv")),
            ("target_bytes", serde_json::json!(123456)),
        ] {
            let mut forged: serde_json::Value = serde_json::from_str(&original).unwrap();
            forged[field] = value;
            let text = serde_json::to_string(&forged).unwrap();
            m.report_sha256 = Some(crate::conversion::sha(text.as_bytes()));
            a.report = Some(Arc::from(text));
            assert!(
                validate_artifact(&m, &a).is_err(),
                "rehashing must not conceal inconsistent {field}"
            );
        }
        a.report = Some(original);
        m.report_sha256 = Some(crate::conversion::sha(
            a.report.as_ref().unwrap().as_bytes(),
        ));
        a.input = Arc::from("changed");
        assert!(validate_artifact(&m, &a).is_err());
    }
    #[test]
    fn conversion_and_import_share_actual_capacity_until_worker_exit() {
        let imports = crate::jobs::JobStore::new();
        let conversions = crate::jobs::JobStore::restore_with_slots(&[], imports.shared_slots());
        let import = imports.create().unwrap();
        let conversion = conversions.create().unwrap();
        conversion.job.cancel();
        assert!(imports.create().is_err());
        assert!(conversions.create().is_err());
        drop(conversion);
        let next = imports.create().unwrap();
        assert!(conversions.create().is_err());
        drop(next);
        drop(import);
        assert!(conversions.create().is_ok());
    }
    #[test]
    fn restart_retains_source_and_produces_explicit_retryable_interruption() {
        let (m, a) = meta();
        let mut repo = Repository::default();
        repo.conversions.insert(m.snapshot.id.clone(), m.clone());
        repo.conversion_artifacts.insert(a.id.clone(), Arc::new(a));
        let mut header = crate::repository_v2::header(&repo);
        assert!(header.recover());
        let recovered = &header.conversions[&m.snapshot.id];
        assert_eq!(recovered.snapshot.state, JobState::Failed);
        assert_eq!(recovered.snapshot.stage, "interrupted");
        assert_eq!(recovered.source_sha256, m.source_sha256);
        assert_eq!(recovered.artifact_id, m.artifact_id);
        assert!(!header.recover());
        repo.conversions = header.conversions;
        assert!(validate_full(&repo).is_ok());
    }
    #[test]
    fn untrusted_recovery_revision_is_checked_before_mutation() {
        let (mut m, _) = meta();
        m.snapshot.job_revision = u64::MAX;
        let mut repo = Repository::default();
        repo.conversions.insert(m.snapshot.id.clone(), m.clone());
        let malformed = crate::repository_v2::header(&repo).value().unwrap();
        let original = malformed.clone();
        assert_eq!(
            crate::repository_v2::Header::parse(malformed.clone())
                .err()
                .unwrap()
                .code,
            "repository_corrupt"
        );
        assert_eq!(malformed, original);
        repo.conversions
            .get_mut(&m.snapshot.id)
            .unwrap()
            .snapshot
            .job_revision = u64::MAX - 1;
        let mut valid = crate::repository_v2::Header::parse(
            crate::repository_v2::header(&repo).value().unwrap(),
        )
        .unwrap();
        assert!(valid.recover());
        assert_eq!(
            valid.conversions[&m.snapshot.id].snapshot.job_revision,
            u64::MAX
        );
        assert_eq!(
            valid.conversions[&m.snapshot.id].snapshot.state,
            JobState::Failed
        );
        assert!(valid.validate().is_ok());
        assert!(!valid.recover());
        // The historical import path shares recovery and must reject the same
        // untrusted boundary while preserving legitimate terminal MAX.
        repo.conversions.clear();
        let mut legacy = m.snapshot.clone();
        legacy.job_revision = u64::MAX;
        repo.durable_jobs.insert(legacy.id.clone(), legacy.clone());
        assert_eq!(
            crate::repository_v2::Header::parse(
                crate::repository_v2::header(&repo).value().unwrap()
            )
            .err()
            .unwrap()
            .code,
            "repository_corrupt"
        );
        repo.durable_jobs.get_mut(&legacy.id).unwrap().job_revision = u64::MAX - 1;
        let mut valid = crate::repository_v2::Header::parse(
            crate::repository_v2::header(&repo).value().unwrap(),
        )
        .unwrap();
        assert!(valid.recover());
        assert_eq!(valid.durable_jobs[&legacy.id].job_revision, u64::MAX);
        assert!(valid.validate().is_ok());
        assert!(!valid.recover());
    }
    #[test]
    fn artifact_metadata_and_backup_require_exact_key_set() {
        let (m, a) = meta();
        let mut repo = Repository::default();
        repo.conversions.insert(m.snapshot.id.clone(), m.clone());
        assert!(validate_full(&repo).is_err());
        repo.conversion_artifacts.insert(a.id.clone(), Arc::new(a));
        assert!(validate_full(&repo).is_ok());
        let (header, records) =
            crate::normalized::split_repository("project", serde_json::to_value(&repo).unwrap())
                .unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].0, "conversion");
        let joined = crate::normalized::join_repository("project", header, records).unwrap();
        assert_eq!(joined, serde_json::to_value(repo).unwrap());
    }
    #[test]
    fn compact_profile_is_a_persisted_capability_and_exact_report_binding() {
        let (mut m, mut a) = meta();
        a.input = Arc::from(
            std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv"))
                .unwrap(),
        );
        m.source_sha256 = crate::conversion::sha(a.input.as_bytes());
        m.input_bytes = a.input.len();
        let old = serde_json::to_value(&m).unwrap();
        assert!(old.get("report_profile").is_none());
        let restored: ConversionMeta = serde_json::from_value(old.clone()).unwrap();
        assert!(restored.report_profile.is_none());
        m.report_profile = Some(crate::conversion::compact::PROFILE.into());
        assert_eq!(
            serde_json::to_value(&m).unwrap()["report_profile"],
            crate::conversion::compact::PROFILE
        );
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_ok());
        let converted = crate::conversion::convert(&m.from, &m.to, a.input.as_bytes(), false);
        let report = crate::conversion::report_bytes_profile(
            &m.from,
            &m.to,
            a.input.as_bytes(),
            false,
            &converted,
            true,
        )
        .unwrap();
        let payload = String::from_utf8(converted.unwrap().payload).unwrap();
        a.payload = Some(Arc::from(payload));
        a.report = Some(Arc::from(String::from_utf8(report).unwrap()));
        m.payload_sha256 = Some(crate::conversion::sha(
            a.payload.as_ref().unwrap().as_bytes(),
        ));
        m.report_sha256 = Some(crate::conversion::sha(
            a.report.as_ref().unwrap().as_bytes(),
        ));
        m.snapshot.state = JobState::Completed;
        m.snapshot.result_id = Some(m.artifact_id.clone());
        assert!(validate_artifact(&m, &a).is_ok());
        m.report_profile = None;
        assert!(validate_artifact(&m, &a).is_err());
        m.report_profile = Some("unknown".into());
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_err());
        m.report_profile = Some(crate::conversion::compact::PROFILE.into());
        m.from = "pnml".into();
        m.to = "petri-json".into();
        assert!(validate_metadata(&BTreeMap::from([(m.snapshot.id.clone(), m.clone())])).is_err());
    }
}
