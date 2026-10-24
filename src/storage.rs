//! PostgreSQL worker owns its synchronous runtime; callers use spawn_blocking.
use crate::domain::ImportError;
use postgres::{Client, NoTls};
use serde_json::Value;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    time::{Duration, Instant},
};
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(15);
const LEASE: i64 = 5785256839849804116;
// PostgreSQL jsonb JEntry offsets have 28 bits. Reserve space for durable job
// metadata; count binary headers/entries as well as strings, not JSON text.
const DOCUMENT_BUDGET: usize = (1 << 28) - (64 << 10);
const IMPORT_BUDGET: usize = DOCUMENT_BUDGET - (2 << 20);

fn document_fits(value: &Value, left: &mut usize) -> bool {
    let overhead = match value {
        Value::Null | Value::Bool(_) => 0,
        // serde_json's default numbers are finite f64/i64/u64. Their
        // significant decimal digits fit this bound for PostgreSQL Numeric,
        // including varlena/header and up to three alignment bytes.
        Value::Number(_) => 32,
        Value::String(s) => s.len(),
        Value::Array(a) => 7usize.saturating_add(a.len().saturating_mul(4)),
        Value::Object(o) => 7usize.saturating_add(o.len().saturating_mul(8)),
    };
    let Some(remainder) = left.checked_sub(overhead) else {
        return false;
    };
    *left = remainder;
    match value {
        Value::Array(a) => a.iter().all(|v| document_fits(v, left)),
        Value::Object(o) => o.iter().all(|(k, v)| {
            let Some(remainder) = left.checked_sub(k.len()) else {
                return false;
            };
            *left = remainder;
            document_fits(v, left)
        }),
        _ => true,
    }
}

pub(crate) fn validate_document_capacity(
    document: &Value,
    importing: bool,
) -> Result<(), ImportError> {
    let mut left = if importing {
        IMPORT_BUDGET
    } else {
        DOCUMENT_BUDGET
    };
    if document_fits(document, &mut left) {
        Ok(())
    } else {
        Err(ImportError::new(
            "project_capacity",
            "Изменение превышает предел отдельной записи. Новый результат не сохранён; прежние данные доступны. Уменьшите объём данных этого изменения.",
        ))
    }
}

