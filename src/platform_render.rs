//! Pure HTML renderers. Route authorization and persistence belong to platform.
use crate::{
    auth::{Actor, Project, ProjectListView, Role},
    bpmn::ProcessModel,
    calendar::CalendarSpec,
    csv_io::CsvPreview,
    filters::FilterSpec,
    project_list::ListFolder,
};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
fn role_label(role: Role) -> &'static str {
    match role {
        Role::Owner => "Владелец",
        Role::Editor => "Редактор",
        Role::Viewer => "Наблюдатель",
    }
}
fn route_id(id: &str) -> String {
    id.bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.') {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

fn list_path(view: &ProjectListView, folder: Option<&str>) -> (String, bool) {
    let folders = view
        .folders
        .iter()
        .map(|folder| (folder.id.as_str(), folder))
        .collect::<BTreeMap<_, _>>();
    let mut cursor = folder;
    let mut parts = Vec::new();
    let mut archived = false;
    let mut seen = BTreeSet::new();
    while let Some(id) = cursor {
        if !seen.insert(id) || seen.len() > 64 {
            break;
        }
        let Some(folder) = folders.get(id) else {
            break;
        };
        archived |= folder.archived;
        parts.push(folder.name.as_str());
        cursor = folder.parent_id.as_deref();
    }
    parts.reverse();
    (
        if parts.is_empty() {
            "Корень списка".into()
        } else {
            parts.join(" / ")
        },
        archived,
    )
}

fn active_destination(
    view: &ProjectListView,
    actor: &Actor,
    folder: &ListFolder,
    moving: Option<&str>,
) -> bool {
    let folders = view
        .folders
        .iter()
        .map(|folder| (folder.id.as_str(), folder))
        .collect::<BTreeMap<_, _>>();
    let mut cursor = Some(folder.id.as_str());
    let mut seen = BTreeSet::new();
    while let Some(id) = cursor {
        if Some(id) == moving || !seen.insert(id) || seen.len() > 64 {
            return false;
        }
        let Some(folder) = folders.get(id) else {
            return false;
        };
        if folder.owner_id != actor.id || folder.archived {
            return false;
        }
        cursor = folder.parent_id.as_deref();
    }
    true
}

fn destination_options(
    view: &ProjectListView,
    actor: &Actor,
    selected: Option<&str>,
    moving: Option<&str>,
) -> String {
    let mut html = format!(
        "<option value=\"\" {}>Корень списка</option>",
        if selected.is_none() { "selected" } else { "" }
    );
    for folder in &view.folders {
        if !active_destination(view, actor, folder, moving) {
            continue;
        }
        let (label, _) = list_path(view, Some(&folder.id));
        html.push_str(&format!(
            "<option value=\"{}\" {}>{}</option>",
            html_escape(&folder.id),
            if selected == Some(folder.id.as_str()) {
                "selected"
            } else {
                ""
            },
            html_escape(&label)
        ));
    }
    html
}

fn project_placement(actor: &Actor, project: &Project, view: &ProjectListView) -> String {
    if !actor.role.can_write() || project.members.get(&actor.id) != Some(&Role::Owner) {
        return String::new();
    }
    let options = destination_options(
        view,
        actor,
        view.project_folders.get(&project.id).map(String::as_str),
        None,
    );
    format!(
        "<tr><td colspan=\"3\"><details><summary>Переместить проект в папку списка</summary><form class=\"platform-form\" method=\"post\" action=\"/projects/{}/move\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><input type=\"hidden\" name=\"project_revision\" value=\"{}\"><label>Куда переместить<select name=\"destination\">{options}</select></label><small>Участники, права, журналы и модели сохранятся. Вернуть свой проект в корень можно из любой папки.</small><button class=\"button\">Переместить проект</button></form></details></td></tr>",
        route_id(&project.id),
        view.revision,
        project.revision
    )
}

fn project_list_folders(actor: &Actor, view: &ProjectListView) -> String {
    let mut html = String::from(
        "<section class=\"platform-card\" id=\"project-list-folders\"><h2>Папки списка проектов</h2><p>Эти папки упорядочивают список проектов. Права остаются у участников каждого проекта и не наследуются от папки. Папки внутри проекта доступны отдельно в разделе «Папки проекта».</p><p>Архив папки сохраняет доступ к проектам, но запрещает добавлять проекты и папки в её ветку.</p>",
    );
    if actor.role.can_write() {
        let options = destination_options(view, actor, None, None);
        html.push_str(&format!("<form class=\"platform-form\" method=\"post\" action=\"/project-list/folders\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><label>Название папки<input name=\"name\" required maxlength=\"200\"></label><label>Родительская папка<select name=\"parent\">{options}</select></label><button class=\"button\">Создать папку списка</button></form>", view.revision));
    }
    if view.folders.is_empty() {
        html.push_str("<p>Папок пока нет.</p>");
    }
    for folder in &view.folders {
        let (label, archived_path) = list_path(view, Some(&folder.id));
        html.push_str(&format!(
            "<div class=\"platform-note\"><strong>{}</strong>{}",
            html_escape(&label),
            if archived_path {
                " <span class=\"platform-badge\">Папка в архивной ветке</span>"
            } else {
                ""
            }
        ));
        if actor.role.can_write() && folder.owner_id == actor.id {
            let id = route_id(&folder.id);
            let options =
                destination_options(view, actor, folder.parent_id.as_deref(), Some(&folder.id));
            html.push_str(&format!("<details><summary>Управление папкой</summary><form class=\"platform-form\" method=\"post\" action=\"/project-list/folders/{id}/rename\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><label>Название<input name=\"name\" value=\"{}\" required maxlength=\"200\"></label><button class=\"small-button\">Переименовать папку</button></form><form class=\"platform-form\" method=\"post\" action=\"/project-list/folders/{id}/move\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><label>Новая родительская папка<select name=\"parent\">{options}</select></label><button class=\"small-button\">Переместить папку</button></form>", view.revision, html_escape(&folder.name), view.revision));
            html.push_str(&format!("<form method=\"post\" action=\"/project-list/folders/{id}/{}\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><button class=\"small-button\">{}</button></form><form method=\"post\" action=\"/project-list/folders/{id}/delete\"><input type=\"hidden\" name=\"catalog_revision\" value=\"{}\"><small>Удаление доступно только для пустой папки. Проекты и дочерние папки не удаляются.</small><button class=\"small-button\">Удалить пустую папку</button></form></details>", if folder.archived { "unarchive" } else { "archive" }, view.revision, if folder.archived { "Вернуть папку из архива" } else { "Архивировать папку" }, view.revision));
        }
        html.push_str("</div>");
    }
    html.push_str("</section>");
    html
}

pub(crate) fn projects(actor: &Actor, projects: &[Project], view: &ProjectListView) -> String {
    let mut html = format!(
        "<section class=\"platform-heading\"><div class=\"eyebrow\">РАБОЧИЕ ПРОЕКТЫ</div><h1>Ваши проекты</h1><p>Вы вошли как <strong>{}</strong>. Журналы и модели доступны участникам своего проекта.</p></section><section class=\"platform-card\"><div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Проект</th><th>Ваши права</th><th>Открыть</th></tr></thead><tbody>",
        html_escape(&actor.username)
    );
    for project in projects {
        let Some(role) = project.members.get(&actor.id).copied() else {
            continue;
        };
        let id = route_id(&project.id);
        let current = project.id == actor.project_id;
        let (folder_path, archived_folder) = list_path(
            view,
            view.project_folders.get(&project.id).map(String::as_str),
        );
        let placement_label = format!(
            "<p class=\"platform-note\">Папка списка: {}{}</p>",
            html_escape(&folder_path),
            if archived_folder {
                " <span class=\"platform-badge\">Архив папки — доступ к проекту сохранён</span>"
            } else {
                ""
            }
        );
        if project.archived {
            html.push_str(&format!(
                "<tr><td>{}{placement_label} <span class=\"platform-badge\">Архив</span></td><td>{}</td><td>",
                html_escape(&project.name),
                role_label(role)
            ));
            if role == Role::Owner && actor.role.can_write() {
                html.push_str(&format!("<form method=\"post\" action=\"/projects/{id}/unarchive\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><button class=\"small-button\">Вернуть из архива</button></form>", project.revision));
                html.push_str(&format!(
                    "<p><a href=\"/projects/{id}/delete\">Проверить постоянное удаление</a></p>"
                ));
            }
            html.push_str("</td></tr>");
            html.push_str(&project_placement(actor, project, view));
            continue;
        }
        html.push_str(&format!("<tr><td>{} {}{placement_label}</td><td>{}</td><td><form method=\"post\" action=\"/projects/{id}/open\"><button class=\"small-button\" type=\"submit\">{}</button></form></td></tr>", html_escape(&project.name), if current { "<span class=\"platform-badge\">Текущий</span>" } else { "" }, role_label(role), if current { "Открыть текущий" } else { "Открыть" }));
        html.push_str(&project_placement(actor, project, view));
        if role == Role::Owner && actor.role.can_write() {
            html.push_str(&format!("<tr><td colspan=\"3\"><details><summary>Название и архив</summary><form class=\"platform-form\" method=\"post\" action=\"/projects/{id}/rename\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><label>Название проекта<input name=\"name\" value=\"{}\" required maxlength=\"200\"></label><button class=\"button\">Переименовать</button></form><form method=\"post\" action=\"/projects/{id}/archive\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><p>Архив закрывает доступ к проекту до восстановления и сохраняет данные. Для текущего проекта нужен другой доступный проект.</p><button class=\"button\">Архивировать проект</button></form></details></td></tr>", project.revision, html_escape(&project.name), project.revision));
            html.push_str(&format!("<tr><td colspan=\"3\"><details><summary>Дать доступ к проекту «{}»</summary><form class=\"platform-form\" method=\"post\" action=\"/projects/{id}/members\"><label>Имя пользователя<input name=\"username\" required maxlength=\"80\" autocomplete=\"off\"></label><label>Права<select name=\"role\"><option value=\"viewer\">Наблюдатель — просмотр и экспорт</option><option value=\"editor\">Редактор — просмотр и изменение</option></select></label><button class=\"button\" type=\"submit\">Предоставить доступ</button><small>Пользователь должен уже иметь учётную запись. Эта операция изменяет его права в выбранном проекте.</small></form></details></td></tr>", html_escape(&project.name)));
        }
    }
    html.push_str("</tbody></table></div></section>");
    html.push_str(&project_list_folders(actor, view));
    if actor.role.can_write() {
        html.push_str("<section class=\"platform-card\"><h2>Новый проект</h2><form class=\"platform-form\" method=\"post\" action=\"/projects\"><label>Название<input name=\"name\" required maxlength=\"200\" placeholder=\"Например, обработка заявок\"></label><button class=\"button primary\" type=\"submit\">Создать проект</button></form></section>");
    } else {
        html.push_str("<p class=\"platform-note\">В текущем проекте у вас права наблюдателя. Откройте проект, в котором вы владелец или редактор, чтобы создавать проекты и менять доступ.</p>");
    }
    if actor.admin && actor.role.can_write() {
        html.push_str("<section class=\"platform-card\"><h2>Добавить пользователя</h2><form class=\"platform-form\" method=\"post\" action=\"/users\"><label>Имя пользователя<input name=\"username\" required maxlength=\"80\" autocomplete=\"off\"></label><label>Пароль<input type=\"password\" name=\"password\" required minlength=\"12\" maxlength=\"256\" autocomplete=\"new-password\"></label><small>Не менее 12 латинских символов; для других символов проверяется длина в UTF-8. После создания предоставьте пользователю доступ к нужному проекту.</small><button class=\"button\" type=\"submit\">Создать учётную запись</button></form></section>");
    }
    html.push_str("<p class=\"platform-note\">Приложение доступно только на этом компьютере. Совместная работа через внешний сервер требует отдельной проверки безопасности.</p>");
    html
}

pub(crate) fn csv_upload() -> String {
    "<section class=\"platform-heading\"><div class=\"eyebrow\">ИМПОРТ ЖУРНАЛА</div><h1>Загрузить таблицу CSV</h1><p>Сначала проверьте строки и выберите колонки. Анализ начнётся после подтверждения.</p></section><section class=\"platform-card\"><form class=\"platform-form\" method=\"post\" action=\"/csv/preview\" enctype=\"multipart/form-data\"><label>Файл CSV<input type=\"file\" name=\"file\" accept=\".csv,text/csv\" required></label><label>Разделитель<select name=\"delimiter\"><option value=\"comma\">Запятая</option><option value=\"semicolon\">Точка с запятой</option><option value=\"tab\">Табуляция</option></select></label><small>UTF-8, первая строка — названия колонок. До 20 MiB и 100 000 событий. Значения с разделителем внутри должны быть заключены в кавычки.</small><button class=\"button primary\" type=\"submit\">Проверить таблицу</button></form></section>".to_owned()
}
pub(crate) fn project_delete(p: &crate::auth::ProjectDeletionPreview) -> String {
    let id = route_id(&p.project_id);
    format!(
        "<section class=\"platform-card\"><h1>Удалить проект навсегда</h1><h2>{}</h2><p>Точный ID: <code>{}</code></p><p>Будут удалены: {} журналов с исходниками и анализами, {} моделей, {} папок и доступ {} участников. Незавершённых задач: {}.</p><p><strong>Вернуть проект одной кнопкой нельзя.</strong> Без заранее сохранённой резервной копии восстановление невозможно. До удаления сохраните копию и проверьте её восстановление в новую базу. Приложение не проверяет наличие вашей копии.</p><p>Резервные копии и прежние версии PostgreSQL могут сохранить удалённые данные. Эта операция не обещает физическое стирание или немедленное уменьшение файлов на диске. У бывших владельцев останется краткое свидетельство удаления без содержимого проекта.</p><form class=\"platform-form\" method=\"post\" action=\"/projects/{id}/delete\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><input type=\"hidden\" name=\"digest\" value=\"{}\"><label>Введите точный ID проекта<input name=\"confirmation_id\" required autocomplete=\"off\"></label><label>Введите УДАЛИТЬ<input name=\"phrase\" required autocomplete=\"off\"></label><button class=\"button\" {}>Удалить проект навсегда</button></form><p><a href=\"/projects\">Отмена — вернуться к проектам</a></p></section>",
        html_escape(&p.name),
        html_escape(&p.project_id),
        p.logs,
        p.models,
        p.folders,
        p.members,
        p.active_jobs,
        p.revision,
        html_escape(&p.digest),
        if p.active_jobs == 0 { "" } else { "disabled" }
    )
}
pub(crate) fn audit(trail: &crate::audit::AuditTrail, auth: &serde_json::Value) -> String {
    let mut html = format!(
        "<section class=\"platform-card\"><h1>История действий</h1><p>Всего записей: {}. Сохранены последние {} записей; более ранних вне этого журнала: {}. Новые действия этого сервера подтверждены; результат старых записей неизвестен. История из загруженной копии не проверена: её автор, время и результат указаны в файле, а не подтверждены этим сервером. Подробные изменения импорта хранятся отдельно у журнала.</p><p><a href=\"/audit/export\">Скачать историю JSON</a></p><table class=\"platform-table\"><thead><tr><th>№</th><th>Время UTC</th><th>Действие</th><th>Кто</th><th>Ресурсы</th></tr></thead><tbody>",
        trail.total,
        trail.entries.len(),
        trail.total.saturating_sub(trail.entries.len() as u64)
    );
    for e in trail.entries.iter().rev().take(200) {
        let label = match e.action.as_str() {
            "log_imported" => "Импорт журнала",
            "xes_import_confirmed" => "Подтверждение импорта XES",
            "filter_applied" => "Изменение фильтров",
            "calendar_changed" => "Изменение календаря",
            "model_saved" => "Сохранение модели",
            "model_created" => "Создание модели",
            "folder_changed" => "Изменение папок",
            "folder_created" => "Создание папки",
            "folder_renamed" => "Переименование папки",
            "folder_moved" => "Перемещение папки",
            "folder_deleted" => "Удаление пустой папки",
            "resource_moved" => "Перемещение ресурса в папку",
            "view_changed" => "Сохранение представления",
            "job_updated" => "Изменение задачи",
            "jobs_interrupted_after_restart" => "Прерывание задач после перезапуска",
            "repository_updated" => "Обновление проекта",
            other => other,
        };
        let policy = if e.origin.is_some() {
            "История из загруженной копии — происхождение не проверено".into()
        } else {
            e.policy
                .as_ref()
                .map(|p| {
                    let rule = match p.rule.as_str() {
                        "strict_import_v1" => "Строгая проверка импорта",
                        "service_preview_confirm_v1" => {
                            "Подтверждение показанных изменений импорта"
                        }
                        "source_case_then_activity_projection_v1" => {
                            "Фильтры случаев, затем событий"
                        }
                        "half_open_business_calendar_v1" => "Расчёт по рабочему календарю",
                        "validated_model_project_cas_v1" => "Проверка модели и версии проекта",
                        "project_catalog_folder_cas_v1" => "Проверка связей папок и версии проекта",
                        "actor_private_view_v1" => "Личное представление пользователя",
                        "durable_job_transition_v1" => "Сохранение перехода задачи",
                        "restart_interrupted_job_v1" => "Восстановление задач после перезапуска",
                        _ => "Проверенная политика действия",
                    };
                    format!(
                        "{} (версия {}); отпечаток параметров {}",
                        rule, p.version, p.parameters_sha256
                    )
                })
                .unwrap_or_else(|| "Политика не сохранена в старой записи".into())
        };
        let outcome = if e.origin.is_some() {
            "Результат не подтверждён этим сервером"
        } else if e.outcome.is_some() {
            "Изменение сохранено"
        } else {
            "Результат не сохранён в старой записи"
        };
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            e.sequence,
            e.at,
            format_args!(
                "{}<br><small>{}<br>{}</small>",
                html_escape(label),
                html_escape(&policy),
                outcome
            ),
            html_escape(&e.actor),
            html_escape(&e.resources.join(", "))
        ));
    }
    html.push_str("</tbody></table><p>На странице показаны до 200 последних записей. Экспорт содержит все удерживаемые записи. Отказы и ошибки не считаются успешными изменениями.</p><details><summary>События учётных записей текущего проекта</summary><p>Владельцу доступны последние 512 событий учётных записей этого проекта. История других проектов хранится отдельно.</p><pre>");
    html.push_str(&html_escape(
        &serde_json::to_string_pretty(auth).unwrap_or_default(),
    ));
    html.push_str("</pre></details></section>");
    html
}
pub(crate) fn folders(
    org: &crate::folders::Organization,
    revision: u64,
    resources: &[(String, String)],
    writable: bool,
) -> String {
    let path = |id: &str| {
        let mut parts = Vec::new();
        let mut current = Some(id);
        // Organization is validated before rendering; retain a bounded fallback.
        for _ in 0..128 {
            let Some(folder) = current.and_then(|id| org.folders.get(id)) else {
                break;
            };
            parts.push(folder.name.as_str());
            current = folder.parent.as_deref();
        }
        parts.reverse();
        let mut label = parts.join(" / ");
        if label.len() > 512 {
            let leaf = parts.last().copied().unwrap_or_default();
            let mut boundary = 256.min(label.len());
            while !label.is_char_boundary(boundary) {
                boundary -= 1;
            }
            label = format!("{} … / {leaf}", &label[..boundary]);
        }
        // IDs distinguish literal slash-containing names and truncated paths too.
        format!("{label} [{id}]")
    };
    let options = |selected: Option<&str>| {
        let mut html = "<option value=\"\">Корень проекта</option>".to_owned();
        for id in org.folders.keys() {
            html.push_str(&format!(
                "<option value=\"{}\" {}>{}</option>",
                html_escape(id),
                if selected == Some(id.as_str()) {
                    "selected"
                } else {
                    ""
                },
                html_escape(&path(id))
            ));
        }
        html
    };
    let hidden = format!("<input type=\"hidden\" name=\"revision\" value=\"{revision}\">");
    let mut html = "<section class=\"platform-card\"><h1>Папки проекта</h1><p>Папки меняют расположение журналов и моделей в этом проекте; исходники и идентификаторы сохраняются. Перенос между проектами запрещён. Удалить можно только пустую папку без вложенных папок.</p>".to_owned();
    if writable {
        html.push_str(&format!("<h2>Новая папка</h2><form class=\"platform-form\" method=\"post\" action=\"/folders\">{hidden}<label>Название<input name=\"name\" required maxlength=\"200\"></label><label>Родитель<select name=\"parent\">{}</select></label><button class=\"button\">Создать папку</button></form>",options(None)));
    }
    html.push_str("<h2>Папки</h2><table class=\"platform-table\"><thead><tr><th>Название</th><th>Родитель</th><th>Изменить</th></tr></thead><tbody>");
    for (id, folder) in &org.folders {
        let parent = folder
            .parent
            .as_deref()
            .map_or_else(|| "Корень проекта".into(), path);
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>",
            html_escape(&path(id)),
            html_escape(&parent)
        ));
        if writable {
            html.push_str(&format!("<details><summary>Название, перенос и удаление</summary><form method=\"post\" action=\"/folders/{id}/rename\">{hidden}<input name=\"name\" value=\"{}\" required maxlength=\"200\"><button>Переименовать</button></form><form method=\"post\" action=\"/folders/{id}/move\">{hidden}<select name=\"parent\">{}</select><button>Переместить</button></form><form method=\"post\" action=\"/folders/{id}/delete\">{hidden}<button>Удалить пустую папку</button></form></details>",html_escape(&folder.name),options(folder.parent.as_deref())));
        }
        html.push_str("</td></tr>");
    }
    html.push_str("</tbody></table><h2>Журналы и модели</h2><table class=\"platform-table\"><thead><tr><th>Ресурс</th><th>Папка</th><th>Переместить</th></tr></thead><tbody>");
    for (id, name) in resources {
        let folder_id = org.assignments.get(id);
        let folder_name = folder_id.map_or_else(|| "Корень проекта".into(), |id| path(id));
        let route = if id.starts_with("log-") {
            "logs"
        } else {
            "models"
        };
        html.push_str(&format!(
            "<tr><td><a href=\"/{route}/{}\">{}</a></td><td>{}</td><td>",
            route_id(id),
            html_escape(name),
            html_escape(&folder_name)
        ));
        if writable {
            html.push_str(&format!("<form method=\"post\" action=\"/folders/assign\">{hidden}<input type=\"hidden\" name=\"resource\" value=\"{}\"><select name=\"folder\">{}</select><button>Переместить</button></form>",html_escape(id),options(folder_id.map(String::as_str))));
        }
        html.push_str("</td></tr>");
    }
    html.push_str("</tbody></table><p>До 128 папок. После изменения обновите страницу перед следующей командой.</p></section>");
    html
}
pub(crate) fn xes_upload() -> String {
    "<section class=\"platform-card\"><h1>Проверить XES перед импортом</h1><p>До подтверждения журнал не сохраняется. Правила предварительного импорта добавляют отсутствующий lifecycle=complete и удаляют события без имени или времени, события с неподдержанным lifecycle и пустые трассы. Некорректные типы, даты и дубликаты отклоняются.</p><form class=\"platform-form\" method=\"post\" action=\"/xes/preview\" enctype=\"multipart/form-data\"><label>Исходный XES<input type=\"file\" name=\"file\" accept=\".xes,application/xml\" required></label><small>До 20 MiB, 100 000 событий, 20 000 трасс. Просмотр доступен пять минут.</small><button class=\"button primary\" type=\"submit\">Показать изменения</button></form><p><a href=\"/logs\">Строгий импорт без удаления событий</a></p></section>".into()
}
pub(crate) fn xes_preview(
    token: &str,
    preview: &crate::service_preview::Preview,
    digest: &str,
    filename: &str,
) -> String {
    let remaining: usize = preview.log.cases.iter().map(|c| c.events.len()).sum();
    let defaults = preview
        .changes
        .iter()
        .filter(|c| c.action == "default_lifecycle")
        .count();
    let projection = projection_notice(&preview.projection_report);
    let mut html = format!(
        "<section class=\"platform-card\"><h1>Изменения перед импортом</h1><p>Файл: <strong>{}</strong>. Пока ничего не сохранено.</p><dl><dt>Трассы</dt><dd>{} → {}</dd><dt>События</dt><dd>{} → {remaining}</dd><dt>Добавлен lifecycle=complete</dt><dd>{defaults}</dd><dt>SHA256 исходника</dt><dd><code>{digest}</code></dd><dt>Политика</dt><dd>{}</dd></dl>{projection}<p>Исходные индексы начинаются с нуля и сохраняются после удаления. Изменения относятся к исходным событиям.</p><table class=\"platform-table\"><thead><tr><th>Трасса</th><th>Событие</th><th>Действие</th><th>Причины</th></tr></thead><tbody>",
        html_escape(filename),
        preview.source_cases,
        preview.log.cases.len(),
        preview.source_events,
        html_escape(preview.policy)
    );
    for change in preview.changes.iter().take(200) {
        let label = match change.action {
            "default_lifecycle" => "Добавлен lifecycle=complete",
            "remove_event" => "Удалено событие",
            "remove_case" => "Удалена пустая трасса",
            other => other,
        };
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            change.case_index,
            change.event_index.map_or("—".into(), |i| i.to_string()),
            html_escape(label),
            html_escape(
                &change
                    .reasons
                    .iter()
                    .map(|reason| match *reason {
                        "missing_lifecycle" => "Не указан этап lifecycle",
                        "missing_activity" => "Нет имени действия",
                        "missing_timestamp" => "Нет времени события",
                        "unsupported_lifecycle" => "Поддерживаются только start и complete",
                        "empty_case" => "В трассе не осталось событий",
                        other => other,
                    })
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        ));
    }
    html.push_str(&format!("</tbody></table><p>Показано {} из {} действий. <a href=\"/xes/previews/{token}/report\">Скачать полный отчёт JSON</a></p>", preview.changes.len().min(200), preview.changes.len()));
    if preview.fully_filtered {
        html.push_str("<p role=\"alert\"><strong>После фильтрации журнал пуст. Подтверждение недоступно.</strong> Исправьте исходный файл или выберите строгий импорт.</p>");
    } else {
        html.push_str(&format!("<form class=\"platform-form\" method=\"post\" action=\"/xes/import\"><input type=\"hidden\" name=\"token\" value=\"{token}\"><label><input type=\"checkbox\" name=\"consent\" value=\"yes\" required> Сохранить новый журнал с показанными изменениями, исходным файлом и историей импорта</label><button class=\"button primary\" type=\"submit\">Подтвердить импорт</button></form><p>После начала подтверждения отмена не принимается. Не закрывайте страницу до ответа. Повтор того же подтверждения открывает тот же журнал в течение пяти минут, пока приложение не перезапущено.</p>"));
    }
    html.push_str(&format!("<form method=\"post\" action=\"/xes/cancel\"><input type=\"hidden\" name=\"token\" value=\"{token}\"><button class=\"button\" type=\"submit\">Отменить просмотр</button></form></section>"));
    html
}

