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
#[serde(deny_unknown_fields)]
pub struct JobError {
    pub code: String,
    pub message: String,
}
impl JobError {
    /// Persistable even when an upstream parser produces an unbounded error.
    pub(crate) fn bounded(code: &str, message: &str) -> Self {
        fn text(value: &str, limit: usize) -> String {
            let mut end = value.len().min(limit);
            while !value.is_char_boundary(end) {
                end -= 1;
            }
            value[..end].chars().filter(|c| !c.is_control()).collect()
        }
        Self {
            code: text(code, 128),
            message: text(message, 4096),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
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
    /// Persist a predicted transition before observers can see it.
    pub(crate) fn try_start_with(
        &self,
        stage: &str,
        commit: impl FnOnce(&JobSnapshot) -> Result<(), crate::domain::ImportError>,
    ) -> Result<bool, crate::domain::ImportError> {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.state != JobState::Queued || snapshot.cancel_requested {
            return Ok(false);
        }
        let mut predicted = snapshot.clone();
        predicted.state = JobState::Running;
        predicted.stage = stage.into();
        predicted.job_revision += 1;
        commit(&predicted)?;
        predicted.job_revision -= 1;
        *snapshot = predicted;
        self.publish(&mut snapshot);
        Ok(true)
    }
    pub(crate) fn try_set_stage_with(
        &self,
        stage: &str,
        commit: impl FnOnce(&JobSnapshot) -> Result<(), crate::domain::ImportError>,
    ) -> Result<(), crate::domain::ImportError> {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.state != JobState::Running
            || snapshot.cancel_requested
            || snapshot.stage == stage
        {
            return Ok(());
        }
        let mut predicted = snapshot.clone();
        predicted.stage = stage.into();
        predicted.job_revision += 1;
        commit(&predicted)?;
        predicted.job_revision -= 1;
        *snapshot = predicted;
        self.publish(&mut snapshot);
        Ok(())
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
            predicted.state = JobState::Cancelled;
            predicted.stage = "cancelled".into();
            predicted.result_id = None;
            predicted.error = None;
            predicted.job_revision += 1;
            commit(&predicted)?;
            // A confirmed cancellation is terminal and durable before it is
            // exposed through GET/watch. The worker cannot publish a result
            // while this lock is held, and later start/complete/fail are no-ops.
            predicted.job_revision -= 1;
            *snapshot = predicted;
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
        self.try_complete_durable_with(commit, |_| Ok(()))
            .expect("in-memory terminal failure")
    }
    pub fn try_complete_durable_with(
        &self,
        commit: impl FnOnce(&JobSnapshot) -> Result<String, crate::domain::ImportError>,
        commit_failure: impl FnOnce(&JobSnapshot) -> Result<(), crate::domain::ImportError>,
    ) -> Result<JobSnapshot, crate::domain::ImportError> {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.is_terminal() || snapshot.state != JobState::Running {
            return Ok(snapshot.clone());
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
                    let mut predicted = snapshot.clone();
                    predicted.state = JobState::Failed;
                    predicted.stage = "failed".into();
                    predicted.error = Some(JobError::bounded(&error.code, &error.message));
                    predicted.job_revision += 1;
                    commit_failure(&predicted)?;
                    predicted.job_revision -= 1;
                    *snapshot = predicted;
                }
            }
        }
        self.publish(&mut snapshot);
        Ok(snapshot.clone())
    }
    pub fn fail(&self, code: &str, message: &str) -> JobSnapshot {
        self.try_fail_with(code, message, |_| Ok(()))
            .expect("in-memory failure")
    }
    pub fn try_fail_with(
        &self,
        code: &str,
        message: &str,
        commit: impl FnOnce(&JobSnapshot) -> Result<(), crate::domain::ImportError>,
    ) -> Result<JobSnapshot, crate::domain::ImportError> {
        let mut snapshot = self.snapshot.lock().expect("job mutex");
        if snapshot.is_terminal() {
            return Ok(snapshot.clone());
        }
        let mut predicted = snapshot.clone();
        if predicted.cancel_requested || code == "cancelled" {
            predicted.state = JobState::Cancelled;
            predicted.stage = "cancelled".into();
        } else {
            predicted.state = JobState::Failed;
            predicted.stage = "failed".into();
            predicted.error = Some(JobError::bounded(code, message));
        }
        predicted.result_id = None;
        predicted.job_revision += 1;
        commit(&predicted)?;
        predicted.job_revision -= 1;
        *snapshot = predicted;
        self.publish(&mut snapshot);
        Ok(snapshot.clone())
    }
}
#[derive(Clone)]
pub struct JobControl {
    job: Arc<Job>,
}
impl JobControl {
    pub fn cancellation_token(&self) -> Arc<AtomicBool> {
        self.job.cancelled.clone()
    }
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

/// An unpublished admission slot. Dropping it releases capacity without creating
/// a job, advancing an ID, or changing the store's current job.
///
/// A reservation transfers exactly once and cannot be cloned:
/// ```compile_fail
/// use process_intelligence_rs::jobs::JobStore;
/// let store = JobStore::new();
/// let reservation = store.reserve().unwrap();
/// let _first = store.create_reserved(reservation, None).unwrap();
/// let _second = store.create_reserved(reservation, None).unwrap();
/// ```
/// ```compile_fail
/// use process_intelligence_rs::jobs::JobStore;
/// let reservation = JobStore::new().reserve().unwrap();
/// let _duplicate = reservation.clone();
/// ```
pub struct JobReservation {
    pool: Arc<Semaphore>,
    permit: OwnedSemaphorePermit,
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
    pub(crate) fn shared_slots(&self) -> Arc<Semaphore> {
        self.slots.clone()
    }
    pub(crate) fn remove_terminal(&self, id: &str) {
        let candidate = self.get(id);
        let Some(candidate) = candidate.filter(|job| job.snapshot().is_terminal()) else {
            return;
        };
        let mut entries = self.entries.lock().expect("jobs mutex");
        if entries
            .jobs
            .get(id)
            .is_some_and(|job| Arc::ptr_eq(job, &candidate))
        {
            entries.jobs.remove(id);
            if entries.current.as_deref() == Some(id) {
                entries.current = None;
            }
        }
    }
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
        self.create_reserved(self.reserve()?, explicit)
    }
    /// Reserves global capacity before reading or allocating a job payload.
    /// This does not publish any in-memory job metadata.
    pub fn reserve(&self) -> Result<JobReservation, &'static str> {
        let permit = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| "job_queue_full")?;
        Ok(JobReservation {
            pool: self.slots.clone(),
            permit,
        })
    }
    /// Converts one reservation from this exact shared pool into a worker lease.
    /// Shared import/conversion stores may transfer reservations; an unrelated
    /// pool is rejected before IDs or entries change and releases its own slot.
    pub fn create_reserved(
        &self,
        reservation: JobReservation,
        explicit: Option<String>,
    ) -> Result<JobLease, &'static str> {
        if !Arc::ptr_eq(&self.slots, &reservation.pool) {
            return Err("job_reservation_pool");
        }
        let JobReservation { pool: _, permit } = reservation;
        let mut entries = self.entries.lock().expect("jobs mutex");
        let sequence = entries
            .sequence
            .checked_add(1)
            .ok_or("job_sequence_exhausted")?;
        let id = explicit.unwrap_or_else(|| format!("job-{sequence}"));
        if entries.jobs.contains_key(&id) {
            return Err("job_duplicate_id");
        }
        let job = Arc::new(Job::new(id.clone()));
        entries.sequence = sequence;
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
        // Snapshot individual jobs without holding the store index. Publication
        // holds a job lock before it enters the repository/creates another job.
        let candidates = self.entries.lock().expect("jobs mutex").jobs.clone();
        let mut terminal: Vec<_> = candidates
            .iter()
            .filter(|(_, job)| job.snapshot().is_terminal())
            .map(|(id, job)| (id.clone(), job.clone()))
            .collect();
        terminal.sort_by_key(|(id, _)| {
            id.strip_prefix("job-")
                .and_then(|n| n.parse::<u64>().ok())
                .unwrap_or(0)
        });
        let mut entries = self.entries.lock().expect("jobs mutex");
        for (id, job) in terminal.iter().take(terminal.len().saturating_sub(8)) {
            if entries
                .jobs
                .get(id)
                .is_some_and(|current| Arc::ptr_eq(current, job))
            {
                entries.jobs.remove(id);
            }
        }
    }
}

