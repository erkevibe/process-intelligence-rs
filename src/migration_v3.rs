//! Explicit, transactional extension of normalized storage for conversion artifacts.
//! The caller owns the application advisory lease throughout migration.
use crate::{domain::ImportError, normalized, storage::sha256};
use postgres::{Client, Transaction};

const VERSION: i32 = 3;
const NAME: &str = "conversion_artifacts_v3";
// This contract deliberately leaves the historical normalized_v2 DDL unchanged.
const CONTRACT: &str = "conversion_artifacts_v3: replace pi_records kind CHECK with kind IN ('log_state','log_data','log_source','log_analysis','model','conversion'); preserve every existing record and project revision; transactional DDL and ledger";

pub(crate) fn checksum() -> String {
    sha256(CONTRACT.as_bytes())
}

fn validate_ledger(tx: &mut Transaction<'_>) -> Result<(), ImportError> {
    let rows = tx
        .query(
            "SELECT version,name,checksum FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(|_| normalized::unavailable())?;
    if rows.len() != 3
        || rows[0].get::<_, i32>(0) != 1
        || rows[1].get::<_, i32>(0) != normalized::VERSION
        || rows[1].get::<_, String>(1) != normalized::NAME
        || rows[1].get::<_, String>(2) != normalized::checksum()
        || rows[2].get::<_, i32>(0) != VERSION
        || rows[2].get::<_, String>(1) != NAME
        || rows[2].get::<_, String>(2) != checksum()
    {
        return Err(normalized::invalid());
    }
    let malformed: bool = tx
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM public.pi_migration_v2 WHERE source_version<1 OR checksum<>$1 OR source_sha !~ '^[0-9a-f]{64}$')",
            &[&normalized::checksum()],
        )
        .map_err(|_| normalized::unavailable())?
        .get(0);
    if malformed {
        return Err(normalized::invalid());
    }
    Ok(())
}

