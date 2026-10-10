use crate::{
    domain::{Analysis, EventLog, GraphView},
    event_io::{Limits, parse_xes},
    mining::{analyze, graph_view},
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
    collections::BTreeMap,
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
    data: Arc<EventLog>,
    analysis: Arc<Analysis>,
    elapsed_ms: u128,
}

impl AppState {
    pub fn new(port: u16) -> Self {
        Self {
            repository: Arc::new(Mutex::new(Repository::default())),
            cpu: Arc::new(Semaphore::new(1)),
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
    let mut response = next.run(request).await;
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
    page(current(&state).as_ref(), None, StatusCode::OK)
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

async fn upload(State(state): State<AppState>, mut multipart: Multipart) -> Response {
    let mut content = None;
    let mut filename = "Журнал XES".to_owned();
    loop {
        let field = match multipart.next_field().await {
            Ok(Some(field)) => field,
            Ok(None) => break,
            Err(_) => {
                return page(
                    current(&state).as_ref(),
                    Some((
                        "multipart",
                        "Не удалось прочитать загрузку; проверьте размер и формат файла.",
                    )),
                    StatusCode::BAD_REQUEST,
                );
            }
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
                Err(_) => {
                    return page(
                        current(&state).as_ref(),
                        Some(("multipart", "Загрузка прервана или превышает лимит.")),
                        StatusCode::BAD_REQUEST,
                    );
                }
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
    import(state, content, filename).await
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
                data: Arc::new(data),
                analysis: Arc::new(analysis),
                elapsed_ms: start.elapsed().as_millis(),
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
            tracing::info!(log_id=%log.id, cases=log.analysis.cases, events=log.analysis.events, elapsed_ms=log.elapsed_ms as u64, "import_completed");
            page(Some(&log), None, StatusCode::OK)
        }
        Ok(Err(error)) => {
            tracing::warn!(code=%error.code, case_index=?error.case_index, event_index=?error.event_index, "import_rejected");
            page(
                current(&state).as_ref(),
                Some((&error.code, &error.message)),
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
        _ => false,
    };
    if !valid {
        return error_json(
            StatusCode::BAD_REQUEST,
            "invalid_selection",
            "Элемент отсутствует в текущем представлении.",
        );
    }
    log.selected = Some(form.id);
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
        Ok(view) => Json(view).into_response(),
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
    graph_view(
        &log.analysis,
        &log.id,
        log.analysis_version,
        log.view_revision,
        log.threshold,
        log.selected.clone(),
    )
    .expect("validated stored view")
}

fn page(log: Option<&StoredLog>, error: Option<(&str, &str)>, status: StatusCode) -> Response {
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
