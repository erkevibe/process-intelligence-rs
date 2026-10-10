//! Project-scoped local platform. Database operations run only on blocking workers.
use crate::{
    auth::{Actor, Auth, Role},
    bpmn::ProcessModel,
    calendar::CalendarSpec,
    csv_io::{self, CsvMapping, NormalizationOrder},
    domain::ImportError,
    filters::FilterSpec,
    jobs::{JobError, JobState, JobStore},
    mining::analyze,
    platform_render as render,
    storage::{Database, sha256},
    web::{AppState, Repository, StoredLog, Workspace},
};
use axum::{
    Form, Json, Router,
    extract::{DefaultBodyLimit, Multipart, Path, Query},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Instant,
};
use tokio::sync::Semaphore;
#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct StoredModel {
    pub id: String,
    pub name: String,
    pub revision: u64,
    pub model: ProcessModel,
    pub source_log: Option<String>,
}
struct Cached {
    repository: Arc<Mutex<Repository>>,
    jobs: Arc<JobStore>,
}
struct PendingCsv {
    bytes: Vec<u8>,
    filename: String,
    delimiter: u8,
    user: String,
    project: String,
    expires: i64,
}
pub(crate) struct Platform {
    pub database: Database,
    pub auth: Auth,
    workspaces: Mutex<BTreeMap<String, Cached>>,
    slots: Arc<Semaphore>,
    pending: Mutex<BTreeMap<String, PendingCsv>>,
}
impl Platform {
    pub fn open(url: String) -> Result<Self, ImportError> {
        let database = Database::connect(url)?;
        database.acquire_platform_lease()?;
        let auth = Auth::open(database.clone())?;
        let platform = Self {
            database,
            auth,
            workspaces: Mutex::new(BTreeMap::new()),
            slots: Arc::new(Semaphore::new(2)),
            pending: Mutex::new(BTreeMap::new()),
        };
        for project in platform.auth.all_projects() {
            platform.load(&project.id)?;
        }
        Ok(platform)
    }
    fn load(&self, id: &str) -> Result<(), ImportError> {
        let mut cache = self.workspaces.lock().expect("workspace mutex");
        if cache.contains_key(id) {
            return Ok(());
        }
        let (revision, mut repository) = match self.database.read(&format!("repository/{id}"))? {
            Some((revision, value)) => (
                revision,
                serde_json::from_value::<Repository>(value)
                    .map_err(|_| failure("repository_corrupt", "Не удалось прочитать проект."))?,
            ),
            None => (0, Repository::default()),
        };
        repository.storage_revision = revision;
        let mut recovered = false;
        for job in repository.durable_jobs.values_mut() {
            if !job.is_terminal() {
                job.state = JobState::Failed;
                job.stage = "interrupted".into();
                job.result_id = None;
                job.error=Some(JobError{code:"interrupted".into(),message:"Приложение было остановлено до подтверждения результата. Загрузите файл заново.".into()});
                job.job_revision += 1;
                recovered = true;
            }
        }
        if recovered {
            repository.storage_revision = self.database.write(
                &format!("repository/{id}"),
                revision,
                serde_json::to_value(&repository).map_err(|_| {
                    failure("repository_corrupt", "Не удалось сохранить восстановление.")
                })?,
            )?;
        }
        let snapshots = repository
            .durable_jobs
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let jobs = Arc::new(JobStore::restore_with_slots(&snapshots, self.slots.clone()));
        cache.insert(
            id.into(),
            Cached {
                repository: Arc::new(Mutex::new(repository)),
                jobs,
            },
        );
        Ok(())
    }
    pub fn scope(&self, root: &AppState, actor: Actor) -> Result<AppState, ImportError> {
        self.database.health()?;
        self.load(&actor.project_id)?;
        let cache = self.workspaces.lock().expect("workspace mutex");
        let cached = cache.get(&actor.project_id).expect("loaded workspace");
        let mut state = root.clone();
        state.repository = cached.repository.clone();
        state.jobs = cached.jobs.clone();
        state.actor = Some(actor);
        Ok(state)
    }
}
fn failure(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
pub(crate) fn session_cookie(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .find_map(|part| part.trim().strip_prefix("pi_session=").map(str::to_owned))
        .filter(|s| s.len() == 64 && s.chars().all(|c| c.is_ascii_hexdigit()))
}
fn platform(state: &AppState) -> Result<Arc<Platform>, ImportError> {
    state.platform.clone().ok_or_else(|| {
        failure(
            "platform_unavailable",
            "Эта функция требует PostgreSQL и входа в проект.",
        )
    })
}
fn actor(state: &AppState) -> Result<Actor, ImportError> {
    state
        .actor
        .clone()
        .ok_or_else(|| failure("access_denied", "Сначала войдите в проект."))
}
fn response_error(error: ImportError) -> Response {
    let status = match error.code.as_str() {
        "access_denied" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "storage_conflict" | "model_conflict" => StatusCode::CONFLICT,
        "storage_unavailable" => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::UNPROCESSABLE_ENTITY,
    };
    (
        status,
        Json(json!({"code":error.code,"message":error.message})),
    )
        .into_response()
}
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, ImportError> + Send + 'static,
) -> Result<T, ImportError> {
    tokio::task::spawn_blocking(work).await.map_err(|_| {
        failure(
            "worker_failed",
            "Операция прервалась. Изменение не подтверждено.",
        )
    })?
}
fn page(title: &str, body: String) -> Response {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let nav = "<nav><a href=\"/\">Анализ</a> · <a href=\"/projects\">Проекты</a> · <a href=\"/logs\">Журналы</a> · <a href=\"/csv\">CSV</a> · <a href=\"/models\">BPMN</a> · <a href=\"/backup\">Резервная копия</a><form method=\"post\" action=\"/logout\"><button>Выйти</button></form></nav>";
    let html = include_str!("../templates/platform.html")
        .replace("{{NONCE}}", &nonce)
        .replace("{{TITLE}}", &render::html_escape(title))
        .replace("{{NAV}}", nav)
        .replace("{{BODY}}", &body);
    let mut response = Html(html).into_response();
    response.headers_mut().insert(header::CONTENT_SECURITY_POLICY,format!("default-src 'self'; script-src 'self' 'nonce-{nonce}'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'").parse().expect("nonce header"));
    response
}
fn redirect(path: &str) -> Response {
    Redirect::to(path).into_response()
}
fn cookie_response(token: String) -> Response {
    let mut response = redirect("/projects");
    response.headers_mut().insert(
        header::SET_COOKIE,
        format!("pi_session={token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800")
            .parse()
            .expect("generated token"),
    );
    response
}
pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/setup",
            get(setup_form)
                .post(setup)
                .layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/login",
            get(login_form)
                .post(login)
                .layer(DefaultBodyLimit::max(4096)),
        )
        .route("/logout", post(logout))
        .route("/projects", get(projects).post(create_project))
        .route("/projects/{id}/open", post(open_project))
        .route("/projects/{id}/members", post(membership))
        .route(
            "/users",
            post(create_user).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/logs", get(logs))
        .route("/csv", get(csv_form))
        .route("/csv/preview", post(csv_preview))
        .route("/csv/import", post(csv_import))
        .route("/logs/{id}/tools", get(log_tools))
        .route("/logs/{id}/activities", get(activity_options))
        .route("/logs/{id}/filter", post(filter_log))
        .route("/logs/{id}/calendar", get(log_tools).post(set_calendar))
        .route("/logs/{id}/discover", post(discover))
        .route("/models", get(models))
        .route("/models/import", post(import_model))
        .route("/models/{id}", get(model).post(save_model))
        .route("/models/{id}/export", get(export_model))
        .route("/models/{id}/json", get(model_json))
        .route("/backup", get(backup))
        .route("/restore", post(restore))
}
#[derive(Deserialize)]
struct Credentials {
    username: String,
    password: String,
}
fn credential_form(setup: bool) -> Response {
    let title = if setup {
        "Создать первую учётную запись"
    } else {
        "Вход"
    };
    let path = if setup { "/setup" } else { "/login" };
    page(
        title,
        format!(
            "<h1>{title}</h1><form method=\"post\" action=\"{path}\"><label>Имя<input name=\"username\" maxlength=\"80\" required autocomplete=\"username\"></label><label>Пароль<input name=\"password\" type=\"password\" minlength=\"12\" maxlength=\"256\" required autocomplete=\"{}\"></label><button>Продолжить</button></form><p>Локальный вход. Сессия действует восемь часов. Пароль: 12–256 bytes UTF-8.</p>",
            if setup {
                "new-password"
            } else {
                "current-password"
            }
        ),
    )
}
async fn setup_form(Workspace(state): Workspace) -> Response {
    match platform(&state) {
        Ok(p) if p.auth.needs_setup() => credential_form(true),
        Ok(_) => redirect("/login"),
        Err(e) => response_error(e),
    }
}
async fn login_form() -> Response {
    credential_form(false)
}
async fn setup(Workspace(state): Workspace, Form(form): Form<Credentials>) -> Response {
    let result =
        blocking(move || platform(&state)?.auth.setup(&form.username, &form.password)).await;
    match result {
        Ok(token) => cookie_response(token),
        Err(e) => response_error(e),
    }
}
async fn login(Workspace(state): Workspace, Form(form): Form<Credentials>) -> Response {
    let result =
        blocking(move || platform(&state)?.auth.login(&form.username, &form.password)).await;
    match result {
        Ok(token) => cookie_response(token),
        Err(e) => response_error(e),
    }
}
async fn logout(Workspace(state): Workspace, headers: HeaderMap) -> Response {
    let token = session_cookie(&headers).unwrap_or_default();
    match blocking(move || platform(&state)?.auth.logout(&token)).await {
        Ok(()) => {
            let mut response = redirect("/login");
            response.headers_mut().insert(
                header::SET_COOKIE,
                "pi_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
                    .parse()
                    .expect("cookie"),
            );
            response
        }
        Err(e) => response_error(e),
    }
}
async fn projects(Workspace(state): Workspace) -> Response {
    match (platform(&state), actor(&state)) {
        (Ok(p), Ok(a)) => page("Проекты", render::projects(&a, &p.auth.projects(&a))),
        _ => response_error(failure("access_denied", "Войдите в проект.")),
    }
}
#[derive(Deserialize)]
struct NameForm {
    name: String,
}
async fn create_project(Workspace(state): Workspace, Form(form): Form<NameForm>) -> Response {
    match blocking(move || {
        platform(&state)?
            .auth
            .create_project(&actor(&state)?, &form.name)
    })
    .await
    {
        Ok(_) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn open_project(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let token = session_cookie(&headers).unwrap_or_default();
    match blocking(move || platform(&state)?.auth.switch(&token, &id)).await {
        Ok(()) => redirect("/logs"),
        Err(e) => response_error(e),
    }
}
#[derive(Deserialize)]
struct MemberForm {
    username: String,
    role: Role,
}
async fn membership(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<MemberForm>,
) -> Response {
    match blocking(move || {
        platform(&state)?
            .auth
            .grant(&actor(&state)?, &id, &form.username, form.role)
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn create_user(Workspace(state): Workspace, Form(form): Form<Credentials>) -> Response {
    match blocking(move || {
        platform(&state)?
            .auth
            .add_user(&actor(&state)?, &form.username, &form.password)
    })
    .await
    {
        Ok(_) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn logs(Workspace(state): Workspace) -> Response {
    let repo = state.repository.lock().expect("repository mutex");
    let items = repo
        .logs
        .values()
        .map(|log| (log.id.clone(), log.filename.clone(), log.analysis.events))
        .collect::<Vec<_>>();
    page(
        "Журналы",
        render::logs_list(
            &items,
            state
                .actor
                .as_ref()
                .is_some_and(|actor| actor.role.can_write()),
        ),
    )
}
async fn csv_form(Workspace(state): Workspace) -> Response {
    page(
        "Импорт CSV",
        if state
            .actor
            .as_ref()
            .is_some_and(|actor| !actor.role.can_write())
        {
            "<h1>Импорт CSV</h1><p>Вы можете просматривать журналы. Импорт доступен редактору проекта.</p>".into()
        } else {
            render::csv_upload()
        },
    )
}
async fn read_upload(
    mut multipart: Multipart,
    max: usize,
) -> Result<(Vec<u8>, String, BTreeMap<String, String>), ImportError> {
    let mut bytes = None;
    let mut filename = "upload".to_owned();
    let mut fields = BTreeMap::new();
    let mut total = 0usize;
    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|_| failure("multipart", "Загрузка прервана."))?
    {
        let name = field.name().unwrap_or("").to_owned();
        let is_file = name == "file";
        if is_file {
            if bytes.is_some() {
                return Err(failure("multipart", "Передайте один файл."));
            }
            filename = field.file_name().unwrap_or("upload").to_owned();
            if filename.len() > 1024 {
                return Err(failure("filename_limit", "Имя файла слишком длинное."));
            }
        }
        let mut data = Vec::new();
        while let Some(chunk) = field
            .chunk()
            .await
            .map_err(|_| failure("multipart", "Загрузка прервана."))?
        {
            total = total.saturating_add(chunk.len());
            if total > max {
                return Err(failure("byte_limit", "Размер загрузки превышает лимит."));
            }
            data.extend_from_slice(&chunk);
        }
        if is_file {
            bytes = Some(data);
        } else {
            if data.len() > 4096 {
                return Err(failure("multipart", "Поле формы слишком длинное."));
            }
            fields.insert(
                name,
                String::from_utf8(data).map_err(|_| failure("utf8", "Форма должна быть UTF-8."))?,
            );
        }
    }
    Ok((
        bytes.ok_or_else(|| failure("missing_file", "Выберите файл."))?,
        filename,
        fields,
    ))
}
async fn csv_preview(Workspace(state): Workspace, multipart: Multipart) -> Response {
    let _permit = match state.uploads.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другие файлы уже загружаются.")),
    };
    let result = async {
        let (bytes, filename, fields) = read_upload(multipart, 20 * 1024 * 1024).await?;
        let delimiter = match fields.get("delimiter").map(String::as_str) {
            Some("semicolon") => b';',
            Some("tab") => b'\t',
            Some("comma") | None => b',',
            _ => return Err(failure("delimiter", "Неизвестный разделитель.")),
        };
        let a = actor(&state)?;
        let p = platform(&state)?;
        let preview = csv_io::preview(&bytes, delimiter)?;
        let token = uuid::Uuid::new_v4().simple().to_string();
        let mut pending = p.pending.lock().expect("CSV mutex");
        let now = chrono::Utc::now().timestamp();
        pending.retain(|_, v| v.expires > now);
        if pending.len() >= 2 {
            return Err(failure(
                "preview_limit",
                "Уже открыты два предварительных просмотра. Подождите пять минут.",
            ));
        }
        pending.insert(
            token.clone(),
            PendingCsv {
                bytes,
                filename,
                delimiter,
                user: a.id,
                project: a.project_id,
                expires: now + 300,
            },
        );
        Ok::<_, ImportError>((token, preview))
    }
    .await;
    match result {
        Ok((token, preview)) => page("Столбцы CSV", render::csv_mapping(&token, &preview)),
        Err(e) => response_error(e),
    }
}
#[derive(Deserialize)]
struct CsvForm {
    token: String,
    case_column: String,
    activity_column: String,
    #[serde(default)]
    timestamp_column: String,
    #[serde(default)]
    lifecycle_column: String,
    order: NormalizationOrder,
}
async fn csv_import(Workspace(state): Workspace, Form(form): Form<CsvForm>) -> Response {
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже анализируется.")),
    };
    match blocking(move || {
        let _permit = permit;
        let p = platform(&state)?;
        let a = actor(&state)?;
        let (bytes, filename, delimiter) = {
            let pending = p.pending.lock().expect("CSV mutex");
            let v = pending
                .get(&form.token)
                .filter(|v| {
                    v.user == a.id
                        && v.project == a.project_id
                        && v.expires > chrono::Utc::now().timestamp()
                })
                .ok_or_else(|| {
                    failure(
                        "preview_expired",
                        "Предварительный просмотр истёк. Загрузите файл заново.",
                    )
                })?;
            (v.bytes.clone(), v.filename.clone(), v.delimiter)
        };
        let mapping = CsvMapping {
            case_column: form.case_column,
            activity_column: form.activity_column,
            timestamp_column: (!form.timestamp_column.is_empty()).then_some(form.timestamp_column),
            lifecycle_column: (!form.lifecycle_column.is_empty()).then_some(form.lifecycle_column),
            delimiter,
            order: form.order,
        };
        let start = Instant::now();
        let data = csv_io::parse_csv(&bytes, &mapping)?;
        let analysis = analyze(&data);
        let log = crate::web::store_log(
            &state,
            data,
            analysis,
            filename,
            start.elapsed().as_millis(),
            sha256(&bytes),
            form.order,
            None,
        )?;
        p.pending.lock().expect("CSV mutex").remove(&form.token);
        Ok(log.id)
    })
    .await
    {
        Ok(id) => redirect(&format!("/logs/{id}")),
        Err(e) => response_error(e),
    }
}
#[derive(Deserialize)]
struct ActivityQuery {
    #[serde(default)]
    q: String,
}
async fn activity_options(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Query(query): Query<ActivityQuery>,
) -> Response {
    if query.q.len() > 4096 {
        return response_error(failure("query_limit", "Поисковый запрос слишком длинный."));
    }
    tokio::task::spawn_blocking(move || {
        let log = state.repository.lock().expect("repository mutex").get_log(&state, &id);
        let Some(log) = log else {
            return response_error(failure("not_found", "Журнал не найден."));
        };
        let labels: std::collections::BTreeSet<_> = log.source.cases.iter()
            .flat_map(|case| &case.events).map(|event| event.activity.clone()).collect();
        let needle = query.q.to_lowercase();
        let mut matches = labels.iter().filter(|label| label.to_lowercase().contains(&needle));
        let activities: Vec<_> = matches.by_ref().take(50).cloned().collect();
        Json(json!({"activities":activities,"has_more":matches.next().is_some(),"total_activities":labels.len()})).into_response()
    }).await.unwrap_or_else(|_| response_error(failure("worker_failed", "Не удалось найти действия.")))
}
async fn log_tools(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    tokio::task::spawn_blocking(move|| {
    let repo = state.repository.lock().expect("repository mutex");
    match repo.get_log(&state, &id) {
        Some(log) => page(
            "Фильтры и календарь",
            format!(
                "<h1>{}</h1><p><a href=\"/logs/{id}\">Открыть анализ</a> · <a href=\"/logs/{id}/export\">Экспорт с политиками</a></p>{}<h2>Рабочая длительность трасс</h2>{}",
                render::html_escape(&log.filename),
                render::log_tools(
                    &id,
                    &log.filters,
                    &log.calendar,
                    state.actor.as_ref().is_some_and(|a| a.role.can_write())
                ),
                render::calendar_table(&calendar_results(&log))
            ),
        ),
        None => response_error(failure("not_found", "Журнал не найден.")),
    }

    }).await.unwrap_or_else(|_|response_error(failure("worker_failed","Не удалось подготовить результат.")))
}
#[derive(Deserialize)]
struct FilterForm {
    #[serde(default)]
    case_activity: String,
    #[serde(default)]
    min_events: String,
    #[serde(default)]
    max_events: String,
    #[serde(default)]
    retain: String,
    #[serde(default)]
    remove: String,
}
fn number(text: &str) -> Result<Option<usize>, ImportError> {
    if text.trim().is_empty() {
        Ok(None)
    } else {
        text.parse().map(Some).map_err(|_| {
            failure(
                "filter_range",
                "Количество событий должно быть целым числом.",
            )
        })
    }
}
fn labels(text: &str) -> Result<Vec<String>, ImportError> {
    if text.trim().is_empty() {
        Ok(Vec::new())
    } else {
        serde_json::from_str(text)
            .map_err(|_| failure("filter_labels", "Метки задаются JSON-массивом строк."))
    }
}
async fn filter_log(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<FilterForm>,
) -> Response {
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже анализируется.")),
    };
    let result = blocking(move || {
        let _permit = permit;
        let spec = FilterSpec {
            case_activity: (!form.case_activity.is_empty()).then_some(form.case_activity),
            min_events: number(&form.min_events)?,
            max_events: number(&form.max_events)?,
            retain_activities: labels(&form.retain)?,
            remove_activities: labels(&form.remove)?,
        };
        let mut repo = state.repository.lock().expect("repository mutex");
        let mut next = repo.clone();
        let mut log = repo
            .logs
            .get(&id)
            .cloned()
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let data = crate::filters::apply(&log.source, &spec)?;
        log.analysis = Arc::new(analyze(&data));
        log.data = Arc::new(data);
        log.filters = spec;
        log.analysis_version = state.next_id(log.analysis_version + 1)?;
        log.selected = None;
        log.selected_case = None;
        log.view_revision = 0;
        next.logs.insert(id.clone(), log);
        for views in next.user_views.values_mut() {
            views.remove(&id);
        }
        state.commit(&mut next)?;
        *repo = next;
        Ok(id)
    })
    .await;
    match result {
        Ok(id) => redirect(&format!("/logs/{id}")),
        Err(e) => response_error(e),
    }
}
#[derive(Deserialize)]
struct CalendarForm {
    offset_minutes: i32,
    weekdays: String,
    start_minute: u32,
    end_minute: u32,
    #[serde(default)]
    holidays: String,
}
async fn set_calendar(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<CalendarForm>,
) -> Response {
    let result = blocking(move || {
        let weekdays = form
            .weekdays
            .split(',')
            .map(|v| v.trim().parse())
            .collect::<Result<Vec<u32>, _>>()
            .map_err(|_| failure("calendar", "Дни недели: числа 1–7 через запятую."))?;
        let holidays = if form.holidays.trim().is_empty() {
            Vec::new()
        } else {
            form.holidays
                .split(',')
                .map(|v| v.trim().parse())
                .collect::<Result<Vec<chrono::NaiveDate>, _>>()
                .map_err(|_| failure("calendar", "Праздники: даты YYYY-MM-DD через запятую."))?
        };
        let spec = CalendarSpec {
            offset_minutes: form.offset_minutes,
            weekdays,
            start_minute: form.start_minute,
            end_minute: form.end_minute,
            holidays,
        };
        let now = chrono::Utc::now();
        crate::calendar::business_millis(now, now, &spec)?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let mut next = repo.clone();
        let log = next
            .logs
            .get_mut(&id)
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        log.calendar = spec;
        state.commit(&mut next)?;
        *repo = next;
        Ok(id)
    })
    .await;
    match result {
        Ok(id) => redirect(&format!("/logs/{id}/tools")),
        Err(e) => response_error(e),
    }
}
pub(crate) fn calendar_results(log: &StoredLog) -> Value {
    Value::Array(log.data.cases.iter().map(|case|{let times=case.events.iter().filter_map(|e|e.timestamp).collect::<Vec<_>>();if times.len()!=case.events.len()||times.is_empty(){return json!({"case_id":case.id,"status":"unverified","reason":"missing_timestamps"});}let start=*times.iter().min().expect("nonempty");let end=*times.iter().max().expect("nonempty");match crate::calendar::business_millis(start,end,&log.calendar){Ok(ms)=>json!({"case_id":case.id,"status":"computed","start":start,"end":end,"business_millis":ms}),Err(e)=>json!({"case_id":case.id,"status":"unverified","reason":e.code})}}).collect())
}
fn insert_model(
    state: &AppState,
    model: ProcessModel,
    name: String,
    source_log: Option<String>,
) -> Result<String, ImportError> {
    exportable_model(&model)?;
    let mut repo = state.repository.lock().expect("repository mutex");
    if repo.models.len() >= 64 {
        return Err(failure("model_limit", "Максимум 64 модели в проекте."));
    }
    let mut next = repo.clone();
    next.sequence += 1;
    let mut fallback = next.sequence;
    let id = loop {
        let id = format!("model-{}", state.next_id(fallback)?);
        if !next.models.contains_key(&id) {
            break id;
        }
        fallback += 1;
    };
    next.models.insert(
        id.clone(),
        StoredModel {
            id: id.clone(),
            name,
            revision: 1,
            model,
            source_log,
        },
    );
    state.commit(&mut next)?;
    *repo = next;
    Ok(id)
}
async fn models(Workspace(state): Workspace) -> Response {
    let repo = state.repository.lock().expect("repository mutex");
    let items = repo
        .models
        .values()
        .map(|model| (model.id.clone(), model.name.clone(), model.revision))
        .collect::<Vec<_>>();
    page(
        "BPMN",
        render::models_list(
            &items,
            state
                .actor
                .as_ref()
                .is_some_and(|actor| actor.role.can_write()),
        ),
    )
}
async fn import_model(Workspace(state): Workspace, multipart: Multipart) -> Response {
    let _permit = match state.uploads.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другие файлы уже загружаются.")),
    };
    let upload = read_upload(multipart, 1024 * 1024).await;
    match upload {
        Ok((bytes, name, _)) => {
            match blocking(move || insert_model(&state, crate::bpmn::parse(&bytes)?, name, None))
                .await
            {
                Ok(id) => redirect(&format!("/models/{id}")),
                Err(e) => response_error(e),
            }
        }
        Err(e) => response_error(e),
    }
}
async fn discover(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже анализируется.")),
    };
    match blocking(move || {
        let _permit = permit;
        let log = state
            .repository
            .lock()
            .expect("repository mutex")
            .logs
            .get(&id)
            .cloned()
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let model = crate::bpmn::discover(&log.data)?;
        insert_model(
            &state,
            model,
            format!("Observed variants · {}", log.filename),
            Some(id),
        )
    })
    .await
    {
        Ok(id) => redirect(&format!("/models/{id}")),
        Err(e) => response_error(e),
    }
}
async fn model(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let repo = state.repository.lock().expect("repository mutex");
    match repo.models.get(&id) {
        Some(m) => page(
            "Модель BPMN",
            render::model_editor(
                &id,
                &m.model,
                m.revision,
                state.actor.as_ref().is_some_and(|a| a.role.can_write()),
            ),
        ),
        None => response_error(failure("not_found", "Модель не найдена.")),
    }
}
#[derive(Deserialize)]
struct ModelForm {
    model_json: String,
    revision: u64,
}
async fn save_model(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ModelForm>,
) -> Response {
    match blocking(move || {
        if form.model_json.len() > 1024 * 1024 {
            return Err(failure("model_limit", "Модель превышает 1 MiB."));
        }
        let mut model: ProcessModel = serde_json::from_str(&form.model_json)
            .map_err(|_| failure("model_json", "Неверный JSON модели."))?;
        exportable_model(&model)?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let mut next = repo.clone();
        let saved = next
            .models
            .get_mut(&id)
            .ok_or_else(|| failure("not_found", "Модель не найдена."))?;
        if saved.revision != form.revision {
            return Err(failure(
                "model_conflict",
                "Модель изменена. Откройте её заново.",
            ));
        }
        let original_nodes=saved.model.nodes.iter().map(|node|(&node.id,node.kind)).collect::<BTreeMap<_,_>>();
        let incoming_nodes=model.nodes.iter().map(|node|(&node.id,node.kind)).collect::<BTreeMap<_,_>>();
        let original_flows=saved.model.flows.iter().map(|flow|(&flow.id,(&flow.source,&flow.target))).collect::<BTreeMap<_,_>>();
        let incoming_flows=model.flows.iter().map(|flow|(&flow.id,(&flow.source,&flow.target))).collect::<BTreeMap<_,_>>();
        if saved.model.process_id!=model.process_id||original_nodes!=incoming_nodes||original_flows!=incoming_flows {return Err(failure("model_structure","Редактор меняет подписи и положение. Для изменения структуры импортируйте новую BPMN-модель."));}
        model.discovery=saved.model.discovery.clone();
        saved.model = model;
        saved.revision += 1;
        state.commit(&mut next)?;
        *repo = next;
        Ok(id)
    })
    .await
    {
        Ok(id) => redirect(&format!("/models/{id}")),
        Err(e) => response_error(e),
    }
}
async fn export_model(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let repo = state.repository.lock().expect("repository mutex");
    match repo.models.get(&id) {
        Some(m) => match crate::bpmn::serialize(&m.model) {
            Ok(xml) => {
                let mut response = xml.into_response();
                response.headers_mut().insert(
                    header::CONTENT_TYPE,
                    "application/xml; charset=utf-8".parse().expect("type"),
                );
                response.headers_mut().insert(
                    header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{id}.bpmn\"")
                        .parse()
                        .expect("ID"),
                );
                response
            }
            Err(e) => response_error(e),
        },
        None => response_error(failure("not_found", "Модель не найдена.")),
    }
}
async fn model_json(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let repo = state.repository.lock().expect("repository mutex");
    match repo.models.get(&id) {
        Some(m) => Json(m).into_response(),
        None => response_error(failure("not_found", "Модель не найдена.")),
    }
}
#[derive(Serialize, Deserialize)]
struct Backup {
    schema_version: u32,
    source_project_id: String,
    payload: Value,
    digest_sha256: String,
}
fn digest(value: &Value) -> Result<String, ImportError> {
    Ok(sha256(&serde_json::to_vec(value).map_err(|_| {
        failure("backup", "Не удалось подготовить копию.")
    })?))
}
async fn backup(Workspace(state): Workspace) -> Response {
    tokio::task::spawn_blocking(move|| {
    let a = match actor(&state) {
        Ok(a) => a,
        Err(e) => return response_error(e),
    };
    let repo = state.repository.lock().expect("repository mutex");
    let result = (|| {
        if repo.durable_jobs.values().any(|job| !job.is_terminal()) {
            return Err(failure(
                "backup_busy",
                "Дождитесь завершения или отмены фоновых задач перед созданием резервной копии.",
            ));
        }
        let payload = serde_json::to_value(&*repo)
            .map_err(|_| failure("backup", "Не удалось подготовить копию."))?;
        let digest_sha256 = digest(&payload)?;
        Ok::<_, ImportError>(Backup {
            schema_version: 1,
            source_project_id: a.project_id,
            payload,
            digest_sha256,
        })
    })();
    match result {
        Ok(bundle) => {
            let bytes = match serde_json::to_vec(&bundle) {
                Ok(bytes) if bytes.len() <= 20 * 1024 * 1024 => bytes,
                _ => {
                    return response_error(failure(
                        "backup_limit",
                        "Копия превышает 20 MiB. Экспортируйте журналы и модели отдельно.",
                    ));
                }
            };
            let mut response = bytes.into_response();
            response.headers_mut().insert(
                header::CONTENT_TYPE,
                "application/json".parse().expect("type"),
            );
            response.headers_mut().insert(
                header::CONTENT_DISPOSITION,
                "attachment; filename=\"project-backup.json\""
                    .parse()
                    .expect("disposition"),
            );
            response
        }
        Err(e) => response_error(e),
    }

    }).await.unwrap_or_else(|_|response_error(failure("worker_failed","Не удалось подготовить результат.")))
}
fn validate_backup(repo: &Repository) -> Result<(), ImportError> {
    if repo.logs.len() > 8 || repo.models.len() > 64 || repo.durable_jobs.len() > 10 {
        return Err(failure("backup_limit", "В копии превышены лимиты проекта."));
    }
    for (id, log) in &repo.logs {
        if id != &log.id
            || !valid_id(id, "log-")
            || log.source_sha256.len() != 64
            || !log.source_sha256.chars().all(|c| c.is_ascii_hexdigit())
        {
            return Err(failure(
                "backup_invalid",
                "Неверные идентификаторы или хеши журнала.",
            ));
        }
        for data in [&log.source, &log.data] {
            let mut case_ids = std::collections::BTreeSet::new();
            if data
                .cases
                .iter()
                .any(|case| case.id.is_empty() || !case_ids.insert(&case.id))
            {
                return Err(failure("backup_invalid", "Неверные идентификаторы трасс."));
            }
            if data.cases.len() > 20_000
                || data.cases.iter().map(|c| c.events.len()).sum::<usize>() > 100_000
            {
                return Err(failure("backup_limit", "Превышены лимиты журнала."));
            }
            if data
                .cases
                .iter()
                .flat_map(|c| &c.events)
                .any(|e| e.activity.is_empty() || e.activity.len() > 4096)
            {
                return Err(failure("backup_invalid", "Неверная метка события."));
            }
        }
        let filtered = crate::filters::apply(&log.source, &log.filters)?;
        if serde_json::to_value(&filtered).ok() != serde_json::to_value(log.data.as_ref()).ok()
            || serde_json::to_value(analyze(&log.data)).ok()
                != serde_json::to_value(log.analysis.as_ref()).ok()
        {
            return Err(failure(
                "backup_invalid",
                "Анализ или фильтр не соответствует данным.",
            ));
        }
        let now = chrono::Utc::now();
        crate::mining::graph_view(
            &log.analysis,
            &log.id,
            log.analysis_version,
            log.view_revision,
            log.threshold,
            log.selected.clone(),
        )?;
        if log
            .selected_case
            .as_ref()
            .is_some_and(|id| !log.data.cases.iter().any(|case| &case.id == id))
        {
            return Err(failure(
                "backup_invalid",
                "Выбранная трасса отсутствует в журнале.",
            ));
        }
        crate::calendar::business_millis(now, now, &log.calendar)?;
    }
    for (id, m) in &repo.models {
        if id != &m.id || !valid_id(id, "model-") {
            return Err(failure("backup_invalid", "Неверный идентификатор модели."));
        }
        exportable_model(&m.model)?;
    }
    if repo.current.values().any(|id| !repo.logs.contains_key(id)) {
        return Err(failure(
            "backup_invalid",
            "Текущий журнал отсутствует в копии.",
        ));
    }
    for job in repo.durable_jobs.values() {
        if !valid_id(&job.id, "job-")
            || !job.is_terminal()
            || job
                .result_id
                .as_ref()
                .is_some_and(|id| !repo.logs.contains_key(id))
        {
            return Err(failure(
                "backup_invalid",
                "Копия содержит незавершённую задачу или отсутствующий результат.",
            ));
        }
    }
    Ok(())
}
fn exportable_model(model: &ProcessModel) -> Result<(), ImportError> {
    crate::bpmn::validate(model)?;
    let bytes = serde_json::to_vec(model)
        .map_err(|_| failure("model_json", "Не удалось сериализовать модель."))?;
    if bytes.len() > 1024 * 1024 {
        return Err(failure(
            "model_limit",
            "Нормализованная модель превышает 1 MiB JSON.",
        ));
    }
    crate::bpmn::serialize(model)?;
    Ok(())
}

fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix).is_some_and(|tail| {
        !tail.is_empty() && tail.len() <= 20 && tail.bytes().all(|b| b.is_ascii_digit())
    })
}
async fn restore(Workspace(state): Workspace, multipart: Multipart) -> Response {
    let _permit = match state.uploads.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другие файлы уже загружаются.")),
    };
    let upload = read_upload(multipart, 20 * 1024 * 1024).await;
    match upload {
        Ok((bytes, _, fields)) => match blocking(move || {
            let bundle: Backup = serde_json::from_slice(&bytes)
                .map_err(|_| failure("backup_format", "Неверный формат резервной копии."))?;
            if bundle.schema_version != 1 {
                return Err(failure(
                    "backup_version",
                    "Версия резервной копии не поддерживается.",
                ));
            }
            if digest(&bundle.payload)? != bundle.digest_sha256 {
                return Err(failure(
                    "backup_digest",
                    "Хеш резервной копии не совпадает.",
                ));
            }
            let mut repo: Repository = serde_json::from_value(bundle.payload)
                .map_err(|_| failure("backup_format", "Неверный формат данных проекта."))?;
            validate_backup(&repo)?;
            let a = actor(&state)?;
            let current = repo.current.get(&a.id).cloned().or_else(|| {
                repo.logs
                    .values()
                    .max_by_key(|l| l.analysis_version)
                    .map(|l| l.id.clone())
            });
            repo.current.clear();
            if let Some(id) = current {
                repo.current.insert(a.id.clone(), id);
            }
            repo.user_views.clear();
            let p = platform(&state)?;
            let name = fields
                .get("name")
                .map_or("Восстановленный проект", String::as_str);
            p.auth.restore_project(
                &a,
                name,
                serde_json::to_value(repo).map_err(|_| {
                    failure("backup_format", "Не удалось подготовить восстановление.")
                })?,
            )
        })
        .await
        {
            Ok(id) => page(
                "Проект восстановлен",
                format!(
                    "<h1>Копия восстановлена в отдельный проект</h1><p>{}</p><form method=\"post\" action=\"/projects/{id}/open\"><button>Открыть восстановленный проект</button></form>",
                    render::html_escape(&id)
                ),
            ),
            Err(e) => response_error(e),
        },
        Err(e) => response_error(e),
    }
}
