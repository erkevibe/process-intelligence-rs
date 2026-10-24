//! Durable bounded native discovery; publication/cancellation share the Job lock.
use crate::{
    discovery_store::{
        self as store, DiscoveryArtifact, DiscoveryInput, DiscoveryMeta, DiscoveryOutput,
    },
    domain::ImportError,
    jobs::{JobLease, JobSnapshot, JobState},
    platform_render::html_escape,
    quality_store as quality,
    web::{AppState, Repository, Workspace},
};
use axum::{
    Form, Json, Router,
    extract::{DefaultBodyLimit, Path},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Redirect, Response, Sse, sse::Event},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::json;
#[cfg(test)]
#[path = "discovery_workflow_tests.rs"]
mod tests;
use std::{
    convert::Infallible,
    sync::Arc,
    time::{Duration, Instant},
};
fn error(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
fn response_error(e: ImportError) -> Response {
    let status = match e.code.as_str() {
        "access_denied" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "discovery_conflict"
        | "discovery_request_conflict"
        | "discovery_deleted"
        | "discovery_method_changed" => StatusCode::CONFLICT,
        "job_queue_full" | "discovery_capacity" | "discovery_receipt_capacity" => {
            StatusCode::TOO_MANY_REQUESTS
        }
        "storage_unavailable" | "storage_busy" => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::UNPROCESSABLE_ENTITY,
    };
    (status, Json(json!({"code":e.code,"message":e.message}))).into_response()
}
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, ImportError> + Send + 'static,
) -> Result<T, ImportError> {
    tokio::task::spawn_blocking(f).await.map_err(|_| {
        error(
            "discovery_worker",
            "Построение прервалось. Проверьте список задач перед повтором.",
        )
    })?
}
fn write_access(s: &AppState) -> Result<(), ImportError> {
    s.validate_resource_actor()?;
    if s.actor.as_ref().is_none_or(|a| !a.role.can_write()) {
        return Err(error("access_denied", "Нужны права редактора проекта."));
    }
    Ok(())
}
fn access_view<T>(
    s: &AppState,
    f: impl FnOnce() -> Result<T, ImportError>,
) -> Result<T, ImportError> {
    let p = s.platform.as_ref().ok_or_else(store::corrupt)?;
    let a = s.actor.as_ref().ok_or_else(store::corrupt)?;
    p.auth
        .with_view_access(s.session.as_deref().ok_or_else(store::corrupt)?, a, f)
}
fn form_error(e: ImportError, headers: &HeaderMap) -> Response {
    if headers
        .get(header::ACCEPT)
        .is_some_and(|h| h == "application/json")
    {
        return response_error(e);
    }
    let status = response_error(e.clone()).status();
    let mut r = crate::platform::page(
        "Построение не принято",
        format!(
            "<h1>Операция не подтверждена</h1><p role=\"alert\">{}</p><p><a href=\"/discovery\">Проверить задачи построения</a> · <a href=\"/logs\">Журналы</a></p>",
            html_escape(&e.message)
        ),
    );
    *r.status_mut() = status;
    r
}
fn artifact(
    s: &AppState,
    repo: &Repository,
    m: &DiscoveryMeta,
) -> Result<Arc<DiscoveryArtifact>, ImportError> {
    s.validate_resource_actor()?;
    if let Some(a) = repo.discovery_artifacts.get(&m.artifact_id) {
        store::validate_artifact(m, a)?;
        return Ok(a.clone());
    }
    store::load_artifact(
        &s.platform.as_ref().ok_or_else(store::corrupt)?.database,
        &s.actor.as_ref().ok_or_else(store::corrupt)?.project_id,
        m,
    )
}
fn current_binding(
    s: &AppState,
    repo: &mut Repository,
    m: &DiscoveryMeta,
) -> Result<(), ImportError> {
    // A retry explicitly requests the retained historical input, even if its
    // original log was deleted. Its provenance remains historical and exact.
    if m.retry_of.is_some() {
        return Ok(());
    }
    let conflict = || {
        error(
            "discovery_conflict",
            "Журнал изменился. Откройте новую форму построения.",
        )
    };
    let log = repo.get_log_base(s, &m.log_id)?.ok_or_else(conflict)?;
    if log.analysis_version != m.analysis_version || log.source_sha256 != m.source_sha256 {
        return Err(conflict());
    }
    let input = DiscoveryInput {
        variants: crate::bpmn_quality_preview::rows(&log.data).map_err(|_| conflict())?,
    };
    if store::input_hash(&input)? != m.variants_sha256 {
        return Err(conflict());
    }
    Ok(())
}
fn persist(
    s: &AppState,
    snapshot: &JobSnapshot,
    output: Option<DiscoveryOutput>,
) -> Result<(), ImportError> {
    let mut repo = s.repository.lock().expect("repository mutex");
    let old = repo
        .discovery_jobs
        .get(&snapshot.id)
        .cloned()
        .ok_or_else(|| error("not_found", "Задача удалена."))?;
    if snapshot.job_revision <= old.snapshot.job_revision {
        return Err(error(
            "storage_conflict",
            "Состояние задачи уже изменилось.",
        ));
    }
    if output.is_some() {
        current_binding(s, &mut repo, &old)?
    }
    let mut next = repo.clone();
    let mut published = None;
    if let Some(result) = output {
        if next.model_count() >= 64 {
            return Err(error(
                "model_limit",
                "Сохранено 64 модели. Освободите место и повторите построение.",
            ));
        }
        let mut fallback = next.sequence.checked_add(1).ok_or_else(store::corrupt)?;
        let model_id = loop {
            let value = s.next_id(fallback)?;
            let id = format!("model-{value}");
            if !next.contains_model(&id) {
                next.sequence = next.sequence.max(value);
                break id;
            }
            fallback = fallback.checked_add(1).ok_or_else(store::corrupt)?;
        };
        let mut saved = (*artifact(s, &repo, &old)?).clone();
        let hash = crate::storage::sha256(&quality::bytes(&result, store::MAX_OUTPUT)?);
        next.models.insert(
            model_id.clone(),
            Arc::new(crate::platform::StoredModel {
                id: model_id.clone(),
                name: old.model_name.clone(),
                revision: 1,
                model: result.model.clone(),
                source_log: Some(old.log_id.clone()),
                training: Some(store::identity(&old)),
            }),
        );
        saved.output = Some(result);
        next.discovery_artifacts
            .insert(saved.id.clone(), Arc::new(saved));
        published = Some((model_id, hash));
    }
    let meta = next.discovery_jobs.get_mut(&snapshot.id).expect("checked");
    meta.snapshot = snapshot.clone();
    if let Some((id, hash)) = published {
        meta.model_id = Some(id);
        meta.output_sha256 = Some(hash)
    }
    s.commit_action_resources(
        &mut next,
        "discovery_job_updated",
        vec![snapshot.id.clone()],
    )?;
    *repo = next;
    Ok(())
}
fn persist_system_failure(s: &AppState, snapshot: &JobSnapshot) -> Result<(), ImportError> {
    if snapshot.state != JobState::Failed || snapshot.result_id.is_some() {
        return Err(store::corrupt());
    }
    let mut repo = s.repository.lock().expect("repository mutex");
    let old = repo
        .discovery_jobs
        .get(&snapshot.id)
        .ok_or_else(|| error("not_found", "Задача удалена."))?;
    if old.snapshot.is_terminal()
        || old.output_sha256.is_some()
        || snapshot.job_revision <= old.snapshot.job_revision
    {
        return Err(error(
            "storage_conflict",
            "Состояние задачи уже изменилось.",
        ));
    }
    let mut next = repo.clone();
    next.discovery_jobs
        .get_mut(&snapshot.id)
        .expect("checked")
        .snapshot = snapshot.clone();
    let p = s.platform.as_ref().ok_or_else(store::corrupt)?;
    let project = &s.actor.as_ref().ok_or_else(store::corrupt)?.project_id;
    next.audit.append_business(
        "system",
        project,
        "discovery_job_updated",
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
    next.storage_revision = p.database.write_project(write)?;
    crate::repository_v2::mark_persisted(&mut next);
    *repo = next;
    Ok(())
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct SubmitForm {
    analysis_version: u64,
    model_name: String,
    request_key: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RetryForm {
    request_key: String,
}
struct Accepted {
    meta: DiscoveryMeta,
    launch: Option<(JobLease, Arc<DiscoveryArtifact>)>,
}
fn accept(
    s: &AppState,
    log_id: &str,
    form: Option<&SubmitForm>,
    retry_of: Option<&str>,
    key: &str,
) -> Result<Accepted, ImportError> {
    write_access(s)?;
    let issued = quality::key_time(key)
        .ok_or_else(|| error("discovery_request_key", "Откройте новую форму построения."))?;
    let fingerprint = crate::storage::sha256(
        &serde_json::to_vec(&if let Some(id) = retry_of {
            json!({"retry_of":id})
        } else {
            let f = form.ok_or_else(store::corrupt)?;
            json!({"log_id":log_id,"analysis_version":f.analysis_version,"model_name":f.model_name})
        })
        .expect("form JSON"),
    );
    let mut repo = s.repository.lock().expect("repository mutex");
    if let Some(m) = repo.discovery_jobs.values().find(|m| m.request_key == key) {
        if m.owner != s.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ принадлежит другому пользователю.",
            ));
        }
        if m.form_sha256 != fingerprint {
            return Err(error(
                "discovery_request_conflict",
                "Запрос отличается от принятого.",
            ));
        }
        return Ok(Accepted {
            meta: m.clone(),
            launch: None,
        });
    }
    if let Some(r) = repo.discovery_requests.get(key) {
        if r.owner != s.actor_id() {
            return Err(error(
                "access_denied",
                "Ключ принадлежит другому пользователю.",
            ));
        }
        if r.form_sha256 != fingerprint {
            return Err(error(
                "discovery_request_conflict",
                "Запрос отличается от принятого.",
            ));
        }
        return Err(error(
            "discovery_deleted",
            "Эта задача удалена. Откройте новую форму.",
        ));
    }
    let now = chrono::Utc::now().timestamp();
    if issued > now + 30 || issued < now - quality::KEY_SECONDS {
        return Err(error(
            "discovery_request_expired",
            "Форма устарела. Откройте её заново.",
        ));
    }
    if repo.discovery_jobs.len() >= store::MAX_RETAINED {
        return Err(error(
            "discovery_capacity",
            "Сохранено восемь построений. Удалите ненужное завершённое задание.",
        ));
    }
    let reservation = s.discovery_jobs.reserve().map_err(|_| {
        error(
            "job_queue_full",
            "Уже приняты две операции. Повторите позже.",
        )
    })?;
    let (
        input,
        source_log,
        log_name,
        analysis_version,
        source_sha256,
        source_project_id,
        model_name,
    ) = if let Some(original) = retry_of {
        let m = repo
            .discovery_jobs
            .get(original)
            .ok_or_else(|| error("not_found", "Исходная задача удалена."))?;
        if !m.snapshot.is_terminal() {
            return Err(error(
                "job_running",
                "Сначала дождитесь завершения или отмените задачу.",
            ));
        }
        if m.method_sha256 != store::method_sha256() {
            return Err(error(
                "discovery_method_changed",
                "Метод изменился. Запустите новое построение из журнала.",
            ));
        }
        let a = artifact(s, &repo, m)?;
        (
            a.input.clone(),
            m.log_id.clone(),
            m.log_name.clone(),
            m.analysis_version,
            m.source_sha256.clone(),
            m.source_project_id.clone(),
            m.model_name.clone(),
        )
    } else {
        let f = form.ok_or_else(store::corrupt)?;
        if f.model_name.trim().is_empty()
            || f.model_name.len() > 1024
            || f.model_name.chars().any(char::is_control)
        {
            return Err(error(
                "discovery_name",
                "Введите название до 1024 байт без управляющих символов.",
            ));
        }
        let log = repo
            .get_log_base(s, log_id)?
            .ok_or_else(|| error("not_found", "Журнал не найден."))?;
        if f.analysis_version != log.analysis_version {
            return Err(error(
                "discovery_conflict",
                "Журнал изменился. Откройте форму заново.",
            ));
        }
        if log.filename.len() > 1024 || log.filename.chars().any(char::is_control) {
            return Err(error(
                "discovery_name",
                "Название журнала не поддерживается.",
            ));
        }
        (
            DiscoveryInput {
                variants: crate::bpmn_quality_preview::rows(&log.data)?,
            },
            log_id.into(),
            log.filename.clone(),
            log.analysis_version,
            log.source_sha256.clone(),
            s.actor
                .as_ref()
                .ok_or_else(store::corrupt)?
                .project_id
                .clone(),
            f.model_name.clone(),
        )
    };
    let variants_sha256 = store::input_hash(&input)?;
    quality::bytes(&input, store::MAX_ARTIFACT - 1024)?;
    let mut next = repo.clone();
    next.discovery_requests.retain(|_, r| r.expires_at >= now);
    if next.discovery_requests.len() >= quality::MAX_RECEIPTS {
        return Err(error(
            "discovery_receipt_capacity",
            "Слишком много запросов за час. Дождитесь истечения старых квитанций.",
        ));
    }
    let (id, artifact_id, sequence) = s.allocate_job_pair(&repo, "discovery")?;
    let lease = s
        .discovery_jobs
        .create_reserved(reservation, Some(id.clone()))
        .map_err(|_| error("job_admission_failed", "Не удалось принять задачу."))?;
    let m = DiscoveryMeta {
        snapshot: lease.job.snapshot(),
        artifact_id: artifact_id.clone(),
        owner: s.actor_id().into(),
        source_project_id,
        request_key: key.into(),
        form_sha256: fingerprint.clone(),
        created_at: chrono::Utc::now(),
        retry_of: retry_of.map(str::to_owned),
        log_id: source_log,
        log_name,
        analysis_version,
        source_sha256,
        variants_sha256,
        method_sha256: store::method_sha256().into(),
        model_name,
        model_id: None,
        output_sha256: None,
    };
    let saved = Arc::new(DiscoveryArtifact {
        id: artifact_id.clone(),
        input,
        output: None,
    });
    next.sequence = sequence;
    next.discovery_jobs.insert(id.clone(), m.clone());
    next.discovery_artifacts.insert(artifact_id, saved.clone());
    next.discovery_requests.insert(
        key.into(),
        quality::RequestReceipt {
            owner: m.owner.clone(),
            job_id: id.clone(),
            form_sha256: fingerprint,
            expires_at: issued + quality::KEY_SECONDS + 30,
            retry_of: retry_of.map(str::to_owned),
        },
    );
    if let Err(e) = s.commit_action_resources(&mut next, "discovery_accepted", vec![id.clone()]) {
        lease.job.fail(&e.code, &e.message);
        s.discovery_jobs.remove_terminal(&id);
        return Err(e);
    }
    *repo = next;
    Ok(Accepted {
        meta: m,
        launch: Some((lease, saved)),
    })
}
fn fail_job(s: &AppState, job: &crate::jobs::Job, e: ImportError) -> Result<(), ImportError> {
    job.try_fail_with(&e.code, &e.message, |snapshot| {
        persist_system_failure(s, snapshot)
    })?;
    Ok(())
}
fn compute_job(
    s: &AppState,
    lease: JobLease,
    input: Arc<DiscoveryArtifact>,
    mut observer: impl FnMut(&str),
) -> Result<(), ImportError> {
    let job = lease.job.clone();
    let _lease = lease;
    if let Err(e) = write_access(s) {
        return fail_job(s, &job, e);
    }
    match job.try_start_with("discover", |snapshot| persist(s, snapshot, None)) {
        Ok(true) => {}
        Ok(false) => return Ok(()),
        Err(e) => return fail_job(s, &job, e),
    }
    let control = job.control();
    let until = Instant::now() + Duration::from_secs(30);
    let mut last = String::from("discover");
    let result = store::compute(&input.input, until, &mut |stage| {
        observer(stage);
        if control.is_cancelled() {
            return Err(error("cancelled", "Построение отменено."));
        }
        if Instant::now() >= until {
            return Err(error(
                "discovery_limit",
                "Построение достигло границы времени.",
            ));
        }
        write_access(s)?;
        if last != stage {
            job.try_set_stage_with(stage, |snapshot| persist(s, snapshot, None))?;
            last = stage.into()
        }
        Ok(())
    });
    if control.is_cancelled() {
        return Ok(());
    }
    let output = match result {
        Ok(value) => value,
        Err(e) => return fail_job(s, &job, e),
    };
    observer("publish");
    job.try_complete_durable_with(
        |before| {
            let mut done = before.clone();
            done.state = JobState::Completed;
            done.stage = "completed".into();
            done.result_id = Some(input.id.clone());
            done.job_revision += 1;
            persist(s, &done, Some(output))?;
            Ok(input.id.clone())
        },
        |failed| persist_system_failure(s, failed),
    )?;
    Ok(())
}
fn launch(mut s: AppState, lease: JobLease, input: Arc<DiscoveryArtifact>) {
    s.payload_permit = None;
    tokio::spawn(async move {
        let job = lease.job.clone();
        let mut changes = job.subscribe();
        let wait_cancel = async {
            loop {
                if changes.borrow().cancel_requested || changes.borrow().is_terminal() {
                    return;
                }
                if changes.changed().await.is_err() {
                    return;
                }
            }
        };
        let permit = tokio::select! {permit=s.cpu.clone().acquire_owned()=>match permit{Ok(p)=>p,Err(_)=>{let _=fail_job(&s,&job,error("discovery_worker","Вычислитель недоступен."));return}},_=wait_cancel=>return};
        let diagnostic = s.clone();
        let result = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            compute_job(&s, lease, input, |_| {})
        })
        .await;
        if !matches!(result, Ok(Ok(()))) {
            tracing::error!(job_id=%job.snapshot().id,"discovery_worker_failed");
            let _ = fail_job(
                &diagnostic,
                &job,
                error(
                    "discovery_worker",
                    "Построение прервалось. Входы сохранены.",
                ),
            );
        }
    });
}
fn accept_and_launch(
    s: AppState,
    log_id: String,
    form: Option<SubmitForm>,
    retry: Option<String>,
    key: String,
    runtime: tokio::runtime::Handle,
) -> Result<DiscoveryMeta, ImportError> {
    let accepted = accept(&s, &log_id, form.as_ref(), retry.as_deref(), &key)?;
    if let Some((lease, input)) = accepted.launch {
        let _entered = runtime.enter();
        launch(s, lease, input)
    }
    Ok(accepted.meta)
}
fn accepted(m: DiscoveryMeta, headers: &HeaderMap) -> Response {
    if headers
        .get(header::ACCEPT)
        .is_some_and(|h| h == "application/json")
    {
        (StatusCode::ACCEPTED, Json(m)).into_response()
    } else {
        Redirect::to(&format!("/discovery/jobs/{}/view", m.snapshot.id)).into_response()
    }
}
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/discovery", get(index))
        .route("/logs/{id}/discovery/new", get(new_form))
        .route(
            "/logs/{id}/discovery/jobs",
            post(submit).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/discovery/jobs/{id}", get(snapshot))
        .route("/discovery/jobs/{id}/view", get(view))
        .route("/discovery/jobs/{id}/events", get(events))
        .route("/discovery/jobs/{id}/report", get(download))
        .route("/discovery/jobs/{id}/bpmn", get(download_bpmn))
        .route("/discovery/jobs/{id}/cancel", post(cancel))
        .route(
            "/discovery/jobs/{id}/retry",
            post(retry).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/discovery/jobs/{id}/delete", post(delete))
        .layer(axum::middleware::map_response(no_store))
}
async fn no_store(mut r: Response) -> Response {
    r.headers_mut()
        .insert(header::CACHE_CONTROL, "no-store".parse().expect("constant"));
    r
}
async fn submit(
    Workspace(s): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(f): Form<SubmitForm>,
) -> Response {
    let runtime = tokio::runtime::Handle::current();
    let key = f.request_key.clone();
    match blocking(move || accept_and_launch(s, id, Some(f), None, key, runtime)).await {
        Ok(m) => accepted(m, &headers),
        Err(e) => form_error(e, &headers),
    }
}
async fn retry(
    Workspace(s): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(f): Form<RetryForm>,
) -> Response {
    let runtime = tokio::runtime::Handle::current();
    match blocking(move || {
        accept_and_launch(s, String::new(), None, Some(id), f.request_key, runtime)
    })
    .await
    {
        Ok(m) => accepted(m, &headers),
        Err(e) => form_error(e, &headers),
    }
}
async fn cancel(Workspace(s): Workspace, Path(id): Path<String>, headers: HeaderMap) -> Response {
    match blocking(move || {
        write_access(&s)?;
        if !s
            .repository
            .lock()
            .expect("repository mutex")
            .discovery_jobs
            .contains_key(&id)
        {
            return Err(error("not_found", "Задача не найдена."));
        }
        let job = s
            .discovery_jobs
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        job.try_cancel_with(|snapshot| persist(&s, snapshot, None))?;
        Ok(Redirect::to(&format!("/discovery/jobs/{id}/view")))
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => form_error(e, &headers),
    }
}
async fn delete(Workspace(s): Workspace, Path(id): Path<String>, headers: HeaderMap) -> Response {
    match blocking(move || {
        write_access(&s)?;
        let mut repo = s.repository.lock().expect("repository mutex");
        let m = repo
            .discovery_jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        if !m.snapshot.is_terminal() {
            return Err(error("job_running", "Сначала отмените задачу."));
        }
        let mut next = repo.clone();
        next.discovery_jobs.remove(&id);
        next.discovery_artifacts.remove(&m.artifact_id);
        next.deleted_discovery_ids.insert(m.artifact_id);
        s.commit_action_resources(&mut next, "discovery_deleted", vec![id.clone()])?;
        *repo = next;
        drop(repo);
        s.discovery_jobs.remove_terminal(&id);
        Ok(Redirect::to("/discovery"))
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => form_error(e, &headers),
    }
}
fn stage(stage: &str) -> &str {
    match stage {
        "queued" => "В очереди",
        "discover" => "Строим модель",
        "validate" | "bridge" | "markings" => "Проверяем модель",
        "training_evaluation" | "fitness" | "precision" | "precision_prefix" | "complete" => {
            "Оцениваем на обучении"
        }
        "completed" => "Модель сохранена",
        "cancelled" => "Построение отменено",
        "interrupted" => "Прервано перезапуском",
        "failed" => "Модель не построена",
        _ => "Выполняется",
    }
}
fn panel(m: &DiscoveryMeta, editable: bool, result: Option<&DiscoveryOutput>) -> String {
    let id = &m.snapshot.id;
    let mut html = format!(
        "<section id=\"discovery-job-{id}\" class=\"platform-card\" aria-live=\"polite\"><h2>{}</h2><p>{} · журнал {} · версия анализа {}.</p><p>Алгоритм: структурные варианты v1, без фильтра шума. <a href=\"/discovery/jobs/{id}/view\">Открыть задачу</a></p>",
        stage(&m.snapshot.stage),
        html_escape(&m.model_name),
        html_escape(&m.log_name),
        m.analysis_version
    );
    if m.retry_of.is_some() {
        html.push_str("<p>Повтор использует сохранённый обучающий снимок, даже если исходный журнал изменён или удалён.</p>")
    }
    if let Some(e) = &m.snapshot.error {
        html.push_str(&format!(
            "<p role=\"alert\">{} ({})</p>",
            html_escape(&e.message),
            html_escape(&e.code)
        ))
    }
    if let Some(model) = &m.model_id {
        html.push_str(&format!("<p><a class=\"button\" href=\"/models/{model}\">Открыть модель</a> · <a href=\"/models/{model}/quality/new?control=1\">Оценить на контрольном журнале</a> · <a href=\"/discovery/jobs/{id}/bpmn\">Скачать BPMN</a> · <a href=\"/discovery/jobs/{id}/report\">Скачать результат с входами</a></p>"))
    }
    if editable {
        if m.snapshot.is_terminal() {
            html.push_str(&format!("<form method=\"post\" action=\"/discovery/jobs/{id}/retry\"><input type=\"hidden\" name=\"request_key\" value=\"{}\"><button>Повторить по сохранённым данным</button></form><form method=\"post\" action=\"/discovery/jobs/{id}/delete\"><button>Удалить задание построения</button></form>",quality::request_key()))
        } else {
            html.push_str(&format!("<form method=\"post\" action=\"/discovery/jobs/{id}/cancel\"><button>Отменить построение</button></form>"))
        }
    }
    if let Some(output) = result {
        html.push_str("<h3>Оценка на обучающих данных</h3><p>Эти числа не подтверждают обобщение. Для проверки выберите отдельный контрольный журнал.</p>");
        html.push_str(&crate::bpmn_quality_preview::panel(&json!({"model_name":m.model_name,"model_revision":1,"log_name":m.log_name,"analysis_version":m.analysis_version,"source_sha256":m.source_sha256,"saved_history":true,"on_construction_log":true,"training_relation":"training_snapshot","report":output.training_report})));
    }
    html.push_str("</section>");
    html
}
async fn new_form(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move||{s.validate_resource_actor()?;let mut repo=s.repository.lock().expect("repository mutex");let log=repo.get_log_base(&s,&id)?.ok_or_else(||error("not_found","Журнал не найден."))?;let editable=s.actor.as_ref().is_some_and(|a|a.role.can_write());let button=if editable{"<button class=\"button primary\">Построить и сохранить модель</button>"}else{"<p>Для запуска нужны права редактора.</p>"};let body=format!("<h1>Построить BPMN-модель</h1><p>Журнал: {} · версия {}. Сохранятся текущие варианты журнала после фильтров.</p><p>Структурные варианты v1: последовательности, выбор, параллельные ветви и простые повторения. Это ограниченная эвристика, без фильтра шума. Качество на других данных проверяется отдельно.</p><form class=\"platform-form\" method=\"post\" action=\"/logs/{id}/discovery/jobs\"><input type=\"hidden\" name=\"analysis_version\" value=\"{}\"><input type=\"hidden\" name=\"request_key\" value=\"{}\"><label>Название модели<input name=\"model_name\" required value=\"{}\" maxlength=\"1024\"></label>{button}</form><p>Пределы: 6 разных действий, 64 трассы, 500 событий, 32 варианта. Общая очередь: две операции, один вычислитель. Сохраняются восемь заданий построения.</p><p><a href=\"/discovery\">Все построения</a></p>",html_escape(&log.filename),log.analysis_version,log.analysis_version,quality::request_key(),html_escape(&format!("Модель: {}",log.filename)));access_view(&s,||Ok(crate::platform::page("Построение BPMN",body)))}).await{Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn index(Workspace(s): Workspace) -> Response {
    match blocking(move||{s.validate_resource_actor()?;let repo=s.repository.lock().expect("repository mutex");let editable=s.actor.as_ref().is_some_and(|a|a.role.can_write());let mut body=String::from("<h1>Построение моделей</h1><p>Сохранённые задачи и обучающие снимки. Новое построение можно запустить из <a href=\"/logs\">журнала</a>.</p>");let mut metas:Vec<_>=repo.discovery_jobs.values().collect();metas.sort_by_key(|a| std::cmp::Reverse(a.created_at));for m in metas{body.push_str(&panel(m,editable,None))}access_view(&s,||Ok(crate::platform::page("Построение моделей",body)))}).await{Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn snapshot(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        s.validate_resource_actor()?;
        let repo = s.repository.lock().expect("repository mutex");
        let m = repo
            .discovery_jobs
            .get(&id)
            .cloned()
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        access_view(&s, || Ok(Json(m)))
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => response_error(e),
    }
}
async fn view(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move||{s.validate_resource_actor()?;let repo=s.repository.lock().expect("repository mutex");let m=repo.discovery_jobs.get(&id).ok_or_else(||error("not_found","Задача не найдена."))?;let editable=s.actor.as_ref().is_some_and(|a|a.role.can_write());let saved=if m.snapshot.state==JobState::Completed{Some(artifact(&s,&repo,m)?)}else{None};let inner=panel(m,editable,saved.as_ref().and_then(|a|a.output.as_ref()));let init=if !m.snapshot.is_terminal(){format!(" data-init=\"@get('/discovery/jobs/{id}/events')\"")}else{String::new()};access_view(&s,||Ok(crate::platform::page("Построение BPMN",format!("<h1>Задача построения</h1><div{init}>{inner}</div><p><a href=\"/discovery\">Все построения</a></p>"))))}).await{Ok(r)=>r,Err(e)=>response_error(e)}
}
async fn download(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move||{s.validate_resource_actor()?;let repo=s.repository.lock().expect("repository mutex");let m=repo.discovery_jobs.get(&id).ok_or_else(||error("not_found","Задача не найдена."))?;let a=artifact(&s,&repo,m)?;let bytes=quality::bytes(&json!({"schema_version":1,"algorithm":store::ALGORITHM,"parameters":store::parameters(),"metadata":m,"artifact":a,"author_signature_verified":false}),store::MAX_ARTIFACT+16*1024)?;access_view(&s,||Ok(([(header::CONTENT_TYPE,"application/json; charset=utf-8"),(header::CONTENT_DISPOSITION,"attachment; filename=discovery-report.json")],bytes)))}).await{Ok(r)=>r.into_response(),Err(e)=>response_error(e)}
}
async fn download_bpmn(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        s.validate_resource_actor()?;
        let repo = s.repository.lock().expect("repository mutex");
        let m = repo
            .discovery_jobs
            .get(&id)
            .ok_or_else(|| error("not_found", "Задача не найдена."))?;
        let a = artifact(&s, &repo, m)?;
        let output = a
            .output
            .as_ref()
            .ok_or_else(|| error("job_not_complete", "Модель ещё не построена."))?;
        let xml = crate::bpmn::serialize(&output.model)?;
        access_view(&s, || {
            Ok((
                [
                    (header::CONTENT_TYPE, "application/xml; charset=utf-8"),
                    (
                        header::CONTENT_DISPOSITION,
                        "attachment; filename=discovered-model.bpmn",
                    ),
                ],
                xml,
            ))
        })
    })
    .await
    {
        Ok(r) => r.into_response(),
        Err(e) => response_error(e),
    }
}
fn patch(id: &str, html: String) -> Event {
    Event::default()
        .event("datastar-patch-elements")
        .data(format!(
            "selector #discovery-job-{id}\nmode outer\nelements {}",
            html.replace('\n', " ")
        ))
}
async fn events(Workspace(s): Workspace, Path(id): Path<String>) -> Response {
    if let Err(e) = s.validate_resource_actor() {
        return response_error(e);
    }
    let exists = s
        .repository
        .lock()
        .expect("repository mutex")
        .discovery_jobs
        .contains_key(&id);
    if !exists {
        return response_error(error("not_found", "Задача не найдена."));
    }
    let job = match s.discovery_jobs.get(&id) {
        Some(j) => j,
        None => return response_error(error("not_found", "Задача не найдена.")),
    };
    let receiver = job.subscribe();
    let stream = futures_util::stream::unfold(
        (s, id, receiver, true, false),
        |(s, id, mut rx, first, ended)| async move {
            if ended {
                return None;
            }
            if !first {
                let changed = tokio::time::timeout(Duration::from_secs(5), rx.changed()).await;
                if matches!(changed, Ok(Err(_))) {
                    return None;
                }
            }
            let saved = s.clone();
            let key = id.clone();
            let update = blocking(move || {
                saved.validate_resource_actor()?;
                let repo = saved.repository.lock().expect("repository mutex");
                let meta = repo
                    .discovery_jobs
                    .get(&key)
                    .ok_or_else(|| error("not_found", "Задача удалена."))?;
                let html = panel(
                    meta,
                    saved.actor.as_ref().is_some_and(|a| a.role.can_write()),
                    None,
                );
                access_view(&saved, || {
                    Ok((meta.snapshot.is_terminal(), patch(&key, html)))
                })
            })
            .await;
            let (ended, event) = match update {
                Ok(value) => value,
                Err(_) => (
                    true,
                    patch(
                        &id,
                        format!(
                            "<section id=\"discovery-job-{id}\"><p role=\"alert\">Обновления остановлены. Проверьте доступ и откройте список задач.</p></section>"
                        ),
                    ),
                ),
            };
            Some((Ok::<_, Infallible>(event), (s, id, rx, false, ended)))
        },
    );
    Sse::new(stream)
        .keep_alive(axum::response::sse::KeepAlive::default())
        .into_response()
}
