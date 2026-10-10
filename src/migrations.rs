//! Additive v1 adoption: singleton is held before this function, all DDL is transactional.
use crate::{domain::ImportError, storage::sha256};
use postgres::{Client, Transaction};

pub(crate) const VERSION: i32 = 1;
const MIGRATION: &str = "CREATE TABLE IF NOT EXISTS public.pi_kv (key text PRIMARY KEY, version bigint NOT NULL, document jsonb NOT NULL); CREATE SEQUENCE IF NOT EXISTS public.pi_resource_sequence; CREATE TABLE public.pi_schema_migrations (version integer PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT clock_timestamp()); ALTER TABLE public.pi_kv ADD CONSTRAINT pi_kv_positive_version CHECK (version > 0);";
fn invalid() -> ImportError {
    ImportError::new(
        "schema_unsupported",
        "Схема базы не поддерживается или повреждена. База не изменена; используйте совместимую версию и резервную копию.",
    )
}
fn database_error() -> ImportError {
    ImportError::new(
        "migration_failed",
        "Миграция не подтверждена. Остановите приложение и проверьте базу перед повторным запуском.",
    )
}
fn columns(
    tx: &mut Transaction<'_>,
    table: &str,
    expected: &[(&str, &str)],
) -> Result<(), ImportError> {
    let rows = tx.query("SELECT column_name,udt_name,is_nullable,is_identity,is_generated,column_default,collation_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 ORDER BY ordinal_position", &[&table]).map_err(|_| database_error())?;
    if rows.len() != expected.len()
        || rows.iter().zip(expected).any(|(row, (name, kind))| {
            row.get::<_, String>(0) != *name
                || row.get::<_, String>(1) != *kind
                || row.get::<_, String>(2) != "NO"
                || row.get::<_, String>(3) != "NO"
                || row.get::<_, String>(4) != "NEVER"
                || row.get::<_, Option<String>>(6).is_some()
                || row.get::<_, Option<String>>(5)
                    != if table == "pi_schema_migrations" && *name == "applied_at" {
                        Some("clock_timestamp()".into())
                    } else {
                        None
                    }
        })
    {
        return Err(invalid());
    }
    Ok(())
}
fn exists(tx: &mut Transaction<'_>, name: &str) -> Result<bool, ImportError> {
    Ok(tx
        .query_one("SELECT to_regclass($1) IS NOT NULL", &[&name])
        .map_err(|_| database_error())?
        .get(0))
}
fn table_contract(tx: &mut Transaction<'_>, name: &str, checks: i64) -> Result<(), ImportError> {
    let row=tx.query_one("SELECT c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity, (SELECT count(*) FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal), (SELECT count(*) FROM pg_rewrite WHERE ev_class=c.oid), (SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype NOT IN ('p','n','c')), (SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype='c'), (SELECT count(*) FROM pg_index WHERE indrelid=c.oid) FROM pg_class c WHERE c.oid=to_regclass($1)", &[&name]).map_err(|_|database_error())?;
    if !row.get::<_, bool>(0)
        || row.get::<_, i64>(1) != 0
        || row.get::<_, i64>(2) != 0
        || row.get::<_, i64>(3) != 0
        || row.get::<_, i64>(4) != checks
        || row.get::<_, i64>(5) != 1
    {
        return Err(invalid());
    }
    Ok(())
}
fn baseline(client: &mut Client, adopt: bool, ready_v2: bool) -> Result<(), ImportError> {
    let mut tx = client.transaction().map_err(|_| database_error())?;
    let table = exists(&mut tx, "public.pi_kv")?;
    let sequence = exists(&mut tx, "public.pi_resource_sequence")?;
    let ledger = exists(&mut tx, "public.pi_schema_migrations")?;
    if table != sequence || (ledger && !table) {
        return Err(invalid());
    }
    if table {
        table_contract(&mut tx, "public.pi_kv", if ledger { 1 } else { 0 })?;
        columns(
            &mut tx,
            "pi_kv",
            &[("key", "text"), ("version", "int8"), ("document", "jsonb")],
        )?;
        let pk: bool = tx.query_one("SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pi_kv'::regclass AND contype='p' AND NOT condeferrable AND NOT condeferred AND convalidated AND conkey=ARRAY[1]::smallint[])", &[]).map_err(|_| database_error())?.get(0);
        let seq: bool = tx.query_one("SELECT EXISTS(SELECT 1 FROM pg_class c JOIN pg_sequence s ON s.seqrelid=c.oid WHERE c.oid='public.pi_resource_sequence'::regclass AND c.relkind='S' AND s.seqtypid='bigint'::regtype AND s.seqincrement=1 AND s.seqmin=1 AND s.seqmax=9223372036854775807 AND NOT s.seqcycle)", &[]).map_err(|_| database_error())?.get(0);
        if !pk || !seq {
            return Err(invalid());
        }
    }
    let checksum = sha256(MIGRATION.as_bytes());
    if ledger {
        table_contract(&mut tx, "public.pi_schema_migrations", 0)?;
        columns(
            &mut tx,
            "pi_schema_migrations",
            &[
                ("version", "int4"),
                ("name", "text"),
                ("checksum", "text"),
                ("applied_at", "timestamptz"),
            ],
        )?;
        let ledger_pk: bool = tx.query_one("SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pi_schema_migrations'::regclass AND contype='p' AND NOT condeferrable AND NOT condeferred AND convalidated AND conkey=ARRAY[1]::smallint[])", &[]).map_err(|_| database_error())?.get(0);
        if !ledger_pk {
            return Err(invalid());
        }
        let rows = tx
            .query(
                "SELECT version,name,checksum FROM public.pi_schema_migrations ORDER BY version",
                &[],
            )
            .map_err(|_| database_error())?;
        if rows.len() != if ready_v2 { 2 } else { 1 }
            || rows[0].get::<_, i32>(0) != VERSION
            || rows[0].get::<_, String>(1) != "baseline_v1"
            || rows[0].get::<_, String>(2) != checksum
        {
            return Err(invalid());
        }
        let constraint: bool = tx.query_one("SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pi_kv'::regclass AND conname='pi_kv_positive_version' AND contype='c' AND convalidated AND pg_get_constraintdef(oid)='CHECK ((version > 0))')", &[]).map_err(|_| database_error())?.get(0);
        if !constraint {
            return Err(invalid());
        }
    }
    if !ledger && !adopt {
        return Err(invalid());
    }
    if !ledger {
        tx.batch_execute(MIGRATION).map_err(|_| database_error())?;
        tx.execute("INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES($1,'baseline_v1',$2)", &[&VERSION, &checksum]).map_err(|_| database_error())?;
    }
    tx.commit().map_err(|_| database_error())?;
    tracing::info!(schema_version = VERSION, adopted = !ledger, "schema_ready");
    Ok(())
}

