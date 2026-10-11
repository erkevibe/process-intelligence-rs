//! Bounded successful-business audit, persisted inside the mutation transaction.
use crate::domain::ImportError;
use serde::{Deserialize, Serialize};
pub const RETAINED: usize = 512;
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
        Ok(())
    }
    pub fn append(
        &mut self,
        actor: &str,
        project: &str,
        action: &str,
        resources: Vec<String>,
        revision: u64,
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
}
