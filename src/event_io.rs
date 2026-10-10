//! Contract validation before an intentionally narrow Rust4PM adapter.
use crate::domain::{Case, Event, EventLog, ImportError};
use chrono::{DateTime, Utc};
use process_mining::core::event_data::case_centric::xes::{XESImportOptions, import_xes_slice};
use quick_xml::{
    Reader, Writer,
    events::{BytesEnd, BytesStart, Event as XmlEvent},
};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_bytes: usize,
    pub max_events: usize,
    pub max_cases: usize,
    pub max_activity_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_bytes: 20 * 1024 * 1024,
            max_events: 100_000,
            max_cases: 20_000,
            max_activity_bytes: 4096,
        }
    }
}

pub fn parse_xes(input: &[u8]) -> Result<EventLog, ImportError> {
    parse_xes_with_limits(input, Limits::default())
}

pub fn parse_xes_with_limits(input: &[u8], limits: Limits) -> Result<EventLog, ImportError> {
    parse_xes_checked(input, limits, &|| false)
}

pub fn parse_xes_cancellable(
    input: &[u8],
    cancelled: &dyn Fn() -> bool,
) -> Result<EventLog, ImportError> {
    parse_xes_checked(input, Limits::default(), cancelled)
}

fn parse_xes_checked(
    input: &[u8],
    limits: Limits,
    cancelled: &dyn Fn() -> bool,
) -> Result<EventLog, ImportError> {
    let normalized = preflight(input, limits, cancelled)?;
    check_cancelled(cancelled)?;
    let options = XESImportOptions {
        verbose: false,
        sort_events_with_timestamp_key: None,
        ..Default::default()
    };
    let log = import_xes_slice(&normalized, false, options).map_err(|_| {
        ImportError::new(
            "xes_parse",
            "Не удалось разобрать XES. Проверьте структуру журнала.",
        )
    })?;
    check_cancelled(cancelled)?;
    let name = log
        .attributes
        .iter()
        .find(|a| a.key == "concept:name")
        .and_then(|a| a.value.try_as_string())
        .cloned();
    let mut cases = Vec::with_capacity(log.traces.len());
    for (case_index, trace) in log.traces.into_iter().enumerate() {
        check_cancelled(cancelled)?;
        let name = trace
            .attributes
            .iter()
            .find(|a| a.key == "concept:name")
            .and_then(|a| a.value.try_as_string())
            .cloned();
        let mut events = Vec::with_capacity(trace.events.len());
        for (ordinal, event) in trace.events.into_iter().enumerate() {
            let activity = event
                .attributes
                .iter()
                .find(|a| a.key == "concept:name")
                .and_then(|a| a.value.try_as_string())
                .cloned()
                .ok_or_else(|| {
                    ImportError::new(
                        "missing_activity",
                        "У события отсутствует строковое concept:name.",
                    )
                })?;
            let timestamp = event
                .attributes
                .iter()
                .find(|a| a.key == "time:timestamp")
                .and_then(|a| a.value.try_as_date())
                .map(|t| t.with_timezone(&Utc));
            let lifecycle = event
                .attributes
                .iter()
                .find(|a| a.key == "lifecycle:transition")
                .and_then(|a| a.value.try_as_string())
                .cloned();
            events.push(Event {
                ordinal,
                activity,
                timestamp,
                lifecycle,
            });
        }
        cases.push(Case {
            id: format!("case-{case_index}"),
            name,
            events,
        });
    }
    Ok(EventLog {
        name,
        cases,
        warnings: vec![
            "Порядок событий — как в XML. Lifecycle start/complete не объединяются.".into(),
            "Совместимость с Apromore ещё не подтверждена legacy oracle.".into(),
        ],
    })
}

#[derive(Default)]
struct Validation {
    stack: Vec<String>,
    root_seen: bool,
    cases: usize,
    events: usize,
    event_in_case: usize,
    activity_seen: bool,
    timestamp_seen: bool,
    lifecycle_seen: bool,
}

fn malformed(message: &str) -> ImportError {
    ImportError::new("malformed_xml", message)
}

fn check_cancelled(cancelled: &dyn Fn() -> bool) -> Result<(), ImportError> {
    if cancelled() {
        Err(ImportError::new(
            "cancelled",
            "Обработка отменена. Предыдущий анализ сохранён.",
        ))
    } else {
        Ok(())
    }
}

