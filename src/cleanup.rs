//! Explicit offline retained-legacy cleanup. No startup, HTTP or retry path.
//! Eligibility hashes use Rust serde bytes; inventory hashes use server JSONB text.
use crate::domain::ImportError;
use postgres::{Client, GenericClient, NoTls};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const LEASE: i64 = 5785256839849804116;
const MAX_ROWS: usize = 10_000;
const MAX_PLAN: usize = 4 * 1024 * 1024;
const VALIDATION_SECONDS: u64 = 300;
const TABLES: &str = "public.pi_kv, public.pi_migration_v2, public.pi_projects, public.pi_records, public.pi_schema_migrations";
const OPTIONS: &str = "-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000 -c search_path=public,pg_catalog -c TimeZone=UTC -c DateStyle=ISO,YMD";

fn fail(code: &str) -> ImportError {
    ImportError::new(
        code,
        "Очистка не подтверждена. Сохраните план и копию; проверьте состояние базы. Автоматического повтора нет.",
    )
}
fn unavailable(_: postgres::Error) -> ImportError {
    fail("cleanup_storage_unavailable")
}
fn env(name: &str) -> Result<String, ImportError> {
    std::env::var(name)
        .ok()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| fail("cleanup_arguments"))
}
fn validation_budget(started: Instant) -> Result<(), ImportError> {
    if started.elapsed() >= Duration::from_secs(VALIDATION_SECONDS) {
        return Err(fail("cleanup_validation_timeout"));
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Identity {
    system_identifier: String,
    database_oid: String,
    database: String,
}
impl Identity {
    fn pair(&self) -> (&str, &str) {
        (&self.system_identifier, &self.database_oid)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Candidate {
    key: String,
    source_version: i64,
    source_sha: String,
    checksum: String,
    logical_bytes: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    rows: Vec<Value>,
    sequence: Value,
}
impl Snapshot {
    fn without(&self, candidates: &[Candidate]) -> Self {
        let keys: BTreeSet<&str> = candidates.iter().map(|c| c.key.as_str()).collect();
        Self {
            rows: self
                .rows
                .iter()
                .filter(|r| !(r[0] == "kv" && r[1].as_str().is_some_and(|key| keys.contains(key))))
                .cloned()
                .collect(),
            sequence: self.sequence.clone(),
        }
    }
    fn digest(&self) -> Result<String, ImportError> {
        Ok(crate::storage::sha256(
            &serde_json::to_vec(self).map_err(|_| fail("cleanup_plan"))?,
        ))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Archive {
    sha256: String,
    size: u64,
    manifest_sha256: String,
    database: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    format: u32,
    build_version: String,
    executable_sha256: String,
    normalized_checksum: String,
    archive: Archive,
    source: Identity,
    restore: Identity,
    pre: Snapshot,
    candidates: Vec<Candidate>,
    created_utc: String,
}

struct HashWriter(Sha256);
impl Write for HashWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn rust_digest(value: &Value) -> Result<String, ImportError> {
    let mut out = HashWriter(Sha256::new());
    serde_json::to_writer(&mut out, value).map_err(|_| fail("cleanup_source_invalid"))?;
    Ok(format!("{:x}", out.0.finalize()))
}
fn file_digest(path: &Path) -> Result<(String, u64), ImportError> {
    let mut file = File::open(path).map_err(|_| fail("cleanup_file"))?;
    let mut hash = Sha256::new();
    let mut size = 0u64;
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer).map_err(|_| fail("cleanup_file"))?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        size += n as u64;
    }
    Ok((format!("{:x}", hash.finalize()), size))
}

// Sensitive artifacts inherit from a directory restricted to the current user.
// Verify the access section without administrator privileges or policy changes.
fn private_directory(path: &Path) -> Result<(), ImportError> {
    if !path.is_dir()
        || fs::symlink_metadata(path)
            .map_err(|_| fail("cleanup_private_acl"))?
            .file_type()
            .is_symlink()
    {
        return Err(fail("cleanup_private_acl"));
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let script = "$ErrorActionPreference='Stop';$a=Get-Acl -LiteralPath $env:PI_CLEANUP_ACL_DIRECTORY;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$r=@($a.Access);if(!$a.AreAccessRulesProtected -or $r.Count-ne 1 -or $r[0].IsInherited -or $r[0].AccessControlType-ne 'Allow' -or $r[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value-ne $sid -or [int]$r[0].FileSystemRights-ne [int][Security.AccessControl.FileSystemRights]::FullControl){exit 3};exit 0";
        let status = std::process::Command::new("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe").args(["-NoProfile", "-NonInteractive", "-Command", script]).env("PI_CLEANUP_ACL_DIRECTORY", path).env("PSModulePath", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules").stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).creation_flags(0x08000000).status().map_err(|_| fail("cleanup_private_acl"))?;
        if !status.success() {
            return Err(fail("cleanup_private_acl"));
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if fs::metadata(path)
            .map_err(|_| fail("cleanup_private_acl"))?
            .permissions()
            .mode()
            & 0o077
            != 0
        {
            return Err(fail("cleanup_private_acl"));
        }
    }
    Ok(())
}
fn private_path(path: &Path) -> Result<(), ImportError> {
    if !path.is_absolute() {
        return Err(fail("cleanup_private_path"));
    }
    let private_root = fs::canonicalize(
        std::env::current_dir()
            .map_err(|_| fail("cleanup_private_path"))?
            .join(".local"),
    )
    .map_err(|_| fail("cleanup_private_path"))?;
    let parent = path.parent().ok_or_else(|| fail("cleanup_private_path"))?;
    let canonical_parent = fs::canonicalize(parent).map_err(|_| fail("cleanup_private_path"))?;
    if !canonical_parent.starts_with(&private_root) {
        return Err(fail("cleanup_private_path"));
    }
    let mut walk = Some(parent);
    while let Some(directory) = walk {
        if fs::symlink_metadata(directory)
            .map_err(|_| fail("cleanup_private_path"))?
            .file_type()
            .is_symlink()
        {
            return Err(fail("cleanup_private_path"));
        }
        if fs::canonicalize(directory).map_err(|_| fail("cleanup_private_path"))? == private_root {
            break;
        }
        walk = directory.parent();
    }
    private_directory(path.parent().ok_or_else(|| fail("cleanup_private_acl"))?)?;
    if path.exists() {
        if fs::symlink_metadata(path)
            .map_err(|_| fail("cleanup_private_acl"))?
            .file_type()
            .is_symlink()
        {
            return Err(fail("cleanup_private_acl"));
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let script = "$ErrorActionPreference='Stop';$a=Get-Acl -LiteralPath $env:PI_CLEANUP_ACL_FILE;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$r=@($a.Access);if($r.Count-ne 1 -or $r[0].AccessControlType-ne 'Allow' -or $r[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value-ne $sid -or [int]$r[0].FileSystemRights-ne [int][Security.AccessControl.FileSystemRights]::FullControl){exit 3};exit 0";
            let status = std::process::Command::new("C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe").args(["-NoProfile","-NonInteractive","-Command",script]).env("PI_CLEANUP_ACL_FILE",path).env("PSModulePath","C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules;C:\\Program Files\\WindowsPowerShell\\Modules").stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).creation_flags(0x08000000).status().map_err(|_| fail("cleanup_private_acl"))?;
            if !status.success() {
                return Err(fail("cleanup_private_acl"));
            }
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if fs::metadata(path)
                .map_err(|_| fail("cleanup_private_acl"))?
                .permissions()
                .mode()
                & 0o077
                != 0
            {
                return Err(fail("cleanup_private_acl"));
            }
        }
    }
    Ok(())
}
fn write_private(path: &Path, value: &Value) -> Result<String, ImportError> {
    private_path(path)?;
    let bytes = serde_json::to_vec_pretty(value).map_err(|_| fail("cleanup_plan"))?;
    if bytes.len() > MAX_PLAN {
        return Err(fail("cleanup_limit"));
    }
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|_| fail("cleanup_file"))?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| fail("cleanup_file"))?;
    Ok(crate::storage::sha256(&bytes))
}
fn bounded_read(path: &Path) -> Result<Vec<u8>, ImportError> {
    let file = File::open(path).map_err(|_| fail("cleanup_file"))?;
    if file.metadata().map_err(|_| fail("cleanup_file"))?.len() > MAX_PLAN as u64 {
        return Err(fail("cleanup_limit"));
    }
    let mut bytes = Vec::new();
    file.take((MAX_PLAN + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| fail("cleanup_file"))?;
    if bytes.len() > MAX_PLAN {
        return Err(fail("cleanup_limit"));
    }
    Ok(bytes)
}
fn archive(path: &Path) -> Result<Archive, ImportError> {
    private_path(path)?;
    let manifest_path = PathBuf::from(format!("{}.manifest.json", path.to_string_lossy()));
    private_path(&manifest_path)?;
    let manifest_bytes = bounded_read(&manifest_path)?;
    let bytes = manifest_bytes
        .strip_prefix(&[0xef, 0xbb, 0xbf])
        .unwrap_or(&manifest_bytes);
    let manifest: Value = serde_json::from_slice(bytes).map_err(|_| fail("cleanup_archive"))?;
    let (digest, size) = file_digest(path)?;
    let mut magic = [0; 5];
    File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .map_err(|_| fail("cleanup_archive"))?;
    if &magic != b"PGDMP"
        || manifest["format"] != "postgres_custom"
        || manifest["includes_auth"] != true
        || manifest["sha256"]
            .as_str()
            .is_none_or(|h| !h.eq_ignore_ascii_case(&digest))
        || manifest["size"].as_u64() != Some(size)
    {
        return Err(fail("cleanup_archive"));
    }
    let database = manifest["database"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 63)
        .ok_or_else(|| fail("cleanup_archive"))?
        .to_owned();
    Ok(Archive {
        sha256: digest,
        size,
        manifest_sha256: crate::storage::sha256(&manifest_bytes),
        database,
    })
}

fn connect(url: &str) -> Result<Client, ImportError> {
    let mut config: postgres::Config = url.parse().map_err(|_| fail("cleanup_arguments"))?;
    config
        .options(OPTIONS)
        .application_name("pi_cleanup_offline");
    config.connect_timeout(Duration::from_secs(5));
    config.connect(NoTls).map_err(unavailable)
}
fn identity(client: &mut Client) -> Result<Identity, ImportError> {
    let r = client.query_one("SELECT (pg_control_system()).system_identifier::text, d.oid::text, current_database(), current_setting('server_version_num'), current_setting('server_encoding'), pg_is_in_recovery(), current_setting('transaction_read_only') FROM pg_database d WHERE d.datname=current_database()", &[]).map_err(unavailable)?;
    if r.get::<_, String>(3) != "180006"
        || r.get::<_, String>(4) != "UTF8"
        || r.get::<_, bool>(5)
        || r.get::<_, String>(6) != "off"
    {
        return Err(fail("cleanup_identity"));
    }
    Ok(Identity {
        system_identifier: r.get(0),
        database_oid: r.get(1),
        database: r.get(2),
    })
}
fn offline(client: &mut Client) -> Result<(), ImportError> {
    if !client
        .query_one("SELECT pg_try_advisory_lock($1)", &[&LEASE])
        .map_err(unavailable)?
        .get::<_, bool>(0)
    {
        return Err(fail("cleanup_busy"));
    }
    // Other roles' activity details can be hidden. A visible connection with an
    // unknown backend type must not pass the offline ownership gate.
    let busy: bool = client.query_one("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datid=(SELECT oid FROM pg_database WHERE datname=current_database()) AND pid<>pg_backend_pid() AND (backend_type='client backend' OR backend_type IS NULL))", &[]).map_err(unavailable)?.get(0);
    if busy {
        return Err(fail("cleanup_busy"));
    }
    Ok(())
}
fn schema(client: &mut Client) -> Result<(), ImportError> {
    client
        .batch_execute("SET default_transaction_read_only=on")
        .map_err(unavailable)?;
    let versions: Vec<i32> = client
        .query(
            "SELECT version FROM public.pi_schema_migrations ORDER BY version",
            &[],
        )
        .map_err(unavailable)?
        .iter()
        .map(|r| r.get(0))
        .collect();
    if versions != [1, 2] {
        return Err(fail("cleanup_schema"));
    }
    // Exact known ledger is prerequisite; default-read-only prevents even a future
    // accidental migration branch from making persistent changes here.
    crate::migrations::apply(client).map_err(|_| fail("cleanup_schema"))?;
    let extra: bool = client.query_one("SELECT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f','S') AND c.relname NOT IN ('pi_kv','pi_projects','pi_records','pi_migration_v2','pi_schema_migrations','pi_resource_sequence')) OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')", &[]).map_err(unavailable)?.get(0);
    if extra {
        return Err(fail("cleanup_schema"));
    }
    client
        .batch_execute("SET default_transaction_read_only=off")
        .map_err(unavailable)
}

fn snapshot<C: GenericClient>(client: &mut C) -> Result<Snapshot, ImportError> {
    let count: i64 = client.query_one("SELECT (SELECT count(*) FROM public.pi_kv)+(SELECT count(*) FROM public.pi_projects)+(SELECT count(*) FROM public.pi_records)+(SELECT count(*) FROM public.pi_migration_v2)+(SELECT count(*) FROM public.pi_schema_migrations)", &[]).map_err(unavailable)?.get(0);
    if count < 0 || count > MAX_ROWS as i64 {
        return Err(fail("cleanup_limit"));
    }
    let oversized: bool = client.query_one("SELECT EXISTS(SELECT 1 FROM public.pi_kv WHERE octet_length(key)>512) OR EXISTS(SELECT 1 FROM public.pi_projects WHERE octet_length(project_id)>512) OR EXISTS(SELECT 1 FROM public.pi_records WHERE octet_length(project_id)>512 OR octet_length(kind)>512 OR octet_length(resource_id)>512)", &[]).map_err(unavailable)?.get(0);
    if oversized {
        return Err(fail("cleanup_limit"));
    }
    client.batch_execute("SET LOCAL max_parallel_workers_per_gather=4; SET LOCAL min_parallel_table_scan_size=0; SET LOCAL parallel_setup_cost=0; SET LOCAL parallel_tuple_cost=0").map_err(unavailable)?;
    let mut rows = Vec::with_capacity(count as usize);
    let sql = "WITH fingerprints AS MATERIALIZED (
        SELECT 1 AS t,key AS k1,''::text AS k2,''::text AS k3,0::bigint AS ledger_order,
            jsonb_build_array('kv',key,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) AS row FROM public.pi_kv
        UNION ALL SELECT 2,project_id,'','',0::bigint,
            jsonb_build_array('project',project_id,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) FROM public.pi_projects
        UNION ALL SELECT 3,project_id,kind,resource_id,0::bigint,
            jsonb_build_array('record',project_id,kind,resource_id,version,encode(sha256(convert_to(document::text,'UTF8')),'hex')) FROM public.pi_records
        UNION ALL SELECT 4,project_id,'','',0::bigint,
            jsonb_build_array('marker',project_id,source_version,source_sha,checksum) FROM public.pi_migration_v2
        UNION ALL SELECT 5,'','','',version::bigint,
            jsonb_build_array('ledger',version,name,checksum,applied_at::text) FROM public.pi_schema_migrations
        ) SELECT row FROM fingerprints ORDER BY t,k1,k2,k3,ledger_order";
    for row in client.query(sql, &[]).map_err(unavailable)? {
        let value: Value = row.get(0);
        if !value.is_array() {
            return Err(fail("cleanup_schema"));
        }
        rows.push(value);
    }
    if rows.len() != count as usize {
        return Err(fail("cleanup_changed"));
    }
    let sequence: Value = client.query_one("SELECT jsonb_build_array(s.seqtypid::regtype::text,s.seqstart,s.seqincrement,s.seqmax,s.seqmin,s.seqcache,s.seqcycle,q.last_value,q.is_called) FROM pg_sequence s CROSS JOIN public.pi_resource_sequence q WHERE s.seqrelid='public.pi_resource_sequence'::regclass", &[]).map_err(unavailable)?.get(0);
    Ok(Snapshot { rows, sequence })
}

fn locked_schema(tx: &mut postgres::Transaction<'_>) -> Result<(), ImportError> {
    crate::normalized::validate_schema(tx).map_err(|_| fail("cleanup_schema"))?;
    for (table, expected_columns, checks) in [
        (
            "pi_kv",
            vec![("key", "text"), ("version", "int8"), ("document", "jsonb")],
            1i64,
        ),
        (
            "pi_schema_migrations",
            vec![
                ("version", "int4"),
                ("name", "text"),
                ("checksum", "text"),
                ("applied_at", "timestamptz"),
            ],
            0i64,
        ),
    ] {
        let columns = tx.query("SELECT column_name,udt_name,is_nullable,is_identity,is_generated,column_default,collation_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 ORDER BY ordinal_position", &[&table]).map_err(unavailable)?;
        if columns.len() != expected_columns.len()
            || columns
                .iter()
                .zip(expected_columns)
                .any(|(r, (name, kind))| {
                    r.get::<_, String>(0) != name
                        || r.get::<_, String>(1) != kind
                        || r.get::<_, String>(2) != "NO"
                        || r.get::<_, String>(3) != "NO"
                        || r.get::<_, String>(4) != "NEVER"
                        || r.get::<_, Option<String>>(6).is_some()
                        || r.get::<_, Option<String>>(5)
                            != if name == "applied_at" {
                                Some("clock_timestamp()".into())
                            } else {
                                None
                            }
                })
        {
            return Err(fail("cleanup_schema"));
        }
        let qualified = format!("public.{table}");
        let r=tx.query_one("SELECT c.relkind='r' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity,(SELECT count(*) FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal),(SELECT count(*) FROM pg_rewrite WHERE ev_class=c.oid),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype NOT IN ('p','n','c')),(SELECT count(*) FROM pg_constraint WHERE conrelid=c.oid AND contype='c'),(SELECT count(*) FROM pg_index WHERE indrelid=c.oid),EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid=c.oid AND contype='p' AND NOT condeferrable AND NOT condeferred AND convalidated AND conkey=ARRAY[1]::smallint[]) FROM pg_class c WHERE c.oid=to_regclass($1)", &[&qualified]).map_err(unavailable)?;
        if !r.get::<_, bool>(0)
            || r.get::<_, i64>(1) != 0
            || r.get::<_, i64>(2) != 0
            || r.get::<_, i64>(3) != 0
            || r.get::<_, i64>(4) != checks
            || r.get::<_, i64>(5) != 1
            || !r.get::<_, bool>(6)
        {
            return Err(fail("cleanup_schema"));
        }
    }
    let valid:bool=tx.query_one("SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pi_kv'::regclass AND conname='pi_kv_positive_version' AND contype='c' AND convalidated AND pg_get_constraintdef(oid)='CHECK ((version > 0))') AND EXISTS(SELECT 1 FROM pg_class c JOIN pg_sequence s ON s.seqrelid=c.oid WHERE c.oid='public.pi_resource_sequence'::regclass AND c.relkind='S' AND s.seqtypid='bigint'::regtype AND s.seqincrement=1 AND s.seqmin=1 AND s.seqmax=9223372036854775807 AND NOT s.seqcycle) AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','f','S') AND c.relname NOT IN ('pi_kv','pi_projects','pi_records','pi_migration_v2','pi_schema_migrations','pi_resource_sequence')) AND NOT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')",&[]).map_err(unavailable)?.get(0);
    if !valid {
        return Err(fail("cleanup_schema"));
    }
    Ok(())
}

fn validate_current(client: &mut Client, started: Instant) -> Result<(), ImportError> {
    validation_budget(started)?;
    let auth_projects: BTreeSet<String> = if let Some(row) = client
        .query_opt("SELECT document FROM public.pi_kv WHERE key='auth'", &[])
        .map_err(unavailable)?
    {
        let v: Value = row.get(0);
        crate::auth::validate_stored(&v).map_err(|_| fail("cleanup_source_invalid"))?;
        v["projects"]
            .as_object()
            .ok_or_else(|| fail("cleanup_source_invalid"))?
            .keys()
            .cloned()
            .collect()
    } else {
        BTreeSet::new()
    };
    let projects: Vec<String> = client
        .query(
            "SELECT project_id FROM public.pi_projects ORDER BY project_id",
            &[],
        )
        .map_err(unavailable)?
        .iter()
        .map(|r| r.get(0))
        .collect();
    for project in projects {
        validation_budget(started)?;
        // Match Platform startup: normalized headers must belong to Auth.
        // Untouched Auth projects may legitimately have no lazy header yet.
        if !auth_projects.contains(&project) {
            return Err(fail("cleanup_source_invalid"));
        }
        let value: Value = client
            .query_one(
                "SELECT document FROM public.pi_projects WHERE project_id=$1",
                &[&project],
            )
            .map_err(unavailable)?
            .get(0);
        let header = crate::repository_v2::Header::parse(value)
            .map_err(|_| fail("cleanup_source_invalid"))?;
        let expected: BTreeSet<(String, String)> = header
            .log_ids
            .iter()
            .flat_map(|id| {
                crate::repository_v2::LOG_KINDS
                    .iter()
                    .map(move |kind| ((*kind).into(), id.clone()))
            })
            .chain(
                header
                    .model_ids
                    .iter()
                    .map(|id| ("model".into(), id.clone())),
            )
            .collect();
        let actual: BTreeSet<(String, String)> = client
            .query(
                "SELECT kind,resource_id FROM public.pi_records WHERE project_id=$1",
                &[&project],
            )
            .map_err(unavailable)?
            .iter()
            .map(|r| (r.get(0), r.get(1)))
            .collect();
        if actual != expected {
            return Err(fail("cleanup_source_invalid"));
        }
        for id in &header.log_ids {
            validation_budget(started)?;
            let records = client.query("SELECT kind,version,document FROM public.pi_records WHERE project_id=$1 AND resource_id=$2 ORDER BY kind", &[&project,id]).map_err(unavailable)?.into_iter().map(|r| (r.get(0),r.get::<_,i64>(1) as u64,r.get(2))).collect();
            let (log, _) = crate::repository_v2::decode_log(&project, id, records)
                .map_err(|_| fail("cleanup_source_invalid"))?;
            for view in header.user_views.values().filter_map(|v| v.get(id)) {
                crate::repository_v2::validate_view(
                    &log,
                    view.threshold,
                    view.selected.as_deref(),
                    view.selected_case.as_deref(),
                )
                .map_err(|_| fail("cleanup_source_invalid"))?;
            }
        }
        for id in &header.model_ids {
            validation_budget(started)?;
            let value: Value = client.query_one("SELECT document FROM public.pi_records WHERE project_id=$1 AND resource_id=$2 AND kind='model'", &[&project,id]).map_err(unavailable)?.get(0);
            let model: crate::platform::StoredModel =
                serde_json::from_value(value).map_err(|_| fail("cleanup_source_invalid"))?;
            if model.id != *id
                || model.revision == 0
                || model
                    .source_log
                    .as_ref()
                    .is_some_and(|log| !header.log_ids.contains(log))
                || crate::platform::exportable_model(&model.model).is_err()
            {
                return Err(fail("cleanup_source_invalid"));
            }
        }
    }
    Ok(())
}

fn candidates(client: &mut Client, started: Instant) -> Result<Vec<Candidate>, ImportError> {
    let keys: Vec<String> = client
        .query(
            "SELECT key FROM public.pi_kv WHERE key LIKE 'repository/%' ORDER BY key",
            &[],
        )
        .map_err(unavailable)?
        .iter()
        .map(|r| r.get(0))
        .collect();
    let mut result = Vec::new();
    for key in keys {
        validation_budget(started)?;
        let project = key
            .strip_prefix("repository/")
            .filter(|p| !p.is_empty())
            .ok_or_else(|| fail("cleanup_source_invalid"))?;
        let row = client.query_one("SELECT version,document,octet_length(document::text)::bigint FROM public.pi_kv WHERE key=$1", &[&key]).map_err(unavailable)?;
        let source_version: i64 = row.get(0);
        let value: Value = row.get(1);
        let digest = rust_digest(&value)?;
        // Historical retained payload must itself be recognized, without comparing
        // its old normalized content to legitimately updated current records.
        crate::normalized::split_repository(project, value)
            .map_err(|_| fail("cleanup_source_invalid"))?;
        let marker = client.query_opt("SELECT m.source_version,m.source_sha,m.checksum FROM public.pi_migration_v2 m JOIN public.pi_projects p USING(project_id) WHERE m.project_id=$1", &[&project]).map_err(unavailable)?.ok_or_else(|| fail("cleanup_source_invalid"))?;
        let checksum: String = marker.get(2);
        if source_version < 1
            || marker.get::<_, i64>(0) != source_version
            || marker.get::<_, String>(1) != digest
            || checksum != crate::normalized::checksum()
        {
            return Err(fail("cleanup_source_invalid"));
        }
        result.push(Candidate {
            key,
            source_version,
            source_sha: digest,
            checksum,
            logical_bytes: row.get(2),
        });
    }
    Ok(result)
}

// Both databases are already locked before either worker runs. Each worker
// borrows a distinct transaction exclusively; no client/transaction is shared.
// Join BOTH workers before propagating any error, deleting rows, or committing.
fn snapshot_pair(
    source: &mut postgres::Transaction<'_>,
    restore: &mut postgres::Transaction<'_>,
    validate_schema: bool,
) -> Result<(Snapshot, Snapshot), ImportError> {
    std::thread::scope(|scope| {
        let source_worker = scope.spawn(|| {
            if validate_schema {
                locked_schema(source)?;
            }
            snapshot(source)
        });
        let restore_worker = scope.spawn(|| {
            if validate_schema {
                locked_schema(restore)?;
            }
            snapshot(restore)
        });
        let source_result = source_worker.join();
        let restore_result = restore_worker.join();
        let source_snapshot = source_result.map_err(|_| fail("cleanup_worker_failed"))??;
        let restore_snapshot = restore_result.map_err(|_| fail("cleanup_worker_failed"))??;
        Ok((source_snapshot, restore_snapshot))
    })
}

fn locked_pair(
    source: &mut Client,
    restore: &mut Client,
    apply: bool,
    expected: Option<&Snapshot>,
) -> Result<Snapshot, ImportError> {
    let mut src = source.transaction().map_err(unavailable)?;
    let mut dst = restore.transaction().map_err(unavailable)?;
    src.batch_execute(&format!(
        "LOCK TABLE {TABLES} IN {} MODE",
        if apply {
            "SHARE ROW EXCLUSIVE"
        } else {
            "SHARE"
        }
    ))
    .map_err(unavailable)?;
    dst.batch_execute(&format!("LOCK TABLE {TABLES} IN SHARE MODE"))
        .map_err(unavailable)?;
    let (pre, restored) = snapshot_pair(&mut src, &mut dst, true)?;
    if restored != pre || expected.is_some_and(|e| *e != pre) {
        return Err(fail("cleanup_changed"));
    }
    dst.rollback().map_err(unavailable)?;
    src.rollback().map_err(unavailable)?;
    Ok(pre)
}

pub fn run(mode: &str) -> Result<Value, ImportError> {
    let validation_started = Instant::now();
    if !matches!(mode, "verify" | "apply") {
        return Err(fail("cleanup_arguments"));
    }
    let source_url =
        crate::configuration::database_url().map_err(|_| fail("cleanup_configuration"))?;
    let restore_url = env("PI_CLEANUP_RESTORE_URL")?;
    let archive_path = PathBuf::from(env("PI_CLEANUP_ARCHIVE")?);
    let plan_path = PathBuf::from(env("PI_CLEANUP_PLAN")?);
    private_path(&plan_path)?;
    let archive_proof = archive(&archive_path)?;
    let executable_sha256 =
        file_digest(&std::env::current_exe().map_err(|_| fail("cleanup_build"))?)?.0;
    validation_budget(validation_started)?;
    let supplied_plan = if mode == "apply" {
        let bytes = bounded_read(&plan_path)?;
        if crate::storage::sha256(&bytes) != env("PI_CLEANUP_CONFIRM_SHA")?.to_ascii_lowercase() {
            return Err(fail("cleanup_plan_sha"));
        }
        let p: Plan = serde_json::from_slice(&bytes).map_err(|_| fail("cleanup_plan"))?;
        if p.format != 1
            || p.build_version != env!("CARGO_PKG_VERSION")
            || p.executable_sha256 != executable_sha256
            || p.normalized_checksum != crate::normalized::checksum()
            || p.archive != archive_proof
        {
            return Err(fail("cleanup_plan"));
        }
        Some(p)
    } else {
        if plan_path.exists() {
            return Err(fail("cleanup_plan_exists"));
        }
        None
    };
    let mut source = connect(&source_url)?;
    let mut restore = connect(&restore_url)?;
    let source_id = identity(&mut source)?;
    let restore_id = identity(&mut restore)?;
    if source_id.pair() == restore_id.pair() || source_id.database != archive_proof.database {
        return Err(fail("cleanup_identity"));
    }
    if let Some(p) = &supplied_plan
        && (p.source != source_id || p.restore != restore_id)
    {
        return Err(fail("cleanup_identity"));
    }
    if source_id.pair() < restore_id.pair() {
        offline(&mut source)?;
        offline(&mut restore)?;
    } else {
        offline(&mut restore)?;
        offline(&mut source)?;
    }
    schema(&mut source)?;
    schema(&mut restore)?;
    let before_validation = locked_pair(&mut source, &mut restore, false, None)?;
    validate_current(&mut source, validation_started)?;
    validate_current(&mut restore, validation_started)?;
    let eligible = candidates(&mut source, validation_started)?;
    let pre = locked_pair(&mut source, &mut restore, false, Some(&before_validation))?;
    validation_budget(validation_started)?;
    if let Some(p) = &supplied_plan
        && (p.pre != pre || p.candidates != eligible)
    {
        return Err(fail("cleanup_changed"));
    }
    if mode == "verify" {
        let plan = Plan {
            format: 1,
            build_version: env!("CARGO_PKG_VERSION").into(),
            executable_sha256,
            normalized_checksum: crate::normalized::checksum(),
            archive: archive_proof,
            source: source_id,
            restore: restore_id,
            pre,
            candidates: eligible,
            created_utc: chrono::Utc::now().to_rfc3339(),
        };
        let sha = write_private(
            &plan_path,
            &serde_json::to_value(&plan).map_err(|_| fail("cleanup_plan"))?,
        )?;
        return Ok(
            json!({"outcome":"cleanup_verified","plan_sha256":sha,"candidate_rows":plan.candidates.len(),"logical_bytes":plan.candidates.iter().map(|c|c.logical_bytes).sum::<i64>(),"physical_disk_shrink":false}),
        );
    }
    let receipt_path = std::env::var("PI_CLEANUP_RECEIPT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(format!("{}.receipt.json", plan_path.to_string_lossy())));
    private_path(&receipt_path)?;
    if receipt_path.exists() {
        return Err(fail("cleanup_receipt_exists"));
    }
    if eligible.is_empty() {
        return Ok(
            json!({"outcome":"cleanup_empty","deleted_rows":0,"database_writes":0,"pre_sha256":pre.digest()?}),
        );
    }
    // Recheck archive outside the final, unchanged ten-second transaction budget.
    if archive(&archive_path)? != archive_proof {
        return Err(fail("cleanup_archive"));
    }
    validation_budget(validation_started)?;
    let expected_post = pre.without(&eligible);
    let pre_sha256 = pre.digest()?;
    let post_sha256 = expected_post.digest()?;
    let confirmation_sha = env("PI_CLEANUP_CONFIRM_SHA")?.to_ascii_lowercase();
    let started = Instant::now();
    let mut src = source.transaction().map_err(unavailable)?;
    let mut dst = restore.transaction().map_err(unavailable)?;
    src.batch_execute(&format!("LOCK TABLE {TABLES} IN SHARE ROW EXCLUSIVE MODE"))
        .map_err(unavailable)?;
    dst.batch_execute(&format!("LOCK TABLE {TABLES} IN SHARE MODE"))
        .map_err(unavailable)?;
    let (source_pre, restore_pre) = snapshot_pair(&mut src, &mut dst, true)?;
    if source_pre != pre || restore_pre != pre {
        return Err(fail("cleanup_changed"));
    }
    let keys: Vec<String> = eligible.iter().map(|c| c.key.clone()).collect();
    let versions: Vec<i64> = eligible.iter().map(|c| c.source_version).collect();
    let returned = src.query("DELETE FROM public.pi_kv k USING unnest($1::text[],$2::bigint[]) AS expected(key,version) WHERE k.key=expected.key AND k.version=expected.version RETURNING k.key,k.version", &[&keys,&versions]).map_err(unavailable)?;
    let actual: BTreeSet<(String, i64)> = returned.iter().map(|r| (r.get(0), r.get(1))).collect();
    let expected: BTreeSet<(String, i64)> = eligible
        .iter()
        .map(|c| (c.key.clone(), c.source_version))
        .collect();
    let (source_post, restore_post) = snapshot_pair(&mut src, &mut dst, false)?;
    if returned.len() != eligible.len()
        || actual != expected
        || source_post != expected_post
        || restore_post != pre
        || started.elapsed().as_secs() >= 10
    {
        return Err(fail("cleanup_conservation"));
    }
    dst.rollback().map_err(unavailable)?;
    let commit = src.commit();
    if commit.is_err() {
        // Never infer rollback from transport failure. New clients perform SELECTs
        // only; the original verified restore remains untouched, and no retry runs.
        let reconciled = reconcile(
            &source_url,
            &restore_url,
            &source_id,
            &restore_id,
            &pre,
            &expected_post,
        );
        return Ok(
            json!({"outcome":"cleanup_outcome_unconfirmed","reconciliation":reconciled,"automatic_retry":false,"deleted_rows_unconfirmed":eligible.len()}),
        );
    }
    let receipt = json!({"outcome":"cleanup_committed","source":source_id,"restore":restore_id,"plan_sha256":confirmation_sha,"archive_sha256":archive_proof.sha256,"pre_sha256":pre_sha256,"post_sha256":post_sha256,"deleted_rows":eligible.len(),"logical_bytes":eligible.iter().map(|c|c.logical_bytes).sum::<i64>(),"committed_utc":chrono::Utc::now().to_rfc3339(),"physical_disk_shrink":false});
    match write_private(&receipt_path, &receipt) {
        Ok(sha) => Ok(
            json!({"outcome":"cleanup_committed","deleted_rows":eligible.len(),"receipt_sha256":sha,"physical_disk_shrink":false}),
        ),
        Err(_) => Ok(
            json!({"outcome":"cleanup_committed_receipt_failed","deleted_rows":eligible.len(),"automatic_retry":false,"physical_disk_shrink":false}),
        ),
    }
}

fn reconcile(
    source_url: &str,
    restore_url: &str,
    source_id: &Identity,
    restore_id: &Identity,
    pre: &Snapshot,
    post: &Snapshot,
) -> &'static str {
    let result = (|| -> Result<&'static str, ImportError> {
        let mut source = connect(source_url)?;
        let mut restore = connect(restore_url)?;
        if identity(&mut source)? != *source_id || identity(&mut restore)? != *restore_id {
            return Ok("unexpected_state_stop");
        }
        source
            .batch_execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .map_err(unavailable)?;
        restore
            .batch_execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .map_err(unavailable)?;
        let src = snapshot(&mut source)?;
        let dst = snapshot(&mut restore)?;
        source.batch_execute("ROLLBACK").map_err(unavailable)?;
        restore.batch_execute("ROLLBACK").map_err(unavailable)?;
        if dst != *pre {
            return Ok("unexpected_state_stop");
        }
        if src == *pre {
            Ok("complete_pre")
        } else if src == *post {
            Ok("complete_post")
        } else {
            Ok("unexpected_state_stop")
        }
    })();
    result.unwrap_or("unavailable_stop")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receipt_snapshot_digest_public_calibration() {
        let snapshot = Snapshot {
            rows: vec![
                json!(["kv", "fixture/Ж𐍈\n\t\"\\", 7, "abc"]),
                json!(["marker", "p", 11, "source", "ddl"]),
            ],
            sequence: json!(["bigint", 1, 1, i64::MAX, 1, 1, false, 63, true]),
        };
        let bytes = serde_json::to_vec(&snapshot).unwrap();
        assert_eq!(snapshot.digest().unwrap(), crate::storage::sha256(&bytes));
        println!(
            "S13_RECEIPT_SNAPSHOT_CALIBRATION {}",
            snapshot.digest().unwrap()
        );
    }
    #[test]
    fn streaming_eligibility_equals_existing_serde_hash_domain() {
        for v in [
            json!({"b":[true,null,"é"],"a":1}),
            serde_json::from_str::<Value>(r#"{"a":1,"b":[true,null,"é"]}"#).unwrap(),
            json!([0,"𐍈",{"nested":null}]),
            Value::Null,
        ] {
            assert_eq!(
                rust_digest(&v).unwrap(),
                crate::storage::sha256(&serde_json::to_vec(&v).unwrap())
            );
        }
    }
    #[test]
    fn post_oracle_removes_only_exact_candidate_kv_and_preserves_every_other_field() {
        let pre = Snapshot {
            rows: vec![
                json!(["kv", "repository/p", 7, "oldhash"]),
                json!(["kv", "fixture/keep", 3, "same"]),
                json!(["marker", "p", 7, "oldhash", "ddl"]),
                json!(["project", "p", 8, "changed-current"]),
                json!(["ledger", 2, "normalized_v2", "ddl", "timestamp"]),
            ],
            sequence: json!(["bigint", 1, 1, 9, 1, 1, false, 42, true]),
        };
        let candidate = Candidate {
            key: "repository/p".into(),
            source_version: 7,
            source_sha: "oldhash".into(),
            checksum: "ddl".into(),
            logical_bytes: 12,
        };
        let post = pre.without(&[candidate]);
        assert_eq!(post.rows, pre.rows[1..]);
        assert_eq!(post.sequence, pre.sequence);
    }
}
