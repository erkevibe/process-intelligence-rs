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
            "В проекте недостаточно места для этого изменения. Новый результат не сохранён; прежние данные доступны. Для нового журнала используйте другой проект.",
        ))
    }
}

type Answer = Result<Reply, ImportError>;
enum Command {
    Lease,
    Health,
    Read(String),
    Write(String, u64, Value),
    Batch(Vec<(String, u64, Value)>),
    NextId,
}
enum Reply {
    Ready,
    Document(Option<(u64, Value)>),
    Version(u64),
    Versions(Vec<u64>),
    Id(u64),
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
                    Command::Lease=>{if lease_held{return Ok(Reply::Ready);}let row=client.query_one("SELECT pg_try_advisory_lock($1)",&[&LEASE]).map_err(|_|unavailable())?;if !row.get::<_,bool>(0){return Err(ImportError::new("app_already_running","С этой базой уже работает приложение. Остановите прежний экземпляр."));}lease_held=true;Ok(Reply::Ready)},
                    Command::Health=>{client.query_one("SELECT 1",&[]).map_err(|_|unavailable())?;Ok(Reply::Ready)},
                    Command::Read(key)=>{
                        let row=client.query_opt("SELECT version,document FROM pi_kv WHERE key=$1",&[&key]).map_err(|_|unavailable())?;
                        Ok(Reply::Document(row.map(|row|(row.get::<_,i64>(0) as u64,row.get(1)))))
                    },
                    Command::NextId=>{let row=client.query_one("SELECT nextval('pi_resource_sequence')",&[]).map_err(|_|unavailable())?;Ok(Reply::Id(row.get::<_,i64>(0) as u64))},
                    Command::Batch(documents)=>{
                        let mut tx=client.transaction().map_err(|_|unavailable())?;let mut versions=Vec::new();
                        for (key,expected,document) in documents {
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
        match self.request(Command::Read(key.into()))? {
            Reply::Document(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub fn write(&self, key: &str, expected: u64, document: Value) -> Result<u64, ImportError> {
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
        for (_, _, document) in &documents {
            validate_document_capacity(document, false)?;
        }
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