fn preflight(
    input: &[u8],
    limits: Limits,
    cancelled: &dyn Fn() -> bool,
) -> Result<Vec<u8>, ImportError> {
    if input.len() > limits.max_bytes {
        return Err(ImportError::new(
            "byte_limit",
            "Файл превышает допустимый размер.",
        ));
    }
    std::str::from_utf8(input)
        .map_err(|_| ImportError::new("encoding", "Поддерживается только UTF-8 XES."))?;
    let mut reader = Reader::from_reader(input);
    reader.config_mut().check_end_names = true;
    let mut state = Validation::default();
    let mut buffer = Vec::new();
    let mut normalized = Writer::new(Vec::with_capacity(input.len()));
    loop {
        check_cancelled(cancelled)?;
        let event = reader
            .read_event_into(&mut buffer)
            .map_err(|_| malformed("XML повреждён: проверьте теги и атрибуты."))?;
        // Rust4PM expects explicit structural start/end events and unprefixed tags.
        // Validation still applies to the original input, before this lossless rewrite.
        let write_error = |_| malformed("Не удалось нормализовать структуру XES.");
        match &event {
            XmlEvent::Start(tag) | XmlEvent::Empty(tag) => {
                let local = tag.local_name().as_ref().to_vec();
                let mut tag = tag.to_owned();
                tag.set_name(&local);
                if matches!(&event, XmlEvent::Empty(_))
                    && matches!(local.as_slice(), b"log" | b"trace" | b"event")
                {
                    normalized
                        .write_event(XmlEvent::Start(tag))
                        .map_err(write_error)?;
                    normalized
                        .write_event(XmlEvent::End(BytesEnd::new(String::from_utf8_lossy(
                            &local,
                        ))))
                        .map_err(write_error)?;
                } else if matches!(&event, XmlEvent::Empty(_)) {
                    normalized
                        .write_event(XmlEvent::Empty(tag))
                        .map_err(write_error)?;
                } else {
                    normalized
                        .write_event(XmlEvent::Start(tag))
                        .map_err(write_error)?;
                }
            }
            XmlEvent::End(tag) => {
                let local = tag.local_name().as_ref().to_vec();
                normalized
                    .write_event(XmlEvent::End(BytesEnd::new(String::from_utf8_lossy(
                        &local,
                    ))))
                    .map_err(write_error)?;
            }
            XmlEvent::Eof => {}
            _ => normalized.write_event(event.clone()).map_err(write_error)?,
        }
        match event {
            XmlEvent::Start(ref tag) | XmlEvent::Empty(ref tag) => {
                let empty = matches!(event, XmlEvent::Empty(_));
                let name = String::from_utf8(tag.local_name().as_ref().to_vec())
                    .map_err(|_| malformed("Некорректное имя XML-элемента."))?;
                let parent = state.stack.last().map(String::as_str);
                if matches!(name.as_str(), "global" | "list" | "container") {
                    return Err(ImportError::new(
                        "unsupported_format",
                        "Global defaults и вложенные list/container пока не поддерживаются.",
                    ));
                }
                match name.as_str() {
                    "log" if parent.is_none() && !state.root_seen => {
                        state.root_seen = true;
                    }
                    "trace" if parent == Some("log") => {
                        state.cases += 1;
                        state.event_in_case = 0;
                        if state.cases > limits.max_cases {
                            return Err(ImportError::new(
                                "case_limit",
                                "В журнале слишком много cases.",
                            ));
                        }
                    }
                    "event" if parent == Some("trace") => {
                        state.events += 1;
                        state.event_in_case += 1;
                        state.activity_seen = false;
                        state.timestamp_seen = false;
                        state.lifecycle_seen = false;
                        if state.events > limits.max_events {
                            return Err(ImportError::new(
                                "event_limit",
                                "В журнале слишком много событий.",
                            ));
                        }
                    }
                    "string" | "date" | "int" | "float" | "boolean" | "id"
                        if matches!(parent, Some("log" | "trace" | "event")) =>
                    {
                        validate_attribute(tag, &reader, &name, &mut state, limits)?;
                    }
                    "extension" | "classifier" if parent == Some("log") => {
                        attributes(tag, &reader)?;
                    }
                    _ => {
                        return Err(malformed(
                            "Неподдерживаемая структура XES: ожидаются log, trace и event.",
                        ));
                    }
                }
                if matches!(name.as_str(), "log" | "trace" | "event") {
                    attributes(tag, &reader)?;
                }
                if empty {
                    finish_element(&name, &state)?;
                } else {
                    state.stack.push(name);
                }
            }
            XmlEvent::End(ref tag) => {
                let name = std::str::from_utf8(tag.local_name().as_ref())
                    .map_err(|_| malformed("Некорректный закрывающий тег."))?
                    .to_owned();
                if state.stack.pop().as_deref() != Some(name.as_str()) {
                    return Err(malformed("Нарушена вложенность XML-тегов."));
                }
                finish_element(&name, &state)?;
            }
            XmlEvent::Text(ref text) => {
                let content = text
                    .unescape()
                    .map_err(|_| malformed("Неизвестная XML-сущность."))?;
                if !content.trim().is_empty() {
                    return Err(malformed("Значения XES должны находиться в атрибутах XML."));
                }
            }
            XmlEvent::CData(ref text) if !text.as_ref().iter().all(u8::is_ascii_whitespace) => {
                return Err(malformed(
                    "CDATA с данными в этом XES-subset не поддерживается.",
                ));
            }
            XmlEvent::DocType(_) => {
                return Err(ImportError::new(
                    "doctype",
                    "DTD и внешние сущности запрещены.",
                ));
            }
            XmlEvent::Decl(ref declaration) => {
                if state.root_seen {
                    return Err(malformed(
                        "XML declaration должна находиться перед журналом.",
                    ));
                }
                if let Some(encoding) = declaration.encoding() {
                    let encoding = encoding.map_err(|_| malformed("Некорректная XML encoding."))?;
                    if !encoding.as_ref().eq_ignore_ascii_case(b"UTF-8") {
                        return Err(ImportError::new(
                            "encoding",
                            "Поддерживается только UTF-8 XES.",
                        ));
                    }
                }
            }
            XmlEvent::Eof => {
                if !state.root_seen || !state.stack.is_empty() {
                    return Err(malformed("Отсутствует полный корневой элемент log."));
                }
                break;
            }
            _ => {}
        }
        buffer.clear();
    }
    Ok(normalized.into_inner())
}