fn projection_notice(report: &crate::service_preview::ProjectionReport) -> String {
    if !report.has_omissions() && report.timestamp_offsets_normalized_to_utc == 0 {
        return String::new();
    }
    let mut html = format!(
        "<section aria-label=\"Поля вне анализа\"><h2>Какие данные не попадут в анализ</h2><p>Анализ использует имя действия, время и lifecycle. Для имён журнала и трасс используются строковые concept:name. Дополнительных полей в исходнике: журнала — {}, трасс — {}, событий — {}. Классификаторов вне анализа: {}. Объявлений расширений: {}.</p><p>Подсчёт включает весь исходный файл до удаления событий. После подтверждения исходный XES сохранится для скачивания; эти поля не будут доступны в CSV и результатах анализа.</p>",
        report.omitted_log_attributes,
        report.omitted_trace_attributes,
        report.omitted_event_attributes,
        report.ignored_classifiers,
        report.omitted_extension_declarations
    );
    if report.timestamp_offsets_normalized_to_utc > 0 {
        html.push_str(&format!("<p>У {} исходных отметок времени смещение часового пояса приводится к UTC. У сохранённых событий сам момент времени не меняется.</p>", report.timestamp_offsets_normalized_to_utc));
    }
    if !report.attributes.is_empty() {
        html.push_str("<ul>");
        for attribute in report.attributes.iter().take(20) {
            let scope = match attribute.scope {
                "log" => "Журнал",
                "trace" => "Трасса",
                _ => "Событие",
            };
            html.push_str(&format!(
                "<li>{scope}: <code>{}</code> ({}) — {}</li>",
                html_escape(&attribute.key),
                html_escape(attribute.value_type),
                attribute.occurrences
            ));
        }
        html.push_str("</ul><p>Показаны первые 20 групп полей; подробности — в отчёте JSON.</p>");
    }
    if report.unlisted_attribute_occurrences > 0 {
        html.push_str(&format!("<p>В кратком списке не перечислены ещё {} вхождений полей из-за ограничения размера отчёта. Итоговые счётчики включают их все; полные данные остаются в исходном XES.</p>", report.unlisted_attribute_occurrences));
    }
    html.push_str("</section>");
    html
}

