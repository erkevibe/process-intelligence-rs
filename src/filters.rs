use crate::domain::{EventLog, ImportError};
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct FilterSpec {
    pub case_activity: Option<String>,
    pub min_events: Option<usize>,
    pub max_events: Option<usize>,
    pub retain_activities: Vec<String>,
    pub remove_activities: Vec<String>,
}
pub fn apply(log: &EventLog, spec: &FilterSpec) -> Result<EventLog, ImportError> {
    if matches!((spec.min_events,spec.max_events),(Some(min),Some(max)) if min>max) {
        return Err(ImportError::new(
            "filter_range",
            "Минимальная длина больше максимальной.",
        ));
    }
    if spec
        .retain_activities
        .iter()
        .any(|v| spec.remove_activities.contains(v))
    {
        return Err(ImportError::new(
            "filter_conflict",
            "Действие нельзя одновременно сохранить и удалить.",
        ));
    }
    let mut result = log.clone();
    result.cases.retain(|c| {
        spec.case_activity
            .as_ref()
            .filter(|v| !v.is_empty())
            .is_none_or(|v| c.events.iter().any(|e| &e.activity == v))
            && spec.min_events.is_none_or(|n| c.events.len() >= n)
            && spec.max_events.is_none_or(|n| c.events.len() <= n)
    });
    for case in &mut result.cases {
        case.events.retain(|e| {
            (spec.retain_activities.is_empty() || spec.retain_activities.contains(&e.activity))
                && !spec.remove_activities.contains(&e.activity)
        });
    }
    Ok(result)
}