fn finish_element(name: &str, state: &Validation) -> Result<(), ImportError> {
    if name == "event" && !state.activity_seen {
        let mut error = ImportError::new(
            "missing_activity",
            "У каждого события должно быть непустое concept:name.",
        );
        error.case_index = Some(state.cases.saturating_sub(1));
        error.event_index = Some(state.event_in_case.saturating_sub(1));
        return Err(error);
    }
    Ok(())
}

fn attributes(
    tag: &BytesStart<'_>,
    reader: &Reader<&[u8]>,
) -> Result<BTreeMap<String, String>, ImportError> {
    let mut result = BTreeMap::new();
    for attribute in tag.attributes() {
        let attribute =
            attribute.map_err(|_| malformed("Повторный или повреждённый XML-атрибут."))?;
        let key = std::str::from_utf8(attribute.key.as_ref())
            .map_err(|_| malformed("Неверное имя атрибута."))?
            .to_owned();
        let value = attribute
            .decode_and_unescape_value(reader.decoder())
            .map_err(|_| malformed("Некорректное значение или XML-сущность."))?
            .into_owned();
        result.insert(key, value);
    }
    Ok(result)
}

fn validate_attribute(
    tag: &BytesStart<'_>,
    reader: &Reader<&[u8]>,
    kind: &str,
    state: &mut Validation,
    limits: Limits,
) -> Result<(), ImportError> {
    let attrs = attributes(tag, reader)?;
    let key = attrs
        .get("key")
        .ok_or_else(|| malformed("У XES-атрибута отсутствует key."))?;
    let value = attrs
        .get("value")
        .ok_or_else(|| malformed("У XES-атрибута отсутствует value."))?;
    if state.stack.last().map(String::as_str) != Some("event") {
        return Ok(());
    }
    let mut error = None;
    match key.as_str() {
        "concept:name" => {
            if state.activity_seen {
                error = Some(ImportError::new(
                    "duplicate_key",
                    "Повторное concept:name у события.",
                ));
            } else if kind != "string" || value.trim().is_empty() {
                error = Some(ImportError::new(
                    "empty_activity",
                    "Activity должна быть непустой строкой.",
                ));
            } else if value.len() > limits.max_activity_bytes {
                error = Some(ImportError::new(
                    "activity_limit",
                    "Имя activity превышает лимит UTF-8 bytes.",
                ));
            }
            state.activity_seen = true;
        }
        "time:timestamp" => {
            if state.timestamp_seen {
                error = Some(ImportError::new(
                    "duplicate_key",
                    "Повторный timestamp у события.",
                ));
            } else if kind != "date" || DateTime::parse_from_rfc3339(value).is_err() {
                error = Some(ImportError::new(
                    "invalid_timestamp",
                    "Timestamp должен быть ISO 8601 с явно указанным часовым поясом.",
                ));
            }
            state.timestamp_seen = true;
        }
        "lifecycle:transition" => {
            if state.lifecycle_seen {
                error = Some(ImportError::new(
                    "duplicate_key",
                    "Повторный lifecycle у события.",
                ));
            } else if kind != "string" {
                error = Some(ImportError::new(
                    "invalid_lifecycle",
                    "Lifecycle должен быть строкой.",
                ));
            }
            state.lifecycle_seen = true;
        }
        _ => {}
    }
    if let Some(mut error) = error {
        error.case_index = Some(state.cases.saturating_sub(1));
        error.event_index = Some(state.event_in_case.saturating_sub(1));
        return Err(error);
    }
    Ok(())
}