pub(crate) fn import_history(
    id: &str,
    current_project: &str,
    provenance: &crate::import_provenance::ImportProvenance,
) -> String {
    let route = route_id(id);
    let mut html = format!(
        "<section class=\"platform-card\"><h1>История импорта</h1><p>Здесь сохранены действия при подтверждении исходного файла. Последующие фильтры и настройки журнала смотрите в истории проекта.</p><dl><dt>Подтверждено, UTC</dt><dd>{}</dd><dt>Автор исходного импорта</dt><dd>{}</dd><dt>Исходный проект</dt><dd>{}</dd><dt>Текущий проект</dt><dd>{}</dd><dt>Операция</dt><dd>{}</dd><dt>Политика</dt><dd>{}</dd><dt>SHA256 исходника</dt><dd><code>{}</code></dd><dt>Трасс / событий в исходнике</dt><dd>{} / {}</dd></dl>",
        provenance.confirmed_at,
        html_escape(&provenance.actor_id),
        html_escape(&provenance.origin_project_id),
        html_escape(current_project),
        html_escape(&provenance.operation_id),
        html_escape(&provenance.policy),
        html_escape(&provenance.source_sha256),
        provenance.source_cases,
        provenance.source_events,
    );
    if provenance.origin_project_id != current_project {
        html.push_str("<p role=\"note\"><strong>Журнал восстановлен в другой проект.</strong> Автор и исходный проект относятся к прежнему импорту; они не предоставляют доступ к текущему проекту.</p>");
    }
    html.push_str("<p>Индексы трасс и событий начинаются с нуля и относятся к исходному файлу.</p><table class=\"platform-table\"><thead><tr><th>Трасса</th><th>Событие</th><th>Действие</th><th>Причины</th></tr></thead><tbody>");
    for change in provenance.actions.iter().take(200) {
        let label = match change.action.as_str() {
            "default_lifecycle" => "Добавлен lifecycle=complete",
            "remove_event" => "Удалено событие",
            "remove_case" => "Удалена пустая трасса",
            other => other,
        };
        let reasons = change
            .reasons
            .iter()
            .map(|reason| match reason.as_str() {
                "missing_lifecycle" => "Не указан этап lifecycle",
                "missing_activity" => "Нет имени действия",
                "missing_timestamp" => "Нет времени события",
                "unsupported_lifecycle" => "Поддерживаются только start и complete",
                "empty_case" => "В трассе не осталось событий",
                other => other,
            })
            .collect::<Vec<_>>()
            .join(", ");
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            change.case_index,
            change.event_index.map_or("—".into(), |n| n.to_string()),
            html_escape(label),
            html_escape(&reasons)
        ));
    }
    html.push_str(&format!("</tbody></table><p>Показано {} из {} действий.</p><p><a href=\"/logs/{route}/original\">Скачать исходный XES</a> · <a href=\"/logs/{route}/import-history\">Скачать полную историю JSON</a> · <a href=\"/logs\">К журналам</a></p></section>", provenance.actions.len().min(200), provenance.actions.len()));
    html
}

