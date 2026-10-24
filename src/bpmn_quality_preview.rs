//! Read-only, bounded quality preview. No durable job or project format extension.
use crate::{
    bpmn_quality::{Issue, facade},
    domain::{EventLog, ImportError},
    platform_render::html_escape,
    web::{AppState, Workspace},
};
use axum::{
    Form, Json, Router,
    extract::{DefaultBodyLimit, Path},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response, Sse, sse::Event},
    routing::get,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    convert::Infallible,
    time::{Duration, Instant},
};

#[cfg(test)]
#[path = "bpmn_quality_preview_tests.rs"]
mod tests;

pub(crate) fn routes() -> Router<AppState> {
    Router::new().route(
        "/models/{id}/quality",
        get(form).post(evaluate).layer(DefaultBodyLimit::max(4096)),
    )
}
fn error(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}
fn path_id(id: &str) -> String {
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
fn failure(error: ImportError) -> Response {
    let status = match error.code.as_str() {
        "access_denied" => StatusCode::FORBIDDEN,
        "not_found" => StatusCode::NOT_FOUND,
        "quality_conflict" => StatusCode::CONFLICT,
        "quality_busy" => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::UNPROCESSABLE_ENTITY,
    };
    (
        status,
        Json(json!({"code":error.code,"message":error.message})),
    )
        .into_response()
}

/// Bound borrowed inputs before cloning any activity names; never sample silently.
pub(crate) fn rows(log: &EventLog) -> Result<Value, ImportError> {
    if log.cases.len() > 64 {
        return Err(error(
            "quality_log_limit",
            "Для предпросмотра нужны не более 64 трасс и 500 событий. Выберите меньший журнал или явно примените фильтр.",
        ));
    }
    let mut variants = BTreeMap::<Vec<&str>, u64>::new();
    let mut events = 0;
    for case in &log.cases {
        events += case.events.len();
        if case.events.len() > 64 || events > 500 {
            return Err(error(
                "quality_log_limit",
                "Превышен предел: 500 событий всего или 64 события в трассе.",
            ));
        }
        let mut sequence = Vec::with_capacity(case.events.len());
        for event in &case.events {
            if event.activity.is_empty() || event.activity.len() > 200 {
                return Err(error(
                    "quality_label_limit",
                    "Метка действия должна занимать от 1 до 200 байт UTF-8.",
                ));
            }
            sequence.push(event.activity.as_str());
        }
        *variants.entry(sequence).or_default() += 1;
        if variants.len() > 32 {
            return Err(error(
                "quality_log_limit",
                "Предпросмотр допускает не более 32 вариантов.",
            ));
        }
    }
    Ok(Value::Array(
        variants
            .into_iter()
            .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
            .collect(),
    ))
}

async fn form(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    let result = tokio::task::spawn_blocking(move || -> Result<String,ImportError> {
        state.validate_resource_actor()?;
        let actor = state.actor.as_ref().ok_or_else(|| error("access_denied","Войдите в проект."))?;
        let platform = state.platform.as_ref().ok_or_else(|| error("platform_unavailable","Нужен проект PostgreSQL."))?;
        let mut repo = state.repository.lock().expect("repository mutex");
        let model = repo.get_model(&state,&id)?.ok_or_else(|| error("not_found","Модель не найдена."))?;
        let summaries = platform.database.resource_summaries(&actor.project_id)?;
        let mut options = String::new();
        for log in summaries.iter().filter(|item| item.kind == "log_state") {
            options.push_str(&format!("<option value=\"{}\"{}>{}</option>",html_escape(&log.id), if model.source_log.as_deref() == Some(log.id.as_str()) {" selected"} else {""},html_escape(&log.name)));
        }
        let writable = actor.role.can_write();
        let path = format!("/models/{}/quality",path_id(&id));
        let mut body = format!("<h1>Оценка BPMN</h1><p><strong>{}</strong> · версия {}</p><p>Оценивается сохранённая модель и текущая отфильтрованная версия выбранного журнала целиком. Порог рисунка и выбранная трасса на расчёт не влияют.</p><section class=\"platform-card\"><form id=\"quality-form\" class=\"platform-form\" method=\"post\" action=\"{path}\" data-signals=\"{{qualitybusy:false}}\" data-indicator:qualitybusy data-on:submit__prevent=\"window.piRunQuality(() =&gt; @post('{path}', {{contentType:'form', selector:'#quality-form', requestCancellation:'disabled', retry:'never'}}))\"><input type=\"hidden\" name=\"revision\" value=\"{}\"><label>Журнал<select name=\"log_id\" required>{options}</select></label>",html_escape(&model.name),model.revision,model.revision);
        if writable && !options.is_empty() {
            body.push_str("<button class=\"button primary\" type=\"submit\" data-attr:disabled=\"$qualitybusy\" data-text=\"$qualitybusy ? 'Считаем…' : 'Оценить модель'\">Оценить модель</button>");
        } else { body.push_str("<p>Для расчёта нужны журнал и права редактора проекта.</p>"); }
        body.push_str("<p id=\"quality-status\" role=\"status\" aria-live=\"polite\"></p></form></section><section id=\"quality-result\" class=\"platform-card\" aria-live=\"polite\"><p>Выберите журнал и запустите оценку.</p></section><p class=\"platform-note\">Предпросмотр: результат не сохраняется в истории и не возобновляется после перезапуска. Пределы: 64 трассы, 500 событий, 32 варианта; до 1000 состояний поиска. Исчерпание предела показывается без численной оценки.</p>");
        state.validate_resource_actor()?;
        Ok(body)
    }).await;
    match result {
        Ok(Ok(body)) => crate::platform::page("Оценка BPMN", body),
        Ok(Err(e)) => failure(e),
        Err(_) => failure(error("quality_worker", "Не удалось открыть оценку.")),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PreviewForm {
    log_id: String,
    revision: u64,
}

fn metric_card(title: &str, description: &str, metric: &Value, scalar: Option<f64>) -> String {
    let status = metric["status"].as_str().unwrap_or("inconclusive");
    let value = if status == "measured" {
        scalar
            .filter(|v| v.is_finite())
            .map(|v| format!("{:.1}%", 100.0 * v))
            .unwrap_or_else(|| "Нет оценки".into())
    } else {
        match status {
            "no_data" => "Нет данных",
            "requires_fitting_log" => "Трассы расходятся с моделью",
            "not_applicable_no_activated_labels" => "Не применимо",
            "quality_unsupported_semantics" => "Семантика не поддерживается",
            _ => "Оценка не получена",
        }
        .into()
    };
    let reason = match status {
        "measured" => "Расчёт выполнен в пределах указанного профиля.",
        "no_data" => "В выбранном журнале нет трасс для оценки.",
        "requires_fitting_log" => {
            "Precision рассчитывается, когда все выбранные трассы воспроизводятся моделью без отклонений. Сначала проверьте соответствие журналу."
        }
        "quality_unsupported_semantics" => "Модель выходит за поддерживаемую семантику оценщика.",
        "not_applicable_no_activated_labels" => {
            "В этой сети нет доступных видимых действий для оценки precision."
        }
        _ => match metric["reason"].as_str().unwrap_or("") {
            "model_not_admitted" => {
                "Модель не допущена к расчёту; проверьте её структуру и ограничения."
            }
            "deadline" => "Достигнута граница времени между этапами. Численная оценка не выдана.",
            "fitness_not_measured" => "Сначала нужно получить оценку соответствия журналу.",
            _ => {
                "Достигнут предел поиска или вход не поддерживается. Численная оценка не выдана; уточните причину в данных расчёта."
            }
        },
    };
    format!(
        "<article><h3>{}</h3><strong>{}</strong><p>{}</p><small>{}</small></article>",
        html_escape(title),
        html_escape(&value),
        html_escape(description),
        html_escape(reason)
    )
}
pub(crate) fn panel(value: &Value) -> String {
    let report = &value["report"];
    let metrics = &report["metrics"];
    let counts = match (
        report["trace_count"].as_u64(),
        report["variant_count"].as_u64(),
    ) {
        (Some(traces), Some(variants)) => {
            format!("Использовано трасс: {traces}. Вариантов: {variants}.")
        }
        _ => "Количество трасс и вариантов не определено: расчёт не выполнен.".into(),
    };
    let relation = if value["on_construction_log"] == true {
        "Оценка на журнале построения модели."
    } else {
        "Выбран другой журнал. Само это различие не доказывает независимость от данных построения."
    };
    format!(
        "<section id=\"quality-result\" class=\"platform-card\" aria-live=\"polite\"><h2>Результат оценки</h2><p>Модель: {} · версия {}. Журнал: {} · версия анализа {}.</p><p>{relation}</p><div class=\"stats-grid\">{}{}{}</div><p>{counts} Простота характеризует структуру сети и не доказывает корректность процесса.</p><details><summary>Данные расчёта</summary><pre>{}</pre></details></section>",
        html_escape(value["model_name"].as_str().unwrap_or("")),
        value["model_revision"],
        html_escape(value["log_name"].as_str().unwrap_or("")),
        value["analysis_version"],
        metric_card(
            "Соответствие журналу",
            "Fitness: насколько модель воспроизводит наблюдённые последовательности.",
            &metrics["fitness"],
            metrics["fitness"]["fitness"]["log_fitness"].as_f64()
        ),
        metric_card(
            "Точность поведения",
            "Precision: чем выше оценка, тем меньше лишнего поведения допускает модель.",
            &metrics["precision"],
            metrics["precision"]["scalar"].as_f64()
        ),
        metric_card(
            "Простота структуры",
            "Simplicity: оценка степени связности представленной сети.",
            &metrics["simplicity"],
            metrics["simplicity"]["scalar"].as_f64()
        ),
        html_escape(&serde_json::to_string_pretty(value).expect("report_json"))
    )
}

async fn evaluate(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    headers: HeaderMap,
    Form(form): Form<PreviewForm>,
) -> Response {
    let datastar = headers.get("Datastar-Request").is_some_and(|v| v == "true");
    let wants_json = headers
        .get(axum::http::header::ACCEPT)
        .is_some_and(|v| v == "application/json");
    if form.log_id.len() > 128 {
        return problem(
            error("not_found", "Журнал не найден."),
            datastar,
            wants_json,
        );
    }
    let result = run_preview(state, id, form, wants_json, datastar, |_| {}).await;
    match result {
        Ok(response) => response,
        Err(e) => problem(e, datastar, wants_json),
    }
}

async fn run_preview(
    state: AppState,
    id: String,
    form: PreviewForm,
    wants_json: bool,
    datastar: bool,
    mut observer: impl FnMut(&str) + Send + 'static,
) -> Result<Response, ImportError> {
    let reservation = state.jobs.reserve().map_err(|_| {
        error(
            "quality_busy",
            "Две операции уже выполняются. Повторите позже.",
        )
    })?;
    let permit = state
        .cpu
        .clone()
        .try_acquire_owned()
        .map_err(|_| error("quality_busy", "Вычислители заняты. Повторите позже."))?;
    tokio::task::spawn_blocking(move || {
        // These three admissions (including state.payload_permit) outlive a dropped HTTP future.
        let _reservation = reservation;
        let _permit = permit;
        compute(&state, &id, &form, wants_json, datastar, &mut observer)
    })
    .await
    .map_err(|_| error("quality_worker", "Расчёт прерван. Результат не сохранён."))?
}

fn compute(
    state: &AppState,
    id: &str,
    form: &PreviewForm,
    wants_json: bool,
    datastar: bool,
    observer: &mut impl FnMut(&str),
) -> Result<Response, ImportError> {
    state.validate_resource_actor()?;
    let actor = state
        .actor
        .as_ref()
        .ok_or_else(|| error("access_denied", "Войдите в проект."))?;
    if !actor.role.can_write() {
        return Err(error("access_denied", "Расчёт доступен редактору проекта."));
    }
    let (model, log) = {
        let mut repo = state.repository.lock().expect("repository mutex");
        let model = repo
            .get_model(state, id)?
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
        (model, log)
    };
    let rows = rows(&log.data)?;
    let deadline = Instant::now() + Duration::from_secs(30);
    let computed = facade::evaluate_model(&model.model, &rows, &Value::Null, &mut |stage| {
        observer(stage);
        if Instant::now() >= deadline {
            return Err(Issue::cap("deadline"));
        }
        state
            .validate_resource_actor()
            .map_err(|_| Issue::refused("access_denied"))
    });
    let report = match computed {
        Ok(report) => report,
        Err(issue) if issue.reason == "access_denied" => {
            return Err(error("access_denied", "Права проекта изменились."));
        }
        Err(issue) => {
            json!({"schema_version":1,"profile":"application_bounded_v1","metrics":{"fitness":issue,"precision":{"status":"inconclusive","reason":"model_not_admitted"},"simplicity":{"status":"inconclusive","reason":"model_not_admitted"}}})
        }
    };
    let value = json!({"model_id":id,"model_name":model.name,"model_revision":model.revision,"log_id":form.log_id,"log_name":log.filename,"analysis_version":log.analysis_version,"source_sha256":log.source_sha256,"on_construction_log":model.source_log.as_deref()==Some(form.log_id.as_str()),"saved_history":false,"report":report});
    observer("publish");
    let mut repo = state.repository.lock().expect("repository mutex");
    let current_model = repo
        .get_model(state, id)?
        .ok_or_else(|| error("quality_conflict", "Модель удалена во время расчёта."))?;
    let current_log = repo
        .get_log_base(state, &form.log_id)?
        .ok_or_else(|| error("quality_conflict", "Журнал удалён во время расчёта."))?;
    if current_model.revision != model.revision
        || current_log.analysis_version != log.analysis_version
        || current_log.source_sha256 != log.source_sha256
    {
        return Err(error(
            "quality_conflict",
            "Модель или журнал изменились во время расчёта. Повторите оценку.",
        ));
    }
    let platform = state
        .platform
        .as_ref()
        .ok_or_else(|| error("platform_unavailable", "Нужен проект PostgreSQL."))?;
    platform.auth.with_write_access(
        state
            .session
            .as_deref()
            .ok_or_else(|| error("access_denied", "Войдите в проект."))?,
        actor,
        || Ok(success(value, wants_json, datastar)),
    )
}

fn success(value: Value, wants_json: bool, datastar: bool) -> Response {
    if wants_json {
        Json(value).into_response()
    } else if datastar {
        patch(panel(&value))
    } else {
        crate::platform::page("Оценка BPMN", panel(&value))
    }
}

fn patch(html: String) -> Response {
    let data = html
        .lines()
        .map(|line| format!("elements {line}"))
        .collect::<Vec<_>>()
        .join("\n");
    Sse::new(futures_util::stream::once(async move {
        Ok::<_, Infallible>(
            Event::default()
                .event("datastar-patch-elements")
                .data(format!("selector #quality-result\nmode outer\n{data}")),
        )
    }))
    .into_response()
}

fn problem(e: ImportError, datastar: bool, wants_json: bool) -> Response {
    if wants_json {
        return failure(e);
    }
    let html = format!(
        "<section id=\"quality-result\" class=\"platform-card\" aria-live=\"polite\"><h2>Оценка не получена</h2><p role=\"alert\">{}</p><p>Предыдущая оценка больше не показана. Исправьте причину и повторите расчёт.</p></section>",
        html_escape(&e.message)
    );
    if datastar {
        patch(html)
    } else {
        let status = failure(e).status();
        let mut response = crate::platform::page("Оценка BPMN", html);
        *response.status_mut() = status;
        response
    }
}
