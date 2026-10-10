use crate::{
    domain::{Analysis, EventLog, GraphView},
    event_io::{Limits, parse_xes, parse_xes_cancellable},
    jobs::{JobSnapshot, JobState, JobStore},
    mining::{analyze, analyze_cancellable, graph_view},
};
use axum::{
    Form, Json, Router,
    extract::{DefaultBodyLimit, Multipart, Path, Query, Request, State},
    http::{HeaderValue, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response, Sse, sse::Event as SseEvent},
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    convert::Infallible,
    sync::{Arc, Mutex},
    time::Instant,
};
use tokio::sync::Semaphore;
use tower_http::services::ServeDir;

const MAX_LOGS: usize = 8;

#[derive(Clone)]
pub struct AppState {
    repository: Arc<Mutex<Repository>>,
    cpu: Arc<Semaphore>,
    uploads: Arc<Semaphore>,
    jobs: Arc<JobStore>,
    pub port: u16,
}

#[derive(Default)]
struct Repository {
    logs: BTreeMap<String, StoredLog>,
    current: Option<String>,
    sequence: u64,
}

#[derive(Clone)]
struct StoredLog {
    id: String,
    filename: String,
    analysis_version: u64,
    view_revision: u64,
    threshold: u64,
    selected: Option<String>,
    selected_case: Option<String>,
    data: Arc<EventLog>,
    analysis: Arc<Analysis>,
    elapsed_ms: u128,
}

impl AppState {
    pub fn new(port: u16) -> Self {
        Self {
            repository: Arc::new(Mutex::new(Repository::default())),
            cpu: Arc::new(Semaphore::new(1)),
            uploads: Arc::new(Semaphore::new(2)),
            jobs: Arc::new(JobStore::new()),
            port,
        }
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(index))
        .route(
            "/health",
            get(|| async { Json(json!({"status":"ready","version":env!("CARGO_PKG_VERSION")})) }),
        )
        .route("/logs", post(upload))
        .route("/jobs", post(upload_job))
        .route("/jobs/{id}", get(job_snapshot))
        .route("/jobs/{id}/events", get(job_events))
        .route("/jobs/{id}/cancel", post(cancel_job))
        .route("/demo", post(demo))
        .route("/logs/{id}", get(show))
        .route("/logs/{id}/view", post(update_view))
        .route("/logs/{id}/selection", post(select))
        .route("/logs/{id}/export", get(export))
        .route("/logs/{id}/graph", get(graph))
        .nest_service("/static", ServeDir::new("static"))
        .layer(DefaultBodyLimit::max(
            Limits::default().max_bytes + 64 * 1024,
        ))
        .layer(middleware::from_fn_with_state(state.clone(), request_guard))
        .with_state(state)
}

async fn request_guard(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let request_id = uuid::Uuid::new_v4().to_string();
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("");
    let host_valid =
        host == format!("127.0.0.1:{}", state.port) || host == format!("localhost:{}", state.port);
    if !host_valid {
        return error_json(
            StatusCode::BAD_REQUEST,
            "invalid_host",
            "Используйте локальный адрес приложения.",
        );
    }
    if request.method() != axum::http::Method::GET && request.method() != axum::http::Method::HEAD {
        let origin = request
            .headers()
            .get(header::ORIGIN)
            .and_then(|h| h.to_str().ok());
        let expected = format!("http://{host}");
        let cross_site = request
            .headers()
            .get("sec-fetch-site")
            .and_then(|h| h.to_str().ok())
            == Some("cross-site");
        if cross_site || origin.is_some_and(|origin| origin != expected) {
            return error_json(
                StatusCode::FORBIDDEN,
                "cross_origin",
                "Изменения разрешены только из локального приложения.",
            );
        }
    }
    let method = request.method().to_string();
    let path = request.uri().path().to_string();
    let start = Instant::now();
    let upload_too_large = matches!(path.as_str(), "/logs" | "/jobs")
        && request
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .is_some_and(|length| length > (Limits::default().max_bytes + 64 * 1024) as u64);
    let mut response = if upload_too_large {
        page(
            current(&state).as_ref(),
            Some(("byte_limit", "Файл превышает 20 MiB.")),
            StatusCode::PAYLOAD_TOO_LARGE,
        )
    } else {
        next.run(request).await
    };
    response.headers_mut().insert(
        "x-request-id",
        HeaderValue::from_str(&request_id).expect("UUID is a header"),
    );
    response.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    // Preserve the origin of same-origin form POSTs in Chromium. `no-referrer`
    // makes their Origin opaque (`null`), which our origin guard rejects.
    response.headers_mut().insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("same-origin"),
    );
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    tracing::info!(%request_id, %method, %path, status=response.status().as_u16(), elapsed_ms=start.elapsed().as_millis() as u64, "request_completed");
    response
}