#[cfg(test)]
mod lock_tests {
    use super::*;
    use std::{sync::mpsc, time::Duration};
    #[test]
    fn quality_duplicate_id_never_replaces_a_retained_job() {
        let jobs = JobStore::new();
        let first = jobs.create_with_id(Some("job-1".into())).unwrap();
        assert_eq!(
            jobs.create_with_id(Some("job-1".into())).err().unwrap(),
            "job_duplicate_id"
        );
        assert!(Arc::ptr_eq(&jobs.get("job-1").unwrap(), &first.job));
        assert_eq!(jobs.shared_slots().available_permits(), 1);
    }
    #[test]
    fn quality_index_cleanup_does_not_block_admission_behind_publication() {
        for prune in [false, true] {
            let jobs = Arc::new(JobStore::new());
            let lease = jobs.create().unwrap();
            let id = lease.job.snapshot().id;
            lease.job.start("running");
            let (entered_tx, entered_rx) = mpsc::sync_channel(1);
            let (release_tx, release_rx) = mpsc::sync_channel(1);
            let job = lease.job.clone();
            let worker = std::thread::spawn(move || {
                job.complete_with(|| {
                    entered_tx.send(()).unwrap();
                    release_rx.recv_timeout(Duration::from_secs(15)).unwrap();
                    "result".into()
                })
            });
            entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            let cleanup_jobs = jobs.clone();
            let (ready_tx, ready_rx) = mpsc::sync_channel(1);
            let cleanup = std::thread::spawn(move || {
                ready_tx.send(()).unwrap();
                if prune {
                    cleanup_jobs.prune()
                } else {
                    cleanup_jobs.remove_terminal(&id)
                }
            });
            ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            std::thread::sleep(Duration::from_millis(50));
            let admitted_jobs = jobs.clone();
            let (admit_tx, admit_rx) = mpsc::sync_channel(1);
            let admission = std::thread::spawn(move || {
                let result = admitted_jobs.create();
                let _ = admit_tx.send(result);
            });
            let admitted = admit_rx.recv_timeout(Duration::from_secs(3));
            release_tx.send(()).unwrap();
            worker.join().unwrap();
            cleanup.join().unwrap();
            admission.join().unwrap();
            assert!(
                admitted.is_ok(),
                "store index was held while waiting on a job publication lock"
            );
            drop(admitted);
            drop(lease);
        }
    }
}