pub(crate) fn logs_list(items: &[crate::storage::ResourceSummary], writable: bool) -> String {
    let mut html = "<section class=\"platform-heading\"><div class=\"eyebrow\">ЖУРНАЛЫ ПРОЕКТА</div><h1>Сохранённые журналы</h1><p>Журналы сохраняются после перезапуска. В проекте можно хранить восемь журналов: если место занято, новый импорт отклоняется, прежние данные остаются доступны. Одинаковые названия не объединяют результаты.</p></section><section class=\"platform-card\">".to_owned();
    if items.is_empty() {
        html.push_str("<div class=\"platform-empty\">В этом проекте пока нет журналов.</div>");
    } else {
        html.push_str("<div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Журнал</th><th>Событий</th><th>Дата сохранения (UTC)</th><th>Состояние</th><th>Анализ</th></tr></thead><tbody>");
        for item in items {
            let route = route_id(&item.id);
            let date = item
                .created_at
                .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::AutoSi, true))
                .unwrap_or_else(|| "Дата не сохранена".into());
            html.push_str(&format!("<tr><td><a href=\"/logs/{route}\">{}</a><br><small>{}</small></td><td>{}</td><td>{}</td><td>Сохранённый анализ</td><td><a href=\"/logs/{route}/tools\">Фильтры и календарь</a> · <a href=\"/logs/{route}/export\">Экспорт</a> · <a href=\"/logs/{route}/original\">Исходный XES</a> · <a href=\"/logs/{route}/import-history/view\">История импорта</a></td></tr>", html_escape(&item.name), html_escape(&item.id), item.number, html_escape(&date)));
        }
        html.push_str("</tbody></table></div>");
    }
    html.push_str("</section>");
    html.push_str("<p class=\"platform-note\">Целостность данных проверяется при открытии; незавершённые обработки находятся в задачах. Дата сохранения — время публикации результата в приложении, а не время событий или файла.</p>");
    html.push_str("<p class=\"platform-note\">Скачанную резервную копию сохраняйте без изменений. Чтобы восстановить проект, загрузите исходный файл: правка или повторное сохранение его содержимого может нарушить проверку копии.</p>");
    if writable {
        html.push_str("<section class=\"platform-card\"><h2>Загрузить журнал</h2><form class=\"platform-form\" method=\"post\" action=\"/logs\" enctype=\"multipart/form-data\"><label>Файл XES<input type=\"file\" name=\"file\" accept=\".xes,application/xml,text/xml\" required></label><small>До 20 MiB, 100 000 событий и 20 000 трасс.</small><button class=\"button primary\" type=\"submit\">Загрузить и анализировать</button></form><hr class=\"platform-divider\"><a class=\"button\" href=\"/xes\">XES: сначала показать изменения</a> · <a class=\"button\" href=\"/csv\">Загрузить CSV с выбором колонок</a></section><section class=\"platform-card\"><h2>Восстановить резервную копию</h2><form class=\"platform-form\" method=\"post\" action=\"/restore\" enctype=\"multipart/form-data\"><label>Название нового проекта<input name=\"name\" required maxlength=\"200\" placeholder=\"Восстановленный проект\"></label><label>Файл резервной копии<input type=\"file\" name=\"file\" accept=\".json,application/json\" required></label><small>Копия восстанавливается в отдельный проект. Текущий проект не перезаписывается. Повреждённая или несовместимая копия отклоняется.</small><button class=\"button\" type=\"submit\">Восстановить в новый проект</button></form></section>");
    } else {
        html.push_str("<p class=\"platform-note\">У вас права наблюдателя: журналы можно открывать и экспортировать. Загрузку и восстановление выполняет редактор проекта.</p>");
    }
    html
}