fn current(state: &AppState) -> Option<StoredLog> {
    let repository = state.repository.lock().expect("repository mutex");
    repository
        .current
        .as_ref()
        .and_then(|id| repository.logs.get(id))
        .cloned()
}

async fn index(State(state): State<AppState>) -> Response {
    let job = state.jobs.current().map(|job| job.snapshot());
    page_with_job(current(&state).as_ref(), None, StatusCode::OK, job.as_ref())
}

async fn show(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let log = state
        .repository
        .lock()
        .expect("repository mutex")
        .logs
        .get(&id)
        .cloned();
    match log {
        Some(log) => page(Some(&log), None, StatusCode::OK),
        None => not_found(),
    }
}

fn multipart_error(state: &AppState, error: axum::extract::multipart::MultipartError) -> Response {
    let status = error.status();
    if status == StatusCode::PAYLOAD_TOO_LARGE {
        page(
            current(state).as_ref(),
            Some(("byte_limit", "Файл превышает 20 MiB.")),
            status,
        )
    } else {
        page(
            current(state).as_ref(),
            Some(("multipart", "Загрузка прервана или имеет неверный формат.")),
            status,
        )
    }
}

async fn upload(State(state): State<AppState>, multipart: Multipart) -> Response {
    upload_to(state, multipart, false).await
}
async fn upload_job(State(state): State<AppState>, multipart: Multipart) -> Response {
    upload_to(state, multipart, true).await
}
async fn upload_to(state: AppState, mut multipart: Multipart, background: bool) -> Response {
    let _upload_permit = match state.uploads.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            return page(
                current(&state).as_ref(),
                Some((
                    "upload_busy",
                    "Уже выполняются две загрузки. Повторите после их завершения.",
                )),
                StatusCode::TOO_MANY_REQUESTS,
            );
        }
    };
    let mut content = None;
    let mut filename = "Журнал XES".to_owned();
    loop {
        let field = match multipart.next_field().await {
            Ok(Some(field)) => field,
            Ok(None) => break,
            Err(error) => return multipart_error(&state, error),
        };
        if field.name() != Some("file") {
            continue;
        }
        if content.is_some() {
            return page(
                current(&state).as_ref(),
                Some(("duplicate_file", "Загрузите один XES-файл.")),
                StatusCode::BAD_REQUEST,
            );
        }
        if let Some(name) = field.file_name() {
            filename = name.chars().take(200).collect();
        }
        let mut field = field;
        let mut bytes = Vec::new();
        loop {
            match field.chunk().await {
                Ok(Some(chunk)) => {
                    if bytes.len().saturating_add(chunk.len()) > Limits::default().max_bytes {
                        return page(
                            current(&state).as_ref(),
                            Some(("byte_limit", "Файл превышает 20 MiB.")),
                            StatusCode::PAYLOAD_TOO_LARGE,
                        );
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(error) => return multipart_error(&state, error),
            }
        }
        content = Some(bytes);
    }
    let Some(content) = content else {
        return page(
            current(&state).as_ref(),
            Some(("missing_file", "Выберите XES-файл.")),
            StatusCode::BAD_REQUEST,
        );
    };
    if background {
        enqueue_job(state, content, filename)
    } else {
        import(state, content, filename).await
    }
}

async fn demo(State(state): State<AppState>) -> Response {
    import(
        state,
        include_bytes!("../fixtures/manual.xes").to_vec(),
        "Пример · 4 трассы, 10 событий".into(),
    )
    .await
}

async fn import(state: AppState, bytes: Vec<u8>, filename: String) -> Response {
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            return page(
                current(&state).as_ref(),
                Some((
                    "busy",
                    "Другой журнал уже анализируется. Повторите после завершения.",
                )),
                StatusCode::TOO_MANY_REQUESTS,
            );
        }
    };
    let start = Instant::now();
    let result = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        parse_xes(&bytes).map(|data| {
            let analysis = analyze(&data);
            (data, analysis)
        })
    })
    .await;
    match result {
        Ok(Ok((data, analysis))) => {
            let log = store_log(
                &state,
                data,
                analysis,
                filename,
                start.elapsed().as_millis(),
            );
            tracing::info!(log_id=%log.id, cases=log.analysis.cases, events=log.analysis.events, elapsed_ms=log.elapsed_ms as u64, "import_completed");
            page(Some(&log), None, StatusCode::OK)
        }
        Ok(Err(error)) => {
            tracing::warn!(code=%error.code, case_index=?error.case_index, event_index=?error.event_index, "import_rejected");
            let message = import_error_message(&error);
            page(
                current(&state).as_ref(),
                Some((&error.code, &message)),
                if error.code == "byte_limit" {
                    StatusCode::PAYLOAD_TOO_LARGE
                } else {
                    StatusCode::UNPROCESSABLE_ENTITY
                },
            )
        }
        Err(_) => {
            tracing::error!("import_worker_failed");
            page(
                current(&state).as_ref(),
                Some((
                    "worker_failed",
                    "Анализ прервался. Предыдущий результат сохранён.",
                )),
                StatusCode::INTERNAL_SERVER_ERROR,
            )
        }
    }
}

