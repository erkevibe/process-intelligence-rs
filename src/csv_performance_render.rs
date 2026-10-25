//! HTML for an actor-scoped temporary CSV preview; no stored repository fields.
use super::CsvPerformanceForm;
use crate::{csv_io::NormalizationOrder, csv_performance::Report, platform_render::html_escape};

fn duration(value: Option<f64>) -> String {
    let Some(seconds) = value else {
        return "Нет данных".into();
    };
    let (value, unit) = if seconds.abs() >= 86_400.0 {
        (seconds / 86_400.0, "дн.")
    } else if seconds.abs() >= 3600.0 {
        (seconds / 3600.0, "ч")
    } else if seconds.abs() >= 60.0 {
        (seconds / 60.0, "мин")
    } else {
        (seconds, "с")
    };
    format!("{value:.2} {unit}")
}
fn label(kind: &str, days: u32) -> String {
    match kind {
        "fast" => format!("Короче {days} дней"),
        "boundary" => format!("Ровно {days} дней"),
        "slow" => format!("Дольше {days} дней"),
        _ => "Все случаи".into(),
    }
}
fn hidden(form: &CsvPerformanceForm, include_cohort: bool) -> String {
    let order = match form.order {
        NormalizationOrder::Source => "source",
        NormalizationOrder::Timestamp => "timestamp",
    };
    let values = [
        ("token", form.token.as_str()),
        ("case_column", form.case_column.as_str()),
        ("activity_column", form.activity_column.as_str()),
        ("timestamp_column", form.timestamp_column.as_str()),
        (
            "start_timestamp_column",
            form.start_timestamp_column.as_str(),
        ),
        (
            "naive_timestamp_offset",
            form.naive_timestamp_offset.as_str(),
        ),
        ("lifecycle_column", form.lifecycle_column.as_str()),
        ("order", order),
    ];
    let mut html = String::new();
    for (name, value) in values {
        html.push_str(&format!(
            "<input type=\"hidden\" name=\"{name}\" value=\"{}\">",
            html_escape(value)
        ));
    }
    if include_cohort {
        html.push_str(&format!("<input type=\"hidden\" name=\"cohort\" value=\"{}\"><input type=\"hidden\" name=\"threshold_days\" value=\"{}\">", html_escape(&form.cohort), form.threshold_days));
    }
    html
}

