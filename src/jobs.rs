//! In-memory bounded jobs. Publication and cancellation share one lock.
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JobSnapshot {
    pub id: String,
    pub state: JobState,
    pub stage: String,
    pub job_revision: u64,
    pub cancel_requested: bool,
    pub result_id: Option<String>,
    pub error: Option<JobError>,
}
impl JobSnapshot {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self.state,
            JobState::Completed | JobState::Failed | JobState::Cancelled
        )
    }
}

pub struct Job {
    snapshot: Mutex<JobSnapshot>,
    cancelled: Arc<AtomicBool>,
    changes: watch::Sender<JobSnapshot>,
}
impl Job {
    fn new(id: String) -> Self {
        let snapshot = JobSnapshot {
            id,
            state: JobState::Queued,
            stage: "queued".into(),
            job_revision: 0,
            cancel_requested: false,
            result_id: None,
            error: None,
        };
        let (changes, _) = watch::channel(snapshot.clone());
        Self {
            snapshot: Mutex::new(snapshot),
            cancelled: Arc::new(AtomicBool::new(false)),
            changes,
        }
    }
    pub fn snapshot(&self) -> JobSnapshot {
        self.snapshot.lock().expect("job mutex").clone()
    }
    pub fn subscribe(&self) -> watch::Receiver<JobSnapshot> {
        self.changes.subscribe()
    }
    pub fn control(self: &Arc<Self>) -> JobControl {
        JobControl { job: self.clone() }
    }
    fn publish(&self, snapshot: &mut JobSnapshot) {
        snapshot.job_revision += 1;
        tracing::info!(job_id=%snapshot.id, state=?snapshot.state, stage=%snapshot.stage, job_revision=snapshot.job_revision, cancel_requested=snapshot.cancel_requested, "job_changed");
        self.changes.send_replace(snapshot.clone());
    }
    pub fn start(&self, stage: &str) -> bool {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.state != JobState::Queued {
            return false;
        }
        if snapshot.cancel_requested {
            snapshot.state = JobState::Cancelled;
            snapshot.stage = "cancelled".into();
            self.publish(&mut snapshot);
            return false;
        }
        snapshot.state = JobState::Running;
        snapshot.stage = stage.into();
        self.publish(&mut snapshot);
        true
    }
    pub fn set_stage(&self, stage: &str) {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.state == JobState::Running
            && !snapshot.cancel_requested
            && snapshot.stage != stage
        {
            snapshot.stage = stage.into();
            self.publish(&mut snapshot);
        }
    }
    pub fn cancel(&self) -> JobSnapshot {
        self.try_cancel_with(|_| Ok(()))
            .expect("in-memory cancellation")
    }
    pub fn try_cancel_with(
        &self,
        commit: impl FnOnce(&JobSnapshot) -> Result<(), crate::domain::ImportError>,
    ) -> Result<JobSnapshot, crate::domain::ImportError> {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if !snapshot.is_terminal() && !snapshot.cancel_requested {
            let mut predicted = snapshot.clone();
            predicted.cancel_requested = true;
            predicted.job_revision += 1;
            commit(&predicted)?;
            snapshot.cancel_requested = true;
            self.cancelled.store(true, Ordering::Release);
            self.publish(&mut snapshot);
        }
        Ok(snapshot.clone())
    }
    /// The callback commits a result only while cancel cannot be accepted.
    pub fn complete_with(&self, commit: impl FnOnce() -> String) -> JobSnapshot {
        self.try_complete_with(|_| Ok(commit()))
    }
    pub fn try_complete_with(
        &self,
        commit: impl FnOnce(&JobSnapshot) -> Result<String, crate::domain::ImportError>,
    ) -> JobSnapshot {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.is_terminal() || snapshot.state != JobState::Running {
            return snapshot.clone();
        }
        if snapshot.cancel_requested {
            snapshot.state = JobState::Cancelled;
            snapshot.stage = "cancelled".into();
        } else {
            match commit(&snapshot) {
                Ok(id) => {
                    snapshot.result_id = Some(id);
                    snapshot.state = JobState::Completed;
                    snapshot.stage = "completed".into();
                }
                Err(error) => {
                    snapshot.state = JobState::Failed;
                    snapshot.stage = "failed".into();
                    snapshot.error = Some(JobError {
                        code: error.code,
                        message: error.message,
                    });
                }
            }
        }
        self.publish(&mut snapshot);
        snapshot.clone()
    }
    pub fn fail(&self, code: &str, message: &str) -> JobSnapshot {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.is_terminal() {
            return snapshot.clone();
        }
        if snapshot.cancel_requested || code == "cancelled" {
            snapshot.state = JobState::Cancelled;
            snapshot.stage = "cancelled".into();
        } else {
            snapshot.state = JobState::Failed;
            snapshot.stage = "failed".into();
            snapshot.error = Some(JobError {
                code: code.into(),
                message: message.into(),
            });
        }
        self.publish(&mut snapshot);
        snapshot.clone()
    }
}
#[derive(Clone)]
pub struct JobControl {
    job: Arc<Job>,
}
impl JobControl {
    pub fn is_cancelled(&self) -> bool {
        self.job.cancelled.load(Ordering::Acquire)
    }
    pub fn set_stage(&self, stage: &str) {
        self.job.set_stage(stage);
    }
}