pub(crate) fn models_list(items: &[(String, String, u64)], writable: bool) -> String {
    let mut html = "<section class=\"platform-heading\"><div class=\"eyebrow\">МОДЕЛИ ПРОЕКТА</div><h1>Модели BPMN</h1><p>Откройте сохранённую модель, чтобы увидеть диаграмму и скачать её.</p></section><section class=\"platform-card\">".to_owned();
    if items.is_empty() {
        html.push_str("<div class=\"platform-empty\">В проекте пока нет моделей. Модель можно построить из журнала или импортировать.</div>");
    } else {
        html.push_str("<div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Модель</th><th>Версия</th><th>Экспорт</th></tr></thead><tbody>");
        for (id, name, revision) in items {
            let route = route_id(id);
            html.push_str(&format!("<tr><td><a href=\"/models/{route}\">{}</a><br><small>{}</small></td><td>{revision}</td><td><a href=\"/models/{route}/export\">BPMN</a> · <a href=\"/models/{route}/json\">JSON</a></td></tr>", html_escape(name), html_escape(id)));
        }
        html.push_str("</tbody></table></div>");
    }
    html.push_str("</section>");
    if writable {
        html.push_str("<section class=\"platform-card\"><h2>Импортировать модель</h2><form class=\"platform-form\" method=\"post\" action=\"/models/import\" enctype=\"multipart/form-data\"><label>Файл BPMN<input type=\"file\" name=\"file\" accept=\".bpmn,.xml,application/xml,text/xml\" required></label><small>До 1 MiB, 1000 узлов и 4000 переходов. Один неисполняемый процесс: обычные задачи, начало, конец, шлюзы выбора и параллельные шлюзы, последовательные переходы. Условия, расширения и другие элементы отклоняются.</small><button class=\"button primary\" type=\"submit\">Импортировать BPMN</button></form></section>");
    } else {
        html.push_str("<p class=\"platform-note\">У вас права наблюдателя: модели можно просматривать и экспортировать. Импорт и изменение доступны редактору проекта.</p>");
    }
    html
}
fn column_select(
    name: &str,
    label: &str,
    headers: &[String],
    optional: bool,
    selected: Option<&str>,
) -> String {
    let mut html = format!(
        "<label>{}<select name=\"{}\" {}>",
        html_escape(label),
        html_escape(name),
        if optional { "" } else { "required" }
    );
    if optional {
        html.push_str("<option value=\"\">Не используется</option>");
    } else {
        html.push_str("<option value=\"\">Выберите колонку</option>");
    }
    for header in headers {
        html.push_str(&format!(
            "<option value=\"{}\" {}>{}</option>",
            html_escape(header),
            if selected == Some(header.as_str()) {
                "selected"
            } else {
                ""
            },
            html_escape(header)
        ));
    }
    html.push_str("</select></label>");
    html
}
pub(crate) fn csv_mapping(token: &str, preview: &CsvPreview) -> String {
    let mut html = "<section class=\"platform-heading\"><div class=\"eyebrow\">ПРОВЕРКА ИМПОРТА</div><h1>Какие колонки описывают события?</h1><p>Одна строка — одно событие. События с одинаковым идентификатором трассы объединяются.</p></section><section class=\"platform-card\"><h2>Первые пять строк</h2><div class=\"platform-table-wrap platform-preview\"><table class=\"platform-table\"><thead><tr>".to_owned();
    for header in &preview.headers {
        html.push_str(&format!("<th>{}</th>", html_escape(header)));
    }
    html.push_str("</tr></thead><tbody>");
    for row in &preview.rows {
        html.push_str("<tr>");
        for value in row {
            html.push_str(&format!("<td>{}</td>", html_escape(value)));
        }
        html.push_str("</tr>");
    }
    html.push_str("</tbody></table></div></section><section class=\"platform-card\"><form class=\"platform-form\" method=\"post\" action=\"/csv/import\">");
    html.push_str(&format!(
        "<input type=\"hidden\" name=\"token\" value=\"{}\">",
        html_escape(token)
    ));
    let suggest = |candidates: &[&str]| {
        preview
            .headers
            .iter()
            .find(|header| {
                candidates
                    .iter()
                    .any(|candidate| header.eq_ignore_ascii_case(candidate))
            })
            .map(String::as_str)
    };
    html.push_str(&column_select(
        "case_column",
        "Идентификатор трассы",
        &preview.headers,
        false,
        suggest(&["case", "case_id", "case:concept:name"]),
    ));
    html.push_str(&column_select(
        "activity_column",
        "Название действия",
        &preview.headers,
        false,
        suggest(&["activity", "concept:name"]),
    ));
    html.push_str(&column_select(
        "timestamp_column",
        "Время события (необязательно)",
        &preview.headers,
        true,
        None,
    ));
    html.push_str(&column_select(
        "lifecycle_column",
        "Этап жизненного цикла (необязательно)",
        &preview.headers,
        true,
        None,
    ));
    html.push_str("<label>Порядок событий<select name=\"order\"><option value=\"source\">Как в исходной таблице</option><option value=\"timestamp\">По времени события</option></select></label><small>Для порядка по времени нужно время каждого события с часовым поясом, например 2026-10-10T09:30:00+05:00. При равном времени сохраняется порядок строк. Каждое событие считается отдельно, этапы start/complete не склеиваются.</small><button class=\"button primary\" type=\"submit\">Импортировать и анализировать</button></form></section>");
    html
}