fn store_log(
    state: &AppState,
    data: EventLog,
    analysis: Analysis,
    filename: String,
    elapsed_ms: u128,
) -> StoredLog {
    let mut repository = state.repository.lock().expect("repository mutex");
    repository.sequence += 1;
    let id = format!("log-{}", repository.sequence);
    let log = StoredLog {
        id: id.clone(),
        filename,
        analysis_version: repository.sequence,
        view_revision: 0,
        threshold: 1,
        selected: None,
        selected_case: None,
        data: Arc::new(data),
        analysis: Arc::new(analysis),
        elapsed_ms,
    };
    if repository.logs.len() >= MAX_LOGS {
        let oldest = repository
            .logs
            .values()
            .min_by_key(|log| log.analysis_version)
            .map(|log| log.id.clone());
        if let Some(oldest) = oldest {
            repository.logs.remove(&oldest);
        }
    }
    repository.logs.insert(id.clone(), log.clone());
    repository.current = Some(id);
    log
}

fn enqueue_job(state: AppState, content: Vec<u8>, filename: String) -> Response {
    let lease = match state.jobs.create() {
        Ok(lease) => lease,
        Err(_) => {
            return page(
                current(&state).as_ref(),
                Some((
                    "job_queue_full",
                    "Уже приняты две задачи. Дождитесь завершения обработки.",
                )),
                StatusCode::TOO_MANY_REQUESTS,
            );
        }
    };
    let initial = lease.job.snapshot();
    let response = page_with_job(
        current(&state).as_ref(),
        None,
        StatusCode::ACCEPTED,
        Some(&initial),
    );
    tokio::spawn(async move {
        let job = lease.job.clone();
        let start = Instant::now();
        tracing::info!(job_id=%job.snapshot().id, "job_queued");
        let permit = match state.cpu.clone().acquire_owned().await {
            Ok(permit) => permit,
            Err(_) => {
                job.fail("worker_unavailable", "Обработка недоступна.");
                state.jobs.prune();
                return;
            }
        };
        if !job.start("parsing") {
            state.jobs.prune();
            return;
        }
        let control = job.control();
        let result = tokio::task::spawn_blocking(move || {
            let cancelled = || control.is_cancelled();
            let data = parse_xes_cancellable(&content, &cancelled)?;
            control.set_stage("analyzing");
            let analysis = analyze_cancellable(&data, &cancelled)?;
            Ok::<_, crate::domain::ImportError>((data, analysis))
        })
        .await;
        match result {
            Ok(Ok((data, analysis))) => {
                job.set_stage("publishing");
                job.complete_with(|| {
                    store_log(
                        &state,
                        data,
                        analysis,
                        filename,
                        start.elapsed().as_millis(),
                    )
                    .id
                });
            }
            Ok(Err(error)) => {
                job.fail(&error.code, &import_error_message(&error));
            }
            Err(_) => {
                job.fail(
                    "worker_failed",
                    "Обработка прервалась. Предыдущий анализ сохранён.",
                );
            }
        }
        let final_state = job.snapshot();
        tracing::info!(job_id=%final_state.id, state=?final_state.state, elapsed_ms=start.elapsed().as_millis() as u64, "job_finished");
        drop(permit);
        drop(lease);
        state.jobs.prune();
    });
    response
}

