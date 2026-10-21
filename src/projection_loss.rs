//! Bounded disclosure of source metadata omitted by the analysis projection.
//! Values stay in the original XES; this report never changes import policy.
use process_mining::core::event_data::case_centric::{Attribute, AttributeValue, EventLog};
use serde::Serialize;
use std::collections::BTreeMap;

const MAX_GROUPS: usize = 128;
const MAX_KEY_BYTES: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OmittedAttribute {
    pub scope: &'static str,
    pub key: String,
    pub value_type: &'static str,
    pub occurrences: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ProjectionReport {
    pub schema_version: u32,
    pub admission_profile: &'static str,
    pub basis: &'static str,
    pub omitted_log_attributes: usize,
    pub omitted_trace_attributes: usize,
    pub omitted_event_attributes: usize,
    pub ignored_classifiers: usize,
    pub omitted_extension_declarations: usize,
    pub timestamp_offsets_normalized_to_utc: usize,
    pub attributes: Vec<OmittedAttribute>,
    /// Occurrences excluded by the group/key display limits, not lost counts.
    pub unlisted_attribute_occurrences: usize,
}

impl ProjectionReport {
    pub fn has_omissions(&self) -> bool {
        self.omitted_log_attributes
            + self.omitted_trace_attributes
            + self.omitted_event_attributes
            + self.ignored_classifiers
            + self.omitted_extension_declarations
            > 0
    }
}

fn kind(value: &AttributeValue) -> &'static str {
    match value {
        AttributeValue::String(_) => "string",
        AttributeValue::Date(_) => "date",
        AttributeValue::Int(_) => "int",
        AttributeValue::Float(_) => "float",
        AttributeValue::Boolean(_) => "boolean",
        AttributeValue::ID(_) => "id",
        AttributeValue::List(_) => "list",
        AttributeValue::Container(_) => "container",
        AttributeValue::None() => "invalid",
    }
}

pub(crate) fn inspect(log: &EventLog, cancelled: &dyn Fn() -> bool) -> Option<ProjectionReport> {
    let mut report = ProjectionReport {
        schema_version: 1,
        admission_profile: "flat_xes_no_global_defaults_or_nested_attributes",
        basis: "all_source_attributes_before_event_filtering",
        omitted_log_attributes: 0,
        omitted_trace_attributes: 0,
        omitted_event_attributes: 0,
        ignored_classifiers: log.classifiers.as_ref().map_or(0, Vec::len),
        omitted_extension_declarations: log.extensions.as_ref().map_or(0, Vec::len),
        timestamp_offsets_normalized_to_utc: 0,
        attributes: Vec::new(),
        unlisted_attribute_occurrences: 0,
    };
    let mut groups: BTreeMap<(&'static str, String, &'static str), usize> = BTreeMap::new();
    let mut add = |scope, attribute: &Attribute| {
        if attribute.key.len() > MAX_KEY_BYTES {
            report.unlisted_attribute_occurrences += 1;
            return;
        }
        let key = (scope, attribute.key.clone(), kind(&attribute.value));
        if let Some(count) = groups.get_mut(&key) {
            *count += 1;
        } else if groups.len() < MAX_GROUPS {
            groups.insert(key, 1);
        } else {
            report.unlisted_attribute_occurrences += 1;
        }
    };
    let retained_name = |attributes: &[Attribute]| {
        attributes
            .iter()
            .position(|a| a.key == "concept:name")
            .filter(|&index| attributes[index].value.try_as_string().is_some())
    };
    let log_name = retained_name(&log.attributes);
    for (index, attribute) in log.attributes.iter().enumerate() {
        if cancelled() {
            return None;
        }
        if Some(index) != log_name {
            report.omitted_log_attributes += 1;
            add("log", attribute);
        }
    }
    for trace in &log.traces {
        if cancelled() {
            return None;
        }
        let trace_name = retained_name(&trace.attributes);
        for (index, attribute) in trace.attributes.iter().enumerate() {
            if cancelled() {
                return None;
            }
            if Some(index) != trace_name {
                report.omitted_trace_attributes += 1;
                add("trace", attribute);
            }
        }
        for event in &trace.events {
            if cancelled() {
                return None;
            }
            for attribute in &event.attributes {
                if cancelled() {
                    return None;
                }
                if attribute.key == "time:timestamp" {
                    if let AttributeValue::Date(value) = &attribute.value
                        && value.offset().local_minus_utc() != 0
                    {
                        report.timestamp_offsets_normalized_to_utc += 1;
                    }
                } else if !matches!(
                    attribute.key.as_str(),
                    "concept:name" | "lifecycle:transition"
                ) {
                    report.omitted_event_attributes += 1;
                    add("event", attribute);
                }
            }
        }
    }
    report.attributes = groups
        .into_iter()
        .map(|((scope, key, value_type), occurrences)| OmittedAttribute {
            scope,
            key,
            value_type,
            occurrences,
        })
        .collect();
    Some(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn metadata_scan_can_be_cancelled_midway_without_changing_source() {
        let log = EventLog {
            attributes: (0..200)
                .map(|index| Attribute {
                    key: format!("key-{index}"),
                    value: AttributeValue::String("private".into()),
                    own_attributes: None,
                })
                .collect(),
            ..Default::default()
        };
        let original = log.clone();
        let progress = Cell::new(0);
        let cancelled = || {
            progress.set(progress.get() + 1);
            progress.get() > 10
        };
        assert!(inspect(&log, &cancelled).is_none());
        assert_eq!(log, original);
    }
}