fn optional_number(value: Option<usize>) -> String {
    value.map(|n| n.to_string()).unwrap_or_default()
}
fn duration_text(millis: i64) -> String {
    let hours = millis / 3_600_000;
    let minutes = millis % 3_600_000 / 60_000;
    let seconds = millis % 60_000 / 1000;
    let remainder = millis % 1000;
    let mut parts = Vec::new();
    for (value, unit) in [
        (hours, "ч"),
        (minutes, "мин"),
        (seconds, "с"),
        (remainder, "мс"),
    ] {
        if value != 0 {
            parts.push(format!("{value} {unit}"));
        }
    }
    if parts.is_empty() {
        "0 с".into()
    } else {
        parts.join(" ")
    }
}

pub(crate) fn calendar_table(results: &serde_json::Value) -> String {
    let Some(rows) = results.as_array() else {
        return "<div class=\"platform-alert\" role=\"alert\">Не удалось отобразить рабочую длительность.</div>".into();
    };
    let mut html = "<section class=\"platform-card\"><h2>Рабочая длительность трасс</h2><p class=\"platform-note\">Время между самым ранним и самым поздним событием учитывается только внутри выбранных рабочих часов. Результат сохраняет точность до миллисекунд.</p>".to_owned();
    if rows.is_empty() {
        html.push_str("<div class=\"platform-empty\">Нет трасс для расчёта.</div></section>");
        return html;
    }
    html.push_str("<div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Трасса</th><th>Рабочая длительность</th><th>Статус</th></tr></thead><tbody>");
    for row in rows.iter().take(200) {
        let case_id = row
            .get("case_id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Неизвестная трасса");
        let computed = row.get("status").and_then(serde_json::Value::as_str) == Some("computed");
        let millis = row
            .get("business_millis")
            .and_then(serde_json::Value::as_i64)
            .filter(|n| *n >= 0);
        let (duration, status) = if computed && millis.is_some() {
            (duration_text(millis.unwrap_or_default()), "Рассчитано")
        } else {
            let status = match row.get("reason").and_then(serde_json::Value::as_str) {
                Some("missing_timestamps") => "Нет времени событий",
                Some("calendar_limit") => "Интервал превышает предел календаря",
                Some("calendar_policy") => "Проверьте параметры календаря",
                _ => "Длительность не проверена",
            };
            ("—".into(), status)
        };
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{status}</td></tr>",
            html_escape(case_id),
            html_escape(&duration)
        ));
    }
    html.push_str("</tbody></table></div>");
    if rows.len() > 200 {
        html.push_str(&format!("<p class=\"platform-note\">Показаны первые 200 трасс из {}. Полный результат доступен в экспорте журнала.</p>", rows.len()));
    }
    html.push_str("</section>");
    html
}
fn array_text(values: &[String]) -> String {
    html_escape(&serde_json::to_string(values).unwrap_or_else(|_| "[]".into()))
}
fn activity_picker(id: &str, field: &str, label: &str, values: &[String]) -> String {
    format!(
        "<fieldset class=\"activity-picker\" data-source=\"/logs/{id}/activities\" data-field=\"{field}\"><legend>{label}</legend><input type=\"hidden\" name=\"{field}\" value=\"{}\"><label>Найти действие<input data-activity-search type=\"search\" placeholder=\"Поиск действия\" autocomplete=\"off\"></label><div data-activity-options class=\"activity-options\">Загрузка…</div><p data-activity-status class=\"platform-note\" role=\"status\" aria-live=\"polite\"></p><div data-activity-selected class=\"activity-selected\"></div><button data-activity-clear type=\"button\" class=\"small-button\">Сбросить выбор</button></fieldset>",
        array_text(values)
    )
}
fn clock(minute: u32) -> String {
    format!("{:02}:{:02}", minute / 60, minute % 60)
}
fn minute_select(name: &str, label: &str, selected: u32) -> String {
    let mut html = format!("<label>{label}<select name=\"{name}\">");
    let mut values: Vec<u32> = (0..=1440).step_by(30).collect();
    if !values.contains(&selected) {
        values.push(selected);
        values.sort_unstable();
    }
    for value in values {
        html.push_str(&format!(
            "<option value=\"{value}\" {}>{}</option>",
            if selected == value { "selected" } else { "" },
            clock(value)
        ));
    }
    html.push_str("</select></label>");
    html
}
pub(crate) fn log_tools(
    id: &str,
    filter: &FilterSpec,
    calendar: &CalendarSpec,
    writable: bool,
) -> String {
    if !writable {
        return "<section class=\"platform-card\"><h2>Просмотр журнала</h2><p class=\"platform-note\">Вы можете просматривать и экспортировать результат. Менять фильтры, календарь и строить модели может редактор проекта.</p></section>".into();
    }
    let id = route_id(id);
    let mut html = format!(
        "<section class=\"platform-card\"><h2>Выбрать трассы и действия</h2><form class=\"platform-form\" method=\"post\" action=\"/logs/{id}/filter\"><label>Трассы, содержащие действие<input name=\"case_activity\" value=\"{}\" placeholder=\"Оставьте пустым для всех трасс\"></label><div class=\"platform-fields\"><label>Минимум событий в исходной трассе<input type=\"number\" min=\"0\" max=\"100000\" name=\"min_events\" value=\"{}\"></label><label>Максимум событий в исходной трассе<input type=\"number\" min=\"0\" max=\"100000\" name=\"max_events\" value=\"{}\"></label></div>",
        html_escape(filter.case_activity.as_deref().unwrap_or("")),
        optional_number(filter.min_events),
        optional_number(filter.max_events)
    );
    html.push_str(&activity_picker(
        &id,
        "retain",
        "Оставить только выбранные действия",
        &filter.retain_activities,
    ));
    html.push_str(&activity_picker(
        &id,
        "remove",
        "Удалить выбранные действия",
        &filter.remove_activities,
    ));
    html.push_str("<small>Если ничего не выбрано, соответствующее ограничение не применяется. Сначала выбираются трассы по исходным событиям, затем в них остаются выбранные действия. Пустые трассы сохраняются. Исходный журнал не меняется; статистика и карта пересчитываются.</small><button class=\"button primary\" type=\"submit\">Применить фильтр</button></form>");
    html.push_str(&format!("<form method=\"post\" action=\"/logs/{id}/filter\" class=\"platform-reset\"><input type=\"hidden\" name=\"case_activity\" value=\"\"><input type=\"hidden\" name=\"min_events\" value=\"\"><input type=\"hidden\" name=\"max_events\" value=\"\"><input type=\"hidden\" name=\"retain\" value=\"[]\"><input type=\"hidden\" name=\"remove\" value=\"[]\"><button type=\"submit\" class=\"button\">Сбросить все фильтры</button></form></section>"));
    html.push_str(&format!("<section class=\"platform-card\"><h2>Построить модель из наблюдённых вариантов</h2><p class=\"platform-note\">Каждый наблюдённый вариант станет отдельным путём через выбор. Это описывает наблюдения, не доказывает параллелизм и не заменяет Split Miner.</p><form method=\"post\" action=\"/logs/{id}/discover\"><button class=\"button\" type=\"submit\">Построить BPMN</button></form></section>"));
    let weekdays = calendar
        .weekdays
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let holidays = calendar
        .holidays
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",");
    html.push_str(&format!("<section class=\"platform-card\"><h2>Рабочее время</h2><form class=\"platform-form\" method=\"post\" action=\"/logs/{id}/calendar\"><label>Фиксированное смещение UTC<select name=\"offset_minutes\">"));
    // Named zone input is rendered below the fixed offset selector.
    let mut offsets: Vec<i32> = (-840..=840).step_by(30).collect();
    if !offsets.contains(&calendar.offset_minutes) {
        offsets.push(calendar.offset_minutes);
        offsets.sort_unstable();
    }
    for offset in offsets {
        html.push_str(&format!(
            "<option value=\"{offset}\" {}>UTC{}{:02}:{:02}</option>",
            if offset == calendar.offset_minutes {
                "selected"
            } else {
                ""
            },
            if offset >= 0 { "+" } else { "−" },
            offset.abs() / 60,
            offset.abs() % 60
        ));
    }
    html.push_str(&format!("</select></label><label>Рабочие дни недели<input name=\"weekdays\" value=\"{}\" required></label><small>1 — понедельник, 2 — вторник, …, 7 — воскресенье. Например: 1,2,3,4,5.</small><div class=\"platform-fields\">", html_escape(&weekdays)));
    html.push_str(&format!("<label>Именованная зона IANA (необязательно)<input name=\"timezone\" value=\"{}\" maxlength=\"128\" placeholder=\"Europe/Berlin\"></label>", html_escape(calendar.timezone.as_deref().unwrap_or(""))));
    html.push_str(&minute_select(
        "start_minute",
        "Начало работы",
        calendar.start_minute,
    ));
    html.push_str(&minute_select(
        "end_minute",
        "Конец работы",
        calendar.end_minute,
    ));
    html.push_str(&format!("</div><label>Нерабочие даты<input name=\"holidays\" value=\"{}\" placeholder=\"2026-12-31,2027-01-01\"></label><small>Считается пересечение интервала между первым и последним временем трассы с рабочими часами. Начало включается, конец не включается. Без именованной зоны смещение UTC фиксировано. При именованной зоне учитываются сезонные переходы; несуществующие и неоднозначные рабочие границы отклоняются. Для именованной зоны выберите фиксированное смещение UTC+00:00.</small><button class=\"button\" type=\"submit\">Рассчитать рабочее время</button></form></section>", html_escape(&holidays)));
    html
}

