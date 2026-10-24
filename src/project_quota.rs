//! Versioned logical payload quota. It does not measure disk or allocator bytes.
use crate::{domain::ImportError, normalized};
use postgres::Transaction;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub(crate) const HEADER_RESERVE: u64 = (1 << 28) - (64 << 10);
pub(crate) const AUDIT_RESERVE: u64 = 32 << 20;
pub(crate) const ACTIVE_RESERVE: u64 = 128 << 10;
pub(crate) const ACCOUNTING_RESERVE: u64 = 128 << 10;
const MAX_LEDGER_BYTES: usize = 64 << 10;
const MAX_RECORDS: usize = 120;
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Entry {
    version: u64,
    cost: u64,
}
pub(crate) type Ledger = BTreeMap<String, BTreeMap<String, Entry>>;
pub(crate) fn parse_ledger(value: Value) -> Result<Ledger, ImportError> {
    if serde_json::to_vec(&value).map_err(|_| invalid())?.len() > MAX_LEDGER_BYTES
        || cost(&value)? > ACCOUNTING_RESERVE - 1024
    {
        return Err(invalid());
    }
    let ledger: Ledger = serde_json::from_value(value).map_err(|_| invalid())?;
    ledger_total(&ledger)?;
    Ok(ledger)
}
fn ledger_total(ledger: &Ledger) -> Result<u64, ImportError> {
    let mut count = 0;
    let mut total = 0;
    for (kind, entries) in ledger {
        if !normalized::valid_kind(kind) || entries.is_empty() {
            return Err(invalid());
        }
        for (id, entry) in entries {
            count += 1;
            if count > MAX_RECORDS
                || id.is_empty()
                || id.len() > 64
                || entry.version == 0
                || entry.version > i64::MAX as u64
                || entry.cost < 32 + kind.len() as u64 + id.len() as u64
                || entry.cost > i64::MAX as u64
            {
                return Err(invalid());
            }
            total = add(total, entry.cost)?;
        }
    }
    if total > i64::MAX as u64 {
        return Err(invalid());
    }
    Ok(total)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    pub(crate) metric_version: u8,
    pub(crate) payload_allowance: u64,
}
impl Policy {
    pub(crate) fn validate(&self) -> Result<(), ImportError> {
        if self.metric_version != 1 || self.payload_allowance > i64::MAX as u64 - HEADER_RESERVE {
            return Err(invalid());
        }
        Ok(())
    }
}
fn invalid() -> ImportError {
    ImportError::new(
        "quota_invalid",
        "Учёт квоты повреждён или не поддерживается. Данные не изменены.",
    )
}
fn capacity() -> ImportError {
    ImportError::new(
        "project_capacity",
        "В заголовке проекта недостаточно запаса для завершения заданий. Уменьшите служебные данные до повторения операции.",
    )
}
fn add(a: u64, b: u64) -> Result<u64, ImportError> {
    a.checked_add(b).ok_or_else(invalid)
}
pub(crate) fn cost(value: &Value) -> Result<u64, ImportError> {
    match value {
        Value::Null | Value::Bool(_) => Ok(0),
        Value::Number(_) => Ok(32),
        Value::String(s) => Ok(s.len() as u64),
        Value::Array(a) => a.iter().try_fold(
            add(7, (a.len() as u64).checked_mul(4).ok_or_else(invalid)?)?,
            |n, v| add(n, cost(v)?),
        ),
        Value::Object(o) => o.iter().try_fold(
            add(7, (o.len() as u64).checked_mul(8).ok_or_else(invalid)?)?,
            |n, (k, v)| add(add(n, k.len() as u64)?, cost(v)?),
        ),
    }
}
pub(crate) fn record_cost(kind: &str, id: &str, value: &Value) -> Result<u64, ImportError> {
    if !normalized::valid_kind(kind) || id.is_empty() {
        return Err(invalid());
    }
    add(
        add(add(32, kind.len() as u64)?, id.len() as u64)?,
        cost(value)?,
    )
}
pub(crate) fn validate_header(value: &Value) -> Result<(), ImportError> {
    validate_header_with_budget(value, HEADER_RESERVE)
}
fn validate_header_with_budget(value: &Value, budget: u64) -> Result<(), ImportError> {
    let h = crate::repository_v2::Header::parse(value.clone())?;
    if let Some(policy) = &h.quota_policy {
        policy.validate()?;
    }
    let mut remainder = value.as_object().cloned().ok_or_else(invalid)?;
    let audit = remainder.remove("audit").unwrap_or(Value::Null);
    if add(cost(&audit)?, 13)? > AUDIT_RESERVE {
        return Err(capacity());
    }
    let active = h.durable_jobs.values().filter(|s| !s.is_terminal()).count()
        + h.conversions
            .values()
            .filter(|m| !m.snapshot.is_terminal())
            .count()
        + h.quality_jobs
            .values()
            .filter(|m| !m.snapshot.is_terminal())
            .count()
        + h.discovery_jobs
            .values()
            .filter(|m| !m.snapshot.is_terminal())
            .count();
    let reserved = add(
        add(AUDIT_RESERVE, ACCOUNTING_RESERVE)?,
        (active as u64)
            .checked_mul(ACTIVE_RESERVE)
            .ok_or_else(invalid)?,
    )?;
    if add(cost(&Value::Object(remainder))?, reserved)? > budget {
        return Err(capacity());
    }
    Ok(())
}
/// Startup/migration only: stream one document at a time and distrust the ledger.
pub(crate) fn measure(
    tx: &mut Transaction<'_>,
    project: &str,
) -> Result<(u64, Ledger), ImportError> {
    use postgres::fallible_iterator::FallibleIterator;
    let mut rows = tx.query_raw("SELECT kind,resource_id,version,document FROM public.pi_records WHERE project_id=$1 ORDER BY kind,resource_id", [&project as &(dyn postgres::types::ToSql + Sync)]).map_err(|_| normalized::unavailable())?;
    let mut ledger = Ledger::new();
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|_| normalized::unavailable())? {
        count += 1;
        if count > MAX_RECORDS {
            return Err(invalid());
        }
        let kind: String = row.get(0);
        let id: String = row.get(1);
        let version: i64 = row.get(2);
        if version < 1 {
            return Err(invalid());
        }
        let entry = Entry {
            version: version as u64,
            cost: record_cost(&kind, &id, &row.get::<_, Value>(3))?,
        };
        if ledger.entry(kind).or_default().insert(id, entry).is_some() {
            return Err(invalid());
        }
    }
    let value = serde_json::to_value(&ledger).map_err(|_| invalid())?;
    let ledger = parse_ledger(value)?;
    Ok((ledger_total(&ledger)?, ledger))
}
/// Called after the project CAS has acquired the row lock and before commit.
pub(crate) fn account(
    tx: &mut Transaction<'_>,
    write: &normalized::ProjectWrite,
) -> Result<(), ImportError> {
    validate_header(&write.metadata)?;
    let old = tx.query_opt("SELECT metric_version,payload_used,record_costs FROM public.pi_project_quota WHERE project_id=$1 FOR UPDATE", &[&write.project]).map_err(|_| normalized::unavailable())?;
    let (before, mut ledger) = match old {
        Some(row) if row.get::<_, i32>(0) == 1 && row.get::<_, i64>(1) >= 0 => {
            let ledger = parse_ledger(row.get(2))?;
            let used = ledger_total(&ledger)?;
            if used != row.get::<_, i64>(1) as u64 {
                return Err(invalid());
            }
            (used, ledger)
        }
        None if write.expected == 0 => (0, Ledger::new()),
        _ => return Err(invalid()),
    };
    // No document projection here: unchanged payload stays outside metadata writes.
    let rows=tx.query("SELECT kind,resource_id,version FROM public.pi_records WHERE project_id=$1 ORDER BY kind,resource_id LIMIT 121",&[&write.project]).map_err(|_|normalized::unavailable())?;
    if rows.len() > MAX_RECORDS || rows.len() != ledger.values().map(BTreeMap::len).sum::<usize>() {
        return Err(invalid());
    }
    for row in rows {
        let kind: String = row.get(0);
        let id: String = row.get(1);
        let version: i64 = row.get(2);
        if version < 1
            || ledger
                .get(&kind)
                .and_then(|m| m.get(&id))
                .is_none_or(|e| e.version != version as u64)
        {
            return Err(invalid());
        }
    }
    let mut after = before;
    for (kind, id) in write
        .puts
        .iter()
        .map(|(k, i, _)| (k, i))
        .chain(write.deletes.iter().map(|(k, i)| (k, i)))
    {
        if let Some(row) = tx.query_opt("SELECT version,document FROM public.pi_records WHERE project_id=$1 AND kind=$2 AND resource_id=$3", &[&write.project, kind, id]).map_err(|_| normalized::unavailable())? {
            let entry=ledger.get(kind).and_then(|m|m.get(id)).ok_or_else(invalid)?;
            let actual=record_cost(kind,id,&row.get::<_,Value>(1))?;
            if row.get::<_,i64>(0) as u64!=entry.version || actual!=entry.cost{return Err(invalid());}
            after=after.checked_sub(actual).ok_or_else(invalid)?;
        }
    }
    for (kind, id, value) in &write.puts {
        let old_version = ledger
            .get(kind)
            .and_then(|m| m.get(id))
            .map_or(0, |e| e.version);
        let version = old_version
            .checked_add(1)
            .filter(|v| *v <= i64::MAX as u64)
            .ok_or_else(invalid)?;
        let new_cost = record_cost(kind, id, value)?;
        after = add(after, new_cost)?;
        ledger.entry(kind.clone()).or_default().insert(
            id.clone(),
            Entry {
                version,
                cost: new_cost,
            },
        );
    }
    for (kind, id) in &write.deletes {
        if let Some(entries) = ledger.get_mut(kind) {
            entries.remove(id);
        }
    }
    ledger.retain(|_, m| !m.is_empty());
    let record_costs = serde_json::to_value(&ledger).map_err(|_| invalid())?;
    let checked = parse_ledger(record_costs.clone())?;
    if ledger_total(&checked)? != after {
        return Err(invalid());
    }
    if after > i64::MAX as u64 {
        return Err(invalid());
    }
    let h = crate::repository_v2::Header::parse(write.metadata.clone())?;
    if h.quota_policy
        .as_ref()
        .is_some_and(|p| after > p.payload_allowance && after > before)
    {
        return Err(ImportError::new(
            "project_quota",
            "Квота проекта заполнена. Результат не сохранён; удалите ненужные данные или попросите владельца увеличить лимит.",
        ));
    }
    tx.execute("INSERT INTO public.pi_project_quota(project_id,metric_version,payload_used,record_costs) VALUES($1,1,$2,$3) ON CONFLICT(project_id) DO UPDATE SET payload_used=EXCLUDED.payload_used,record_costs=EXCLUDED.record_costs", &[&write.project, &(after as i64),&record_costs]).map_err(|_| normalized::unavailable())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn structural_metric_unicode_and_numeric_representation() {
        assert_eq!(
            cost(&json!({"я": [null, true, "💡", 1]})).unwrap(),
            7 + 8 + 2 + 7 + 16 + 4 + 32
        );
        for n in [json!(1), json!(1.0), json!(-0.0), json!(1e100)] {
            assert_eq!(cost(&n).unwrap(), 32);
        }
        assert_eq!(
            record_cost("model", "model-1", &json!({})).unwrap(),
            32 + 5 + 7 + 7
        );
        assert!(
            Policy {
                metric_version: 2,
                payload_allowance: 0
            }
            .validate()
            .is_err()
        );
    }
    #[test]
    fn ledger_schema_bounds_and_collision_free_nested_keys() {
        let good = json!({"model":{"model-1":{"version":1,"cost":44}}});
        assert_eq!(
            ledger_total(&parse_ledger(good.clone()).unwrap()).unwrap(),
            44
        );
        for bad in [
            json!([]),
            json!({"unknown":{"model-1":{"version":1,"cost":44}}}),
            json!({"model":{}}),
            json!({"model":{"":{"version":1,"cost":44}}}),
            json!({"model":{"model-1":{"version":0,"cost":44}}}),
            json!({"model":{"model-1":{"version":1.0,"cost":44}}}),
            json!({"model":{"model-1":{"version":1,"cost":true}}}),
            json!({"model":{"model-1":{"version":1,"cost":43}}}),
            json!({"model":{"model-1":{"version":1,"cost":44,"extra":null}}}),
        ] {
            assert!(parse_ledger(bad).is_err());
        }
        let mut too_many = serde_json::Map::new();
        for i in 0..121 {
            too_many.insert(format!("model-{i}"), json!({"version":1,"cost":100}));
        }
        assert!(parse_ledger(json!({"model":too_many})).is_err());
        let oversized = json!({"model":{("x".repeat(65536)):{"version":1,"cost":100000}}});
        assert!(parse_ledger(oversized).is_err());
    }
    #[test]
    fn all_job_namespaces_have_terminal_and_full_audit_headroom_at_boundary() {
        use crate::{
            jobs::{JobError, JobSnapshot, JobState},
            repository_v2::Header,
        };
        let backup: Value = serde_json::from_slice(include_bytes!(
            "../evidence/sprint29/api-contract/fixture-backup.json"
        ))
        .unwrap();
        let repo: crate::web::Repository =
            serde_json::from_value(backup["payload"].clone()).unwrap();
        let mut h = crate::repository_v2::header(&repo);
        h.audit = Default::default();
        let snapshot = JobSnapshot {
            id: "job-900001".into(),
            state: JobState::Running,
            stage: "x".repeat(64),
            job_revision: u64::MAX - 1,
            cancel_requested: false,
            result_id: None,
            error: None,
        };
        h.durable_jobs.clear();
        h.durable_jobs.insert(snapshot.id.clone(), snapshot.clone());
        let mut conversion_snapshot = snapshot.clone();
        conversion_snapshot.id = "job-900002".into();
        h.conversions.clear();
        h.conversions.insert(
            conversion_snapshot.id.clone(),
            crate::conversion_workflow::ConversionMeta {
                snapshot: conversion_snapshot,
                artifact_id: "conversion-900003".into(),
                from: "csv".into(),
                to: "xes".into(),
                filename: "fixture".into(),
                owner: "owner".into(),
                source_sha256: "a".repeat(64),
                input_bytes: 1,
                allow_loss: false,
                report_profile: None,
                created_at: chrono::Utc::now(),
                retry_of: None,
                payload_sha256: None,
                report_sha256: None,
            },
        );
        assert!(!h.quality_jobs.is_empty() && !h.discovery_jobs.is_empty());
        for meta in h.quality_jobs.values_mut() {
            meta.snapshot = JobSnapshot {
                id: meta.snapshot.id.clone(),
                ..snapshot.clone()
            };
            meta.report_sha256 = None;
        }
        for meta in h.discovery_jobs.values_mut() {
            meta.snapshot = JobSnapshot {
                id: meta.snapshot.id.clone(),
                ..snapshot.clone()
            };
            meta.model_id = None;
            meta.output_sha256 = None;
        }
        h.validate().unwrap();
        let value = h.value().unwrap();
        let active = 2 + h.quality_jobs.len() + h.discovery_jobs.len();
        let budget = cost(&value).unwrap()
            + AUDIT_RESERVE
            + ACCOUNTING_RESERVE
            + active as u64 * ACTIVE_RESERVE;
        assert!(validate_header_with_budget(&value, budget - 1).is_err());
        validate_header_with_budget(&value, budget).unwrap();
        validate_header_with_budget(&value, budget + 1).unwrap();
        assert!(h.recover());
        for s in h
            .durable_jobs
            .values_mut()
            .chain(h.conversions.values_mut().map(|m| &mut m.snapshot))
            .chain(h.quality_jobs.values_mut().map(|m| &mut m.snapshot))
            .chain(h.discovery_jobs.values_mut().map(|m| &mut m.snapshot))
        {
            assert_eq!(s.job_revision, u64::MAX);
            s.error = Some(JobError::bounded(&"💡".repeat(100), &"я".repeat(4000)));
            assert_eq!(s.error.as_ref().unwrap().code.len(), 128);
            assert_eq!(s.error.as_ref().unwrap().message.len(), 4096);
        }
        h.audit
            .append_business(
                &"a".repeat(128),
                &"p".repeat(128),
                "job_updated",
                (0..128)
                    .map(|i| format!("{i:03}{}", "r".repeat(253)))
                    .collect(),
                u64::MAX,
                &Value::Null,
            )
            .unwrap();
        let entry = h.audit.entries[0].clone();
        h.audit.total = 512;
        h.audit.entries = (1..=512)
            .map(|n| crate::audit::AuditEntry {
                sequence: n,
                ..entry.clone()
            })
            .collect();
        let terminal = h.value().unwrap();
        Header::parse(terminal.clone()).unwrap();
        assert!(cost(&terminal).unwrap() <= budget);
        validate_header_with_budget(&terminal, budget).unwrap();
        h.audit
            .append_business(
                "owner",
                "project-1",
                "model_saved",
                vec!["model-1".into()],
                1,
                &Value::Null,
            )
            .unwrap();
        validate_header_with_budget(&h.value().unwrap(), budget).unwrap();
        assert!(JobError::bounded("x\0\n", "a\tb").message == "ab");
    }
}

#[cfg(test)]
#[path = "project_quota_tests.rs"]
pub(crate) mod postgres_tests;