pub(super) fn render(report: &Report, filename: &str, form: &CsvPerformanceForm) -> String {
    let cohort = report
        .cohorts
        .iter()
        .find(|v| v.kind == form.cohort)
        .expect("validated cohort");
    let order = match report.order {
        NormalizationOrder::Source => "порядок строк CSV",
        NormalizationOrder::Timestamp => {
            "порядок по окончанию действия, при равенстве — по строке CSV"
        }
    };
    let mut html = format!(
        "<section class=\"platform-heading\"><div class=\"eyebrow\">ПРЕДПРОСМОТР CSV</div><h1>Длительности и повторные прохождения</h1><p>{}</p></section><section class=\"platform-card\"><p>Длительность случая — от самого раннего начала до самого позднего окончания среди его записей. Это наблюдаемая часть процесса в файле, включая возможные незавершённые случаи. Рабочий календарь не применяется.</p><p>Начало: <strong>{}</strong>. Окончание: <strong>{}</strong>. Используется {}.</p>",
        html_escape(filename),
        html_escape(&report.start_column),
        html_escape(&report.end_column),
        order
    );
    if let Some(offset) = &report.naive_timestamp_offset {
        html.push_str(&format!("<p>Для дат без пояса явно выбрано смещение UTC{}. Смещения в самом файле сохраняются. Переход на летнее время не применяется.</p>", html_escape(offset)));
    } else {
        html.push_str("<p>Часовые пояса взяты из отметок времени файла.</p>");
    }
    html.push_str("<p>Просмотр временный: пять минут с момента загрузки CSV. Он не меняет проект. Скачайте отчёт, если хотите сохранить эти расчёты по двум колонкам.</p></section><section class=\"platform-card\"><h2>Сравнение длительностей случаев</h2><div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Группа</th><th>Случаев</th><th>Событий</th><th>Средняя длительность</th></tr></thead><tbody>");
    for group in &report.cohorts {
        html.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            label(group.kind, report.threshold_days),
            group.cases,
            group.events,
            duration(group.cycle.as_ref().map(|v| v.mean_seconds))
        ));
    }
    html.push_str("</tbody></table></div><p>Случаи ровно на границе показаны отдельно. Пустая группа не получает нулевую среднюю длительность.</p><form class=\"platform-form\" method=\"post\" action=\"/csv/performance\">");
    html.push_str(&hidden(form, false));
    html.push_str(&format!("<label>Граница длительности, дней<input type=\"number\" name=\"threshold_days\" min=\"1\" max=\"3650\" required value=\"{}\"></label><label>Подробности для группы<select name=\"cohort\">", form.threshold_days));
    for kind in ["all", "fast", "boundary", "slow"] {
        html.push_str(&format!(
            "<option value=\"{kind}\" {}>{}</option>",
            if kind == form.cohort { "selected" } else { "" },
            label(kind, report.threshold_days)
        ));
    }
    html.push_str(
        "</select></label><button class=\"button\">Обновить сравнение</button></form></section>",
    );
    html.push_str(&format!("<section class=\"platform-card\"><h2>{}</h2><p>Действий: {}. Переходов: {}. Отрицательных интервалов конец→начало: {}.</p>", label(cohort.kind, report.threshold_days), cohort.activity_count, cohort.transition_count, cohort.negative_intervals));
    if cohort.cases == 0 {
        html.push_str("<p>В этой группе нет случаев.</p>");
    } else {
        html.push_str("<h3>Частота и длительность действий</h3><div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Действие</th><th>Событий</th><th>Случаев</th><th>Среднее от начала до окончания</th></tr></thead><tbody>");
        for activity in &cohort.activities {
            html.push_str(&format!(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
                html_escape(&activity.activity),
                activity.events,
                activity.cases,
                duration(Some(activity.processing.mean_seconds))
            ));
        }
        html.push_str("</tbody></table></div><h3>Интервалы между соседними действиями</h3><p>От окончания предыдущего до начала следующего действия в выбранном порядке. Отрицательный интервал означает перекрытие во времени или иной порядок записей. Эти интервалы сами по себе не доказывают ожидание ресурса. Средняя считается по всем наблюдениям, включая отрицательные.</p><div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Из</th><th>В</th><th>Наблюдений</th><th>Случаев</th><th>Средний интервал</th><th>Отрицательных</th></tr></thead><tbody>");
        for transition in &cohort.transitions {
            html.push_str(&format!(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
                html_escape(&transition.source),
                html_escape(&transition.target),
                transition.end_to_start.samples,
                transition.cases,
                duration(Some(transition.end_to_start.mean_seconds)),
                transition.end_to_start.negative_samples
            ));
        }
        html.push_str("</tbody></table></div><h3>Непосредственные возвраты A → B → A</h3><p>Наблюдённые последовательности из трёх соседних записей с разными A и B. Это не полный поиск всех циклов BPMN.</p><div class=\"platform-table-wrap\"><table class=\"platform-table\"><thead><tr><th>Из и обратно</th><th>Через</th><th>Повторений</th><th>Случаев</th></tr></thead><tbody>");
        for pattern in &cohort.returns {
            html.push_str(&format!(
                "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
                html_escape(&pattern.source),
                html_escape(&pattern.via),
                pattern.occurrences,
                pattern.cases
            ));
        }
        html.push_str("</tbody></table></div>");
    }
    if cohort.details_truncated {
        html.push_str(&format!("<p>Подробные таблицы и экспорт содержат до {} строк каждого вида для группы. Общие счётчики и средняя длительность случая рассчитаны по всей группе.</p>", report.detail_limit_per_cohort));
    }
    html.push_str("</section><section class=\"platform-card\"><form method=\"post\" action=\"/csv/performance\">");
    html.push_str(&hidden(form, true));
    html.push_str("<button class=\"button\" name=\"output\" value=\"json\">Скачать отчёт о длительностях JSON</button></form><p>Суммы, минимум и максимум в наносекундах экспортируются точными целыми строками. Значения в таблицах округлены для показа.</p><form method=\"post\" action=\"/csv/import\">");
    html.push_str(&hidden(form, true));
    html.push_str("<p>В журнал импортируется одна отметка из колонки времени события. Расчёты по двум колонкам сохраняйте отдельным отчётом.</p><button class=\"button primary\">Импортировать журнал</button></form><p><a href=\"/csv\">Загрузить другой CSV</a></p></section>");
    html
}