fn import_error_message(error: &crate::domain::ImportError) -> String {
    let context = match (error.case_index, error.event_index) {
        (Some(case), Some(event)) => format!(" Трасса {}, событие {}.", case + 1, event + 1),
        (Some(case), None) => format!(" Трасса {}.", case + 1),
        _ => String::new(),
    };
    format!("{}{context}", error.message)
}

async fn job_snapshot(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.jobs.get(&id) {
        Some(job) => Json(job.snapshot()).into_response(),
        None => error_json(
            StatusCode::NOT_FOUND,
            "job_not_found",
            "Задача не найдена или удалена из памяти.",
        ),
    }
}

async fn cancel_job(
    State(state): State<AppState>,
    Path(id): Path<String>,
    headers: axum::http::HeaderMap,
) -> Response {
    let Some(job) = state.jobs.get(&id) else {
        return error_json(
            StatusCode::NOT_FOUND,
            "job_not_found",
            "Задача не найдена или удалена из памяти.",
        );
    };
    let snapshot = job.cancel();
    tracing::info!(job_id=%id, accepted=snapshot.cancel_requested, state=?snapshot.state, "job_cancel_request");
    // Only the watch stream patches the panel: a cancel response snapshot could
    // otherwise arrive after a newer terminal snapshot on that stream.
    if headers
        .get(header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.contains("text/event-stream"))
    {
        StatusCode::NO_CONTENT.into_response()
    } else {
        Json(snapshot).into_response()
    }
}

async fn job_events(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let Some(job) = state.jobs.get(&id) else {
        return error_json(
            StatusCode::NOT_FOUND,
            "job_not_found",
            "Задача не найдена или удалена из памяти.",
        );
    };
    let receiver = job.subscribe();
    let stream = futures_util::stream::unfold(
        (receiver, state, true, false, VecDeque::<SseEvent>::new()),
        |(mut receiver, state, mut first, mut terminal, mut pending)| async move {
            if let Some(event) = pending.pop_front() {
                return Some((
                    Ok::<_, Infallible>(event),
                    (receiver, state, first, terminal, pending),
                ));
            }
            if terminal {
                return None;
            }
            if !first && receiver.changed().await.is_err() {
                return None;
            }
            first = false;
            let snapshot = receiver.borrow_and_update().clone();
            terminal = snapshot.is_terminal();
            if snapshot.state == JobState::Completed {
                let repository = state.repository.lock().expect("repository mutex");
                let log = snapshot
                    .result_id
                    .as_ref()
                    .filter(|id| repository.current.as_ref() == Some(*id))
                    .and_then(|id| repository.logs.get(id))
                    .cloned();
                drop(repository);
                if let Some(log) = log {
                    pending.push_back(patch_event("#analysis-panel", panel(&log)));
                }
            }
            pending.push_back(
                patch_event("#job-panel", job_panel(&snapshot))
                    .id(snapshot.job_revision.to_string()),
            );
            let event = pending.pop_front().expect("snapshot event");
            Some((
                Ok::<_, Infallible>(event),
                (receiver, state, first, terminal, pending),
            ))
        },
    );
    Sse::new(stream)
        .keep_alive(
            axum::response::sse::KeepAlive::new()
                .interval(std::time::Duration::from_secs(10))
                .text("heartbeat"),
        )
        .into_response()
}

