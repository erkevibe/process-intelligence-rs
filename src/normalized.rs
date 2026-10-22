//! Independently bounded project records, with one atomic project revision.
use crate::{domain::ImportError, storage::validate_document_capacity};
use postgres::{Client, Transaction};
use serde_json::Value;
#[cfg(test)]
use serde_json::json;
use std::collections::BTreeSet;

pub(crate) const VERSION: i32 = 2;
pub(crate) const NAME: &str = "normalized_v2";
pub(crate) const DDL: &str = "CREATE TABLE public.pi_projects (project_id text PRIMARY KEY, version bigint NOT NULL CHECK (version > 0), document jsonb NOT NULL); CREATE TABLE public.pi_records (project_id text NOT NULL REFERENCES public.pi_projects(project_id), kind text NOT NULL CHECK (kind IN ('log_state','log_data','log_source','log_analysis','model')), resource_id text NOT NULL, version bigint NOT NULL CHECK (version > 0), document jsonb NOT NULL, PRIMARY KEY(project_id,kind,resource_id)); CREATE TABLE public.pi_migration_v2 (project_id text PRIMARY KEY REFERENCES public.pi_projects(project_id), source_version bigint NOT NULL CHECK (source_version > 0), source_sha text NOT NULL, checksum text NOT NULL);";
pub(crate) type Record = (String, String, Value);
pub(crate) struct ProjectWrite {
    pub(crate) project: String,
    pub(crate) expected: u64,
    pub(crate) metadata: Value,
    pub(crate) puts: Vec<Record>,
    pub(crate) deletes: Vec<(String, String)>,
}
pub(crate) fn invalid() -> ImportError {
    ImportError::new(
        "schema_unsupported",
        "Схема или сохранённые данные не поддерживаются. Исходные записи не изменены; проверьте состояние миграции.",
    )
}
pub(crate) fn unavailable() -> ImportError {
    ImportError::new(
        "storage_unavailable",
        "База недоступна; изменение не подтверждено.",
    )
}
pub(crate) fn checksum() -> String {
    crate::storage::sha256(DDL.as_bytes())
}
pub(crate) fn create_schema(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    tx.batch_execute(DDL).map_err(|_| unavailable())
}
pub(crate) fn initialize_empty(client: &mut Client) -> Result<(), ImportError> {
    let mut tx = client.transaction().map_err(|_| unavailable())?;
    create_schema(&mut tx)?;
    tx.execute(
        "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES($1,$2,$3)",
        &[&VERSION, &NAME, &checksum()],
    )
    .map_err(|_| unavailable())?;
    validate_schema(&mut tx)?;
    tx.commit().map_err(|_| unavailable())
}
pub(crate) fn validate_ready(client: &mut Client) -> Result<(), ImportError> {
    let mut tx = client.transaction().map_err(|_| unavailable())?;
    validate_schema(&mut tx)?;
    let rows = tx
        .query(
            "SELECT version,name,checksum FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(|_| unavailable())?;
    if rows.len() != 2
        || rows[0].get::<_, i32>(0) != 1
        || rows[1].get::<_, i32>(0) != VERSION
        || rows[1].get::<_, String>(1) != NAME
        || rows[1].get::<_, String>(2) != checksum()
    {
        return Err(invalid());
    }
    let malformed:bool=tx.query_one("SELECT EXISTS(SELECT 1 FROM public.pi_migration_v2 WHERE source_version<1 OR checksum<>$1 OR source_sha !~ '^[0-9a-f]{64}$')", &[&checksum()]).map_err(|_|unavailable())?.get(0);
    if malformed {
        return Err(invalid());
    }
    tx.commit().map_err(|_| unavailable())
}
pub(crate) fn validate_schema(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    validate_schema_version(tx, false)
}
pub(crate) fn validate_schema_v3(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    validate_schema_version(tx, true)
}
fn validate_schema_version(tx: &mut Transaction<'_>, conversions: bool) -> Result<(), ImportError> {
    for (table, columns, checks, foreign, indexes) in [
        (
            "pi_projects",
            vec![
                ("project_id", "text"),
                ("version", "int8"),
                ("document", "jsonb"),
            ],
            1i64,
            0i64,
            1i64,
        ),
        (
            "pi_records",
            vec![
                ("project_id", "text"),
                ("kind", "text"),
                ("resource_id", "text"),
                ("version", "int8"),
                ("document", "jsonb"),
            ],
            2,
            1,
            1,
        ),
        (
            "pi_migration_v2",
            vec![
                ("project_id", "text"),
                ("source_version", "int8"),
                ("source_sha", "text"),
                ("checksum", "text"),
            ],
            1,
            1,
            1,
        ),
    ] {
        let rows = tx.query("SELECT column_name,udt_name,is_nullable,is_identity,is_generated,column_default,collation_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 ORDER BY ordinal_position", &[&table]).map_err(|_| unavailable())?;
        if rows.len() != columns.len()
            || rows.iter().zip(columns).any(|(r, (n, t))| {
                r.get::<_, String>(0) != n
                    || r.get::<_, String>(1) != t
                    || r.get::<_, String>(2) != "NO"
                    || r.get::<_, String>(3) != "NO"
                    || r.get::<_, String>(4) != "NEVER"
                    || r.get::<_, Option<String>>(5).is_some()
                    || r.get::<_, Option<String>>(6).is_some()
            })
        {
            return Err(invalid());
        }
        let qualified = format!("public.{table}");
        let r=tx.query_opt("SELECT c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity,(SELECT count(*) FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal),(SELECT count(*) FROM pg_rewrite WHERE ev_class=c.oid),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype='c'),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype='f'),(SELECT count(*) FROM pg_index WHERE indrelid=c.oid),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND (contype NOT IN ('p','n','c','f') OR NOT convalidated OR condeferrable OR condeferred)) FROM pg_class c WHERE c.oid=to_regclass($1)", &[&qualified]).map_err(|_| unavailable())?.ok_or_else(invalid)?;
        if !r.get::<_, bool>(0)
            || r.get::<_, i64>(1) != 0
            || r.get::<_, i64>(2) != 0
            || r.get::<_, i64>(3) != checks
            || r.get::<_, i64>(4) != foreign
            || r.get::<_, i64>(5) != indexes
            || r.get::<_, i64>(6) != 0
        {
            return Err(invalid());
        }
        let pk: Vec<i16> = tx
            .query_one(
                "SELECT conkey FROM pg_constraint WHERE conrelid=to_regclass($1) AND contype='p'",
                &[&qualified],
            )
            .map_err(|_| unavailable())?
            .get(0);
        if pk
            != if table == "pi_records" {
                vec![1, 2, 3]
            } else {
                vec![1]
            }
        {
            return Err(invalid());
        }
        for r in tx.query("SELECT conkey,confkey,confrelid='public.pi_projects'::regclass,confupdtype,confdeltype,confmatchtype FROM pg_constraint WHERE conrelid=to_regclass($1) AND contype='f'", &[&qualified]).map_err(|_| unavailable())? {
            if r.get::<_,Vec<i16>>(0)!=vec![1] || r.get::<_,Vec<i16>>(1)!=vec![1] || !r.get::<_,bool>(2) || r.get::<_,i8>(3)!=b'a' as i8 || r.get::<_,i8>(4)!=b'a' as i8 || r.get::<_,i8>(5)!=b's' as i8 {return Err(invalid());}
        }
        let definitions:Vec<String>=tx.query("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid=to_regclass($1) AND contype='c' ORDER BY pg_get_constraintdef(oid)", &[&qualified]).map_err(|_| unavailable())?.iter().map(|r|r.get(0)).collect();
        let expected = match table {
            "pi_projects" => vec!["CHECK ((version > 0))"],
            "pi_migration_v2" => vec!["CHECK ((source_version > 0))"],
            _ if conversions => vec![
                "CHECK ((kind = ANY (ARRAY['log_state'::text, 'log_data'::text, 'log_source'::text, 'log_analysis'::text, 'model'::text, 'conversion'::text])))",
                "CHECK ((version > 0))",
            ],
            _ => vec![
                "CHECK ((kind = ANY (ARRAY['log_state'::text, 'log_data'::text, 'log_source'::text, 'log_analysis'::text, 'model'::text])))",
                "CHECK ((version > 0))",
            ],
        };
        if definitions != expected {
            return Err(invalid());
        }
    }
    Ok(())
}
fn valid_kind(kind: &str) -> bool {
    matches!(
        kind,
        "log_state" | "log_data" | "log_source" | "log_analysis" | "model" | "conversion"
    )
}
pub(crate) fn validate_write(write: &ProjectWrite) -> Result<(), ImportError> {
    if write.project.is_empty() || write.expected >= i64::MAX as u64 {
        return Err(invalid());
    }
    validate_document_capacity(&write.metadata, false)?;
    let mut keys = BTreeSet::new();
    for (kind, id, value) in &write.puts {
        if !valid_kind(kind) || id.is_empty() || !keys.insert((kind, id)) {
            return Err(invalid());
        }
        validate_document_capacity(value, false)?;
    }
    for (kind, id) in &write.deletes {
        if !valid_kind(kind) || id.is_empty() || !keys.insert((kind, id)) {
            return Err(invalid());
        }
    }
    Ok(())
}
pub(crate) fn write(tx: &mut Transaction<'_>, write: &ProjectWrite) -> Result<u64, ImportError> {
    validate_write(write)?;
    let row=if write.expected==0 {
        tx.query_opt("INSERT INTO public.pi_projects(project_id,version,document) VALUES($1,1,$2) ON CONFLICT DO NOTHING RETURNING version", &[&write.project,&write.metadata])
    }else{
        tx.query_opt("UPDATE public.pi_projects SET version=version+1,document=$2 WHERE project_id=$1 AND version=$3 RETURNING version", &[&write.project,&write.metadata,&(write.expected as i64)])
    }.map_err(|_| unavailable())?.ok_or_else(||ImportError::new("storage_conflict","Данные проекта изменились. Повторите после перезапуска."))?;
    for (kind, id, value) in &write.puts {
        tx.execute("INSERT INTO public.pi_records(project_id,kind,resource_id,version,document) VALUES($1,$2,$3,1,$4) ON CONFLICT(project_id,kind,resource_id) DO UPDATE SET version=pi_records.version+1,document=EXCLUDED.document", &[&write.project,kind,id,value]).map_err(|_| unavailable())?;
    }
    for (kind, id) in &write.deletes {
        tx.execute(
            "DELETE FROM public.pi_records WHERE project_id=$1 AND kind=$2 AND resource_id=$3",
            &[&write.project, kind, id],
        )
        .map_err(|_| unavailable())?;
    }
    Ok(row.get::<_, i64>(0) as u64)
}
pub(crate) fn read_header(
    client: &mut Client,
    project: &str,
) -> Result<Option<(u64, Value)>, ImportError> {
    Ok(client
        .query_opt(
            "SELECT version,document FROM public.pi_projects WHERE project_id=$1",
            &[&project],
        )
        .map_err(|_| unavailable())?
        .map(|r| (r.get::<_, i64>(0) as u64, r.get(1))))
}
pub(crate) fn headers(client: &mut Client) -> Result<Vec<(String, u64, Value)>, ImportError> {
    Ok(client
        .query(
            "SELECT project_id,version,document FROM public.pi_projects ORDER BY project_id",
            &[],
        )
        .map_err(|_| unavailable())?
        .into_iter()
        .map(|r| (r.get(0), r.get::<_, i64>(1) as u64, r.get(2)))
        .collect())
}
pub(crate) fn split_repository(
    project: &str,
    value: Value,
) -> Result<(Value, Vec<Record>), ImportError> {
    let repository: crate::web::Repository =
        serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if serde_json::to_value(&repository).map_err(|_| invalid())? != value {
        return Err(invalid());
    }
    for (id, log) in &repository.logs {
        if id != &log.id || log.project_id.as_deref() != Some(project) {
            return Err(invalid());
        }
    }
    for (id, model) in &repository.models {
        if id != &model.id || crate::bpmn::validate(&model.model).is_err() {
            return Err(invalid());
        }
    }
    for (id, job) in &repository.durable_jobs {
        if id != &job.id
            || (job.state == crate::jobs::JobState::Completed
                && !job
                    .result_id
                    .as_ref()
                    .is_some_and(|id| repository.logs.contains_key(id)))
            || (job.state != crate::jobs::JobState::Completed && job.result_id.is_some())
        {
            return Err(invalid());
        }
    }
    crate::conversion_workflow::validate_full(&repository).map_err(|_| invalid())?;
    drop(value);
    // Restore and migration use the same immutable payload encoder as new writes.
    // A separate field splitter placed provenance in mutable log_state and made
    // otherwise valid restored logs unreadable by the strict lazy decoder.
    let write =
        crate::repository_v2::prepare(project, &repository, false).map_err(|_| invalid())?;
    Ok((write.metadata, write.puts))
}
#[cfg(test)]
pub(crate) fn join_repository(
    project: &str,
    metadata: Value,
    records: Vec<Record>,
) -> Result<Value, ImportError> {
    let mut root = metadata.as_object().cloned().ok_or_else(invalid)?;
    let log_ids: Vec<String> = serde_json::from_value(root.remove("log_ids").ok_or_else(invalid)?)
        .map_err(|_| invalid())?;
    let model_ids: Vec<String> =
        serde_json::from_value(root.remove("model_ids").ok_or_else(invalid)?)
            .map_err(|_| invalid())?;
    let mut entries = std::collections::BTreeMap::new();
    for (kind, id, value) in records {
        if !valid_kind(&kind) || entries.insert((kind, id), value).is_some() {
            return Err(invalid());
        }
    }
    let mut logs = serde_json::Map::new();
    for id in log_ids {
        let mut pieces = Vec::new();
        for &kind in crate::repository_v2::LOG_KINDS {
            pieces.push((
                kind.into(),
                1,
                entries
                    .remove(&(kind.into(), id.clone()))
                    .ok_or_else(invalid)?,
            ));
        }
        let (log, _) =
            crate::repository_v2::decode_log(project, &id, pieces).map_err(|_| invalid())?;
        if logs
            .insert(id, serde_json::to_value(log).map_err(|_| invalid())?)
            .is_some()
        {
            return Err(invalid());
        }
    }
    let mut models = serde_json::Map::new();
    for id in model_ids {
        if models
            .insert(
                id.clone(),
                entries.remove(&("model".into(), id)).ok_or_else(invalid)?,
            )
            .is_some()
        {
            return Err(invalid());
        }
    }
    let conversions: std::collections::BTreeMap<
        String,
        crate::conversion_workflow::ConversionMeta,
    > = root
        .get("conversions")
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|_| invalid())?
        .unwrap_or_default();
    let mut artifacts = serde_json::Map::new();
    for meta in conversions.values() {
        artifacts.insert(
            meta.artifact_id.clone(),
            entries
                .remove(&("conversion".into(), meta.artifact_id.clone()))
                .ok_or_else(invalid)?,
        );
    }
    if !artifacts.is_empty() {
        root.insert("conversion_artifacts".into(), Value::Object(artifacts));
    }
    if !entries.is_empty()
        || root.insert("logs".into(), Value::Object(logs)).is_some()
        || root
            .insert("models".into(), Value::Object(models))
            .is_some()
    {
        return Err(invalid());
    }
    let value = Value::Object(root);
    let repository: crate::web::Repository =
        serde_json::from_value(value.clone()).map_err(|_| invalid())?;
    if serde_json::to_value(&repository).map_err(|_| invalid())? != value {
        return Err(invalid());
    }
    for (id, log) in &repository.logs {
        if id != &log.id || log.project_id.as_deref() != Some(project) {
            return Err(invalid());
        }
    }
    for (id, model) in &repository.models {
        if id != &model.id || crate::bpmn::validate(&model.model).is_err() {
            return Err(invalid());
        }
    }
    for (id, job) in &repository.durable_jobs {
        if id != &job.id
            || (job.state == crate::jobs::JobState::Completed
                && !job
                    .result_id
                    .as_ref()
                    .is_some_and(|id| repository.logs.contains_key(id)))
            || (job.state != crate::jobs::JobState::Completed && job.result_id.is_some())
        {
            return Err(invalid());
        }
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn empty_repository_roundtrips_without_losing_metadata() {
        let value = serde_json::to_value(crate::web::Repository::default()).unwrap();
        let (header, records) = split_repository("p1", value.clone()).unwrap();
        assert_eq!(join_repository("p1", header, records).unwrap(), value);
    }
    #[test]
    fn orphan_payload_and_duplicate_identifiers_refuse() {
        let value = serde_json::to_value(crate::web::Repository::default()).unwrap();
        let (header, _) = split_repository("p1", value).unwrap();
        assert!(
            join_repository(
                "p1",
                header.clone(),
                vec![("model".into(), "foreign".into(), json!({}))]
            )
            .is_err()
        );
        let mut duplicate = header;
        duplicate["model_ids"] = json!(["same", "same"]);
        assert!(
            join_repository(
                "p1",
                duplicate,
                vec![("model".into(), "same".into(), json!({}))]
            )
            .is_err()
        );
    }
    #[test]
    fn duplicate_batch_key_and_out_of_range_revision_refuse_before_sql() {
        let mut write = ProjectWrite {
            project: "p".into(),
            expected: 0,
            metadata: json!({}),
            puts: vec![("model".into(), "m".into(), json!({}))],
            deletes: vec![("model".into(), "m".into())],
        };
        assert!(validate_write(&write).is_err());
        write.deletes.clear();
        write.expected = i64::MAX as u64;
        assert!(validate_write(&write).is_err());
    }
}