pub(crate) fn validate_ready(client: &mut Client) -> Result<(), ImportError> {
    crate::migrations::validate_v3_baseline(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    normalized::validate_schema_v3(&mut tx)?;
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
    if versions == [1, 2, 3] {
        return validate_ready(client);
    }
    crate::migrations::validate_v2(client)?;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    // Repeat strict validation under the same transaction that owns the DDL locks.
    tx.batch_execute("LOCK TABLE public.pi_schema_migrations, public.pi_projects, public.pi_records, public.pi_migration_v2 IN ACCESS EXCLUSIVE MODE")
        .map_err(|_| normalized::unavailable())?;
    normalized::validate_schema(&mut tx)?;
    let constraint: String = tx
        .query_one(
            "SELECT conname FROM pg_constraint WHERE conrelid='public.pi_records'::regclass AND contype='c' AND conkey=ARRAY[2]::smallint[]",
            &[],
        )
        .map_err(|_| normalized::invalid())?
        .get(0);
    let quoted = constraint.replace('"', "\"\"");
    tx.batch_execute(&format!(
        "ALTER TABLE public.pi_records DROP CONSTRAINT \"{quoted}\"; ALTER TABLE public.pi_records ADD CONSTRAINT pi_records_kind_check CHECK (kind IN ('log_state','log_data','log_source','log_analysis','model','conversion'));"
    ))
    .map_err(|_| normalized::unavailable())?;
    tx.execute(
        "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES($1,$2,$3)",
        &[&VERSION, &NAME, &checksum()],
    )
    .map_err(|_| normalized::unavailable())?;
    normalized::validate_schema_v3(&mut tx)?;
    validate_ledger(&mut tx)?;
    tx.commit().map_err(|_| normalized::unavailable())?;
    tracing::info!(schema_version = VERSION, "migration_v3_complete");
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
    match version {
        1 => {
            crate::migration_v2::run(client)?;
            run(client)
        }
        2 | 3 => run(client),
        _ => Err(normalized::invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use postgres::NoTls;
    use serde_json::{Value, json};

    #[test]
    #[ignore = "requires fresh isolated S21_MIGRATION_DATABASE_URL database pi_s21_migration"]
    fn populated_v2_upgrade_is_explicit_atomic_and_idempotent() {
        let url = std::env::var("S21_MIGRATION_DATABASE_URL")
            .expect("isolated migration database required");
        let mut client = Client::connect(&url, NoTls).unwrap();
        let name: String = client
            .query_one("SELECT current_database()", &[])
            .unwrap()
            .get(0);
        assert_eq!(name, "pi_s21_migration");
        let absent: bool = client
            .query_one(
                "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
                &[],
            )
            .unwrap()
            .get(0);
        assert!(absent, "migration fixture requires an empty database");
        crate::migrations::apply(&mut client).unwrap();
        // Produce the exact historical V2 contract, without changing its checksum.
        client.batch_execute("DROP TABLE public.pi_project_quota; ALTER TABLE public.pi_records DROP CONSTRAINT pi_records_kind_check; ALTER TABLE public.pi_records ADD CONSTRAINT pi_records_kind_check CHECK(kind IN ('log_state','log_data','log_source','log_analysis','model')); DELETE FROM public.pi_schema_migrations WHERE version>=3;").unwrap();
        let original = json!({"source":"retained", "unicode":"данные", "revision":17});
        client
            .execute(
                "INSERT INTO public.pi_projects VALUES('project-1',17,$1)",
                &[&original],
            )
            .unwrap();
        client
            .execute(
                "INSERT INTO public.pi_records VALUES('project-1','model','model-1',9,$1)",
                &[&original],
            )
            .unwrap();
        let before: Vec<(i32, String, String, String)> = client.query("SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations ORDER BY version", &[]).unwrap().iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3))).collect();
        assert_eq!(
            crate::migrations::apply(&mut client).unwrap_err().code,
            "migration_required"
        );
        // A malformed constraint must be rejected before either ledger or data changes.
        client.batch_execute("ALTER TABLE public.pi_records ADD CONSTRAINT unexpected_check CHECK(version < 999)").unwrap();
        assert!(migrate_offline(&mut client).is_err());
        let max: i32 = client
            .query_one("SELECT max(version) FROM public.pi_schema_migrations", &[])
            .unwrap()
            .get(0);
        assert_eq!(max, 2);
        client
            .batch_execute("ALTER TABLE public.pi_records DROP CONSTRAINT unexpected_check")
            .unwrap();
        migrate_offline(&mut client).unwrap();
        validate_ready(&mut client).unwrap();
        let after: Vec<(i32, String, String, String)> = client.query("SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations ORDER BY version", &[]).unwrap().iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3))).collect();
        assert_eq!(&after[..2], before.as_slice());
        migrate_offline(&mut client).unwrap();
        let again: Vec<(i32, String, String, String)> = client.query("SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations ORDER BY version", &[]).unwrap().iter().map(|r|(r.get(0),r.get(1),r.get(2),r.get(3))).collect();
        assert_eq!(after, again);
        let row = client
            .query_one(
                "SELECT version,document FROM public.pi_records WHERE resource_id='model-1'",
                &[],
            )
            .unwrap();
        assert_eq!(row.get::<_, i64>(0), 9);
        assert_eq!(row.get::<_, Value>(1), original);
        let row = client
            .query_one(
                "SELECT version,document FROM public.pi_projects WHERE project_id='project-1'",
                &[],
            )
            .unwrap();
        assert_eq!(row.get::<_, i64>(0), 17);
        assert_eq!(row.get::<_, Value>(1), original);
        client.execute("INSERT INTO public.pi_records VALUES('project-1','conversion','conversion-1',1,$1)", &[&json!({"input":"original"})]).unwrap();
        assert!(
            normalized::validate_ready(&mut client).is_err(),
            "old V2 validator must refuse V3"
        );
        client
            .execute(
                "UPDATE public.pi_schema_migrations SET checksum='tampered' WHERE version=3",
                &[],
            )
            .unwrap();
        assert!(migrate_offline(&mut client).is_err());
    }
}