fn job_section(snapshot: &JobSnapshot) -> String {
    let connection = if snapshot.is_terminal() {
        String::new()
    } else {
        format!(
            "<div id=\"job-connection\" hidden data-events-url=\"/jobs/{}/events\" data-init=\"@get(el.dataset.eventsUrl, {{openWhenHidden: true}})\"></div>",
            escape(&snapshot.id)
        )
    };
    format!("{connection}{}", job_panel(snapshot))
}

fn job_panel(snapshot: &JobSnapshot) -> String {
    let message = if snapshot.cancel_requested && !snapshot.is_terminal() {
        "Отмена запрошена. Ожидаем безопасную остановку текущего этапа."
    } else {
        match snapshot.state {
            JobState::Queued => "Журнал ожидает обработки",
            JobState::Running => match snapshot.stage.as_str() {
                "analyzing" => "Считаем варианты и переходы",
                "publishing" => "Подготавливаем результат",
                _ => "Читаем и проверяем XES",
            },
            JobState::Completed => "Обработка завершена",
            JobState::Failed => "Не удалось обработать журнал. Предыдущий анализ сохранён.",
            JobState::Cancelled => "Обработка отменена. Предыдущий анализ сохранён.",
        }
    };
    let error = snapshot
        .error
        .as_ref()
        .map(|error| {
            format!(
                "<p class=\"job-error\" role=\"alert\">{}: {}</p>",
                escape(&error.code),
                escape(&error.message)
            )
        })
        .unwrap_or_default();
    let cancel = if snapshot.is_terminal() || snapshot.cancel_requested {
        String::new()
    } else {
        format!(
            "<button type=\"button\" class=\"button secondary\" data-cancel-url=\"/jobs/{}/cancel\" data-on:click=\"@post(el.dataset.cancelUrl, {{requestCancellation: 'disabled', retry: 'never'}})\">Отменить обработку</button>",
            escape(&snapshot.id)
        )
    };
    let result = snapshot
        .result_id
        .as_ref()
        .map(|id| {
            format!(
                "<p><a href=\"/logs/{}\">Открыть результат задачи</a></p>",
                escape(id)
            )
        })
        .unwrap_or_default();
    format!(
        "<section id=\"job-panel\" class=\"job-card\" data-job-id=\"{}\" data-job-revision=\"{}\" data-job-state=\"{:?}\"><div class=\"job-header\"><h2>Фоновая обработка</h2>{cancel}</div><p class=\"job-stage\" role=\"status\">{message}</p>{result}{error}<p class=\"job-memory\">Задачи находятся в памяти. Один обработчик, до двух принятых задач. Перезапуск удалит их. Внутренний разбор Rust4PM завершает текущий этап перед остановкой.</p></section>",
        escape(&snapshot.id),
        snapshot.job_revision,
        snapshot.state
    )
}

fn case_rows(log: &StoredLog) -> String {
    log.data.cases.iter().take(20).map(|case| format!("<button type=\"button\" class=\"case-button\" data-case-id=\"{}\" aria-pressed=\"{}\" data-on:click=\"window.piQueueCase(el.dataset.caseId)\"><span>{} · {}</span><span>{} событий</span></button>", escape(&case.id), log.selected_case.as_deref()==Some(&case.id), escape(case.name.as_deref().unwrap_or("Без имени")), escape(&case.id), case.events.len())).collect()
}

