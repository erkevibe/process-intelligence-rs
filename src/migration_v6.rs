//! Atomic full accounting and a strict old-writer barrier; no automatic adoption of v5.
use crate::{domain::ImportError, normalized, project_quota};
use postgres::{Client, Transaction};
const NAME: &str = "project_quota_v6";
const CONTRACT: &str = "project_quota_v6: structural_bytes_v1 null/bool=0 number=32 string=utf8 array=7+4*n+children object=7+8*n+utf8keys+children record=32+utf8kind+utf8id+document; header reserve=268369920 audit=33554432 active=131072 accounting=131072; bounded record_costs nested kind/id ledger(version,cost),120records,64KiB JSON,strictpositivei64versions; project CAS atomic counter/ledger/record with key-version verification and touchedpayload recount; startup/migration full streaming verification; persisted header policy optional; old writer barrier";
const DDL: &str = "CREATE TABLE public.pi_project_quota(project_id text PRIMARY KEY REFERENCES public.pi_projects(project_id) ON DELETE CASCADE, metric_version integer NOT NULL CHECK(metric_version=1), payload_used bigint NOT NULL CHECK(payload_used>=0),record_costs jsonb NOT NULL);";
fn checksum() -> String {
    crate::storage::sha256(CONTRACT.as_bytes())
}
fn ledger(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    let expected = [
        (2, normalized::NAME, normalized::checksum()),
        (
            3,
            "conversion_artifacts_v3",
            crate::migration_v3::checksum(),
        ),
        (4, "quality_artifacts_v4", crate::migration_v4::checksum()),
        (5, "discovery_artifacts_v5", crate::migration_v5::checksum()),
        (6, NAME, checksum()),
    ];
    let rows = tx.query("SELECT version,name,checksum FROM public.pi_schema_migrations WHERE version>1 ORDER BY version", &[]).map_err(|_| normalized::unavailable())?;
    if rows.len() != expected.len()
        || rows.iter().zip(expected).any(|(r, (v, n, c))| {
            r.get::<_, i32>(0) != v || r.get::<_, String>(1) != n || r.get::<_, String>(2) != c
        })
    {
        return Err(normalized::invalid());
    }
    let malformed:bool=tx.query_one("SELECT EXISTS(SELECT 1 FROM public.pi_migration_v2 WHERE source_version<1 OR checksum<>$1 OR source_sha !~ '^[0-9a-f]{64}$')", &[&normalized::checksum()]).map_err(|_|normalized::unavailable())?.get(0);
    if malformed {
        return Err(normalized::invalid());
    }
    Ok(())
}
fn schema(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    normalized::validate_schema_v5(tx)?;
    ledger(tx)?;
    let cols = tx.query("SELECT column_name,udt_name,is_nullable,column_default,is_identity,is_generated,collation_name FROM information_schema.columns WHERE table_schema='public' AND table_name='pi_project_quota' ORDER BY ordinal_position", &[]).map_err(|_| normalized::unavailable())?;
    if cols.len() != 4
        || cols
            .iter()
            .zip([
                ("project_id", "text"),
                ("metric_version", "int4"),
                ("payload_used", "int8"),
                ("record_costs", "jsonb"),
            ])
            .any(|(r, (n, t))| {
                r.get::<_, String>(0) != n
                    || r.get::<_, String>(1) != t
                    || r.get::<_, String>(2) != "NO"
                    || r.get::<_, Option<String>>(3).is_some()
                    || r.get::<_, String>(4) != "NO"
                    || r.get::<_, String>(5) != "NEVER"
                    || r.get::<_, Option<String>>(6).is_some()
            })
    {
        return Err(normalized::invalid());
    }
    let r=tx.query_one("SELECT c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity,(SELECT count(*) FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal),(SELECT count(*) FROM pg_rewrite WHERE ev_class=c.oid),(SELECT count(*) FROM pg_index WHERE indrelid=c.oid),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype NOT IN ('p','f','c','n')) FROM pg_class c WHERE c.oid='public.pi_project_quota'::regclass", &[]).map_err(|_| normalized::invalid())?;
    if !r.get::<_, bool>(0)
        || r.get::<_, i64>(1) != 0
        || r.get::<_, i64>(2) != 0
        || r.get::<_, i64>(3) != 1
        || r.get::<_, i64>(4) != 0
    {
        return Err(normalized::invalid());
    }
    let constraints:Vec<(String,String,bool,bool,bool)>=tx.query("SELECT contype::text,pg_get_constraintdef(oid),convalidated,condeferrable,condeferred FROM pg_constraint WHERE conrelid='public.pi_project_quota'::regclass AND contype<>'n' ORDER BY contype,pg_get_constraintdef(oid)",&[]).map_err(|_|normalized::invalid())?.iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3),r.get(4))).collect();
    let expected = [
        ("c", "CHECK ((metric_version = 1))"),
        ("c", "CHECK ((payload_used >= 0))"),
        (
            "f",
            "FOREIGN KEY (project_id) REFERENCES pi_projects(project_id) ON DELETE CASCADE",
        ),
        ("p", "PRIMARY KEY (project_id)"),
    ];
    if constraints.len() != expected.len()
        || constraints
            .iter()
            .zip(expected)
            .any(|((t, d, v, f, i), (et, ed))| t != et || d != ed || !v || *f || *i)
    {
        return Err(normalized::invalid());
    }
    Ok(())
}
fn accounting(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    let rows=tx.query("SELECT p.project_id,p.document,q.metric_version,q.payload_used,q.record_costs FROM public.pi_projects p LEFT JOIN public.pi_project_quota q USING(project_id) ORDER BY p.project_id", &[]).map_err(|_|normalized::unavailable())?;
    for row in rows {
        project_quota::validate_header(&row.get::<_, serde_json::Value>(1))?;
        let (used, measured) = project_quota::measure(tx, &row.get::<_, String>(0))?;
        if row.get::<_, Option<i32>>(2) != Some(1)
            || row
                .get::<_, Option<i64>>(3)
                .is_none_or(|n| n < 0 || n as u64 != used)
        {
            return Err(normalized::invalid());
        }
        let stored = project_quota::parse_ledger(
            row.get::<_, Option<serde_json::Value>>(4)
                .ok_or_else(normalized::invalid)?,
        )?;
        if measured != stored {
            return Err(normalized::invalid());
        }
    }
    Ok(())
}
pub(crate) fn validate_ready(client: &mut Client) -> Result<(), ImportError> {
    crate::migrations::validate_v6_baseline(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    schema(&mut tx)?;
    accounting(&mut tx)?;
    tx.commit().map_err(|_| normalized::unavailable())
}
pub(crate) fn run(client: &mut Client) -> Result<(), ImportError> {
    crate::migration_v5::validate_ready(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    tx.batch_execute("LOCK TABLE public.pi_schema_migrations,public.pi_projects,public.pi_records,public.pi_migration_v2 IN ACCESS EXCLUSIVE MODE").map_err(|_|normalized::unavailable())?;
    tx.batch_execute(DDL)
        .map_err(|_| normalized::unavailable())?;
    let rows = tx
        .query(
            "SELECT project_id,document FROM public.pi_projects ORDER BY project_id",
            &[],
        )
        .map_err(|_| normalized::unavailable())?;
    for row in rows {
        let project: String = row.get(0);
        project_quota::validate_header(&row.get::<_, serde_json::Value>(1))?;
        let (used, records) = project_quota::measure(&mut tx, &project)?;
        let used = i64::try_from(used).map_err(|_| normalized::invalid())?;
        let records = serde_json::to_value(records).map_err(|_| normalized::invalid())?;
        tx.execute(
            "INSERT INTO public.pi_project_quota VALUES($1,1,$2,$3)",
            &[&project, &used, &records],
        )
        .map_err(|_| normalized::unavailable())?;
    }
    tx.execute(
        "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES(6,$1,$2)",
        &[&NAME, &checksum()],
    )
    .map_err(|_| normalized::unavailable())?;
    schema(&mut tx)?;
    accounting(&mut tx)?;
    tx.commit().map_err(|_| normalized::unavailable())
}
pub(crate) fn migrate_offline(client: &mut Client) -> Result<(), ImportError> {
    let version: i32 = client
        .query_one(
            "SELECT coalesce(max(version),0) FROM public.pi_schema_migrations",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .get(0);
    if version == 6 {
        return validate_ready(client);
    }
    if !(1..=5).contains(&version) {
        return Err(normalized::invalid());
    }
    crate::migration_v5::migrate_offline(client)?;
    run(client)
}

#[cfg(test)]
mod tests {
    use super::*;
    use postgres::NoTls;
    use serde_json::{Value, json};
    fn inventory(c: &mut Client) -> Value {
        c.query_one("SELECT json_build_object('projects',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY project_id),'[]'::json) FROM public.pi_projects t),'records',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id),'[]'::json) FROM public.pi_records t),'ledger',(SELECT json_agg(to_jsonb(t) ORDER BY version) FROM public.pi_schema_migrations t),'sequence',(SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM public.pi_resource_sequence))",&[]).unwrap().get(0)
    }
    #[test]
    #[ignore = "fresh isolated S30_QUOTA_MIGRATION_URL pi_s30_quota_migration required"]
    fn populated_v5_full_accounting_repeat_and_malformed_refusals() {
        let url = std::env::var("S30_QUOTA_MIGRATION_URL").expect("isolated URL");
        let mut c = Client::connect(&url, NoTls).unwrap();
        let name: String = c
            .query_one("SELECT current_database()", &[])
            .unwrap()
            .get(0);
        assert!(name.starts_with("pi_s30_quota_migration"));
        assert!(
            c.query_one("SELECT to_regclass('public.pi_projects') IS NULL", &[])
                .unwrap()
                .get::<_, bool>(0)
        );
        crate::migrations::apply(&mut c).unwrap();
        c.batch_execute("DROP TABLE public.pi_project_quota; DELETE FROM public.pi_schema_migrations WHERE version=6;").unwrap();
        let r = crate::project_quota::postgres_tests::fixture("project-migration");
        let w = crate::repository_v2::prepare("project-migration", &r, false).unwrap();
        c.execute(
            "INSERT INTO public.pi_projects VALUES($1,17,$2)",
            &[&w.project, &w.metadata],
        )
        .unwrap();
        for (k, id, v) in &w.puts {
            c.execute(
                "INSERT INTO public.pi_records VALUES($1,$2,$3,9,$4)",
                &[&w.project, k, id, v],
            )
            .unwrap();
        }
        c.batch_execute("SELECT setval('public.pi_resource_sequence',42,true)")
            .unwrap();
        crate::migration_v5::validate_ready(&mut c).unwrap();
        let before = inventory(&mut c);
        assert_eq!(
            crate::migrations::apply(&mut c).unwrap_err().code,
            "migration_required"
        );
        assert_eq!(inventory(&mut c), before);
        c.execute(
            "UPDATE public.pi_schema_migrations SET checksum='tampered' WHERE version=5",
            &[],
        )
        .unwrap();
        let malformed = inventory(&mut c);
        assert!(migrate_offline(&mut c).is_err());
        assert_eq!(inventory(&mut c), malformed);
        assert!(
            c.query_one("SELECT to_regclass('public.pi_project_quota') IS NULL", &[])
                .unwrap()
                .get::<_, bool>(0)
        );
        c.execute(
            "UPDATE public.pi_schema_migrations SET checksum=$1 WHERE version=5",
            &[&crate::migration_v5::checksum()],
        )
        .unwrap();
        migrate_offline(&mut c).unwrap();
        let after = inventory(&mut c);
        assert_eq!(after["projects"], before["projects"]);
        assert_eq!(after["records"], before["records"]);
        assert_eq!(after["sequence"], before["sequence"]);
        assert_eq!(
            after["ledger"].as_array().unwrap()[..5],
            before["ledger"].as_array().unwrap()[..]
        );
        let used: i64 = c
            .query_one(
                "SELECT payload_used FROM public.pi_project_quota WHERE project_id=$1",
                &[&w.project],
            )
            .unwrap()
            .get(0);
        let expected: u64 = w
            .puts
            .iter()
            .map(|(k, i, v)| project_quota::record_cost(k, i, v).unwrap())
            .sum();
        assert_eq!(used as u64, expected);
        migrate_offline(&mut c).unwrap();
        assert_eq!(inventory(&mut c), after);
        crate::migrations::apply(&mut c).unwrap();
        assert_eq!(inventory(&mut c), after);
        assert!(crate::migration_v5::validate_ready(&mut c).is_err());
        c.batch_execute("ALTER TABLE public.pi_project_quota ADD CONSTRAINT unexpected CHECK(payload_used<999999999)").unwrap();
        assert!(validate_ready(&mut c).is_err());
        assert_eq!(inventory(&mut c), after);
        c.batch_execute("ALTER TABLE public.pi_project_quota DROP CONSTRAINT unexpected")
            .unwrap();
        c.batch_execute(
            "ALTER TABLE public.pi_project_quota ALTER COLUMN record_costs DROP NOT NULL",
        )
        .unwrap();
        assert!(validate_ready(&mut c).is_err());
        assert_eq!(inventory(&mut c), after);
        c.batch_execute(
            "ALTER TABLE public.pi_project_quota ALTER COLUMN record_costs SET NOT NULL",
        )
        .unwrap();
        let mut header = crate::repository_v2::Header::parse(w.metadata.clone()).unwrap();
        header.quota_policy = Some(project_quota::Policy {
            metric_version: 2,
            payload_allowance: 0,
        });
        c.execute(
            "UPDATE public.pi_projects SET document=$1 WHERE project_id=$2",
            &[&header.value().unwrap(), &w.project],
        )
        .unwrap();
        let bad_policy = inventory(&mut c);
        assert!(validate_ready(&mut c).is_err());
        assert_eq!(inventory(&mut c), bad_policy);
        c.execute(
            "UPDATE public.pi_projects SET document=$1 WHERE project_id=$2",
            &[&w.metadata, &w.project],
        )
        .unwrap();
        validate_ready(&mut c).unwrap();
        let out = std::path::PathBuf::from(
            std::env::var("S30_QUOTA_MIGRATION_EVIDENCE").expect("private output"),
        );
        assert!(out.is_dir());
        std::fs::write(out.join("migration-proof.json"),serde_json::to_vec(&json!({"status":"S30_POPULATED_V5_TO_V6_PASS","all_eight_record_kinds":w.puts.iter().map(|(k,_,_)|k).collect::<std::collections::BTreeSet<_>>().len()==8,"payload_used":used,"project_revisions_preserved":true,"record_revisions_preserved":true,"prior_ledger_preserved":true,"sequence_preserved":true,"repeat_no_change":true,"bad_ledger_policy_schema_refused":true,"old_contract_refuses_v6":true})).unwrap()).unwrap();
    }
}
