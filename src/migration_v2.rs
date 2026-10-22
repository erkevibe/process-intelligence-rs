//! Explicit offline migration. Caller retains the exclusive application lease.
//! Managed writers increment pi_kv.version. Direct unversioned administrator SQL
//! is outside this migration's concurrency contract.
use crate::{
    domain::ImportError,
    normalized::{self, Record},
    storage::sha256,
};
use postgres::Client;
use serde_json::Value;

fn source(client: &mut Client, key: &str) -> Result<(i64, Value, String), ImportError> {
    let row = client
        .query_opt(
            "SELECT version,document FROM public.pi_kv WHERE key=$1",
            &[&key],
        )
        .map_err(|_| normalized::unavailable())?
        .ok_or_else(normalized::invalid)?;
    let version: i64 = row.get(0);
    let value: Value = row.get(1);
    if version < 1 {
        return Err(normalized::invalid());
    }
    let digest = sha256(&serde_json::to_vec(&value).map_err(|_| normalized::invalid())?);
    Ok((version, value, digest))
}
fn verify_record(client: &mut Client, project: &str, record: &Record) -> Result<(), ImportError> {
    let (kind, id, value) = record;
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    let old=tx.query_opt("SELECT version,document FROM public.pi_records WHERE project_id=$1 AND kind=$2 AND resource_id=$3", &[&project,kind,id]).map_err(|_|normalized::unavailable())?;
    if let Some(row) = old {
        if row.get::<_, i64>(0) != 1 || row.get::<_, Value>(1) != *value {
            return Err(normalized::invalid());
        }
    } else {
        tx.execute("INSERT INTO public.pi_records(project_id,kind,resource_id,version,document) VALUES($1,$2,$3,1,$4)", &[&project,kind,id,value]).map_err(|_|normalized::unavailable())?;
    }
    tx.commit().map_err(|_| normalized::unavailable())?;
    tracing::info!(
        project_id = project,
        record_kind = kind,
        resource_id = id,
        "migration_v2_record_verified"
    );
    Ok(())
}
pub(crate) fn run(client: &mut Client) -> Result<(), ImportError> {
    let ledger: Vec<i32> = client
        .query(
            "SELECT version FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .iter()
        .map(|r| r.get(0))
        .collect();
    if ledger == [1, 2] {
        return crate::migrations::validate_v2(client);
    }
    crate::migrations::validate_v1(client)?;
    let auth = client
        .query_opt(
            "SELECT version,document FROM public.pi_kv WHERE key='auth'",
            &[],
        )
        .map_err(|_| normalized::unavailable())?;
    let auth_source = if let Some(row) = auth {
        let version: i64 = row.get(0);
        let value: Value = row.get(1);
        crate::auth::validate_stored(&value).map_err(|_| normalized::invalid())?;
        Some((
            version,
            sha256(&serde_json::to_vec(&value).map_err(|_| normalized::invalid())?),
        ))
    } else {
        None
    };
    let keys: Vec<String> = client
        .query(
            "SELECT key FROM public.pi_kv WHERE key LIKE 'repository/%' ORDER BY key",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .iter()
        .map(|r| r.get(0))
        .collect();
    {
        let mut tx = client
            .transaction()
            .map_err(|_| normalized::unavailable())?;
        let present: Vec<bool> = [
            "public.pi_projects",
            "public.pi_records",
            "public.pi_migration_v2",
        ]
        .iter()
        .map(|name| {
            tx.query_one("SELECT to_regclass($1) IS NOT NULL", &[name])
                .map(|r| r.get(0))
                .map_err(|_| normalized::unavailable())
        })
        .collect::<Result<_, _>>()?;
        if present.iter().all(|v| !*v) {
            normalized::create_schema(&mut tx)?;
        } else if !present.iter().all(|v| *v) {
            return Err(normalized::invalid());
        }
        normalized::validate_schema(&mut tx)?;
        // Every pre-existing shadow header must have a recognized marker.
        let stray:bool=tx.query_one("SELECT EXISTS(SELECT 1 FROM public.pi_projects p LEFT JOIN public.pi_migration_v2 m USING(project_id) WHERE m.project_id IS NULL) OR EXISTS(SELECT 1 FROM public.pi_migration_v2 m WHERE NOT EXISTS(SELECT 1 FROM public.pi_kv k WHERE k.key='repository/'||m.project_id))", &[]).map_err(|_|normalized::unavailable())?.get(0);
        if stray {
            return Err(normalized::invalid());
        }
        tx.commit().map_err(|_| normalized::unavailable())?;
    }
    let mut verified = Vec::new();
    for key in &keys {
        let project = key
            .strip_prefix("repository/")
            .filter(|s| !s.is_empty())
            .ok_or_else(normalized::invalid)?;
        let (version, value, digest) = source(client, key)?;
        let (metadata, records) = normalized::split_repository(project, value)?;
        {
            let mut tx = client
                .transaction()
                .map_err(|_| normalized::unavailable())?;
            let marker=tx.query_opt("SELECT source_version,source_sha,checksum FROM public.pi_migration_v2 WHERE project_id=$1", &[&project]).map_err(|_|normalized::unavailable())?;
            if let Some(marker) = marker {
                if marker.get::<_, i64>(0) != version
                    || marker.get::<_, String>(1) != digest
                    || marker.get::<_, String>(2) != normalized::checksum()
                {
                    return Err(normalized::invalid());
                }
                let header = tx
                    .query_opt(
                        "SELECT version,document FROM public.pi_projects WHERE project_id=$1",
                        &[&project],
                    )
                    .map_err(|_| normalized::unavailable())?
                    .ok_or_else(normalized::invalid)?;
                if header.get::<_, i64>(0) != version || header.get::<_, Value>(1) != metadata {
                    return Err(normalized::invalid());
                }
            } else {
                tx.execute(
                    "INSERT INTO public.pi_projects(project_id,version,document) VALUES($1,$2,$3)",
                    &[&project, &version, &metadata],
                )
                .map_err(|_| normalized::unavailable())?;
                tx.execute("INSERT INTO public.pi_migration_v2(project_id,source_version,source_sha,checksum) VALUES($1,$2,$3,$4)", &[&project,&version,&digest,&normalized::checksum()]).map_err(|_|normalized::unavailable())?;
            }
            tx.commit().map_err(|_| normalized::unavailable())?;
        }
        for record in &records {
            verify_record(client, project, record)?;
        }
        let count: i64 = client
            .query_one(
                "SELECT count(*) FROM public.pi_records WHERE project_id=$1",
                &[&project],
            )
            .map_err(|_| normalized::unavailable())?
            .get(0);
        if count != records.len() as i64 {
            return Err(normalized::invalid());
        }
        let (again, _, again_digest) = source(client, key)?;
        if again != version || again_digest != digest {
            return Err(normalized::invalid());
        }
        verified.push((key.clone(), version, digest));
        tracing::info!(
            project_id = project,
            records = records.len(),
            "migration_v2_project_verified"
        );
    }
    // Re-read full source values outside transaction; publish only when every
    // source digest and revision matches. No original row is ever changed.
    for (key, version, digest) in &verified {
        let (again, _, again_digest) = source(client, key)?;
        if again != *version || again_digest != *digest {
            return Err(normalized::invalid());
        }
    }
    let final_auth = client
        .query_opt(
            "SELECT version,document FROM public.pi_kv WHERE key='auth'",
            &[],
        )
        .map_err(|_| normalized::unavailable())?;
    let final_auth_source = final_auth
        .map(|row| {
            let version: i64 = row.get(0);
            let value: Value = row.get(1);
            serde_json::to_vec(&value)
                .map(|bytes| (version, sha256(&bytes)))
                .map_err(|_| normalized::invalid())
        })
        .transpose()?;
    if final_auth_source != auth_source {
        return Err(normalized::invalid());
    }
    let mut tx = client
        .transaction()
        .map_err(|_| normalized::unavailable())?;
    // Close the final keyset/revision race even for managed pi_kv writers
    // that do not hold the platform lease. SHARE conflicts with their
    // ROW EXCLUSIVE lock; the existing lock/transaction deadlines remain.
    // Our own subsequent FOR UPDATE lock is compatible within this session.
    tx.batch_execute("LOCK TABLE public.pi_kv IN SHARE MODE")
        .map_err(|_| normalized::unavailable())?;
    let final_keys: Vec<String> = tx
        .query(
            "SELECT key FROM public.pi_kv WHERE key LIKE 'repository/%' ORDER BY key",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .iter()
        .map(|r| r.get(0))
        .collect();
    if final_keys != keys {
        return Err(normalized::invalid());
    }
    if let Some((version, _)) = &auth_source {
        let current: i64 = tx
            .query_one(
                "SELECT version FROM public.pi_kv WHERE key='auth' FOR UPDATE",
                &[],
            )
            .map_err(|_| normalized::unavailable())?
            .get(0);
        if current != *version {
            return Err(normalized::invalid());
        }
    } else if tx
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM public.pi_kv WHERE key='auth')",
            &[],
        )
        .map_err(|_| normalized::unavailable())?
        .get::<_, bool>(0)
    {
        return Err(normalized::invalid());
    }
    for (key, version, _) in &verified {
        let current: i64 = tx
            .query_one(
                "SELECT version FROM public.pi_kv WHERE key=$1 FOR UPDATE",
                &[key],
            )
            .map_err(|_| normalized::unavailable())?
            .get(0);
        if current != *version {
            return Err(normalized::invalid());
        }
    }
    let count: i64 = tx
        .query_one("SELECT count(*) FROM public.pi_projects", &[])
        .map_err(|_| normalized::unavailable())?
        .get(0);
    if count != verified.len() as i64 {
        return Err(normalized::invalid());
    }
    tx.execute(
        "INSERT INTO public.pi_schema_migrations(version,name,checksum) VALUES($1,$2,$3)",
        &[
            &normalized::VERSION,
            &normalized::NAME,
            &normalized::checksum(),
        ],
    )
    .map_err(|_| normalized::unavailable())?;
    tx.commit().map_err(|_| normalized::unavailable())?;
    tracing::info!(projects = verified.len(), "migration_v2_complete");
    Ok(())
}
