use crate::{
    domain::{Case, Event, EventLog, ImportError},
    event_io::Limits,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NormalizationOrder {
    #[default]
    Source,
    Timestamp,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CsvMapping {
    pub case_column: String,
    pub activity_column: String,
    pub timestamp_column: Option<String>,
    pub lifecycle_column: Option<String>,
    pub delimiter: u8,
    pub order: NormalizationOrder,
}
#[derive(Debug, Serialize)]
pub struct CsvPreview {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
}
fn reader(input: &[u8], delimiter: u8) -> Result<csv::Reader<&[u8]>, ImportError> {
    if input.len() > Limits::default().max_bytes {
        return Err(ImportError::new("byte_limit", "Файл превышает 20 MiB."));
    }
    if !b",;\t".contains(&delimiter) {
        return Err(ImportError::new(
            "csv_separator",
            "Выберите запятую, точку с запятой или табуляцию.",
        ));
    }
    std::str::from_utf8(input)
        .map_err(|_| ImportError::new("csv_utf8", "CSV должен быть UTF-8."))?;
    Ok(csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .flexible(false)
        .from_reader(input))
}
fn csv_error(error: csv::Error) -> ImportError {
    ImportError::new(
        "csv_format",
        format!(
            "Строка {}: неверный формат CSV.",
            error.position().map_or(1, |p| p.line())
        ),
    )
}
fn headers(reader: &mut csv::Reader<&[u8]>) -> Result<Vec<String>, ImportError> {
    let h: Vec<String> = reader
        .headers()
        .map_err(csv_error)?
        .iter()
        .map(str::to_owned)
        .collect();
    if h.is_empty()
        || h.iter().any(String::is_empty)
        || h.iter().collect::<BTreeSet<_>>().len() != h.len()
    {
        return Err(ImportError::new(
            "csv_header",
            "Названия колонок должны быть непустыми и уникальными.",
        ));
    }
    Ok(h)
}
pub fn preview(input: &[u8], delimiter: u8) -> Result<CsvPreview, ImportError> {
    let mut r = reader(input, delimiter)?;
    let headers = headers(&mut r)?;
    let rows = r
        .records()
        .take(5)
        .map(|v| {
            v.map(|v| v.iter().map(str::to_owned).collect())
                .map_err(csv_error)
        })
        .collect::<Result<_, _>>()?;
    Ok(CsvPreview { headers, rows })
}
pub fn parse_csv(input: &[u8], mapping: &CsvMapping) -> Result<EventLog, ImportError> {
    let limits = Limits::default();
    let mut r = reader(input, mapping.delimiter)?;
    let h = headers(&mut r)?;
    let column = |name: &str| {
        h.iter()
            .position(|v| v == name)
            .ok_or_else(|| ImportError::new("csv_mapping", format!("Колонка {name} не найдена.")))
    };
    let c = column(&mapping.case_column)?;
    let a = column(&mapping.activity_column)?;
    let t = mapping
        .timestamp_column
        .as_deref()
        .filter(|v| !v.is_empty())
        .map(column)
        .transpose()?;
    let l = mapping
        .lifecycle_column
        .as_deref()
        .filter(|v| !v.is_empty())
        .map(column)
        .transpose()?;
    let indices = [Some(c), Some(a), t, l]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    if indices.iter().collect::<BTreeSet<_>>().len() != indices.len() {
        return Err(ImportError::new(
            "csv_mapping",
            "Для разных полей выберите разные колонки.",
        ));
    }
    let mut cases: Vec<Case> = Vec::new();
    let mut case_map: BTreeMap<String, usize> = BTreeMap::new();
    for (ordinal, record) in r.records().enumerate() {
        if ordinal >= limits.max_events {
            return Err(ImportError::new("event_limit", "Превышен предел событий."));
        }
        let record = record.map_err(csv_error)?;
        let line = record.position().map_or((ordinal + 2) as u64, |p| p.line());
        let err = |code: &str, text: &str| ImportError::new(code, format!("Строка {line}: {text}"));
        let case = record.get(c).unwrap_or("");
        let activity = record.get(a).unwrap_or("");
        if case.is_empty() {
            return Err(err("csv_case", "Пустой идентификатор трассы."));
        }
        if activity.is_empty() {
            return Err(err("csv_activity", "Пустое название действия."));
        }
        if activity.len() > limits.max_activity_bytes {
            return Err(err(
                "activity_limit",
                "Название действия превышает 4096 UTF-8 bytes.",
            ));
        }
        let timestamp = match t
            .map(|i| record.get(i).unwrap_or(""))
            .filter(|v| !v.is_empty())
        {
            Some(value) => Some(
                DateTime::parse_from_rfc3339(value)
                    .map_err(|_| err("csv_timestamp", "Нужен RFC3339 timestamp с часовым поясом."))?
                    .with_timezone(&Utc),
            ),
            None => None,
        };
        if mapping.order == NormalizationOrder::Timestamp && timestamp.is_none() {
            return Err(err(
                "csv_timestamp",
                "Для сортировки по времени нужны timestamps всех событий.",
            ));
        }
        let index = if let Some(index) = case_map.get(case) {
            *index
        } else {
            if cases.len() >= limits.max_cases {
                return Err(err("case_limit", "Превышен предел трасс."));
            }
            let index = cases.len();
            case_map.insert(case.to_owned(), index);
            cases.push(Case {
                id: format!("case-{index}"),
                name: Some(case.into()),
                events: Vec::new(),
            });
            index
        };
        cases[index].events.push(Event {
            ordinal,
            activity: activity.into(),
            timestamp,
            lifecycle: l
                .and_then(|i| record.get(i))
                .filter(|v| !v.is_empty())
                .map(str::to_owned),
        });
    }
    let mut log = EventLog {
        name: None,
        cases,
        warnings: Vec::new(),
    };
    normalize(&mut log, mapping.order)?;
    Ok(log)
}
pub fn normalize(log: &mut EventLog, order: NormalizationOrder) -> Result<(), ImportError> {
    if order == NormalizationOrder::Timestamp {
        for case in &mut log.cases {
            if case.events.iter().any(|e| e.timestamp.is_none()) {
                return Err(ImportError::new(
                    "missing_timestamp",
                    "Для сортировки по времени нужны timestamps всех событий.",
                ));
            }
            case.events.sort_by_key(|e| (e.timestamp, e.ordinal));
        }
    }
    Ok(())
}
