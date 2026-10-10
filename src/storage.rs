//! PostgreSQL worker owns its synchronous runtime; callers use spawn_blocking.
use crate::domain::ImportError;
use postgres::{Client, NoTls};
use serde_json::Value;
use std::sync::mpsc::{self, SyncSender};

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
    sender: SyncSender<(Command, mpsc::Sender<Answer>)>,
}
fn unavailable() -> ImportError {
    ImportError::new(
        "storage_unavailable",
        "База данных недоступна. Изменение не подтверждено.",
    )
}
impl Database {
    pub fn connect(url: String) -> Result<Self, ImportError> {
        let (sender, receiver) = mpsc::sync_channel::<(Command, mpsc::Sender<Answer>)>(64);
        let (ready_send, ready_recv) = mpsc::channel();
        std::thread::Builder::new().name("postgres-repository".into()).spawn(move||{
            let mut client=match Client::connect(&url,NoTls){Ok(c)=>c,Err(_)=>{let _=ready_send.send(Err(unavailable()));return;}};
            if client.batch_execute("CREATE TABLE IF NOT EXISTS pi_kv (key text PRIMARY KEY, version bigint NOT NULL, document jsonb NOT NULL); CREATE SEQUENCE IF NOT EXISTS pi_resource_sequence;").is_err(){let _=ready_send.send(Err(unavailable()));return;}
            let _=ready_send.send(Ok(()));
            for(command,answer)in receiver {
                let result=(||->Answer{match command{
                    Command::Lease=>{let row=client.query_one("SELECT pg_try_advisory_lock(5785256839849804116::bigint)",&[]).map_err(|_|unavailable())?;if !row.get::<_,bool>(0){return Err(ImportError::new("app_already_running","С этой базой уже работает приложение. Остановите прежний экземпляр."));}Ok(Reply::Ready)},
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
                }})();let _=answer.send(result);
            }
        }).map_err(|_|unavailable())?;
        ready_recv.recv().map_err(|_| unavailable())??;
        Ok(Self { sender })
    }
    fn request(&self, command: Command) -> Answer {
        let (sender, receiver) = mpsc::channel();
        self.sender
            .send((command, sender))
            .map_err(|_| unavailable())?;
        receiver.recv().map_err(|_| unavailable())?
    }
    pub fn read(&self, key: &str) -> Result<Option<(u64, Value)>, ImportError> {
        match self.request(Command::Read(key.into()))? {
            Reply::Document(v) => Ok(v),
            _ => unreachable!(),
        }
    }
    pub fn write(&self, key: &str, expected: u64, document: Value) -> Result<u64, ImportError> {
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
