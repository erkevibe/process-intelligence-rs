//! Pure HTML renderers. Route authorization and persistence belong to platform.
use crate::{
    auth::{Actor, Project, Role},
    bpmn::ProcessModel,
    calendar::CalendarSpec,
    csv_io::CsvPreview,
    filters::FilterSpec,
};

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

pub(crate) fn projects(actor: &Actor, projects: &[Project]) -> String {
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
        html.push_str(&format!("<tr><td>{} {}</td><td>{}</td><td><form method=\"post\" action=\"/projects/{id}/open\"><button class=\"small-button\" type=\"submit\">{}</button></form></td></tr>", html_escape(&project.name), if current { "<span class=\"platform-badge\">Текущий</span>" } else { "" }, role_label(role), if current { "Открыть текущий" } else { "Открыть" }));
        if role == Role::Owner && actor.role.can_write() {
            html.push_str(&format!("<tr><td colspan=\"3\"><details><summary>Дать доступ к проекту «{}»</summary><form class=\"platform-form\" method=\"post\" action=\"/projects/{id}/members\"><label>Имя пользователя<input name=\"username\" required maxlength=\"80\" autocomplete=\"off\"></label><label>Права<select name=\"role\"><option value=\"viewer\">Наблюдатель — просмотр и экспорт</option><option value=\"editor\">Редактор — просмотр и изменение</option></select></label><button class=\"button\" type=\"submit\">Предоставить доступ</button><small>Пользователь должен уже иметь учётную запись. Эта операция изменяет его права в выбранном проекте.</small></form></details></td></tr>", html_escape(&project.name)));
        }
    }
    html.push_str("</tbody></table></div></section>");
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