type Answer = Result<Reply, ImportError>;
pub(crate) struct ResourceSummary {
    pub(crate) kind: String,
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) number: u64,
    pub(crate) created_at: Option<chrono::DateTime<chrono::Utc>>,
}
enum Command {
    Lease,
    Health,
    Read(String),
    Write(String, u64, Value),
    Batch(Vec<BatchDocument>),
    NextId,
    ProjectHeader(String),
    ProjectHeaders,
    RecordKeys(String),
    ResourceRecords(String, String, Vec<String>),
    ResourceVersions(String, String, Vec<String>),
    ResourceSummaries(String),
    ProjectWrite(crate::normalized::ProjectWrite),
    ProjectDelete(ProjectDelete),
}
pub(crate) struct ProjectDelete {
    pub(crate) project: String,
    pub(crate) expected_auth: u64,
    pub(crate) auth_document: Value,
    pub(crate) expected_project: u64,
}
enum Reply {
    Ready,
    Document(Option<(u64, Value)>),
    Version(u64),
    Versions(Vec<u64>),
    Id(u64),
    Keys(Vec<(String, String)>),
    Headers(Vec<(String, u64, Value)>),
    Records(Vec<(String, u64, Value)>),
    RecordVersions(Vec<(String, u64)>),
    Summaries(Vec<ResourceSummary>),
}
#[derive(Clone)]
pub struct Database {
    sender: SyncSender<(Command, mpsc::Sender<Answer>, Instant)>,
    failed: Arc<AtomicBool>,
}
fn unavailable() -> ImportError {
    ImportError::new(
        "storage_unavailable",
        "База недоступна; изменение не подтверждено. Перезапустите приложение и проверьте сохранённые данные перед повтором.",
    )
}
impl Database {
    pub fn connect(url: String) -> Result<Self, ImportError> {
        let (sender, receiver) = mpsc::sync_channel::<(Command, mpsc::Sender<Answer>, Instant)>(64);
        let (ready_send, ready_recv) = mpsc::channel();
        let failed = Arc::new(AtomicBool::new(false));
        let worker_failed = failed.clone();
        std::thread::Builder::new().name("postgres-repository".into()).spawn(move||{
            let init=(|| -> Result<Client,ImportError> {
                let mut config: postgres::Config=url.parse().map_err(|_|unavailable())?;
                config.connect_timeout(Duration::from_secs(5));
                config.options("-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000 -c search_path=public,pg_catalog");
                let mut client=config.connect(NoTls).map_err(|_|unavailable())?;
                if !client.query_one("SELECT pg_try_advisory_lock($1)",&[&LEASE]).map_err(|_|unavailable())?.get::<_,bool>(0) { return Err(ImportError::new("app_already_running","С этой базой уже работает приложение. Остановите прежний экземпляр.")); }
                crate::migrations::apply(&mut client)?;
                client.query_one("SELECT pg_advisory_unlock($1)",&[&LEASE]).map_err(|_|unavailable())?;
                Ok(client)
            })();
            let mut client=match init {Ok(c)=>c,Err(e)=>{let _=ready_send.send(Err(e));return;}};
            if worker_failed.load(Ordering::Acquire){return;}
            let _=ready_send.send(Ok(()));
            let mut lease_held=false;
            for(command,answer,deadline)in receiver {
                if worker_failed.load(Ordering::Acquire){let _=answer.send(Err(unavailable()));break;}
                if Instant::now()>=deadline {let _=answer.send(Err(unavailable()));continue;}
                let result=(||->Answer{match command{
                    Command::ProjectHeaders=>Ok(Reply::Headers(crate::normalized::headers(&mut client)?)),
                    Command::ProjectHeader(project)=>Ok(Reply::Document(crate::normalized::read_header(&mut client,&project)?)),
                    Command::RecordKeys(project)=>Ok(Reply::Keys(client.query("SELECT kind,resource_id FROM public.pi_records WHERE project_id=$1 ORDER BY kind,resource_id",&[&project]).map_err(|_|unavailable())?.iter().map(|r|(r.get(0),r.get(1))).collect())),
                    Command::ResourceRecords(project,id,kinds)=>{
                        let rows=client.query("SELECT kind,version,document FROM public.pi_records WHERE project_id=$1 AND resource_id=$2 AND kind=ANY($3) ORDER BY kind",&[&project,&id,&kinds]).map_err(|_|unavailable())?;
                        tracing::info!(%project,resource_id=%id,records=rows.len(),"resource_payload_read");
                        Ok(Reply::Records(rows.iter().map(|r|(r.get(0),r.get::<_,i64>(1) as u64,r.get(2))).collect()))
                    },
                    Command::ResourceVersions(project,id,kinds)=>Ok(Reply::RecordVersions(client.query("SELECT kind,version FROM public.pi_records WHERE project_id=$1 AND resource_id=$2 AND kind=ANY($3) ORDER BY kind",&[&project,&id,&kinds]).map_err(|_|unavailable())?.iter().map(|r|(r.get(0),r.get::<_,i64>(1) as u64)).collect())),
                    Command::ResourceSummaries(project)=>{
                        // Only bounded scalar metadata crosses the worker boundary. A list
                        // never deserializes log data/source/analysis or model documents.
                        let rows=client.query("SELECT kind,resource_id,CASE WHEN kind='log_state' THEN document->>'filename' ELSE document->>'name' END,CASE WHEN kind='model' THEN document->>'revision' ELSE (SELECT a.document->>'events' FROM public.pi_records a WHERE a.project_id=r.project_id AND a.resource_id=r.resource_id AND a.kind='log_analysis') END,CASE WHEN kind='log_state' AND document ? 'created_at' THEN CASE WHEN jsonb_typeof(document->'created_at')='string' AND length(document->>'created_at')<=64 THEN document->'created_at' ELSE 'null'::jsonb END ELSE NULL END FROM public.pi_records r WHERE project_id=$1 AND kind IN ('log_state','model') ORDER BY kind,resource_id",&[&project]).map_err(|_|unavailable())?;
                        let mut summaries=Vec::new();
                        for row in rows {
                            let name=row.get::<_,Option<String>>(2).filter(|s|s.len()<=65536).ok_or_else(crate::normalized::invalid)?;
                            let number=row.get::<_,Option<String>>(3).and_then(|s|s.parse::<u64>().ok()).ok_or_else(crate::normalized::invalid)?;
                            let created_at = row.get::<_,Option<Value>>(4).map(|value| crate::web::deserialize_created_at(value).map_err(|_|crate::normalized::invalid())).transpose()?.flatten();
                            summaries.push(ResourceSummary { kind: row.get(0), id: row.get(1), name, number, created_at });
                        }
                        tracing::info!(%project,records=summaries.len(),"resource_summary_read");
                        Ok(Reply::Summaries(summaries))
                    },
                    Command::ProjectWrite(write)=>{let mut tx=client.transaction().map_err(|_|unavailable())?;let version=crate::normalized::write(&mut tx,&write)?;validate_record_index(&mut tx,&write.project,&write.metadata)?;tx.commit().map_err(|_|unavailable())?;tracing::info!(records_written=write.puts.len(),records_deleted=write.deletes.len(),project_revision=version,"normalized_committed");Ok(Reply::Version(version))},
                    Command::ProjectDelete(write)=>{
                        crate::auth::validate_stored(&write.auth_document)?;
                        validate_document_capacity(&write.auth_document,false)?;
                        if write.expected_auth>=i64::MAX as u64 || write.expected_project>=i64::MAX as u64 || write.project.is_empty(){return Err(crate::normalized::invalid());}
                        let mut tx=client.transaction().map_err(|_|unavailable())?;
                        let previous=tx.query_opt("SELECT version,document FROM public.pi_kv WHERE key='auth' FOR UPDATE",&[]).map_err(|_|unavailable())?.ok_or_else(crate::normalized::invalid)?;
                        let previous_value:Value=previous.get(1);
                        if previous.get::<_,i64>(0) as u64 != write.expected_auth
                            || previous_value.get("projects").and_then(|v|v.get(&write.project)).is_none()
                            || write.auth_document.get("projects").and_then(|v|v.get(&write.project)).is_some(){return Err(ImportError::new("storage_conflict","Проект или права изменились. Обновите страницу."));}
                        let header=tx.query_opt("SELECT version FROM public.pi_projects WHERE project_id=$1 FOR UPDATE",&[&write.project]).map_err(|_|unavailable())?;
                        if header.as_ref().map_or(0,|r|r.get::<_,i64>(0) as u64)!=write.expected_project{return Err(ImportError::new("storage_conflict","Данные проекта изменились. Обновите страницу."));}
                        let auth=tx.query_one("UPDATE public.pi_kv SET document=$1,version=version+1 WHERE key='auth' AND version=$2 RETURNING version",&[&write.auth_document,&(write.expected_auth as i64)]).map_err(|_|unavailable())?;
                        tx.execute("DELETE FROM public.pi_records WHERE project_id=$1",&[&write.project]).map_err(|_|unavailable())?;
                        tx.execute("DELETE FROM public.pi_migration_v2 WHERE project_id=$1",&[&write.project]).map_err(|_|unavailable())?;
                        tx.execute("DELETE FROM public.pi_kv WHERE key=$1",&[&format!("repository/{}",write.project)]).map_err(|_|unavailable())?;
                        let removed=tx.execute("DELETE FROM public.pi_projects WHERE project_id=$1 AND version=$2",&[&write.project,&(write.expected_project as i64)]).map_err(|_|unavailable())?;
                        if removed!=u64::from(write.expected_project!=0){return Err(crate::normalized::invalid());}
                        tx.commit().map_err(|_|unavailable())?;
                        tracing::info!("project_delete_committed");Ok(Reply::Version(auth.get::<_,i64>(0) as u64))
                    },
                    Command::Lease=>{if lease_held{return Ok(Reply::Ready);}let row=client.query_one("SELECT pg_try_advisory_lock($1)",&[&LEASE]).map_err(|_|unavailable())?;if !row.get::<_,bool>(0){return Err(ImportError::new("app_already_running","С этой базой уже работает приложение. Остановите прежний экземпляр."));}lease_held=true;Ok(Reply::Ready)},
                    Command::Health=>{client.query_one("SELECT 1",&[]).map_err(|_|unavailable())?;Ok(Reply::Ready)},
                    Command::Read(key)=>{
                        let row=client.query_opt("SELECT version,document FROM pi_kv WHERE key=$1",&[&key]).map_err(|_|unavailable())?;
                        Ok(Reply::Document(row.map(|row|(row.get::<_,i64>(0) as u64,row.get(1)))))
                    },
                    Command::NextId=>{let row=client.query_one("SELECT nextval('pi_resource_sequence')",&[]).map_err(|_|unavailable())?;Ok(Reply::Id(row.get::<_,i64>(0) as u64))},
                    Command::Batch(documents)=>{
                        let mut tx=client.transaction().map_err(|_|unavailable())?;let mut versions=Vec::new();
                        for entry in documents {
                            let (key,expected,document)=match entry {BatchDocument::Generic(k,e,d)=>(k,e,d),BatchDocument::Project(write)=>{let version=crate::normalized::write(&mut tx,&write)?;validate_record_index(&mut tx,&write.project,&write.metadata)?;versions.push(version);continue;}};
                            let row=if expected==0 {tx.query_opt("INSERT INTO pi_kv(key,version,document) VALUES($1,1,$2) ON CONFLICT DO NOTHING RETURNING version",&[&key,&document])}
                            else {tx.query_opt("UPDATE pi_kv SET document=$2,version=version+1 WHERE key=$1 AND version=$3 RETURNING version",&[&key,&document,&(expected as i64)])}.map_err(|_|unavailable())?;
                            let row=row.ok_or_else(||ImportError::new("storage_conflict","Данные изменились другим процессом."))?;versions.push(row.get::<_,i64>(0) as u64);
                        }tx.commit().map_err(|_|unavailable())?;Ok(Reply::Versions(versions))
                    },
                    Command::Write(key,expected,document)=>{
                        let mut tx=client.transaction().map_err(|_|unavailable())?;
                        let row=if expected==0{tx.query_opt("INSERT INTO pi_kv(key,version,document) VALUES($1,1,$2) ON CONFLICT DO NOTHING RETURNING version",&[&key,&document])}
                            else {tx.query_opt("UPDATE pi_kv SET document=$2,version=version+1 WHERE key=$1 AND version=$3 RETURNING version",&[&key,&document,&(expected as i64)])}.map_err(|_|unavailable())?;
                        let Some(row)=row else{return Err(ImportError::new("storage_conflict","Данные изменились другим процессом. Повторите после перезапуска."));};
                        let version=row.get::<_,i64>(0) as u64;tx.commit().map_err(|_|unavailable())?;
                        tracing::info!(storage_key=%key,revision=version,"storage_committed");Ok(Reply::Version(version))
                    }
                }})();
                if result.as_ref().is_err_and(|e|e.code=="storage_unavailable") {worker_failed.store(true,Ordering::Release);tracing::warn!("storage_failed_closed");}
                let _=answer.send(result);
                if worker_failed.load(Ordering::Acquire){break;}
            }
        }).map_err(|_|unavailable())?;
        match ready_recv.recv_timeout(RESPONSE_TIMEOUT) {
            Ok(result) => result?,
            Err(_) => {
                failed.store(true, Ordering::Release);
                return Err(unavailable());
            }
        }
        Ok(Self { sender, failed })
    }
    fn request(&self, command: Command) -> Answer {
        if self.failed.load(Ordering::Acquire) {
            return Err(unavailable());
        }
        let (sender, receiver) = mpsc::channel();
        match self
            .sender
            .try_send((command, sender, Instant::now() + RESPONSE_TIMEOUT))
        {
            Ok(()) => {}
            Err(mpsc::TrySendError::Full(_)) => {
                return Err(ImportError::new(
                    "storage_busy",
                    "Очередь базы заполнена. Запрос не принят.",
                ));
            }
            Err(mpsc::TrySendError::Disconnected(_)) => {
                self.failed.store(true, Ordering::Release);
                return Err(unavailable());
            }
        }
        match receiver.recv_timeout(RESPONSE_TIMEOUT) {
            Ok(result) => result,
            Err(_) => {
                self.failed.store(true, Ordering::Release);
                tracing::warn!("storage_response_timeout_outcome_unconfirmed");
                Err(unavailable())
            }
        }
    }
    pub fn read(&self, key: &str) -> Result<Option<(u64, Value)>, ImportError> {
        if key.starts_with("repository/") {
            return Err(legacy_reserved());
        }
        match self.request(Command::Read(key.into()))? {
            Reply::Document(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub fn write(&self, key: &str, expected: u64, document: Value) -> Result<u64, ImportError> {
        if key.starts_with("repository/") {
            return Err(legacy_reserved());
        }
        validate_document_capacity(&document, false)?;
        match self.request(Command::Write(key.into(), expected, document))? {
            Reply::Version(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub fn next_id(&self) -> Result<u64, ImportError> {
        match self.request(Command::NextId)? {
            Reply::Id(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub fn acquire_platform_lease(&self) -> Result<(), ImportError> {
        match self.request(Command::Lease)? {
            Reply::Ready => Ok(()),
            _ => unreachable!(),
        }
    }
    pub fn health(&self) -> Result<(), ImportError> {
        match self.request(Command::Health)? {
            Reply::Ready => Ok(()),
            _ => unreachable!(),
        }
    }
    pub fn write_batch(
        &self,
        documents: Vec<(String, u64, Value)>,
    ) -> Result<Vec<u64>, ImportError> {
        let documents = documents
            .into_iter()
            .map(|(key, expected, document)| {
                if let Some(project) = key.strip_prefix("repository/") {
                    if expected != 0 {
                        return Err(legacy_reserved());
                    }
                    let (metadata, puts) = crate::normalized::split_repository(project, document)?;
                    crate::repository_v2::Header::parse(metadata.clone())?;
                    Ok(BatchDocument::Project(crate::normalized::ProjectWrite {
                        project: project.into(),
                        expected,
                        metadata,
                        puts,
                        deletes: vec![],
                    }))
                } else {
                    validate_document_capacity(&document, false)?;
                    Ok(BatchDocument::Generic(key, expected, document))
                }
            })
            .collect::<Result<Vec<_>, ImportError>>()?;
        match self.request(Command::Batch(documents))? {
            Reply::Versions(v) => Ok(v),
            _ => unreachable!(),
        }
    }
}
pub fn sha256(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(bytes))
}

fn legacy_reserved() -> ImportError {
    ImportError::new(
        "legacy_reserved",
        "Прежние записи проекта доступны только для проверки миграции. Используйте новый формат хранения.",
    )
}
enum BatchDocument {
    Generic(String, u64, Value),
    Project(crate::normalized::ProjectWrite),
}
fn validate_record_index(
    tx: &mut postgres::Transaction<'_>,
    project: &str,
    metadata: &Value,
) -> Result<(), ImportError> {
    use std::collections::BTreeSet;
    let h = crate::repository_v2::Header::parse(metadata.clone())?;
    let expected: BTreeSet<(String, String)> = h
        .log_ids
        .iter()
        .flat_map(|id| {
            ["log_state", "log_data", "log_source", "log_analysis"]
                .map(|kind| (kind.to_string(), id.clone()))
        })
        .chain(h.model_ids.iter().map(|id| ("model".into(), id.clone())))
        .chain(
            h.conversions
                .values()
                .map(|m| ("conversion".into(), m.artifact_id.clone())),
        )
        .chain(
            h.quality_jobs
                .values()
                .map(|m| ("quality".into(), m.artifact_id.clone())),
        )
        .chain(
            h.discovery_jobs
                .values()
                .map(|m| ("discovery".into(), m.artifact_id.clone())),
        )
        .collect();
    let actual: BTreeSet<(String, String)> = tx
        .query(
            "SELECT kind,resource_id FROM public.pi_records WHERE project_id=$1",
            &[&project],
        )
        .map_err(|_| unavailable())?
        .iter()
        .map(|r| (r.get(0), r.get(1)))
        .collect();
    if actual != expected {
        return Err(ImportError::new(
            "repository_corrupt",
            "Неполный набор записей проекта. Изменение не сохранено.",
        ));
    }
    Ok(())
}
impl Database {
    pub(crate) fn resource_records(
        &self,
        project: &str,
        id: &str,
        kinds: &[&str],
    ) -> Result<Vec<(String, u64, Value)>, ImportError> {
        match self.request(Command::ResourceRecords(
            project.into(),
            id.into(),
            kinds.iter().map(|k| k.to_string()).collect(),
        ))? {
            Reply::Records(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub(crate) fn resource_versions(
        &self,
        project: &str,
        id: &str,
        kinds: &[&str],
    ) -> Result<Vec<(String, u64)>, ImportError> {
        match self.request(Command::ResourceVersions(
            project.into(),
            id.into(),
            kinds.iter().map(|k| k.to_string()).collect(),
        ))? {
            Reply::RecordVersions(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub(crate) fn resource_summaries(
        &self,
        project: &str,
    ) -> Result<Vec<ResourceSummary>, ImportError> {
        match self.request(Command::ResourceSummaries(project.into()))? {
            Reply::Summaries(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub(crate) fn project_headers(&self) -> Result<Vec<(String, u64, Value)>, ImportError> {
        match self.request(Command::ProjectHeaders)? {
            Reply::Headers(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub(crate) fn project_header(
        &self,
        project: &str,
    ) -> Result<Option<(u64, Value)>, ImportError> {
        match self.request(Command::ProjectHeader(project.into()))? {
            Reply::Document(d) => Ok(d),
            _ => unreachable!(),
        }
    }
    pub(crate) fn record_keys(&self, project: &str) -> Result<Vec<(String, String)>, ImportError> {
        match self.request(Command::RecordKeys(project.into()))? {
            Reply::Keys(d) => Ok(d),
            _ => unreachable!(),
        }
    }
    pub(crate) fn write_project(
        &self,
        write: crate::normalized::ProjectWrite,
    ) -> Result<u64, ImportError> {
        crate::normalized::validate_write(&write)?;
        crate::repository_v2::Header::parse(write.metadata.clone())?;
        match self.request(Command::ProjectWrite(write))? {
            Reply::Version(v) => Ok(v),
            _ => unreachable!(),
        }
    }
}
pub fn migrate_offline(url: String) -> Result<(), ImportError> {
    let mut config: postgres::Config = url.parse().map_err(|_| unavailable())?;
    config.connect_timeout(Duration::from_secs(5));
    config.options("-c statement_timeout=5000 -c lock_timeout=2000 -c transaction_timeout=10000 -c idle_in_transaction_session_timeout=10000 -c search_path=public,pg_catalog");
    let mut client = config.connect(NoTls).map_err(|_| unavailable())?;
    if !client
        .query_one("SELECT pg_try_advisory_lock($1)", &[&LEASE])
        .map_err(|_| unavailable())?
        .get::<_, bool>(0)
    {
        return Err(ImportError::new(
            "app_already_running",
            "Остановите приложение перед офлайн-миграцией.",
        ));
    }
    crate::migration_v5::migrate_offline(&mut client)
}
impl Database {
    pub(crate) fn delete_project(&self, write: ProjectDelete) -> Result<u64, ImportError> {
        match self.request(Command::ProjectDelete(write))? {
            Reply::Version(version) => Ok(version),
            _ => unreachable!(),
        }
    }
}

#[cfg(test)]
mod capacity_tests {
    use super::document_fits;
    use serde_json::json;

    #[test]
    fn utf8_keys_and_nested_container_entries_consume_the_budget() {
        let document = json!({"Ж": ["😀", null, true]});
        // object 7+8, key 2, array 7+12, string 4 = 40 bytes.
        assert!(document_fits(&document, &mut 40));
        assert!(!document_fits(&document, &mut 39));
    }

    #[test]
    fn short_numbers_need_more_space_than_their_json_text() {
        let document = json!([0, 0, 0]);
        assert!(serde_json::to_vec(&document).unwrap().len() < 20);
        assert!(!document_fits(&document, &mut 20));
        assert!(document_fits(&document, &mut 115));
        assert!(!document_fits(&document, &mut 114));
    }

    #[test]
    fn finite_numeric_extremes_and_empty_containers_are_bounded() {
        let document = json!([u64::MAX, i64::MIN, f64::MAX, f64::MIN_POSITIVE]);
        assert!(document_fits(&document, &mut 151));
        assert!(!document_fits(&document, &mut 150));
        assert!(document_fits(&json!({}), &mut 7));
        assert!(!document_fits(&json!([]), &mut 6));
    }
}
