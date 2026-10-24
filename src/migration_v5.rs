//! Explicit transactional storage contract for immutable discovery training inputs/results.
use crate::{domain::ImportError, normalized, storage::sha256};
use postgres::{Client, Transaction};

const VERSION: i32 = 5;
const NAME: &str = "discovery_artifacts_v5";
const CONTRACT: &str = "discovery_artifacts_v5: extend pi_records kind CHECK with discovery; preserve existing records, project revisions, sequence and prior migration ledger; transactional DDL; durable discovery snapshots and model results";

fn checksum() -> String {
    sha256(CONTRACT.as_bytes())
}
fn validate_ledger(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    let rows = tx
        .query(
            "SELECT version,name,checksum FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(|_| normalized::unavailable())?;
    let expected = [
        (1, "baseline_v1", None),
        (2, normalized::NAME, Some(normalized::checksum())),
        (
            3,
            "conversion_artifacts_v3",
            Some(crate::migration_v3::checksum()),
        ),
        (
            4,
            "quality_artifacts_v4",
            Some(crate::migration_v4::checksum()),
        ),
        (VERSION, NAME, Some(checksum())),
    ];
    if rows.len() != expected.len()
        || rows
            .iter()
            .zip(expected)
            .any(|(row, (version, name, hash))| {
                row.get::<_, i32>(0) != version
                    || row.get::<_, String>(1) != name
                    || hash.is_some_and(|hash| row.get::<_, String>(2) != hash)
            })
    {
        return Err(normalized::invalid());
    }
    let malformed: bool = tx.query_one("SELECT EXISTS(SELECT 1 FROM public.pi_migration_v2 WHERE source_version<1 OR checksum<>$1 OR source_sha !~ '^[0-9a-f]{64}$')", &[&normalized::checksum()]).map_err(|_| normalized::unavailable())?.get(0);
    if malformed {
        return Err(normalized::invalid());
    }
    Ok(())
}
pub(crate) fn validate_ready(client: &mut Client) -> Result<(), ImportError> {
    crate::migrations::validate_v5_baseline(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    normalized::validate_schema_v5(&mut tx)?;
    validate_ledger(&mut tx)?;
    tx.commit().map_err(|_| normalized::unavailable())
}
pub(crate) fn run(client: &mut Client) -> Result<(), ImportError> {
    let versions: Vec<i32> = client
        .query(
            "SELECT version FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .iter()
        .map(|r| r.get(0))
        .collect();
    if versions == [1, 2, 3, 4, 5] {
        return validate_ready(client);
    }
    crate::migration_v4::validate_ready(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    tx.batch_execute("LOCK TABLE public.pi_schema_migrations, public.pi_projects, public.pi_records, public.pi_migration_v2 IN ACCESS EXCLUSIVE MODE").map_err(|_| normalized::unavailable())?;
    normalized::validate_schema_v4(&mut tx)?;
    let constraint: String = tx.query_one("SELECT conname FROM pg_constraint WHERE conrelid='public.pi_records'::regclass AND contype='c' AND conkey=ARRAY[2]::smallint[]", &[]).map_err(|_| normalized::invalid())?.get(0);
    let quoted = constraint.replace('"', "\"\"");
    tx.batch_execute(&format!("ALTER TABLE public.pi_records DROP CONSTRAINT \"{quoted}\"; ALTER TABLE public.pi_records ADD CONSTRAINT pi_records_kind_check CHECK (kind IN ('log_state','log_data','log_source','log_analysis','model','conversion','quality','discovery'));" )).map_err(|_| normalized::unavailable())?;
    tx.execute(
        "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES($1,$2,$3)",
        &[&VERSION, &NAME, &checksum()],
    )
    .map_err(|_| normalized::unavailable())?;
    normalized::validate_schema_v5(&mut tx)?;
    validate_ledger(&mut tx)?;
    tx.commit().map_err(|_| normalized::unavailable())?;
    tracing::info!(schema_version = VERSION, "migration_v5_complete");
    Ok(())
}
pub(crate) fn migrate_offline(client: &mut Client) -> Result<(), ImportError> {
    let version: i32 = client
        .query_one(
            "SELECT coalesce(max(version),0) FROM public.pi_schema_migrations",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .get(0);
    if version == VERSION {
        return validate_ready(client);
    }
    if !(1..=4).contains(&version) {
        return Err(normalized::invalid());
    }
    crate::migration_v4::migrate_offline(client)?;
    run(client)
}
#[cfg(test)]
mod tests {
    use super::*;
    use postgres::NoTls;
    use serde_json::{Value, json};
    fn inventory(client: &mut Client) -> Value {
        client.query_one("SELECT json_build_object('projects',(SELECT coalesce(json_agg(to_jsonb(r) ORDER BY project_id),'[]'::json) FROM public.pi_projects r),'records',(SELECT coalesce(json_agg(to_jsonb(r) ORDER BY project_id,kind,resource_id),'[]'::json) FROM public.pi_records r),'sequence',(SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM public.pi_resource_sequence))",&[]).unwrap().get(0)
    }
    fn contract(client: &mut Client) -> Value {
        client.query_one("SELECT json_build_object('ledger',(SELECT json_agg(to_jsonb(r) ORDER BY version) FROM public.pi_schema_migrations r),'constraints',(SELECT json_agg(json_build_object('name',conname,'definition',pg_get_constraintdef(oid)) ORDER BY conname) FROM pg_constraint WHERE conrelid='public.pi_records'::regclass))", &[]).unwrap().get(0)
    }
    #[test]
    #[ignore = "fresh isolated S28_DISCOVERY_MIGRATION_URL pi_s28_discovery_migration required"]
    fn populated_v4_upgrade_preserves_data_and_rejects_malformed_contracts() {
        let url = std::env::var("S28_DISCOVERY_MIGRATION_URL")
            .expect("isolated URL required; do not print");
        assert!(url.contains("/pi_s28_discovery_migration"));
        let mut client = Client::connect(&url, NoTls).unwrap();
        let name: String = client
            .query_one("SELECT current_database()", &[])
            .unwrap()
            .get(0);
        assert!(name.starts_with("pi_s28_discovery_migration"));
        assert!(
            client
                .query_one(
                    "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
                    &[]
                )
                .unwrap()
                .get::<_, bool>(0)
        );
        crate::migrations::apply(&mut client).unwrap();
        client.batch_execute("ALTER TABLE public.pi_records DROP CONSTRAINT pi_records_kind_check; ALTER TABLE public.pi_records ADD CONSTRAINT pi_records_kind_check CHECK (kind IN ('log_state','log_data','log_source','log_analysis','model','conversion','quality')); DELETE FROM public.pi_schema_migrations WHERE version=5;").unwrap();
        let header = crate::repository_v2::Header {
            model_ids: vec!["model-1".into()],
            sequence: 17,
            ..Default::default()
        };
        let value = header.value().unwrap();
        client
            .execute(
                "INSERT INTO public.pi_projects VALUES('project-1',17,$1)",
                &[&value],
            )
            .unwrap();
        let model = crate::platform::StoredModel {
            id: "model-1".into(),
            name: "Сохранённая модель".into(),
            revision: 9,
            model: crate::bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap(),
            source_log: None,
            training: None,
        };
        client
            .execute(
                "INSERT INTO public.pi_records VALUES('project-1','model','model-1',9,$1)",
                &[&json!(model)],
            )
            .unwrap();
        client
            .batch_execute("SELECT setval('public.pi_resource_sequence',33,true)")
            .unwrap();
        let before = inventory(&mut client);
        let ledger:Vec<(i32,String,String,String)>=client.query("SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations ORDER BY version",&[]).unwrap().iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3))).collect();
        assert_eq!(
            crate::migrations::apply(&mut client).unwrap_err().code,
            "migration_required"
        );
        assert_eq!(inventory(&mut client), before);
        client
            .batch_execute(
                "ALTER TABLE public.pi_records ADD CONSTRAINT unexpected_check CHECK(version<999)",
            )
            .unwrap();
        let malformed_contract = contract(&mut client);
        assert!(run(&mut client).is_err());
        assert_eq!(contract(&mut client), malformed_contract);
        assert_eq!(inventory(&mut client), before);
        assert_eq!(
            client
                .query_one("SELECT max(version) FROM public.pi_schema_migrations", &[])
                .unwrap()
                .get::<_, i32>(0),
            4
        );
        client
            .batch_execute("ALTER TABLE public.pi_records DROP CONSTRAINT unexpected_check")
            .unwrap();
        migrate_offline(&mut client).unwrap();
        crate::migrations::apply(&mut client).unwrap();
        assert_eq!(inventory(&mut client), before);
        let after:Vec<(i32,String,String,String)>=client.query("SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations ORDER BY version",&[]).unwrap().iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3))).collect();
        assert_eq!(&after[..4], ledger.as_slice());
        migrate_offline(&mut client).unwrap();
        assert_eq!(inventory(&mut client), before);
        assert!(
            crate::migration_v4::validate_ready(&mut client).is_err(),
            "old strict schema contract must refuse v5"
        );
        client
            .execute(
                "UPDATE public.pi_schema_migrations SET checksum='tampered' WHERE version=5",
                &[],
            )
            .unwrap();
        let malformed_contract = contract(&mut client);
        assert!(migrate_offline(&mut client).is_err());
        assert_eq!(contract(&mut client), malformed_contract);
        assert_eq!(inventory(&mut client), before);
        client
            .execute(
                "UPDATE public.pi_schema_migrations SET checksum=$1 WHERE version=5",
                &[&checksum()],
            )
            .unwrap();
        validate_ready(&mut client).unwrap();
    }
}