pub(crate) fn validate_v1(client: &mut Client) -> Result<(), ImportError> {
    baseline(client, false, false)
}

pub(crate) fn apply(client: &mut Client) -> Result<(), ImportError> {
    let ledger: bool = client
        .query_one(
            "SELECT to_regclass('public.pi_schema_migrations') IS NOT NULL",
            &[],
        )
        .map_err(|_| database_error())?
        .get(0);
    if !ledger {
        let old: bool = client.query_one("SELECT to_regclass('public.pi_kv') IS NOT NULL OR to_regclass('public.pi_resource_sequence') IS NOT NULL", &[]).map_err(|_| database_error())?.get(0);
        if old {
            return Err(ImportError::new(
                "migration_required",
                "Требуется офлайн-миграция базы. Сохраните резервную копию и запустите --migrate-storage.",
            ));
        }
        let shadow:bool=client.query_one("SELECT to_regclass('public.pi_projects') IS NOT NULL OR to_regclass('public.pi_records') IS NOT NULL OR to_regclass('public.pi_migration_v2') IS NOT NULL",&[]).map_err(|_|database_error())?.get(0);
        if shadow {
            return Err(invalid());
        }
        baseline(client, true, false)?;
        return crate::normalized::initialize_empty(client);
    }
    let version: i32 = client
        .query_one(
            "SELECT coalesce(max(version),0) FROM public.pi_schema_migrations",
            &[],
        )
        .map_err(|_| database_error())?
        .get(0);
    match version {
        1 => {
            validate_v1(client)?;
            Err(ImportError::new(
                "migration_required",
                "Требуется офлайн-миграция базы 0.3. Сохраните резервную копию и запустите --migrate-storage.",
            ))
        }
        2 => {
            baseline(client, false, true)?;
            crate::normalized::validate_ready(client)
        }
        _ => Err(invalid()),
    }
}
