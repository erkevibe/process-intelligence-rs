//! Opt-in, non-persisting preview of the pinned Apromore validateLog policy.
//! Strict admission divergences are deliberate; this is not the whole service.
use crate::{
    domain::{Case, Event, EventLog, ImportError},
    event_io::{Limits, preflight_profile},
};
use chrono::Utc;
use process_mining::core::event_data::case_centric::xes::{XESImportOptions, import_xes_slice};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Change {
    pub case_index: usize,
    pub event_index: Option<usize>,
    pub action: &'static str,
    pub reasons: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct Preview {
    pub policy: &'static str,
    pub source_cases: usize,
    pub source_events: usize,
    pub fully_filtered: bool,
    pub changes: Vec<Change>,
    pub log: EventLog,
}

pub fn preview_xes(input: &[u8]) -> Result<Preview, ImportError> {
    preview_xes_checked(input, Limits::default(), &|| false)
}

/// Checks limits on the original input, including events later removed.
pub fn preview_xes_checked(
    input: &[u8],
    limits: Limits,
    cancelled: &dyn Fn() -> bool,
) -> Result<Preview, ImportError> {
    let check = || {
        if cancelled() {
            Err(ImportError::new(
                "cancelled",
                "Предварительный просмотр отменён.",
            ))
        } else {
            Ok(())
        }
    };
    let normalized = preflight_profile(input, limits, cancelled, true)?;
    check()?;
    let raw = import_xes_slice(
        &normalized,
        false,
        XESImportOptions {
            verbose: false,
            sort_events_with_timestamp_key: None,
            ..Default::default()
        },
    )
    .map_err(|_| ImportError::new("xes_parse", "Не удалось разобрать XES."))?;
    check()?;
    let name = raw
        .attributes
        .iter()
        .find(|a| a.key == "concept:name")
        .and_then(|a| a.value.try_as_string())
        .cloned();
    let source_cases = raw.traces.len();
    let source_events = raw.traces.iter().map(|t| t.events.len()).sum();
    let mut changes = Vec::new();
    let mut cases = Vec::new();
    for (case_index, trace) in raw.traces.into_iter().enumerate() {
        check()?;
        let name = trace
            .attributes
            .iter()
            .find(|a| a.key == "concept:name")
            .and_then(|a| a.value.try_as_string())
            .cloned();
        let mut events = Vec::new();
        for (ordinal, event) in trace.events.into_iter().enumerate() {
            check()?;
            let activity = event
                .attributes
                .iter()
                .find(|a| a.key == "concept:name")
                .and_then(|a| a.value.try_as_string())
                .cloned();
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
            if lifecycle.is_none() {
                changes.push(Change {
                    case_index,
                    event_index: Some(ordinal),
                    action: "default_lifecycle",
                    reasons: vec!["missing_lifecycle"],
                });
            }
            let lifecycle = lifecycle.unwrap_or_else(|| "complete".into());
            let mut reasons = Vec::new();
            if activity.is_none() {
                reasons.push("missing_activity");
            }
            if timestamp.is_none() {
                reasons.push("missing_timestamp");
            }
            if !lifecycle.eq_ignore_ascii_case("start")
                && !lifecycle.eq_ignore_ascii_case("complete")
            {
                reasons.push("unsupported_lifecycle");
            }
            if !reasons.is_empty() {
                changes.push(Change {
                    case_index,
                    event_index: Some(ordinal),
                    action: "remove_event",
                    reasons,
                });
                continue;
            }
            events.push(Event {
                ordinal,
                activity: activity.expect("checked presence"),
                timestamp,
                lifecycle: Some(lifecycle),
            });
        }
        if events.is_empty() {
            changes.push(Change {
                case_index,
                event_index: None,
                action: "remove_case",
                reasons: vec!["empty_case"],
            });
        } else {
            cases.push(Case {
                id: format!("case-{case_index}"),
                name,
                events,
            });
        }
    }
    check()?;
    Ok(Preview {
        policy: "apromore-validateLog-bbf24df-preview-v1",
        source_cases, source_events, fully_filtered: cases.is_empty(), changes,
        log: EventLog { name, cases, warnings: vec!["Предварительный просмотр: исходные данные не изменены. Это не полный сервис Apromore.".into()] }
    })
}