/// Keep the lease until the actual worker exits, including non-interruptible work.
pub struct JobLease {
    pub job: Arc<Job>,
    _permit: OwnedSemaphorePermit,
}

#[derive(Default)]
struct Entries {
    sequence: u64,
    jobs: BTreeMap<String, Arc<Job>>,
    current: Option<String>,
}
pub struct JobStore {
    entries: Mutex<Entries>,
    slots: Arc<Semaphore>,
}
impl Default for JobStore {
    fn default() -> Self {
        Self::new()
    }
}
impl JobStore {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(Entries::default()),
            slots: Arc::new(Semaphore::new(2)),
        }
    }
    pub fn create(&self) -> Result<JobLease, &'static str> {
        self.create_with_id(None)
    }
    pub fn create_with_id(&self, explicit: Option<String>) -> Result<JobLease, &'static str> {
        let permit = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| "job_queue_full")?;
        let mut entries = self.entries.lock().expect("jobs mutex");
        entries.sequence += 1;
        let id = explicit.unwrap_or_else(|| format!("job-{}", entries.sequence));
        let job = Arc::new(Job::new(id.clone()));
        entries.jobs.insert(id.clone(), job.clone());
        entries.current = Some(id);
        Ok(JobLease {
            job,
            _permit: permit,
        })
    }
    pub fn restore(snapshots: &[JobSnapshot]) -> Self {
        Self::restore_with_slots(snapshots, Arc::new(Semaphore::new(2)))
    }
    pub fn restore_with_slots(snapshots: &[JobSnapshot], slots: Arc<Semaphore>) -> Self {
        let store = Self {
            entries: Mutex::new(Entries::default()),
            slots,
        };
        {
            let mut entries = store.entries.lock().expect("jobs mutex");
            for snapshot in snapshots {
                let job = Arc::new(Job::new(snapshot.id.clone()));
                *job.snapshot.lock().expect("job mutex") = snapshot.clone();
                job.changes.send_replace(snapshot.clone());
                entries.sequence = entries.sequence.max(
                    snapshot
                        .id
                        .strip_prefix("job-")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                );
                entries.current = Some(snapshot.id.clone());
                entries.jobs.insert(snapshot.id.clone(), job);
            }
        }
        store
    }
    pub fn get(&self, id: &str) -> Option<Arc<Job>> {
        self.entries
            .lock()
            .expect("jobs mutex")
            .jobs
            .get(id)
            .cloned()
    }
    pub fn current(&self) -> Option<Arc<Job>> {
        let entries = self.entries.lock().expect("jobs mutex");
        entries
            .current
            .as_ref()
            .and_then(|id| entries.jobs.get(id))
            .cloned()
    }
    pub fn prune(&self) {
        let mut entries = self.entries.lock().expect("jobs mutex");
        let mut terminal: Vec<_> = entries
            .jobs
            .iter()
            .filter(|(_, job)| job.snapshot().is_terminal())
            .map(|(id, _)| id.clone())
            .collect();
        terminal.sort_by_key(|id| {
            id.strip_prefix("job-")
                .and_then(|n| n.parse::<u64>().ok())
                .unwrap_or(0)
        });
        for id in terminal.iter().take(terminal.len().saturating_sub(8)) {
            entries.jobs.remove(id);
        }
    }
}
