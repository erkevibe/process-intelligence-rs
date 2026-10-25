//! Durable, project-scoped BPMN quality jobs. Inputs and terminal result are atomic.
#[cfg(test)]
use crate::bpmn_quality::facade;
use crate::{
    bpmn_quality::Issue,
    domain::ImportError,
    jobs::{JobLease, JobSnapshot, JobState},
    platform_render::html_escape,
    quality_store::{self as store, QualityArtifact, QualityInput, QualityMeta, RequestReceipt},
    web::{AppState, Repository, Workspace},
};
use axum::{
    Form, Json, Router,
    extract::{DefaultBodyLimit, Path, Query},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Redirect, Response, Sse, sse::Event},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    convert::Infallible,
    sync::Arc,
    time::{Duration, Instant},
};

#[cfg(test)]
#[path = "quality_workflow_tests.rs"]
mod tests;

fn error(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
fn response_error(e: ImportError) -> Response {
    let status = error_status(&e.code);
    (status, Json(json!({"code":e.code,"message":e.message}))).into_response()
}
fn error_status(code: &str) -> StatusCode {
    match code {
        "access_denied" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "quality_conflict"
        | "quality_request_conflict"
        | "quality_deleted"
        | "quality_method_changed" => StatusCode::CONFLICT,
        "job_queue_full" | "quality_capacity" | "quality_receipt_capacity" => {
            StatusCode::TOO_MANY_REQUESTS
        }
        "storage_unavailable" | "storage_busy" => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::UNPROCESSABLE_ENTITY,
    }
}
fn form_error(e: ImportError, headers: &HeaderMap) -> Response {
    if headers
        .get(header::ACCEPT)
        .is_some_and(|h| h == "application/json")
    {
        return response_error(e);
    }
    let status = error_status(&e.code);
    let mut response = crate::platform::page(
        "Оценка не принята",
        format!(
            "<h1>Операция не подтверждена</h1><p role=\"alert\">{}</p><p><a href=\"/quality\">Проверить список оценок</a> · <a href=\"/models\">Открыть модель и новую форму</a></p>",
            html_escape(&e.message)
        ),
    );
    *response.status_mut() = status;
    response
}
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, ImportError> + Send + 'static,
) -> Result<T, ImportError> {
    tokio::task::spawn_blocking(f).await.map_err(|_| {
        error(
            "quality_worker",
            "Операция прервана. Проверьте список задач перед повтором.",
        )
    })?
}
fn write_access(state: &AppState) -> Result<(), ImportError> {
    state.validate_resource_actor()?;
    if state.actor.as_ref().is_none_or(|a| !a.role.can_write()) {
        return Err(error("access_denied", "Нужны права редактора проекта."));
    }
    Ok(())
}
fn artifact(
    state: &AppState,
    repo: &Repository,
    meta: &QualityMeta,
) -> Result<Arc<QualityArtifact>, ImportError> {
    state.validate_resource_actor()?;
    if let Some(a) = repo.quality_artifacts.get(&meta.artifact_id) {
        store::validate_artifact(meta, a)?;
        return Ok(a.clone());
    }
    let platform = state.platform.as_ref().ok_or_else(store::corrupt)?;
    let actor = state.actor.as_ref().ok_or_else(store::corrupt)?;
    store::load_artifact(&platform.database, &actor.project_id, meta)
}
fn current_binding(
    state: &AppState,
    repo: &mut Repository,
    m: &QualityMeta,
) -> Result<(), ImportError> {
    let conflict = || {
        error(
            "quality_conflict",
            "Модель или журнал изменились. Запустите новую оценку из формы модели.",
        )
    };
    let model = repo.get_model(state, &m.model_id)?.ok_or_else(conflict)?;
    let log = repo.get_log_base(state, &m.log_id)?.ok_or_else(conflict)?;
    if model.revision != m.model_revision
        || log.analysis_version != m.analysis_version
        || log.source_sha256 != m.source_sha256
    {
        return Err(conflict());
    }
    let model_sha =
        crate::storage::sha256(&store::bytes(&model.model, 1024 * 1024).map_err(|_| conflict())?);
    let rows =
        crate::dfg_discovery::rows_for(&log.data, m.profile.as_deref()).map_err(|_| conflict())?;
    let variants_sha =
        crate::storage::sha256(&store::bytes(&rows, 1024 * 1024).map_err(|_| conflict())?);
    if model_sha != m.model_sha256 || variants_sha != m.variants_sha256 {
        return Err(conflict());
    }
    Ok(())
}
fn persist(
    state: &AppState,
    snapshot: &JobSnapshot,
    report: Option<Value>,
) -> Result<(), ImportError> {
    let mut repo = state.repository.lock().expect("repository mutex");
    let old = repo
        .quality_jobs
        .get(&snapshot.id)
        .cloned()
        .ok_or_else(|| error("not_found", "Задача удалена."))?;
    if snapshot.job_revision <= old.snapshot.job_revision {
        return Err(error(
            "storage_conflict",
            "Состояние задачи уже изменилось.",
        ));
    }
    if report.is_some() {
        current_binding(state, &mut repo, &old)?;
    }
    let mut next = repo.clone();
    let meta = next.quality_jobs.get_mut(&snapshot.id).expect("checked");
    meta.snapshot = snapshot.clone();
    if let Some(core) = report {
        let mut saved = (*artifact(state, &repo, &old)?).clone();
        let result = store::envelope(meta, core);
        meta.report_sha256 = Some(crate::storage::sha256(&store::bytes(
            &result,
            store::MAX_REPORT,
        )?));
        saved.report = Some(result);
        next.quality_artifacts
            .insert(saved.id.clone(), Arc::new(saved));
    }
    state.commit_action_resources(&mut next, "quality_job_updated", vec![snapshot.id.clone()])?;
    *repo = next;
    Ok(())
}
/// Internal terminal bookkeeping only: revocation must not leave a live-looking
/// job forever. It cannot publish a report or mutate inputs, even after logout.
fn persist_system_failure(state: &AppState, snapshot: &JobSnapshot) -> Result<(), ImportError> {
    if snapshot.state != JobState::Failed || snapshot.result_id.is_some() {
        return Err(store::corrupt());
    }
    let mut repo = state.repository.lock().expect("repository mutex");
    let old = repo
        .quality_jobs
        .get(&snapshot.id)
        .ok_or_else(|| error("not_found", "Задача удалена."))?;
    if old.snapshot.is_terminal()
        || old.report_sha256.is_some()
        || snapshot.job_revision <= old.snapshot.job_revision
    {
        return Err(error(
            "storage_conflict",
            "Состояние задачи уже изменилось.",
        ));
    }
    let mut next = repo.clone();
    next.quality_jobs
        .get_mut(&snapshot.id)
        .expect("checked")
        .snapshot = snapshot.clone();
    let platform = state.platform.as_ref().ok_or_else(store::corrupt)?;
    let project = &state.actor.as_ref().ok_or_else(store::corrupt)?.project_id;
    next.audit.append_business(
        "system",
        project,
        "quality_job_updated",
        vec![snapshot.id.clone()],
        next.storage_revision
            .checked_add(1)
            .ok_or_else(store::corrupt)?,
        &json!({"policy":"terminal_failure_only","snapshot":snapshot}),
    )?;
    let write = crate::repository_v2::prepare(project, &next, false)?;
    if !write.puts.is_empty() || !write.deletes.is_empty() {
        return Err(store::corrupt());
    }
    next.storage_revision = platform.database.write_project(write)?;
    crate::repository_v2::mark_persisted(&mut next);
    *repo = next;
    Ok(())
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct SubmitForm {
    #[serde(default, deserialize_with = "crate::dfg_discovery::optional_profile")]
    profile: Option<String>,
    log_id: String,
    revision: u64,
    request_key: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RetryForm {
    request_key: String,
}
struct Accepted {
    meta: QualityMeta,
    launch: Option<(JobLease, Arc<QualityArtifact>)>,
}
fn form_sha(model_id: &str, form: &SubmitForm, retry_of: Option<&str>) -> String {
    {
        let mut value = json!({"model_id":model_id,"log_id":form.log_id,"revision":form.revision,"retry_of":retry_of});
        if let Some(profile) = &form.profile {
            value["profile"] = json!(profile);
        }
        crate::storage::sha256(&serde_json::to_vec(&value).expect("form JSON"))
    }
}
fn accept(
    state: &AppState,
    model_id: &str,
    form: &SubmitForm,
    retry_of: Option<&str>,
) -> Result<Accepted, ImportError> {
    if !crate::dfg_discovery::profile_valid(form.profile.as_deref()) {
        return Err(error(
            "unsupported_profile",
            "Выберите поддерживаемый профиль.",
        ));
    }
    write_access(state)?;
    let issued = store::key_time(&form.request_key)
        .ok_or_else(|| error("quality_request_key", "Откройте новую форму оценки."))?;
    let fingerprint = form_sha(model_id, form, retry_of);
    let mut repo = state.repository.lock().expect("repository mutex");
    // Replay is resolved before reading current inputs, reserving slots or IDs.
    if let Some(meta) = repo
        .quality_jobs
        .values()
        .find(|m| m.request_key == form.request_key)
    {
        if meta.owner != state.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ запроса принадлежит другому пользователю.",
            ));
        }
        if meta.form_sha256 != fingerprint {
            return Err(error(
                "quality_request_conflict",
                "Повторный запрос отличается от принятого.",
            ));
        }
        return Ok(Accepted {
            meta: meta.clone(),
            launch: None,
        });
    }
    if let Some(receipt) = repo.quality_requests.get(&form.request_key) {
        if receipt.owner != state.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ запроса принадлежит другому пользователю.",
            ));
        }
        if receipt.form_sha256 != fingerprint {
            return Err(error(
                "quality_request_conflict",
                "Повторный запрос отличается от принятого.",
            ));
        }
        return Err(error(
            "quality_deleted",
            "Эта задача уже удалена. Откройте новую форму для нового запуска.",
        ));
    }
    let now = chrono::Utc::now().timestamp();
    if issued > now + 30 || issued < now - store::KEY_SECONDS {
        return Err(error(
            "quality_request_expired",
            "Форма устарела. Откройте её заново.",
        ));
    }
    if repo.quality_jobs.len() >= store::MAX_RETAINED {
        return Err(error(
            "quality_capacity",
            "Сохранено восемь оценок. Удалите ненужную завершённую оценку.",
        ));
    }
    let reservation = state.quality_jobs.reserve().map_err(|_| {
        error(
            "job_queue_full",
            "Уже приняты две операции. Повторите позже.",
        )
    })?;
    let model = repo
        .get_model(state, model_id)?
        .ok_or_else(|| error("not_found", "Модель не найдена."))?;
    let log = repo
        .get_log_base(state, &form.log_id)?
        .ok_or_else(|| error("not_found", "Журнал не найден."))?;
    if model.revision != form.revision {
        return Err(error(
            "quality_conflict",
            "Модель изменилась. Откройте форму заново.",
        ));
    }
    if model.name.len() > 1024
        || log.filename.len() > 1024
        || model.name.chars().any(char::is_control)
        || log.filename.chars().any(char::is_control)
    {
        return Err(error(
            "quality_label_limit",
            "Названия модели и журнала должны занимать до 1024 байт без управляющих символов.",
        ));
    }
    let variants = crate::dfg_discovery::rows_for(&log.data, form.profile.as_deref())?;
    if model.model.nodes.len() > 128 || model.model.flows.len() > 256 {
        return Err(error(
            "quality_model_limit",
            "Для оценки нужны не более 128 узлов и 256 переходов.",
        ));
    }
    // Bound borrowed model serialization before cloning it into durable input.
    store::bytes(&model.model, 1024 * 1024)?;
    let input = QualityInput {
        profile: form.profile.clone(),
        model: model.model.clone(),
        variants,
    };
    let (model_sha256, variants_sha256) = store::input_hashes(&input)?;
    if let Some(id) = retry_of {
        let original = repo
            .quality_jobs
            .get(id)
            .ok_or_else(|| error("not_found", "Исходная задача удалена."))?;
        if !original.snapshot.is_terminal() {
            return Err(error(
                "job_running",
                "Дождитесь завершения или отмены задачи.",
            ));
        }
        if original.profile != form.profile
            || original.method_sha256
                != crate::dfg_discovery::quality_method(original.profile.as_deref())
        {
            return Err(error(
                "quality_method_changed",
                "Методика изменилась. Запустите новую оценку из формы.",
            ));
        }
        if original.model_sha256 != model_sha256
            || original.variants_sha256 != variants_sha256
            || original.analysis_version != log.analysis_version
            || original.source_sha256 != log.source_sha256
        {
            return Err(error(
                "quality_conflict",
                "Исходные данные изменились. Запустите новую оценку из формы.",
            ));
        }
    }
    let mut next = repo.clone();
    next.quality_requests.retain(|_, r| r.expires_at >= now);
    if next.quality_requests.len() >= store::MAX_RECEIPTS {
        return Err(error(
            "quality_receipt_capacity",
            "Принято слишком много оценок за час. Дождитесь истечения старых ключей запросов.",
        ));
    }
    let (id, artifact_id, artifact_sequence) = state.allocate_job_pair(&repo, "quality")?;
    let lease = state
        .quality_jobs
        .create_reserved(reservation, Some(id.clone()))
        .map_err(|_| error("job_admission_failed", "Не удалось принять задачу."))?;
    let relation = store::training_relation(
        &model,
        &state.actor.as_ref().ok_or_else(store::corrupt)?.project_id,
        &form.log_id,
        log.analysis_version,
        &log.source_sha256,
        &variants_sha256,
    );
    let meta = QualityMeta {
        profile: form.profile.clone(),
        snapshot: lease.job.snapshot(),
        artifact_id: artifact_id.clone(),
        owner: state.actor_id().into(),
        source_project_id: state
            .actor
            .as_ref()
            .ok_or_else(store::corrupt)?
            .project_id
            .clone(),
        request_key: form.request_key.clone(),
        form_sha256: fingerprint.clone(),
        created_at: chrono::Utc::now(),
        retry_of: retry_of.map(str::to_owned),
        model_id: model_id.into(),
        model_name: model.name.clone(),
        model_revision: model.revision,
        log_id: form.log_id.clone(),
        log_name: log.filename.clone(),
        analysis_version: log.analysis_version,
        source_sha256: log.source_sha256.clone(),
        on_construction_log: model.source_log.as_deref() == Some(form.log_id.as_str()),
        training_relation: Some(relation.into()),
        model_sha256,
        variants_sha256,
        method_sha256: crate::dfg_discovery::quality_method(form.profile.as_deref()).into(),
        report_sha256: None,
    };
    let saved = Arc::new(QualityArtifact {
        id: artifact_id.clone(),
        input,
        report: None,
    });
    next.sequence = artifact_sequence;
    next.quality_jobs.insert(id.clone(), meta.clone());
    next.quality_artifacts.insert(artifact_id, saved.clone());
    next.quality_requests.insert(
        form.request_key.clone(),
        RequestReceipt {
            owner: meta.owner.clone(),
            job_id: id.clone(),
            form_sha256: fingerprint,
            expires_at: issued + store::KEY_SECONDS + 30,
            retry_of: retry_of.map(str::to_owned),
        },
    );
    if let Err(e) = state.commit_action_resources(&mut next, "quality_accepted", vec![id.clone()]) {
        lease.job.fail(&e.code, &e.message);
        state.quality_jobs.remove_terminal(&id);
        return Err(e);
    }
    *repo = next;
    Ok(Accepted {
        meta,
        launch: Some((lease, saved)),
    })
}
fn fail_job(
    state: &AppState,
    job: &crate::jobs::Job,
    error: ImportError,
) -> Result<(), ImportError> {
    job.try_fail_with(&error.code, &error.message, |s| {
        persist_system_failure(state, s)
    })?;
    Ok(())
}
fn compute_job(
    state: &AppState,
    lease: JobLease,
    input: Arc<QualityArtifact>,
    mut observer: impl FnMut(&str),
) -> Result<(), ImportError> {
    let job = lease.job.clone();
    let _lease = lease;
    if let Err(e) = write_access(state) {
        return fail_job(state, &job, e);
    }
    match job.try_start_with("validate", |s| persist(state, s, None)) {
        Ok(true) => {}
        Ok(false) => return Ok(()),
        Err(e) => return fail_job(state, &job, e),
    }
    let control = job.control();
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut checkpoint_error = None;
    let result = crate::dfg_discovery::evaluate_for(
        &input.input.model,
        &input.input.variants,
        input.input.profile.as_deref(),
        &mut |stage| {
            observer(stage);
            if control.is_cancelled() {
                return Err(Issue::refused("cancelled"));
            }
            if Instant::now() >= deadline {
                return Err(Issue::cap("deadline"));
            }
            let checked = write_access(state)
                .and_then(|()| job.try_set_stage_with(stage, |s| persist(state, s, None)));
            if let Err(e) = checked {
                let issue = Issue::refused(&e.code);
                checkpoint_error = Some(e);
                return Err(issue);
            }
            Ok(())
        },
    );
    if control.is_cancelled() {
        return Ok(());
    }
    if let Some(e) = checkpoint_error {
        return fail_job(state, &job, e);
    }
    let core = crate::dfg_discovery::result_core(result, input.input.profile.as_deref());
    observer("publish");
    job.try_complete_durable_with(
        |before| {
            let mut done = before.clone();
            done.state = JobState::Completed;
            done.stage = "completed".into();
            done.result_id = Some(input.id.clone());
            done.job_revision += 1;
            persist(state, &done, Some(core))?;
            Ok(input.id.clone())
        },
        |failed| persist_system_failure(state, failed),
    )?;
    Ok(())
}
fn launch(mut state: AppState, lease: JobLease, input: Arc<QualityArtifact>) {
    state.payload_permit = None;
    tokio::spawn(async move {
        let job = lease.job.clone();
        let permit = match state.cpu.clone().acquire_owned().await {
            Ok(p) => p,
            Err(_) => {
                let _ = fail_job(
                    &state,
                    &job,
                    error("quality_worker", "Вычислитель недоступен."),
                );
                return;
            }
        };
        let diagnostic = state.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            compute_job(&state, lease, input, |_| {})
        })
        .await;
        if !matches!(result, Ok(Ok(()))) {
            tracing::error!(job_id=%job.snapshot().id,"quality_worker_failed");
            let _ = fail_job(
                &diagnostic,
                &job,
                error("quality_worker", "Расчёт прервался. Входы сохранены."),
            );
        }
    });
}
fn accept_and_launch(
    state: AppState,
    model_id: String,
    form: SubmitForm,
    retry_of: Option<String>,
    runtime: tokio::runtime::Handle,
) -> Result<QualityMeta, ImportError> {
    // This blocking closure owns acceptance even when the HTTP waiter disappears.
    let accepted = accept(&state, &model_id, &form, retry_of.as_deref())?;
    if let Some((lease, input)) = accepted.launch {
        let _entered = runtime.enter();
        launch(state, lease, input);
    }
    Ok(accepted.meta)
}
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/quality", get(index))
        .route("/models/{id}/quality/new", get(new_form))
        .route(
            "/models/{id}/quality/jobs",
            post(submit).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/quality/jobs/{id}", get(snapshot))
        .route("/quality/jobs/{id}/view", get(view))
        .route("/quality/jobs/{id}/events", get(events))
        .route("/quality/jobs/{id}/report", get(download))
        .route("/quality/jobs/{id}/cancel", post(cancel))
        .route(
            "/quality/jobs/{id}/retry",
            post(retry).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/quality/jobs/{id}/delete", post(delete))
        .layer(axum::middleware::map_response(no_store))
}
async fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().expect("constant"));
    response
}
async fn submit(
    Workspace(state): Workspace,
    Path(model_id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<SubmitForm>,
) -> Response {
    let runtime = tokio::runtime::Handle::current();
    match blocking(move || accept_and_launch(state, model_id, form, None, runtime)).await {
        Ok(meta) => accepted_response(meta, &headers),
        Err(e) => form_error(e, &headers),
    }
}
fn accepted_response(meta: QualityMeta, headers: &HeaderMap) -> Response {
    if headers
        .get(header::ACCEPT)
        .is_some_and(|h| h == "application/json")
    {
        (StatusCode::ACCEPTED, Json(meta)).into_response()
    } else {
        Redirect::to(&format!("/quality/jobs/{}/view", meta.snapshot.id)).into_response()
    }
}
async fn retry(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<RetryForm>,
) -> Response {
    let runtime = tokio::runtime::Handle::current();
    match blocking(move || {
        write_access(&state)?;
        if let Some(meta) = retry_replay(&state, &id, &form.request_key)? {
            return Ok(meta);
        }
        let original = state
            .repository
            .lock()
            .expect("repository mutex")
            .quality_jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        let submitted = SubmitForm {
            profile: original.profile.clone(),
            log_id: original.log_id,
            revision: original.model_revision,
            request_key: form.request_key,
        };
        accept_and_launch(state, original.model_id, submitted, Some(id), runtime)
    })
    .await
    {
        Ok(meta) => accepted_response(meta, &headers),
        Err(e) => form_error(e, &headers),
    }
}
fn retry_replay(state: &AppState, id: &str, key: &str) -> Result<Option<QualityMeta>, ImportError> {
    write_access(state)?;
    if store::key_time(key).is_none() {
        return Err(error(
            "quality_request_key",
            "Откройте новую форму повтора.",
        ));
    }
    let repo = state.repository.lock().expect("repository mutex");
    if let Some(meta) = repo.quality_jobs.values().find(|m| m.request_key == key) {
        if meta.owner != state.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ запроса принадлежит другому пользователю.",
            ));
        }
        if meta.retry_of.as_deref() != Some(id) {
            return Err(error(
                "quality_request_conflict",
                "Ключ относится к другой операции.",
            ));
        }
        return Ok(Some(meta.clone()));
    }
    if let Some(receipt) = repo.quality_requests.get(key) {
        if receipt.owner != state.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ запроса принадлежит другому пользователю.",
            ));
        }
        if receipt.retry_of.as_deref() != Some(id) {
            return Err(error(
                "quality_request_conflict",
                "Ключ относится к другой операции.",
            ));
        }
        return Err(error(
            "quality_deleted",
            "Принятая задача уже удалена. Откройте новую форму для нового запуска.",
        ));
    }
    Ok(None)
}
async fn cancel(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match blocking(move || {
        write_access(&state)?;
        let saved = state
            .repository
            .lock()
            .expect("repository mutex")
            .quality_jobs
            .contains_key(&id);
        if !saved {
            return Err(error("not_found", "Задача не найдена."));
        }
        let job = state
            .quality_jobs
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        job.try_cancel_with(|s| persist(&state, s, None))?;
        Ok(Redirect::to(&format!("/quality/jobs/{id}/view")))
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => form_error(e, &headers),
    }
}
async fn delete(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    match blocking(move || {
        write_access(&state)?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let meta = repo
            .quality_jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        if !meta.snapshot.is_terminal() {
            return Err(error("job_running", "Сначала отмените задачу."));
        }
        let mut next = repo.clone();
        next.quality_jobs.remove(&id);
        next.quality_artifacts.remove(&meta.artifact_id);
        next.deleted_quality_ids.insert(meta.artifact_id);
        state.commit_action_resources(&mut next, "quality_deleted", vec![id.clone()])?;
        *repo = next;
        drop(repo);
        state.quality_jobs.remove_terminal(&id);
        Ok(Redirect::to("/quality"))
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => form_error(e, &headers),
    }
}
fn access_view<T>(
    state: &AppState,
    produce: impl FnOnce() -> Result<T, ImportError>,
) -> Result<T, ImportError> {
    let platform = state.platform.as_ref().ok_or_else(store::corrupt)?;
    let actor = state.actor.as_ref().ok_or_else(store::corrupt)?;
    platform.auth.with_view_access(
        state.session.as_deref().ok_or_else(store::corrupt)?,
        actor,
        produce,
    )
}
async fn new_form(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Query(query): Query<std::collections::BTreeMap<String, String>>,
) -> Response {
    let control = query.get("control").is_some_and(|v| v == "1");
    match blocking(move || {
        state.validate_resource_actor()?;
        let mut repo=state.repository.lock().expect("repository mutex");
        let model=repo.get_model(&state,&id)?.ok_or_else(||error("not_found","Модель не найдена."))?;
        let actor=state.actor.as_ref().ok_or_else(store::corrupt)?;
        let logs=state.platform.as_ref().ok_or_else(store::corrupt)?.database.resource_summaries(&actor.project_id)?;
        let mut options=if control{String::from("<option value=\"\" disabled selected>Выберите контрольный журнал</option>")}else{String::new()};
        for log in logs.iter().filter(|item|item.kind=="log_state") {
            options.push_str(&format!("<option value=\"{}\"{}>{}</option>",html_escape(&log.id),if !control&&model.source_log.as_deref()==Some(log.id.as_str()) {" selected"}else{""},html_escape(&log.name)));
        }
        let mut body=format!("<h1>Сохраняемая оценка BPMN</h1><p><strong>{}</strong> · версия {}</p><p>Сохранятся снимки модели и текущей отфильтрованной версии журнала. Порог рисунка и выбор отдельной трассы не меняют вход.</p><form method=\"post\" action=\"/models/{}/quality/jobs\" class=\"platform-form\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><input type=\"hidden\" name=\"request_key\" value=\"{}\"><label>Журнал<select name=\"log_id\" required>{options}</select></label><label>Профиль оценки<select name=\"profile\"><option value=\"\">Прежний · до 64 случаев / 500 событий</option><option value=\"full_log_state_machine_v1\">Полный журнал · до 1000 случаев / 20 000 событий</option></select></label><p>Полный профиль поддерживает последовательные модели с одним токеном; параллельные модели могут быть отклонены. Все случаи учитываются без выборки.</p>",html_escape(&model.name),model.revision,model.id,model.revision,store::request_key());
        if actor.role.can_write() && logs.iter().any(|item|item.kind=="log_state") {body.push_str("<button class=\"button primary\" type=\"submit\">Запустить и сохранить оценку</button>");}
        else {body.push_str("<p>Для запуска нужны журнал и права редактора проекта.</p>");}
        body.push_str(&format!("</form><p>Прежний профиль: 64 трассы, 500 событий, 32 варианта. Полный: 1000 случаев, 20 000 событий, 256 вариантов и 32 действия. Оба профиля: до 1000 состояний поиска. Сохранится до восьми оценок проекта; одновременно принимаются две операции.</p><p><a href=\"/quality\">Все оценки проекта</a> · <a href=\"/models/{}/quality\">Временный предпросмотр</a></p>",model.id));
        access_view(&state,||Ok(crate::platform::page("Оценка BPMN",body)))
    }).await {Ok(r)=>r,Err(e)=>response_error(e)}
}
fn stage_name(stage: &str) -> &str {
    match stage {
        "queued" => "В очереди",
        "validate" => "Проверка входов",
        "bridge" => "Подготовка сети",
        "markings" => "Построение пространства состояний",
        "fitness" => "Соответствие журналу",
        "precision" | "precision_prefix" => "Точность поведения",
        "complete" => "Подготовка отчёта",
        "completed" => "Завершено",
        "cancelled" => "Отменено",
        "failed" => "Ошибка",
        "interrupted" => "Прервано перезапуском",
        _ => "Выполняется",
    }
}
fn job_panel(m: &QualityMeta, editable: bool, report: Option<&Value>) -> String {
    let id = &m.snapshot.id;
    let mut html = format!(
        "<section id=\"quality-job-{id}\" class=\"platform-card\" aria-live=\"polite\"><h2>{}</h2><p>Модель: {} · версия {}. Журнал: {} · версия анализа {}.</p><p>Принято: {}. <a href=\"/quality/jobs/{id}/view\">Открыть задачу</a></p>",
        stage_name(&m.snapshot.stage),
        html_escape(&m.model_name),
        m.model_revision,
        html_escape(&m.log_name),
        m.analysis_version,
        m.created_at.format("%Y-%m-%d %H:%M:%S UTC")
    );
    if let Some(e) = &m.snapshot.error {
        html.push_str(&format!(
            "<p role=\"alert\">{} ({})</p>",
            html_escape(&e.message),
            html_escape(&e.code)
        ));
    }
    if m.snapshot.state == JobState::Completed {
        html.push_str(&format!("<p><a class=\"button\" href=\"/quality/jobs/{id}/view\">Показать результат</a> · <a href=\"/quality/jobs/{id}/report\">Скачать отчёт JSON с входами</a></p>"));
    }
    if editable {
        if m.snapshot.is_terminal() {
            html.push_str(&format!("<form method=\"post\" action=\"/quality/jobs/{id}/retry\"><input type=\"hidden\" name=\"request_key\" value=\"{}\"><button>Повторить с теми же входами</button></form><form method=\"post\" action=\"/quality/jobs/{id}/delete\"><button>Удалить сохранённую оценку</button></form>",store::request_key()));
        } else {
            html.push_str(&format!("<form method=\"post\" action=\"/quality/jobs/{id}/cancel\"><button>Отменить оценку</button></form>"));
        }
    }
    if let Some(report) = report {
        html.push_str(&crate::bpmn_quality_preview::panel(report));
    }
    html.push_str("</section>");
    html
}
async fn index(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo=state.repository.lock().expect("repository mutex");
        let editable=state.actor.as_ref().is_some_and(|a|a.role.can_write());
        let mut body=String::from("<h1>Оценки BPMN</h1><p>Подтверждённые отчёты и снимки входов сохраняются после перезапуска. Новую оценку можно запустить из <a href=\"/models\">модели BPMN</a>.</p>");
        let mut ordered:Vec<_>=repo.quality_jobs.values().collect();
        ordered.sort_by_key(|m|std::cmp::Reverse(m.created_at));
        for meta in ordered {body.push_str(&job_panel(meta,editable,None));}
        if repo.quality_jobs.is_empty() {body.push_str("<p>Сохранённых оценок пока нет.</p>");}
        access_view(&state,||Ok(crate::platform::page("Оценки BPMN",body)))
    }).await {Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn snapshot(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo = state.repository.lock().expect("repository mutex");
        let meta = repo
            .quality_jobs
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        access_view(&state, || Ok(Json(meta).into_response()))
    })
    .await
    {
        Ok(r) => r,
        Err(e) => response_error(e),
    }
}
async fn view(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo=state.repository.lock().expect("repository mutex");
        let meta=repo.quality_jobs.get(&id).ok_or_else(||error("not_found","Задача не найдена."))?;
        let saved=if meta.snapshot.state==JobState::Completed {Some(artifact(&state,&repo,meta)?)}else{None};
        let report=saved.as_ref().and_then(|a|a.report.as_ref());
        let panel=job_panel(meta,state.actor.as_ref().is_some_and(|a|a.role.can_write()),report);
        let body=if meta.snapshot.is_terminal() {panel}else{format!("<div data-init=\"@get('/quality/jobs/{id}/events', {{retry:'never'}})\">{panel}</div>")};
        access_view(&state,||Ok(crate::platform::page("Задача оценки BPMN",format!("<h1>Оценка BPMN</h1><p><a href=\"/quality\">Все оценки</a></p>{body}"))))
    }).await {Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn download(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo=state.repository.lock().expect("repository mutex");
        let meta=repo.quality_jobs.get(&id).ok_or_else(||error("not_found","Задача не найдена."))?;
        let saved=artifact(&state,&repo,meta)?;
        let report=saved.report.as_ref().ok_or_else(||error("not_found","Подтверждённый отчёт отсутствует."))?;
        let export=json!({"schema_version":1,"method_sha256":meta.method_sha256,"evaluation":report,"input":saved.input});
        let bytes=store::bytes(&export,store::MAX_ARTIFACT+16*1024)?;
        access_view(&state,|| {
            let mut response=bytes.into_response();
            response.headers_mut().insert(header::CONTENT_TYPE,"application/json; charset=utf-8".parse().expect("constant"));
            response.headers_mut().insert(header::CONTENT_DISPOSITION,format!("attachment; filename=\"quality-report-{id}.json\"").parse().expect("validated ID"));
            response.headers_mut().insert(header::CACHE_CONTROL,"no-store".parse().expect("constant"));
            Ok(response)
        })
    }).await {Ok(r)=>r,Err(e)=>response_error(e)}
}
fn patch(id: &str, html: String) -> Event {
    let elements = html
        .lines()
        .map(|line| format!("elements {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    Event::default()
        .event("datastar-patch-elements")
        .data(format!(
            "selector #quality-job-{id}\nmode outer\n{elements}"
        ))
}
async fn events(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let Some(job) = state.quality_jobs.get(&id) else {
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
                    tokio::time::timeout(Duration::from_secs(5), receiver.changed()).await;
                if matches!(changed, Ok(Err(_))) {
                    return None;
                }
            }
            let saved = state.clone();
            let key = id.clone();
            let current = blocking(move || {
                saved.validate_resource_actor()?;
                let repo = saved.repository.lock().expect("repository mutex");
                let meta = repo
                    .quality_jobs
                    .get(&key)
                    .ok_or_else(|| error("not_found", "Задача удалена."))?;
                // Live status streams stay metadata-only. Completed reports are
                // opened through the separately admitted view/download routes.
                let html = job_panel(
                    meta,
                    saved.actor.as_ref().is_some_and(|a| a.role.can_write()),
                    None,
                );
                access_view(&saved, || {
                    Ok((meta.snapshot.is_terminal(), patch(&key, html)))
                })
            })
            .await;
            let (terminal, event) = match current {
                Ok(value) => value,
                Err(_) => (
                    true,
                    patch(
                        &id,
                        format!(
                            "<section id=\"quality-job-{id}\"><p role=\"alert\">Обновления остановлены. Проверьте доступ к проекту и откройте список задач заново.</p></section>"
                        ),
                    ),
                ),
            };
            Some((
                Ok::<_, Infallible>(event),
                (state, id, receiver, false, terminal),
            ))
        },
    );
    Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::default())
        .into_response()
}