fn case_details(log: &StoredLog) -> String {
    let Some(case) = log
        .selected_case
        .as_ref()
        .and_then(|id| log.data.cases.iter().find(|case| &case.id == id))
    else {
        return "<p class=\"muted\">Выберите трассу, чтобы увидеть её события.</p>".into();
    };
    let sequence = case
        .events
        .iter()
        .take(200)
        .map(|event| format!("<li>{}</li>", escape(&event.activity)))
        .collect::<String>();
    let note = if case.events.is_empty() {
        "Пустая трасса: событий нет."
    } else if case.events.len() > 200 {
        "Показаны первые 200 событий. Полная выбранная трасса доступна в JSON."
    } else if view(log).case_highlight.edge_ids.is_empty() && case.events.len() > 1 {
        "Переходы этой трассы скрыты текущим порогом."
    } else {
        "Порядок событий — как в исходном XML."
    };
    format!(
        "<h3>{} · {}</h3><p>Событий: {}</p><ol>{sequence}</ol><p class=\"muted\">{note}</p>",
        escape(case.name.as_deref().unwrap_or("Без имени")),
        escape(&case.id),
        case.events.len()
    )
}

fn patch_event(selector: &str, html: String) -> SseEvent {
    let elements = html
        .lines()
        .map(|line| format!("elements {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    SseEvent::default()
        .event("datastar-patch-elements")
        .data(format!("selector {selector}\nmode outer\n{elements}"))
}

#[derive(Deserialize)]
struct ViewForm {
    threshold: u64,
}

async fn update_view(
    State(state): State<AppState>,
    Path(id): Path<String>,
    form: Result<Form<ViewForm>, axum::extract::rejection::FormRejection>,
) -> Response {
    let Ok(Form(form)) = form else {
        return error_json(
            StatusCode::BAD_REQUEST,
            "invalid_threshold",
            "Порог должен быть целым числом.",
        );
    };
    let mut repository = state.repository.lock().expect("repository mutex");
    let Some(log) = repository.logs.get_mut(&id) else {
        return not_found();
    };
    match graph_view(
        &log.analysis,
        &id,
        log.analysis_version,
        log.view_revision + 1,
        form.threshold,
        log.selected.clone(),
    ) {
        Ok(view) => {
            log.threshold = form.threshold;
            log.view_revision += 1;
            log.selected = view.selected_id;
            patch(panel(log))
        }
        Err(error) => error_json(StatusCode::BAD_REQUEST, &error.code, &error.message),
    }
}

#[derive(Deserialize)]
struct SelectionForm {
    kind: String,
    id: String,
}

async fn select(
    State(state): State<AppState>,
    Path(id): Path<String>,
    form: Result<Form<SelectionForm>, axum::extract::rejection::FormRejection>,
) -> Response {
    let Ok(Form(form)) = form else {
        return error_json(
            StatusCode::BAD_REQUEST,
            "invalid_selection",
            "Выберите узел или ребро.",
        );
    };
    let mut repository = state.repository.lock().expect("repository mutex");
    let Some(log) = repository.logs.get_mut(&id) else {
        return not_found();
    };
    let valid = match form.kind.as_str() {
        "node" => log.analysis.nodes.iter().any(|n| n.id == form.id),
        "edge" => log
            .analysis
            .edges
            .iter()
            .any(|e| e.id == form.id && e.count >= log.threshold),
        "case" => log.data.cases.iter().any(|case| case.id == form.id),
        _ => false,
    };
    if !valid {
        return error_json(
            StatusCode::BAD_REQUEST,
            "invalid_selection",
            "Элемент отсутствует в текущем представлении.",
        );
    }
    if form.kind == "case" {
        log.selected_case = Some(form.id);
    } else {
        log.selected = Some(form.id);
    }
    log.view_revision += 1;
    patch(panel(log))
}

#[derive(Deserialize)]
struct GraphQuery {
    threshold: Option<u64>,
}

async fn graph(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<GraphQuery>,
) -> Response {
    let repository = state.repository.lock().expect("repository mutex");
    let Some(log) = repository.logs.get(&id) else {
        return not_found();
    };
    match graph_view(
        &log.analysis,
        &id,
        log.analysis_version,
        log.view_revision,
        query.threshold.unwrap_or(log.threshold),
        log.selected.clone(),
    ) {
        Ok(view) => Json(case_projection(log, view)).into_response(),
        Err(error) => error_json(StatusCode::BAD_REQUEST, &error.code, &error.message),
    }
}

async fn export(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let repository = state.repository.lock().expect("repository mutex");
    let Some(log) = repository.logs.get(&id) else {
        return not_found();
    };
    let mut response = Json(json!({
        "schema_version":1,"log_id":log.id,"name":log.filename,"analysis_version":log.analysis_version,"view_revision":log.view_revision,
        "parameters":{"min_edge_frequency":log.threshold,"order":"xml","lifecycle":"each-event"},
        "analysis":log.analysis.as_ref(),"view":view(log),"warnings":log.data.warnings,"elapsed_ms":log.elapsed_ms,
        "selected_case":log.selected_case.as_ref().and_then(|id| log.data.cases.iter().find(|case| &case.id == id)),
        "compatibility":{"apromore":"unverified"}
    })).into_response();
    response.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&format!("attachment; filename=\"{id}.json\""))
            .expect("generated ID"),
    );
    response
}