pub(crate) fn model_editor(
    id: &str,
    model: &ProcessModel,
    revision: u64,
    writable: bool,
) -> String {
    let id = route_id(id);
    let json = match serde_json::to_string(model) { Ok(json) => html_escape(&json), Err(_) => return "<div class=\"platform-alert\" role=\"alert\">Не удалось отобразить модель.</div>".into() };
    let mut html = format!(
        "<section class=\"platform-heading\"><div class=\"eyebrow\">МОДЕЛЬ ПРОЦЕССА</div><h1>{}</h1><p>Круги — начало и конец, прямоугольники — действия, ромбы × и + — выбор и параллельный шлюз.</p><div class=\"platform-actions\"><a class=\"button\" href=\"/models/{id}/export\">Скачать BPMN</a><a class=\"button\" href=\"/models/{id}/json\">Скачать JSON</a><span class=\"platform-badge\">Версия {revision}</span></div></section><div id=\"bpmn-data\" hidden data-editable=\"{writable}\">{json}</div><div class=\"bpmn-layout\"><section class=\"platform-card bpmn-diagram-card\"><header class=\"bpmn-toolbar\"><strong>Диаграмма</strong><button id=\"bpmn-fit\" type=\"button\" class=\"small-button\">Вписать</button></header><div class=\"bpmn-diagram\"><div id=\"bpmn-cy\" role=\"img\" aria-label=\"Модель процесса BPMN\"></div></div><div class=\"bpmn-caption\">Выберите узел или переход; подпись показана для выбранного элемента, положение — для узла. Масштаб меняется колёсиком.</div></section><section class=\"platform-card bpmn-editor\"><h2>Выбранный элемент</h2>",
        html_escape(&model.name)
    );
    if writable {
        html.push_str(&format!("<form id=\"bpmn-save-form\" class=\"platform-form\" method=\"post\" action=\"/models/{id}\"><input type=\"hidden\" name=\"revision\" value=\"{revision}\"><input id=\"bpmn-model-json\" type=\"hidden\" name=\"model_json\" value=\"{json}\">"));
    } else {
        html.push_str("<div class=\"platform-form\">");
    }
    html.push_str("<label>Идентификатор<input id=\"bpmn-node-id\" readonly disabled></label><label>Подпись<input id=\"bpmn-node-label\" disabled maxlength=\"4096\"></label><div class=\"platform-fields\"><label>Положение X<input id=\"bpmn-node-x\" type=\"number\" step=\"any\" min=\"-1000000\" max=\"1000000\" disabled></label><label>Положение Y<input id=\"bpmn-node-y\" type=\"number\" step=\"any\" min=\"-1000000\" max=\"1000000\" disabled></label></div><p id=\"bpmn-node-hint\" class=\"platform-note\">Выберите узел или переход на диаграмме.</p>");
    if writable {
        html.push_str("<button id=\"bpmn-apply-node\" class=\"button\" type=\"button\" disabled>Изменить черновик</button><button id=\"bpmn-delete-element\" class=\"button\" type=\"button\" disabled>Удалить выбранное</button><hr><label>Название новой задачи<input id=\"bpmn-new-task-label\" maxlength=\"4096\" value=\"Новое действие\"></label><button id=\"bpmn-add-task\" class=\"button\" type=\"button\">Добавить задачу</button><label>Переход из узла<select id=\"bpmn-flow-source\"></select></label><label>В узел<select id=\"bpmn-flow-target\"></select></label><button id=\"bpmn-add-flow\" class=\"button\" type=\"button\">Добавить переход</button><button class=\"button primary\" type=\"submit\">Сохранить модель</button><p class=\"platform-note\">Добавляйте задачи и переходы, удаляйте выбранную задачу или переход. Начало, конец и шлюзы сохраняются. Удаление задачи убирает её переходы из черновика. Для сохранения каждый узел должен лежать на пути от начала к концу. Подпись выбранного элемента и положение узла применяются при сохранении; изменения подтверждаются после обновления страницы.</p></form>");
    } else {
        html.push_str(
            "<p class=\"platform-note\">Просмотр: изменения доступны редактору проекта.</p></div>",
        );
    }
    html.push_str("<div id=\"bpmn-status\" class=\"bpmn-status\" role=\"status\" aria-live=\"polite\"></div></section></div>");
    if model.discovery.is_some() {
        if revision == 1 {
            html.push_str("<p class=\"platform-note\">Модель построена из наблюдённых вариантов: каждый путь воспроизводит известную последовательность. Качество обобщения и совместимость с Apromore не подтверждены.</p>");
        } else {
            html.push_str("<p class=\"platform-note\">Основа построена из наблюдённых вариантов. Сохранённые изменения могут отличаться от исходных последовательностей; качество обобщения и совместимость с Apromore не подтверждены.</p>");
        }
    }
    html.push_str("<p class=\"platform-note\">Поддерживается один неисполняемый процесс с обычными задачами, началом, концом, шлюзами и последовательными переходами. Подписи переходов — текст, а не условия. Условия, default flow, BPMNLabel DI, расширения и другие элементы отклоняются при импорте.</p>");
    html
}

