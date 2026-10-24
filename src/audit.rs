//! Bounded successful-business audit, persisted inside the mutation transaction.
use crate::domain::ImportError;
use serde::{Deserialize, Serialize};
pub const RETAINED: usize = 512;
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BusinessPolicy {
    pub version: u8,
    pub rule: String,
    pub parameters_sha256: String,
}
impl BusinessPolicy {
    /// Parameters originate in the validated server-side mutation, never in an
    /// actor/time/outcome field submitted by a client. Keep payloads out of audit.
    pub fn for_action(action: &str, parameters: &serde_json::Value) -> Result<Self, ImportError> {
        let rule = match action {
            "log_imported" => "strict_import_v1",
            "xes_import_confirmed" => "service_preview_confirm_v1",
            "filter_applied" => "source_case_then_activity_projection_v1",
            "calendar_changed" => "half_open_business_calendar_v1",
            "model_created" | "model_saved" => "validated_model_project_cas_v1",
            "folder_created" | "folder_renamed" | "folder_moved" | "folder_deleted"
            | "resource_moved" | "folder_changed" => "project_catalog_folder_cas_v1",
            "view_changed" => "actor_private_view_v1",
            "job_updated" => "durable_job_transition_v1",
            "conversion_accepted" | "conversion_job_updated" | "conversion_deleted" => {
                "durable_conversion_pair_cas_v1"
            }
            "quality_accepted" | "quality_job_updated" | "quality_deleted" => {
                "durable_quality_snapshot_cas_v1"
            }
            "discovery_accepted" | "discovery_job_updated" | "discovery_deleted" => {
                "durable_discovery_snapshot_model_cas_v1"
            }
            "jobs_interrupted_after_restart" => "restart_interrupted_job_v1",
            "project_created" => "current_writer_new_owner_project_v1",
            "project_renamed" => "owner_project_name_cas_v1",
            "project_moved" => "owner_project_list_placement_cas_v1",
            "project_list_folder_created"
            | "project_list_folder_renamed"
            | "project_list_folder_moved"
            | "project_list_folder_archived"
            | "project_list_folder_restored"
            | "project_list_folder_deleted" => "creator_current_writer_project_list_catalog_cas_v1",
            "project_archived" | "project_restored" => "owner_archive_session_cas_v1",
            "project_deleted" => "owner_archived_exact_confirmation_cas_v1",
            "membership_changed" => "owner_nonowner_membership_v1",
            "user_created" => "administrator_account_creation_v1",
            "platform_initialized" => "empty_workspace_initial_admin_v1",
            "project_backup_restored" => "writer_validated_new_project_restore_v1",
            "repository_updated" => "current_writer_repository_cas_v1",
            "quota_changed" => "owner_structural_bytes_v1_policy_cas_v1",
            _ => {
                return Err(ImportError::new(
                    "audit_policy",
                    "Политика действия не поддерживается.",
                ));
            }
        };
        Ok(Self {
            version: 1,
            rule: rule.into(),
            parameters_sha256: crate::storage::sha256(
                &serde_json::to_vec(parameters).map_err(|_| invalid())?,
            ),
        })
    }
    fn validate(&self, action: &str) -> Result<(), ImportError> {
        let expected = Self::for_action(action, &serde_json::Value::Null)?;
        if self.version != 1
            || self.rule != expected.rule
            || self.parameters_sha256.len() != 64
            || !self
                .parameters_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(invalid());
        }
        Ok(())
    }
}
fn invalid() -> ImportError {
    ImportError::new(
        "audit_invalid",
        "История действий повреждена или не поддерживается.",
    )
}
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BusinessOutcome {
    Committed,
}
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuditOrigin {
    ProjectBackupUnverified,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuditEntry {
    pub sequence: u64,
    pub at: chrono::DateTime<chrono::Utc>,
    pub actor: String,
    pub project: String,
    pub action: String,
    pub resources: Vec<String>,
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<AuditOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy: Option<BusinessPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<BusinessOutcome>,
}
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuditTrail {
    pub total: u64,
    pub entries: Vec<AuditEntry>,
}
impl AuditTrail {
    pub fn is_empty(&self) -> bool {
        self.total == 0 && self.entries.is_empty()
    }
    pub fn validate(&self) -> Result<(), ImportError> {
        if self.entries.len() > RETAINED
            || self.entries.len() as u64 != self.total.min(RETAINED as u64)
            || self.entries.iter().enumerate().any(|(i, e)| {
                e.sequence != self.total - self.entries.len() as u64 + i as u64 + 1
                    || e.actor.is_empty()
                    || e.actor.len() > 128
                    || e.project.is_empty()
                    || e.project.len() > 128
                    || e.action.is_empty()
                    || e.action.len() > 80
                    || e.resources.len() > 128
                    || e.resources.iter().any(|r| r.is_empty() || r.len() > 256)
            })
        {
            return Err(ImportError::new(
                "audit_invalid",
                "История действий повреждена или не поддерживается.",
            ));
        }
        for entry in &self.entries {
            if entry.origin.is_some() && (entry.policy.is_some() || entry.outcome.is_some()) {
                return Err(invalid());
            }
            match (&entry.policy, &entry.outcome) {
                (None, None) => {} // Legacy events retain unknown policy/outcome.
                (Some(policy), Some(BusinessOutcome::Committed)) => {
                    if entry.revision == 0 {
                        return Err(invalid());
                    }
                    policy.validate(&entry.action)?
                }
                _ => return Err(invalid()),
            }
        }
        Ok(())
    }
    /// Client project backups preserve history, but cannot authenticate its
    /// claimed actor/time/policy/outcome. Stock database recovery bypasses this.
    pub(crate) fn mark_project_backup_unverified(&mut self) -> Result<(), ImportError> {
        self.validate()?;
        for entry in &mut self.entries {
            entry.policy = None;
            entry.outcome = None;
            entry.origin = Some(AuditOrigin::ProjectBackupUnverified);
        }
        self.validate()
    }
    pub fn append(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
    ) -> Result<(), ImportError> {
        self.append_policy(actor, project, action, resources, revision, None)
    }
    pub fn append_business(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
        parameters: &serde_json::Value,
    ) -> Result<(), ImportError> {
        let policy = BusinessPolicy::for_action(action, parameters)?;
        self.append_policy(actor, project, action, resources, revision, Some(policy))
    }
    fn append_policy(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
        policy: Option<BusinessPolicy>,
    ) -> Result<(), ImportError> {
        let sequence = self
            .total
            .checked_add(1)
            .ok_or_else(|| ImportError::new("audit_limit", "Счётчик истории исчерпан."))?;
        let mut next = self.clone();
        next.total = sequence;
        next.entries.push(AuditEntry {
            sequence,
            at: chrono::Utc::now(),
            actor: actor.into(),
            project: project.into(),
            action: action.into(),
            resources,
            revision,
            origin: None,
            outcome: policy.as_ref().map(|_| BusinessOutcome::Committed),
            policy,
        });
        if next.entries.len() > RETAINED {
            next.entries.remove(0);
        }
        next.validate()?;
        *self = next;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn client_backup_history_cannot_keep_committed_trust_or_promote_on_reimport() {
        let mut trail = AuditTrail::default();
        trail
            .append("old", "source", "old_action", vec!["r".into()], 0)
            .unwrap();
        trail
            .append_business(
                "claimed_actor",
                "source",
                "folder_created",
                vec!["folder-1".into()],
                42,
                &serde_json::json!({"client_claim":true}),
            )
            .unwrap();
        let original = trail.clone();
        trail.mark_project_backup_unverified().unwrap();
        assert_eq!(trail.total, original.total);
        for (imported, old) in trail.entries.iter().zip(&original.entries) {
            let mut expected = old.clone();
            expected.origin = Some(AuditOrigin::ProjectBackupUnverified);
            expected.policy = None;
            expected.outcome = None;
            assert_eq!(imported, &expected);
        }
        let marked = trail.clone();
        trail.mark_project_backup_unverified().unwrap();
        assert_eq!(trail, marked);
        trail
            .append_business(
                "server_actor",
                "new",
                "folder_created",
                vec!["folder-2".into()],
                1,
                &serde_json::json!({}),
            )
            .unwrap();
        assert_eq!(trail.entries[2].origin, None);
        assert_eq!(trail.entries[2].outcome, Some(BusinessOutcome::Committed));
        let mut contradictory = marked.clone();
        contradictory.entries[1].policy = original.entries[1].policy.clone();
        contradictory.entries[1].outcome = Some(BusinessOutcome::Committed);
        assert!(contradictory.validate().is_err());
        let mut unsupported = serde_json::to_value(marked).unwrap();
        unsupported["entries"][0]["origin"] = serde_json::json!("server_verified_by_client");
        assert!(serde_json::from_value::<AuditTrail>(unsupported).is_err());
    }
    #[test]
    fn retention_is_explicit_monotonic_and_invalid_append_is_atomic() {
        let mut audit = AuditTrail::default();
        for _ in 0..520 {
            audit
                .append("u", "p", "update", vec!["log-1".into()], 1)
                .unwrap();
        }
        assert_eq!(audit.total, 520);
        assert_eq!(audit.entries.len(), 512);
        assert_eq!(audit.entries.first().unwrap().sequence, 9);
        let before = audit.clone();
        assert!(audit.append("", "p", "update", vec![], 1).is_err());
        assert_eq!(audit, before);
        audit.entries[0].sequence += 1;
        assert!(audit.validate().is_err());
    }
    #[test]
    fn other_project_cannot_evict_auth_history_and_foreign_entries_refuse() {
        let mut audit = ProjectAuditTrails::default();
        audit.append("u", "a", "rename", vec![], 1).unwrap();
        let before = audit.0["a"].clone();
        for _ in 0..520 {
            audit.append("u", "b", "rename", vec![], 1).unwrap();
        }
        assert_eq!(audit.0["a"], before);
        assert_eq!(audit.0["b"].entries.len(), 512);
        audit.validate().unwrap();
        audit.0.get_mut("a").unwrap().entries[0].project = "b".into();
        assert!(audit.validate().is_err());
    }
    #[test]
    fn legacy_events_remain_unknown_and_business_policy_tampering_refuses() {
        let mut trail = AuditTrail::default();
        trail.append("u", "p", "rename", vec![], 1).unwrap();
        let legacy = serde_json::to_value(&trail).unwrap();
        assert!(legacy["entries"][0].get("policy").is_none());
        assert!(legacy["entries"][0].get("outcome").is_none());
        let decoded: AuditTrail = serde_json::from_value(legacy.clone()).unwrap();
        assert_eq!(serde_json::to_value(decoded).unwrap(), legacy);
        let parameters = serde_json::json!({"expected_revision":1,"name_sha256":"bounded"});
        trail
            .append_business(
                "u",
                "p",
                "project_renamed",
                vec!["p".into()],
                2,
                &parameters,
            )
            .unwrap();
        assert_eq!(trail.entries[1].outcome, Some(BusinessOutcome::Committed));
        let mut forged = trail.clone();
        forged.entries[1].policy.as_mut().unwrap().rule = "owner_archive_session_cas_v1".into();
        assert!(forged.validate().is_err());
        let mut zero_revision = trail.clone();
        zero_revision.entries[1].revision = 0;
        assert!(zero_revision.validate().is_err());
        let before = trail.clone();
        assert!(
            trail
                .append_business("u", "p", "unsupported", vec![], 3, &parameters)
                .is_err()
        );
        assert_eq!(trail, before);
        let mut injected = serde_json::to_value(&trail).unwrap();
        injected["entries"][1]["policy"]["password"] = serde_json::json!("forged");
        assert!(serde_json::from_value::<AuditTrail>(injected).is_err());
    }
}
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(transparent)]
pub struct ProjectAuditTrails(pub std::collections::BTreeMap<String, AuditTrail>);
impl ProjectAuditTrails {
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn validate(&self) -> Result<(), crate::domain::ImportError> {
        for (project, trail) in &self.0 {
            trail.validate()?;
            if project.is_empty()
                || project.len() > 128
                || trail.entries.iter().any(|e| &e.project != project)
            {
                return Err(crate::domain::ImportError::new(
                    "audit_corrupt",
                    "История другого проекта.",
                ));
            }
        }
        Ok(())
    }
    pub fn append(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
    ) -> Result<(), crate::domain::ImportError> {
        let mut trail = self.0.get(project).cloned().unwrap_or_default();
        trail.append(actor, project, action, resources, revision)?;
        self.0.insert(project.into(), trail);
        Ok(())
    }
    pub fn append_business(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
        parameters: &serde_json::Value,
    ) -> Result<(), ImportError> {
        let mut trail = self.0.get(project).cloned().unwrap_or_default();
        trail.append_business(actor, project, action, resources, revision, parameters)?;
        self.0.insert(project.into(), trail);
        Ok(())
    }
}