fn not_found() -> Response {
    error_json(
        StatusCode::NOT_FOUND,
        "not_found",
        "Журнал не найден или удалён из локальной памяти.",
    )
}
fn error_json(status: StatusCode, code: &str, message: &str) -> Response {
    (status, Json(json!({"code":code,"message":message}))).into_response()
}

fn view(log: &StoredLog) -> GraphView {
    case_projection(
        log,
        graph_view(
            &log.analysis,
            &log.id,
            log.analysis_version,
            log.view_revision,
            log.threshold,
            log.selected.clone(),
        )
        .expect("validated stored view"),
    )
}

fn case_projection(log: &StoredLog, mut graph: GraphView) -> GraphView {
    let Some(case) = log
        .selected_case
        .as_ref()
        .and_then(|id| log.data.cases.iter().find(|case| &case.id == id))
    else {
        return graph;
    };
    graph.selected_case_id = Some(case.id.clone());
    let ids: BTreeMap<_, _> = graph
        .nodes
        .iter()
        .map(|node| (node.label.as_str(), node.id.as_str()))
        .collect();
    let nodes: BTreeSet<_> = case
        .events
        .iter()
        .filter_map(|event| ids.get(event.activity.as_str()).copied())
        .collect();
    let pairs: BTreeSet<_> = case
        .events
        .windows(2)
        .filter_map(|pair| {
            Some((
                *ids.get(pair[0].activity.as_str())?,
                *ids.get(pair[1].activity.as_str())?,
            ))
        })
        .collect();
    graph.case_highlight.node_ids = nodes.into_iter().map(str::to_owned).collect();
    graph.case_highlight.edge_ids = graph
        .edges
        .iter()
        .filter(|edge| pairs.contains(&(edge.source.as_str(), edge.target.as_str())))
        .map(|edge| edge.id.clone())
        .collect();
    graph
}

fn page(log: Option<&StoredLog>, error: Option<(&str, &str)>, status: StatusCode) -> Response {
    page_with_job(log, error, status, None)
}

fn page_with_job(
    log: Option<&StoredLog>,
    error: Option<(&str, &str)>,
    status: StatusCode,
    job: Option<&JobSnapshot>,
) -> Response {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let error_panel = error
        .map(|(code, message)| {
            format!(
                "<div class=\"alert\" role=\"alert\"><strong>{}</strong><p>{}</p></div>",
                escape(code),
                escape(message)
            )
        })
        .unwrap_or_default();
    let analysis = log.map(panel).unwrap_or_else(|| "<section id=\"analysis-panel\"><div class=\"card placeholder-card\"><h2>Результаты без догадок</h2><p>Загрузите журнал или откройте пример, чтобы увидеть реальные частоты.</p><form action=\"/demo\" method=\"post\"><button class=\"button primary\" type=\"submit\">Открыть пример</button></form></div></section>".into());
    let html = template(
        include_str!("../templates/shell.html"),
        &[
            ("NONCE", nonce.clone()),
            ("ERROR_PANEL", error_panel),
            ("ANALYSIS_PANEL", analysis),
            ("JOB_PANEL", job.map(job_section).unwrap_or_default()),
        ],
    );
    let mut response = (status, Html(html)).into_response();
    let policy = format!(
        "default-src 'self'; script-src 'self' 'nonce-{nonce}'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    );
    response.headers_mut().insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_str(&policy).expect("valid CSP"),
    );
    response
}