#[cfg(test)]
mod c06_tests {
    use super::*;
    #[test]
    fn duplicate_names_show_distinct_ids_utc_or_unknown_and_saved_state() {
        let date = chrono::DateTime::parse_from_rfc3339("2025-01-02T03:04:05.123Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let items = [
            crate::storage::ResourceSummary {
                kind: "log_state".into(),
                id: "log-1".into(),
                name: "<script>&same.xes".into(),
                number: 4,
                created_at: Some(date),
            },
            crate::storage::ResourceSummary {
                kind: "log_state".into(),
                id: "log-2".into(),
                name: "<script>&same.xes".into(),
                number: 4,
                created_at: None,
            },
        ];
        let html = logs_list(&items, false);
        assert!(html.contains("href=\"/logs/log-1\""));
        assert!(html.contains("href=\"/logs/log-2\""));
        assert_eq!(html.matches("&lt;script&gt;&amp;same.xes").count(), 2);
        assert!(!html.contains("<script>"));
        assert_eq!(html.matches("<td>4</td>").count(), 2);
        assert!(html.contains("2025-01-02T03:04:05.123Z"));
        assert!(html.contains("Дата не сохранена"));
        assert_eq!(html.matches("<td>Сохранённый анализ</td>").count(), 2);
        assert!(html.contains("Целостность данных проверяется при открытии; незавершённые обработки находятся в задачах"));
        assert!(!html.contains("action=\"/restore\""));
    }
}

#[cfg(test)]
mod projection_report_tests {
    use super::*;

    #[test]
    fn preview_discloses_omissions_before_consent_and_escapes_keys_without_values() {
        let input = br#"<log><classifier name="By resource" keys="org:resource"/>
        <trace><event><string key="concept:name" value="A"/>
        <date key="time:timestamp" value="2026-01-01T05:00:00+05:00"/>
        <string key="&lt;script&gt;&amp;" value="PRIVATE_VALUE"/>
        </event></trace></log>"#;
        let preview = crate::service_preview::preview_xes(input).unwrap();
        let html = xes_preview("token", &preview, "digest", "<img>");
        assert!(html.contains("Какие данные не попадут в анализ"));
        assert!(html.contains("Классификаторов вне анализа: 1"));
        assert!(html.contains("&lt;script&gt;&amp;"));
        assert!(html.contains("&lt;img&gt;"));
        assert!(!html.contains("<script>"));
        assert!(!html.contains("PRIVATE_VALUE"));
        assert!(html.contains("исходный XES сохранится"));
        assert!(
            html.find("Какие данные не попадут в анализ").unwrap()
                < html.find("Подтвердить импорт").unwrap()
        );
        assert!(html.contains("сам момент времени не меняется"));
        assert!(html.contains("action=\"/xes/import\""));
    }
}

#[cfg(test)]
mod project_list_tests {
    use super::*;

    fn actor(role: Role) -> Actor {
        Actor {
            id: "owner".into(),
            username: "Owner".into(),
            project_id: "project".into(),
            role,
            admin: false,
        }
    }

    #[test]
    fn destinations_exclude_foreign_archived_branches_and_moving_subtree() {
        let folder = |id: &str, owner: &str, parent: Option<&str>, archived| ListFolder {
            id: id.into(),
            name: format!("<{id}>"),
            owner_id: owner.into(),
            parent_id: parent.map(str::to_owned),
            archived,
        };
        let view = ProjectListView {
            projects: vec![],
            revision: 7,
            folders: vec![
                folder("root", "owner", None, false),
                folder("child", "owner", Some("root"), false),
                folder("archived", "owner", None, true),
                folder("under-archive", "owner", Some("archived"), false),
                folder("foreign", "other", None, false),
            ],
            project_folders: BTreeMap::new(),
        };
        let options = destination_options(&view, &actor(Role::Owner), None, None);
        assert!(options.contains("value=\"root\""));
        assert!(options.contains("&lt;root&gt; / &lt;child&gt;"));
        assert!(!options.contains("value=\"archived\""));
        assert!(!options.contains("value=\"under-archive\""));
        assert!(!options.contains("value=\"foreign\""));
        let moving = destination_options(&view, &actor(Role::Owner), None, Some("root"));
        assert!(!moving.contains("value=\"root\""));
        assert!(!moving.contains("value=\"child\""));
    }

    #[test]
    fn archived_project_keeps_path_and_owner_move_while_viewer_has_no_mutations() {
        let project = Project {
            id: "project".into(),
            name: "<Project>".into(),
            members: BTreeMap::from([("owner".into(), Role::Owner)]),
            archived: true,
            revision: 9,
        };
        let view = ProjectListView {
            projects: vec![project.clone()],
            revision: 8,
            folders: vec![ListFolder {
                id: "folder".into(),
                name: "<Folder>".into(),
                owner_id: "owner".into(),
                parent_id: None,
                archived: true,
            }],
            project_folders: BTreeMap::from([("project".into(), "folder".into())]),
        };
        let html = projects(&actor(Role::Owner), &view.projects, &view);
        assert!(html.contains("&lt;Project&gt;"));
        assert!(html.contains("&lt;Folder&gt;"));
        assert!(html.contains("Архив папки — доступ к проекту сохранён"));
        assert!(html.contains("action=\"/projects/project/move\""));
        assert!(html.contains("name=\"catalog_revision\" value=\"8\""));
        assert!(html.contains("name=\"project_revision\" value=\"9\""));
        assert!(html.contains("action=\"/projects/project/unarchive\""));
        assert!(!html.contains("<Folder>"));
        let readonly = projects(&actor(Role::Viewer), &view.projects, &view);
        assert!(!readonly.contains("action=\"/projects/project/move\""));
        assert!(!readonly.contains("action=\"/project-list/folders"));
        assert!(!readonly.contains("action=\"/projects/project/unarchive\""));
    }
}
