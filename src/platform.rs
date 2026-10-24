//! Project-scoped local platform. Database operations run only on blocking workers.
use crate::{
    auth::{Actor, Auth, ProjectListChange, Role},
    bpmn::ProcessModel,
    calendar::CalendarSpec,
    csv_io::{self, CsvMapping, NormalizationOrder},
    domain::ImportError,
    filters::FilterSpec,
    jobs::JobStore,
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
#[serde(deny_unknown_fields)]
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
    conversion_jobs: Arc<JobStore>,
}
struct PendingCsv {
    bytes: Vec<u8>,
    filename: String,
    delimiter: u8,
    user: String,
    project: String,
    expires: i64,
}
struct PendingXes {
    raw: Option<Arc<String>>,
    filename: String,
    user: String,
    project: String,
    expires: i64,
    status: PreviewStatus,
}
enum PreviewStatus {
    Ready,
    Confirming,
    Completed(String),
    Uncertain,
}
pub(crate) struct Platform {
    pub database: Database,
    pub auth: Auth,
    workspaces: Mutex<BTreeMap<String, Cached>>,
    slots: Arc<Semaphore>,
    pub(crate) resources: crate::resource_cache::ResourceCache,
    pub(crate) payload_slots: Arc<Semaphore>,
    pending: Mutex<BTreeMap<String, PendingCsv>>,
    pending_xes: Mutex<BTreeMap<String, PendingXes>>,
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
            resources: crate::resource_cache::ResourceCache::new(),
            payload_slots: Arc::new(Semaphore::new(2)),
            pending: Mutex::new(BTreeMap::new()),
            pending_xes: Mutex::new(BTreeMap::new()),
        };
        let projects = platform.auth.all_projects();
        for (id, _, value) in platform.database.project_headers()? {
            if !projects.iter().any(|project| project.id == id) {
                return Err(failure(
                    "repository_corrupt",
                    "Проект не принадлежит учётным записям.",
                ));
            }
            crate::repository_v2::Header::parse(value)?;
        }
        for project in projects {
            platform.recover_metadata(&project.id)?;
        }
        Ok(platform)
    }
    fn recover_metadata(&self, id: &str) -> Result<(), ImportError> {
        if let Some((revision, value)) = self.database.project_header(id)? {
            let mut header = crate::repository_v2::Header::parse(value)?;
            let keys: std::collections::BTreeSet<_> =
                self.database.record_keys(id)?.into_iter().collect();
            let expected: std::collections::BTreeSet<_> = header
                .log_ids
                .iter()
                .flat_map(|id| {
                    ["log_state", "log_data", "log_source", "log_analysis"]
                        .map(|kind| (kind.to_string(), id.clone()))
                })
                .chain(
                    header
                        .conversions
                        .values()
                        .map(|m| ("conversion".into(), m.artifact_id.clone())),
                )
                .chain(
                    header
                        .model_ids
                        .iter()
                        .map(|id| ("model".into(), id.clone())),
                )
                .collect();
            if keys != expected {
                return Err(failure(
                    "repository_corrupt",
                    "Неполный набор записей проекта.",
                ));
            }
            let interrupted = header
                .durable_jobs
                .values()
                .filter(|job| !job.is_terminal())
                .map(|job| job.id.clone())
                .chain(
                    header
                        .conversions
                        .values()
                        .filter(|m| !m.snapshot.is_terminal())
                        .map(|m| m.snapshot.id.clone()),
                )
                .collect();
            if header.recover() {
                let mut recovery_parameters = json!({"policy":"nonterminal_to_failed_after_restart","jobs":header.durable_jobs});
                if !header.conversions.is_empty() {
                    recovery_parameters["conversions"] = json!(header.conversions);
                }
                header.audit.append_business(
                    "system",
                    id,
                    "jobs_interrupted_after_restart",
                    interrupted,
                    revision
                        .checked_add(1)
                        .ok_or_else(|| failure("storage_conflict", "Счётчик проекта исчерпан."))?,
                    &recovery_parameters,
                )?;
                self.database
                    .write_project(crate::normalized::ProjectWrite {
                        project: id.into(),
                        expected: revision,
                        metadata: header.value()?,
                        puts: vec![],
                        deletes: vec![],
                    })?;
            }
        }
        Ok(())
    }
    fn recover_repository(&self, id: &str, repository: &mut Repository) -> Result<(), ImportError> {
        let mut header = crate::repository_v2::header(repository);
        let interrupted = header
            .durable_jobs
            .values()
            .filter(|job| !job.is_terminal())
            .map(|job| job.id.clone())
            .chain(
                header
                    .conversions
                    .values()
                    .filter(|m| !m.snapshot.is_terminal())
                    .map(|m| m.snapshot.id.clone()),
            )
            .collect();
        if header.recover() {
            repository.durable_jobs = header.durable_jobs;
            repository.conversions = header.conversions;
            let mut recovery_parameters = json!({"policy":"nonterminal_to_failed_after_restart","jobs":repository.durable_jobs});
            if !repository.conversions.is_empty() {
                recovery_parameters["conversions"] = json!(repository.conversions);
            }
            repository.audit.append_business(
                "system",
                id,
                "jobs_interrupted_after_restart",
                interrupted,
                repository
                    .storage_revision
                    .checked_add(1)
                    .ok_or_else(|| failure("storage_conflict", "Счётчик проекта исчерпан."))?,
                &recovery_parameters,
            )?;
            let write = crate::repository_v2::prepare(id, repository, false)?;
            repository.storage_revision = self.database.write_project(write)?;
            crate::repository_v2::mark_persisted(repository);
        }
        Ok(())
    }
    fn load(&self, id: &str) -> Result<(), ImportError> {
        if self
            .workspaces
            .lock()
            .expect("workspace mutex")
            .contains_key(id)
        {
            return Ok(());
        }
        let mut repository = crate::repository_v2::load_metadata(&self.database, id)?;
        self.recover_repository(id, &mut repository)?;
        let snapshots = repository
            .durable_jobs
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let jobs = Arc::new(JobStore::restore_with_slots(&snapshots, self.slots.clone()));
        let conversion_snapshots = repository
            .conversions
            .values()
            .map(|m| m.snapshot.clone())
            .collect::<Vec<_>>();
        let conversion_jobs = Arc::new(JobStore::restore_with_slots(
            &conversion_snapshots,
            self.slots.clone(),
        ));
        self.workspaces
            .lock()
            .expect("workspace mutex")
            .entry(id.into())
            .or_insert_with(|| Cached {
                repository: Arc::new(Mutex::new(repository)),
                jobs,
                conversion_jobs,
            });
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
        state.conversion_jobs = cached.conversion_jobs.clone();
        state.actor = Some(actor);
        Ok(state)
    }
}
fn failure(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
#[path = "xes_workflow.inc.rs"]
mod xes_workflow;
use xes_workflow::*;
#[path = "folder_workflow.rs"]
mod folder_workflow;
use folder_workflow::*;
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
fn current_session(state: &AppState) -> Result<&str, ImportError> {
    state
        .session
        .as_deref()
        .ok_or_else(|| failure("access_denied", "Войдите в проект."))
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
        "project_capacity" => StatusCode::PAYLOAD_TOO_LARGE,
        "storage_conflict"
        | "model_conflict"
        | "preview_conflict"
        | "project_conflict"
        | "project_list_conflict" => StatusCode::CONFLICT,
        "storage_unavailable" | "storage_busy" | "confirmation_uncertain" => {
            StatusCode::SERVICE_UNAVAILABLE
        }
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
pub(crate) fn page(title: &str, body: String) -> Response {
    let nonce = uuid::Uuid::new_v4().simple().to_string();
    let nav = "<nav><a href=\"/\">Анализ</a> · <a href=\"/projects\">Проекты</a> · <a href=\"/folders\">Папки</a> · <a href=\"/audit\">История</a> · <a href=\"/logs\">Журналы</a> · <a href=\"/csv\">CSV</a> · <a href=\"/conversions\">Преобразования</a> · <a href=\"/models\">BPMN</a> · <a href=\"/backup\">Резервная копия</a><form method=\"post\" action=\"/logout\"><button>Выйти</button></form></nav>";
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
        .route("/project-list/json", get(project_list_json))
        .route(
            "/project-list/folders",
            post(project_list_create).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/project-list/folders/{id}/rename",
            post(project_list_rename).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/project-list/folders/{id}/move",
            post(project_list_move).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/project-list/folders/{id}/archive",
            post(project_list_archive).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/project-list/folders/{id}/unarchive",
            post(project_list_unarchive).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/project-list/folders/{id}/delete",
            post(project_list_delete).layer(DefaultBodyLimit::max(4096)),
        )
        .route(
            "/projects/{id}/move",
            post(move_project_in_list).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/projects/{id}/open", post(open_project))
        .route("/projects/{id}/members", post(membership))
        .route("/projects/{id}/rename", post(rename_project))
        .route("/projects/{id}/archive", post(archive_project))
        .route("/projects/{id}/unarchive", post(unarchive_project))
        .route(
            "/projects/{id}/delete",
            get(project_delete_preview)
                .post(project_delete)
                .layer(DefaultBodyLimit::max(4096)),
        )
        .route("/audit", get(audit_page))
        .route("/audit/export", get(audit_export))
        .route("/folders", get(folders_page).post(folder_create))
        .route("/folders/json", get(folders_json))
        .route("/folders/assign", post(folder_assign))
        .route("/folders/{id}/rename", post(folder_rename))
        .route("/folders/{id}/move", post(folder_move))
        .route("/folders/{id}/delete", post(folder_delete))
        .route(
            "/users",
            post(create_user).layer(DefaultBodyLimit::max(4096)),
        )
        .route("/logs", get(logs))
        .route("/csv", get(csv_form))
        .route("/csv/preview", post(csv_preview))
        .route("/csv/import", post(csv_import))
        .route("/xes", get(xes_form))
        .route("/xes/preview", post(xes_preview))
        .route("/xes/previews/{token}/report", get(xes_report))
        .route("/xes/import", post(xes_import))
        .route("/xes/cancel", post(xes_cancel))
        .route("/logs/{id}/original", get(original_xes))
        .route("/logs/{id}/import-history", get(import_history))
        .route("/logs/{id}/import-history/view", get(import_history_view))
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
        .route("/diagnostics/cache", get(cache_stats))
}
async fn cache_stats(Workspace(state): Workspace) -> Response {
    match (platform(&state),actor(&state)) {
        (Ok(p),Ok(actor)) if actor.admin=>Json(json!({"cache":p.resources.stats(),"active_payload_operations":2usize.saturating_sub(p.payload_slots.available_permits()),"active_limit":2,"charged_byte_limit":crate::resource_cache::BYTE_LIMIT,"entry_limit":crate::resource_cache::ENTRY_LIMIT,"scope":"retained cache estimate; active payloads/jobs/uploads/allocator excluded"})).into_response(),
        _=>response_error(failure("access_denied","Диагностика доступна администратору.")),
    }
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
    match blocking(move || {
        let a = actor(&state)?;
        let view = platform(&state)?
            .auth
            .project_list_view(&a, current_session(&state)?)?;
        Ok((a, view))
    })
    .await
    {
        Ok((a, view)) => page("Проекты", render::projects(&a, &view.projects, &view)),
        Err(e) => response_error(e),
    }
}

async fn project_list_json(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        let a = actor(&state)?;
        let view = platform(&state)?
            .auth
            .project_list_view(&a, current_session(&state)?)?;
        let projects = view
            .projects
            .iter()
            .filter_map(|project| {
                project.members.get(&a.id).map(|role| {
                    json!({
                        "id":project.id,"name":project.name,"revision":project.revision,
                        "archived":project.archived,"role":role,
                        "folder_id":view.project_folders.get(&project.id)
                    })
                })
            })
            .collect::<Vec<_>>();
        Ok(json!({"revision":view.revision,"folders":view.folders,
            "project_folders":view.project_folders,"projects":projects}))
    })
    .await
    {
        Ok(view) => Json(view).into_response(),
        Err(e) => response_error(e),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectListCreateForm {
    catalog_revision: u64,
    name: String,
    #[serde(default)]
    parent: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectListRenameForm {
    catalog_revision: u64,
    name: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectListParentForm {
    catalog_revision: u64,
    #[serde(default)]
    parent: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectListRevisionForm {
    catalog_revision: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectListAssignmentForm {
    catalog_revision: u64,
    project_revision: u64,
    #[serde(default)]
    destination: String,
}

async fn change_project_list(
    state: AppState,
    revision: u64,
    change: ProjectListChange,
) -> Response {
    match blocking(move || {
        platform(&state)?.auth.change_project_list(
            &actor(&state)?,
            current_session(&state)?,
            revision,
            change,
        )
    })
    .await
    {
        Ok(_) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn project_list_create(
    Workspace(state): Workspace,
    Form(form): Form<ProjectListCreateForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Create {
            name: form.name,
            parent: (!form.parent.is_empty()).then_some(form.parent),
        },
    )
    .await
}
async fn project_list_rename(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListRenameForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Rename {
            id,
            name: form.name,
        },
    )
    .await
}
async fn project_list_move(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListParentForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Move {
            id,
            parent: (!form.parent.is_empty()).then_some(form.parent),
        },
    )
    .await
}
async fn project_list_archive(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListRevisionForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Archive { id, archived: true },
    )
    .await
}
async fn project_list_unarchive(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListRevisionForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Archive {
            id,
            archived: false,
        },
    )
    .await
}
async fn project_list_delete(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListRevisionForm>,
) -> Response {
    change_project_list(
        state,
        form.catalog_revision,
        ProjectListChange::Delete { id },
    )
    .await
}
async fn move_project_in_list(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectListAssignmentForm>,
) -> Response {
    match blocking(move || {
        platform(&state)?.auth.move_project_in_list(
            &actor(&state)?,
            current_session(&state)?,
            &id,
            (!form.destination.is_empty()).then_some(form.destination.as_str()),
            form.catalog_revision,
            form.project_revision,
        )
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(e) => response_error(e),
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
            .create_project(&actor(&state)?, current_session(&state)?, &form.name)
    })
    .await
    {
        Ok(_) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RenameProjectForm {
    name: String,
    revision: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectRevisionForm {
    revision: u64,
}
async fn rename_project(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<RenameProjectForm>,
) -> Response {
    match blocking(move || {
        platform(&state)?.auth.rename_project(
            &actor(&state)?,
            state
                .session
                .as_deref()
                .ok_or_else(|| failure("access_denied", "Войдите в проект."))?,
            &id,
            &form.name,
            form.revision,
        )
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn archive_project(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectRevisionForm>,
) -> Response {
    change_archive(state, id, true, form.revision).await
}
async fn unarchive_project(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectRevisionForm>,
) -> Response {
    change_archive(state, id, false, form.revision).await
}
async fn change_archive(
    state: AppState,
    id: String,
    archived: bool,
    expected_revision: u64,
) -> Response {
    match blocking(move || {
        platform(&state)?.auth.set_archived(
            &actor(&state)?,
            state
                .session
                .as_deref()
                .ok_or_else(|| failure("access_denied", "Войдите в проект."))?,
            &id,
            archived,
            expected_revision,
        )
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn audit_export(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?; let a = actor(&state)?; let p = platform(&state)?;
        let repo = state.repository.lock().expect("repository");
        Ok(json!({"schema_version":2,"scope":"server business mutations committed; legacy policy/outcome unknown; client project-backup history explicitly unverified; retained last512 per scope","project_id":a.project_id,"project_total":repo.audit.total,"project_dropped":repo.audit.total.saturating_sub(repo.audit.entries.len() as u64),"project_entries":repo.audit.entries,"auth_owner_projection":p.auth.audit(&a),"deletion_owner_projection":p.auth.deletion_audit(&a,current_session(&state)?)?}))
    }).await { Ok(report) => Json(report).into_response(), Err(e) => response_error(e) }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectDeleteForm {
    confirmation_id: String,
    phrase: String,
    revision: u64,
    digest: String,
}
async fn project_delete_preview(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        let preview = platform(&state)?.auth.deletion_preview(
            &actor(&state)?,
            current_session(&state)?,
            &id,
        )?;
        Ok(render::project_delete(&preview))
    })
    .await
    {
        Ok(body) => page("Постоянное удаление проекта", body),
        Err(error) => response_error(error),
    }
}
async fn project_delete(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<ProjectDeleteForm>,
) -> Response {
    match blocking(move || {
        let p = platform(&state)?;
        p.auth.delete_project(
            &actor(&state)?,
            current_session(&state)?,
            &id,
            crate::auth::ProjectDeletionConfirmation {
                id: &form.confirmation_id,
                phrase: &form.phrase,
                revision: form.revision,
                digest: &form.digest,
            },
        )?;
        // These maps are retired only after the atomic commit was acknowledged.
        // Captured requests still recheck current Auth before any publication.
        p.workspaces.lock().expect("workspace mutex").remove(&id);
        p.pending
            .lock()
            .expect("pending CSV mutex")
            .retain(|_, pending| pending.project != id);
        p.pending_xes
            .lock()
            .expect("pending XES mutex")
            .retain(|_, pending| pending.project != id);
        p.resources.invalidate_project(&id);
        Ok(())
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(error) => response_error(error),
    }
}
async fn audit_page(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let a = actor(&state)?;
        let p = platform(&state)?;
        let repo = state.repository.lock().expect("repository");
        Ok(render::audit(
            &repo.audit,
            &json!({"project_auth":p.auth.audit(&a),
            "deleted_projects":p.auth.deletion_audit(&a,current_session(&state)?)?}),
        ))
    })
    .await
    {
        Ok(body) => page("История действий", body),
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
        platform(&state)?.auth.grant(
            &actor(&state)?,
            current_session(&state)?,
            &id,
            &form.username,
            form.role,
        )
    })
    .await
    {
        Ok(()) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn create_user(Workspace(state): Workspace, Form(form): Form<Credentials>) -> Response {
    match blocking(move || {
        platform(&state)?.auth.add_user(
            &actor(&state)?,
            current_session(&state)?,
            &form.username,
            &form.password,
        )
    })
    .await
    {
        Ok(_) => redirect("/projects"),
        Err(e) => response_error(e),
    }
}
async fn logs(Workspace(state): Workspace) -> Response {
    let writable = state.actor.as_ref().is_some_and(|a| a.role.can_write());
    let items = match blocking(move || {
        let a = actor(&state)?;
        platform(&state)?
            .database
            .resource_summaries(&a.project_id)
            .map(|items| {
                items
                    .into_iter()
                    .filter(|item| item.kind == "log_state")
                    .collect::<Vec<_>>()
            })
    })
    .await
    {
        Ok(items) => items,
        Err(e) => return response_error(e),
    };
    page("Журналы", render::logs_list(&items, writable))
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
        let log = crate::web::store_log_with_policy(
            &state,
            data,
            analysis,
            filename,
            start.elapsed().as_millis(),
            sha256(&bytes),
            form.order,
            None,
            None,
            Some(serde_json::json!({"format":"csv","mapping":mapping})),
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
        let log = match log {
            Ok(Some(log))=>log,Ok(None)=>return response_error(failure("not_found", "Журнал не найден.")),Err(e)=>return response_error(e),
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
    let mut repo = state.repository.lock().expect("repository mutex");
    match repo.get_log(&state, &id) {
        Ok(Some(log)) => page(
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
        Ok(None) => response_error(failure("not_found", "Журнал не найден.")),
        Err(e)=>response_error(e),
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
        let mut log = repo
            .get_log_base(&state, &id)?
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let mut next = repo.clone();
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
        state.commit_action_resources(&mut next, "filter_applied", vec![id.clone()])?;
        *repo = next;
        Ok(id)
    })
    .await;
    match result {
        Ok(id) => redirect(&format!("/logs/{id}")),
        Err(e) => response_error(e),
    }
}
#[derive(Clone, Deserialize)]
struct CalendarForm {
    #[serde(default)]
    timezone: String,
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
    headers: HeaderMap,
    Form(form): Form<CalendarForm>,
) -> Response {
    let html_draft = (calendar_html_requested(&headers)
        && form.timezone.len() + form.weekdays.len() + form.holidays.len() <= 16 * 1024)
        .then(|| form.clone());
    let error_state = state.clone();
    let error_id = id.clone();
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
            timezone: (!form.timezone.trim().is_empty()).then_some(form.timezone),
            offset_minutes: form.offset_minutes,
            weekdays,
            start_minute: form.start_minute,
            end_minute: form.end_minute,
            holidays,
        };
        let now = chrono::Utc::now();
        crate::calendar::business_millis(now, now, &spec)?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let mut log = repo
            .get_log_base(&state, &id)?
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let mut next = repo.clone();
        log.calendar = spec;
        next.logs.insert(id.clone(), log);
        state.commit_action_resources(&mut next, "calendar_changed", vec![id.clone()])?;
        *repo = next;
        Ok(id)
    })
    .await;
    match result {
        Ok(id) => redirect(&format!("/logs/{id}/tools")),
        Err(e) => match html_draft {
            Some(draft)
                if matches!(
                    e.code.as_str(),
                    "calendar" | "calendar_policy" | "calendar_timezone"
                ) =>
            {
                tokio::task::spawn_blocking(move || {
                    calendar_form_error(&error_state, &error_id, &draft, e)
                })
                .await
                .unwrap_or_else(|_| {
                    response_error(failure(
                        "worker_failed",
                        "Не удалось подготовить результат.",
                    ))
                })
            }
            _ => response_error(e),
        },
    }
}
// Deliberately conservative opt-in: an explicit positive JSON range wins, while
// wildcards never enable HTML. Invalid quality parameters keep the original API.
fn calendar_html_requested(headers: &HeaderMap) -> bool {
    let mut html = false;
    let mut json = false;
    for value in headers.get_all(header::ACCEPT).iter() {
        let Ok(value) = value.to_str() else {
            return false;
        };
        for range in value.split(',') {
            let mut parts = range.split(';');
            let media = parts.next().unwrap_or("").trim();
            let mut positive = true;
            let mut seen_quality = false;
            for parameter in parts {
                let Some((name, value)) = parameter.trim().split_once('=') else {
                    return false;
                };
                if name.trim().eq_ignore_ascii_case("q") {
                    if seen_quality {
                        return false;
                    }
                    seen_quality = true;
                    let value = value.trim();
                    let valid = value == "0"
                        || value == "1"
                        || value.strip_prefix("0.").is_some_and(|fraction| {
                            fraction.len() <= 3 && fraction.bytes().all(|b| b.is_ascii_digit())
                        })
                        || value.strip_prefix("1.").is_some_and(|fraction| {
                            fraction.len() <= 3 && fraction.bytes().all(|b| b == b'0')
                        });
                    if !valid {
                        return false;
                    }
                    positive = value
                        .bytes()
                        .any(|b| b == b'1' || (b'2'..=b'9').contains(&b));
                }
            }
            if positive && media.eq_ignore_ascii_case("text/html") {
                html = true;
            }
            if positive && media.eq_ignore_ascii_case("application/json") {
                json = true;
            }
        }
    }
    html && !json
}
fn calendar_form_error(
    state: &AppState,
    id: &str,
    form: &CalendarForm,
    error: ImportError,
) -> Response {
    let mut repo = state.repository.lock().expect("repository mutex");
    let log = match repo.get_log_base(state, id) {
        Ok(Some(log)) => log,
        Ok(None) => return response_error(failure("not_found", "Журнал не найден.")),
        Err(error) => return response_error(error),
    };
    let draft = render::CalendarDraft {
        timezone: &form.timezone,
        offset_minutes: form.offset_minutes,
        weekdays: &form.weekdays,
        start_minute: form.start_minute,
        end_minute: form.end_minute,
        holidays: &form.holidays,
    };
    let body = format!(
        "<h1>{}</h1><div class=\"platform-alert\" role=\"alert\" tabindex=\"-1\" autofocus><strong>Настройки не сохранены.</strong> {}</div><p>Исправьте введённые значения. Расчёт ниже использует последний сохранённый календарь.</p>{}<h2>Результаты по последнему сохранённому календарю</h2>{}",
        render::html_escape(&log.filename),
        render::html_escape(&error.message),
        render::calendar_form(id, &draft),
        render::calendar_table(&calendar_results(&log))
    );
    let mut response = page("Исправить календарь", body);
    *response.status_mut() = StatusCode::UNPROCESSABLE_ENTITY;
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        "no-store".parse().expect("static header"),
    );
    response
        .headers_mut()
        .insert(header::VARY, "Accept".parse().expect("static header"));
    // get_log_base validates the read first. Acquire the auth lock only for the
    // final handoff, never recursively while loading or calculating a log.
    match (&state.platform, &state.actor, &state.session) {
        (Some(platform), Some(actor), Some(session)) => platform
            .auth
            .with_write_access(session, actor, || Ok(response))
            .unwrap_or_else(response_error),
        (None, None, _) => response,
        _ => response_error(failure("access_denied", "Сначала войдите в проект.")),
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
    if repo.model_count() >= 64 {
        return Err(failure("model_limit", "Максимум 64 модели в проекте."));
    }
    let mut next = repo.clone();
    next.sequence += 1;
    let mut fallback = next.sequence;
    let id = loop {
        let id = format!("model-{}", state.next_id(fallback)?);
        if !next.contains_model(&id) {
            break id;
        }
        fallback += 1;
    };
    next.models.insert(
        id.clone(),
        Arc::new(StoredModel {
            id: id.clone(),
            name,
            revision: 1,
            model,
            source_log,
        }),
    );
    state.commit_action_resources(&mut next, "model_created", vec![id.clone()])?;
    *repo = next;
    Ok(id)
}
async fn models(Workspace(state): Workspace) -> Response {
    let writable = state.actor.as_ref().is_some_and(|a| a.role.can_write());
    let items = match blocking(move || {
        let a = actor(&state)?;
        platform(&state)?
            .database
            .resource_summaries(&a.project_id)
            .map(|items| {
                items
                    .into_iter()
                    .filter(|item| item.kind == "model")
                    .map(|item| (item.id, item.name, item.number))
                    .collect::<Vec<_>>()
            })
    })
    .await
    {
        Ok(items) => items,
        Err(e) => return response_error(e),
    };
    page("BPMN", render::models_list(&items, writable))
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
            .get_log_base(&state, &id)?
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
    tokio::task::spawn_blocking(move || {
        let mut repo = state.repository.lock().expect("repository mutex");
        match repo.get_model(&state, &id) {
            Ok(Some(m)) => page(
                "Модель BPMN",
                render::model_editor(
                    &id,
                    &m.model,
                    m.revision,
                    state.actor.as_ref().is_some_and(|a| a.role.can_write()),
                ),
            ),
            Ok(None) => response_error(failure("not_found", "Модель не найдена.")),
            Err(e) => response_error(e),
        }
    })
    .await
    .unwrap_or_else(|_| response_error(failure("worker_failed", "Не удалось открыть модель.")))
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
        let mut saved = repo
            .get_model(&state, &id)?
            .ok_or_else(|| failure("not_found", "Модель не найдена."))?;
        let mut next = repo.clone();
        if saved.revision != form.revision {
            return Err(failure(
                "model_conflict",
                "Модель изменена. Откройте её заново.",
            ));
        }
        crate::bpmn::validate_edit(&saved.model, &model)?;
        model.discovery = saved.model.discovery.clone();
        let saved_mut = Arc::make_mut(&mut saved);
        saved_mut.model = model;
        saved_mut.revision += 1;
        next.models.insert(id.clone(), saved);
        state.commit_action_resources(&mut next, "model_saved", vec![id.clone()])?;
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
    tokio::task::spawn_blocking(move || {
        let mut repo = state.repository.lock().expect("repository mutex");
        match repo.get_model(&state, &id) {
            Ok(Some(m)) => match crate::bpmn::serialize(&m.model) {
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
            Ok(None) => response_error(failure("not_found", "Модель не найдена.")),
            Err(e) => response_error(e),
        }
    })
    .await
    .unwrap_or_else(|_| response_error(failure("worker_failed", "Не удалось открыть модель.")))
}
async fn model_json(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    tokio::task::spawn_blocking(move || {
        let mut repo = state.repository.lock().expect("repository mutex");
        match repo.get_model(&state, &id) {
            Ok(Some(m)) => Json(m.as_ref()).into_response(),
            Ok(None) => response_error(failure("not_found", "Модель не найдена.")),
            Err(e) => response_error(e),
        }
    })
    .await
    .unwrap_or_else(|_| response_error(failure("worker_failed", "Не удалось открыть модель.")))
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
        if repo.durable_jobs.values().any(|job| !job.is_terminal()) || repo.conversions.values().any(|m| !m.snapshot.is_terminal()) {
            return Err(failure(
                "backup_busy",
                "Дождитесь завершения или отмены фоновых задач перед созданием резервной копии.",
            ));
        }
        let full=crate::repository_v2::load(&platform(&state)?.database,&a.project_id)?;
        if full.storage_revision!=repo.storage_revision {return Err(failure("storage_conflict","Проект изменился во время подготовки копии."));}
        let payload = serde_json::to_value(&full)
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
    crate::repository_v2::header(repo).validate()?;
    crate::conversion_workflow::validate_full(repo)?;
    repo.audit.validate()?;
    repo.organization.validate(&repo.resource_catalog())?;
    if repo.logs.len() > 8 || repo.models.len() > 64 || repo.durable_jobs.len() > 10 {
        return Err(failure("backup_limit", "В копии превышены лимиты проекта."));
    }
    for (id, log) in &repo.logs {
        if let Some(provenance) = &log.provenance {
            provenance.validate(&log.source, &log.source_sha256)?;
            if log.order != NormalizationOrder::Source {
                return Err(failure(
                    "backup_invalid",
                    "Политика импорта не соответствует исходнику.",
                ));
            }
        }
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
        let mut normalized_source = log.source.as_ref().clone();
        crate::csv_io::normalize(&mut normalized_source, log.order)?;
        if serde_json::to_value(&normalized_source).ok()
            != serde_json::to_value(log.source.as_ref()).ok()
        {
            return Err(failure(
                "backup_invalid",
                "Порядок событий не соответствует политике копии.",
            ));
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
pub(crate) fn exportable_model(model: &ProcessModel) -> Result<(), ImportError> {
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
                current_session(&state)?,
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