pub fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn template(source: &str, values: &[(&str, String)]) -> String {
    let mut result = String::with_capacity(source.len());
    let mut rest = source;
    while let Some(start) = rest.find("{{") {
        result.push_str(&rest[..start]);
        let token = &rest[start + 2..];
        let Some(end) = token.find("}}") else {
            result.push_str(&rest[start..]);
            return result;
        };
        if let Some((_, value)) = values.iter().find(|(key, _)| *key == &token[..end]) {
            result.push_str(value);
        }
        rest = &token[end + 2..];
    }
    result.push_str(rest);
    result
}

fn panel(log: &StoredLog) -> String {
    let graph = view(log);
    let graph_json = serde_json::to_string(&graph).expect("graph serializable");
    let rows = log.analysis.variants.iter().take(30).map(|v| {
        let path = if v.sequence.is_empty() { "Пустая трасса".into() } else { v.sequence.iter().map(|s| escape(s)).collect::<Vec<_>>().join(" <span aria-hidden=\"true\">→</span> ") };
        format!("<div class=\"variant-row\"><span class=\"variant-path\">{path}</span><strong class=\"variant-count\">{}</strong></div>",v.count)
    }).collect::<String>();
    let details = log
        .selected
        .as_ref()
        .map(|id| {
            if let Some(node) = log.analysis.nodes.iter().find(|node| &node.id == id) {
                format!(
                    "<h3>{}</h3><p>Событий: {}</p><p>Начало трассы: {} · Конец трассы: {}</p>",
                    escape(&node.label),
                    node.count,
                    node.start_count,
                    node.end_count
                )
            } else if let Some(edge) = log.analysis.edges.iter().find(|edge| &edge.id == id) {
                let source = log
                    .analysis
                    .nodes
                    .iter()
                    .find(|n| n.id == edge.source)
                    .expect("edge source");
                let target = log
                    .analysis
                    .nodes
                    .iter()
                    .find(|n| n.id == edge.target)
                    .expect("edge target");
                format!(
                    "<h3>{} → {}</h3><p>Непосредственных переходов: {}</p>",
                    escape(&source.label),
                    escape(&target.label),
                    edge.count
                )
            } else {
                String::new()
            }
        })
        .unwrap_or_else(|| "<p class=\"muted\">Выберите действие или стрелку на карте.</p>".into());
    template(
        include_str!("../templates/analysis-panel.html"),
        &[
            ("ANALYSIS_VERSION", log.analysis_version.to_string()),
            ("VIEW_REVISION", log.view_revision.to_string()),
            ("LOG_NAME", escape(&log.filename)),
            ("LOG_ID", log.id.clone()),
            ("CASE_COUNT", log.analysis.cases.to_string()),
            ("EVENT_COUNT", log.analysis.events.to_string()),
            ("ACTIVITY_COUNT", log.analysis.activities.to_string()),
            ("VARIANT_COUNT", log.analysis.variants.len().to_string()),
            ("THRESHOLD", log.threshold.to_string()),
            (
                "MAX_THRESHOLD",
                log.analysis
                    .max_edge_frequency
                    .saturating_add(1)
                    .max(1)
                    .to_string(),
            ),
            ("VARIANT_ROWS", rows),
            (
                "SHOWN_VARIANTS",
                log.analysis.variants.len().min(30).to_string(),
            ),
            ("SELECTION_DETAILS", details),
            ("CASE_ROWS", case_rows(log)),
            ("CASE_DETAILS", case_details(log)),
            ("ESCAPED_GRAPH_JSON", escape(&graph_json)),
        ],
    )
}

fn patch(html: String) -> Response {
    let elements = html
        .lines()
        .map(|line| format!("elements {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    let data = format!("selector #analysis-panel\nmode outer\n{elements}");
    let event = SseEvent::default()
        .event("datastar-patch-elements")
        .data(data);
    Sse::new(futures_util::stream::once(async move {
        Ok::<_, Infallible>(event)
    }))
    .into_response()
}
