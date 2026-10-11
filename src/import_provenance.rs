//! Immutable source and server-observed import history. Never mutable view state.
use crate::{
    domain::{EventLog, ImportError},
    service_preview::{self, Preview},
    storage::sha256,
};
use serde::{Deserialize, Serialize};

pub const MAX_ACTIONS: usize = 200_000;
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportAction {
    pub case_index: usize,
    pub event_index: Option<usize>,
    pub action: String,
    pub reasons: Vec<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportProvenance {
    pub schema_version: u32,
    pub operation_id: String,
    pub actor_id: String,
    pub origin_project_id: String,
    pub confirmed_at: chrono::DateTime<chrono::Utc>,
    pub policy: String,
    pub original_utf8: String,
    pub source_sha256: String,
    pub source_cases: usize,
    pub source_events: usize,
    pub actions: Vec<ImportAction>,
}
fn actions(preview: &Preview) -> Vec<ImportAction> {
    preview
        .changes
        .iter()
        .map(|c| ImportAction {
            case_index: c.case_index,
            event_index: c.event_index,
            action: c.action.into(),
            reasons: c.reasons.iter().map(|s| (*s).into()).collect(),
        })
        .collect()
}
fn invalid() -> ImportError {
    ImportError::new(
        "provenance_invalid",
        "Исходник или история импорта повреждены либо не поддерживаются.",
    )
}
impl ImportProvenance {
    pub fn capture(
        raw: String,
        preview: &Preview,
        actor_id: String,
        project_id: String,
        operation_id: String,
    ) -> Result<Self, ImportError> {
        if preview.changes.len() > MAX_ACTIONS || preview.fully_filtered {
            return Err(ImportError::new(
                "preview_unusable",
                "Пустой результат или слишком много изменений для подтверждения.",
            ));
        }
        Ok(Self {
            schema_version: 1,
            operation_id,
            actor_id,
            origin_project_id: project_id,
            confirmed_at: chrono::Utc::now(),
            policy: preview.policy.into(),
            source_sha256: sha256(raw.as_bytes()),
            original_utf8: raw,
            source_cases: preview.source_cases,
            source_events: preview.source_events,
            actions: actions(preview),
        })
    }
    pub fn validate(&self, source: &EventLog, digest: &str) -> Result<(), ImportError> {
        if self.schema_version != 1
            || self.original_utf8.len() > 20 * 1024 * 1024
            || self.actions.len() > MAX_ACTIONS
            || self.actor_id.is_empty()
            || self.actor_id.len() > 128
            || self.origin_project_id.is_empty()
            || self.origin_project_id.len() > 128
            || uuid::Uuid::parse_str(&self.operation_id).is_err()
            || self.source_sha256 != digest
            || sha256(self.original_utf8.as_bytes()) != digest
        {
            return Err(invalid());
        }
        let preview =
            service_preview::preview_xes(self.original_utf8.as_bytes()).map_err(|_| invalid())?;
        if preview.fully_filtered
            || preview.policy != self.policy
            || preview.source_cases != self.source_cases
            || preview.source_events != self.source_events
            || preview.log != *source
            || actions(&preview) != self.actions
        {
            return Err(invalid());
        }
        Ok(())
    }
    /// Conservative owned-allocation charge, independently of active request memory.
    pub(crate) fn charge(&self) -> usize {
        let text = |s: &String| s.capacity().saturating_add(32);
        std::mem::size_of::<Self>()
            .saturating_add(32)
            .saturating_add(text(&self.operation_id))
            .saturating_add(text(&self.actor_id))
            .saturating_add(text(&self.origin_project_id))
            .saturating_add(text(&self.policy))
            .saturating_add(text(&self.original_utf8))
            .saturating_add(text(&self.source_sha256))
            .saturating_add(
                self.actions
                    .capacity()
                    .saturating_mul(std::mem::size_of::<ImportAction>()),
            )
            .saturating_add(32)
            .saturating_add(
                self.actions
                    .iter()
                    .map(|a| {
                        text(&a.action)
                            .saturating_add(
                                a.reasons
                                    .capacity()
                                    .saturating_mul(std::mem::size_of::<String>()),
                            )
                            .saturating_add(32)
                            .saturating_add(a.reasons.iter().map(text).sum::<usize>())
                    })
                    .sum::<usize>(),
            )
    }
}