pub(crate) fn logs_list(items: &[(String, String, usize)], writable: bool) -> String {
    let mut html = "<section class=\"platform-heading\"><div class=\"eyebrow\">ЖУРНАЛЫ ПРОЕКТА</div><h1>Сохранённые журналы</h1><p>Журналы сохраняются после перезапуска. В проекте можно хранить восемь журналов: если место занято, новый импорт отклоняется, прежние данные остаются доступны. Одинаковые названия не объединяют результаты.</p></section><section class=\"platform-card\">".to_owned();
    if items.is_empty() {
        html.push_str("<div class=\"platform-empty\">В этом проекте пока нет журналов.</div>");
    } else {
        html.push_str("<div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Журнал</th><th>Событий</th><th>Анализ</th></tr></thead><tbody>");
        for (id, name, events) in items {
            let route = route_id(id);
            html.push_str(&format!("<tr><td><a href=\"/logs/{route}\">{}</a><br><small>{}</small></td><td>{events}</td><td><a href=\"/logs/{route}/tools\">Фильтры и календарь</a> · <a href=\"/logs/{route}/export\">Экспорт</a></td></tr>", html_escape(name), html_escape(id)));
        }
        html.push_str("</tbody></table></div>");
    }
    html.push_str("</section>");
    html.push_str("<p class=\"platform-note\">Скачанную резервную копию сохраняйте без изменений. Чтобы восстановить проект, загрузите исходный файл: правка или повторное сохранение его содержимого может нарушить проверку копии.</p>");
    if writable {
        html.push_str("<section class=\"platform-card\"><h2>Загрузить журнал</h2><form class=\"platform-form\" method=\"post\" action=\"/logs\" enctype=\"multipart/form-data\"><label>Файл XES<input type=\"file\" name=\"file\" accept=\".xes,application/xml,text/xml\" required></label><small>До 20 MiB, 100 000 событий и 20 000 трасс.</small><button class=\"button primary\" type=\"submit\">Загрузить и анализировать</button></form><hr class=\"platform-divider\"><a class=\"button\" href=\"/csv\">Загрузить CSV с выбором колонок</a></section><section class=\"platform-card\"><h2>Восстановить резервную копию</h2><form class=\"platform-form\" method=\"post\" action=\"/restore\" enctype=\"multipart/form-data\"><label>Название нового проекта<input name=\"name\" required maxlength=\"200\" placeholder=\"Восстановленный проект\"></label><label>Файл резервной копии<input type=\"file\" name=\"file\" accept=\".json,application/json\" required></label><small>Копия восстанавливается в отдельный проект. Текущий проект не перезаписывается. Повреждённая или несовместимая копия отклоняется.</small><button class=\"button\" type=\"submit\">Восстановить в новый проект</button></form></section>");
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
    html.push_str(&format!("<section class=\"platform-card\"><h2>Рабочее время</h2><form class=\"platform-form\" method=\"post\" action=\"/logs/{id}/calendar\"><label>Часовой пояс<select name=\"offset_minutes\">"));
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
    html.push_str(&format!("</div><label>Нерабочие даты<input name=\"holidays\" value=\"{}\" placeholder=\"2026-12-31,2027-01-01\"></label><small>Считается пересечение интервала между первым и последним временем трассы с рабочими часами. Начало включается, конец не включается. Сдвиг UTC фиксирован: сезонный перевод часов не поддерживается.</small><button class=\"button\" type=\"submit\">Рассчитать рабочее время</button></form></section>", html_escape(&holidays)));
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
        "<section class=\"platform-heading\"><div class=\"eyebrow\">МОДЕЛЬ ПРОЦЕССА</div><h1>{}</h1><p>Круги — начало и конец, прямоугольники — действия, ромбы × и + — выбор и параллельный шлюз.</p><div class=\"platform-actions\"><a class=\"button\" href=\"/models/{id}/export\">Скачать BPMN</a><a class=\"button\" href=\"/models/{id}/json\">Скачать JSON</a><span class=\"platform-badge\">Версия {revision}</span></div></section><div id=\"bpmn-data\" hidden data-editable=\"{writable}\">{json}</div><div class=\"bpmn-layout\"><section class=\"platform-card bpmn-diagram-card\"><header class=\"bpmn-toolbar\"><strong>Диаграмма</strong><button id=\"bpmn-fit\" type=\"button\" class=\"small-button\">Вписать</button></header><div class=\"bpmn-diagram\"><div id=\"bpmn-cy\" role=\"img\" aria-label=\"Модель процесса BPMN\"></div></div><div class=\"bpmn-caption\">Выберите узел или переход; подпись и положение показаны для узла. Масштаб меняется колёсиком.</div></section><section class=\"platform-card bpmn-editor\"><h2>Выбранный элемент</h2>",
        html_escape(&model.name)
    );
    if writable {
        html.push_str(&format!("<form id=\"bpmn-save-form\" class=\"platform-form\" method=\"post\" action=\"/models/{id}\"><input type=\"hidden\" name=\"revision\" value=\"{revision}\"><input id=\"bpmn-model-json\" type=\"hidden\" name=\"model_json\" value=\"{json}\">"));
    } else {
        html.push_str("<div class=\"platform-form\">");
    }
    html.push_str("<label>Идентификатор<input id=\"bpmn-node-id\" readonly disabled></label><label>Подпись<input id=\"bpmn-node-label\" disabled maxlength=\"4096\"></label><div class=\"platform-fields\"><label>Положение X<input id=\"bpmn-node-x\" type=\"number\" step=\"any\" min=\"-1000000\" max=\"1000000\" disabled></label><label>Положение Y<input id=\"bpmn-node-y\" type=\"number\" step=\"any\" min=\"-1000000\" max=\"1000000\" disabled></label></div><p id=\"bpmn-node-hint\" class=\"platform-note\">Выберите узел на диаграмме.</p>");
    if writable {
        html.push_str("<button id=\"bpmn-apply-node\" class=\"button\" type=\"button\" disabled>Изменить черновик</button><button id=\"bpmn-delete-element\" class=\"button\" type=\"button\" disabled>Удалить выбранное</button><hr><label>Название новой задачи<input id=\"bpmn-new-task-label\" maxlength=\"4096\" value=\"Новое действие\"></label><button id=\"bpmn-add-task\" class=\"button\" type=\"button\">Добавить задачу</button><label>Переход из узла<select id=\"bpmn-flow-source\"></select></label><label>В узел<select id=\"bpmn-flow-target\"></select></label><button id=\"bpmn-add-flow\" class=\"button\" type=\"button\">Добавить переход</button><button class=\"button primary\" type=\"submit\">Сохранить модель</button><p class=\"platform-note\">Добавляйте задачи и переходы, удаляйте выбранную задачу или переход. Начало, конец и шлюзы сохраняются. Удаление задачи убирает её переходы из черновика. Для сохранения каждый узел должен лежать на пути от начала к концу. Подпись и положение выбранного узла применяются при сохранении; изменения подтверждаются после обновления страницы.</p></form>");
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
    html.push_str("<p class=\"platform-note\">Поддерживается один неисполняемый процесс с обычными задачами, началом, концом, шлюзами и последовательными переходами. Условия, расширения и другие элементы отклоняются при импорте.</p>");
    html
}
