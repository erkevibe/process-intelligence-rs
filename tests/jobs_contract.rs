use process_intelligence_rs::jobs::{JobState, JobStore};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
    mpsc,
};

#[test]
fn queued_running_stages_completed_are_monotonic_and_terminal() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    let queued = job.snapshot();
    assert_eq!(queued.state, JobState::Queued);
    assert_eq!(queued.stage, "queued");
    assert_eq!(queued.job_revision, 0);
    assert!(job.start("parsing"));
    let running = job.snapshot();
    assert_eq!(running.state, JobState::Running);
    assert!(running.job_revision > queued.job_revision);
    assert!(!job.start("parsing"));
    job.set_stage("analyzing");
    let analyzed = job.snapshot();
    assert_eq!(analyzed.stage, "analyzing");
    assert!(analyzed.job_revision > running.job_revision);
    job.set_stage("analyzing");
    assert_eq!(job.snapshot(), analyzed);
    let completed = job.complete_with(|| "result-1".into());
    assert_eq!(completed.state, JobState::Completed);
    assert_eq!(completed.result_id.as_deref(), Some("result-1"));
    assert_eq!(job.cancel(), completed);
    assert_eq!(job.fail("late", "ignored"), completed);
    job.set_stage("late");
    assert_eq!(job.snapshot(), completed);
    assert_eq!(
        job.complete_with(|| panic!("terminal callback must not execute")),
        completed
    );
}

#[test]
fn accepted_cancel_skips_publication_and_repeated_cancel_is_idempotent() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    assert!(job.start("parsing"));
    let cancelled_request = job.cancel();
    assert!(cancelled_request.cancel_requested);
    assert!(job.control().is_cancelled());
    assert_eq!(job.cancel(), cancelled_request);
    // Running may continue during a noninterruptible parser; accepted request must dominate publication.
    assert_eq!(cancelled_request.state, JobState::Running);
    job.set_stage("publishing");
    assert_eq!(job.snapshot(), cancelled_request);
    let marker = AtomicBool::new(false);
    let terminal = job.complete_with(|| {
        marker.store(true, Ordering::SeqCst);
        "forbidden".into()
    });
    assert!(!marker.load(Ordering::SeqCst));
    assert_eq!(terminal.state, JobState::Cancelled);
    assert!(terminal.result_id.is_none());
    assert!(terminal.error.is_none());
    assert_eq!(job.cancel(), terminal);
    assert_eq!(job.fail("late", "ignored"), terminal);
    assert_eq!(job.complete_with(|| panic!("cancelled callback")), terminal);
}

#[test]
fn queued_cancel_never_starts_and_failure_is_terminal() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    let request = job.cancel();
    assert!(request.cancel_requested);
    assert!(!job.start("parsing"));
    let terminal = job.snapshot();
    assert_eq!(terminal.state, JobState::Cancelled);
    assert!(terminal.result_id.is_none());
    let second = store.create().unwrap();
    let failed = second.job.fail("parse_error", "synthetic expected failure");
    assert_eq!(failed.state, JobState::Failed);
    assert_eq!(failed.error.as_ref().unwrap().code, "parse_error");
    assert_eq!(second.job.cancel(), failed);
    assert!(!second.job.control().is_cancelled());
    assert!(!second.job.start("retry"));
}

#[test]
fn work_lease_holds_admission_after_cancel_until_actual_exit() {
    let store = JobStore::new();
    let first = store.create().unwrap();
    let second = store.create().unwrap();
    assert_eq!(store.create().err(), Some("job_queue_full"));
    first.job.cancel();
    first.job.fail("cancelled", "expected");
    assert_eq!(
        store.create().err(),
        Some("job_queue_full"),
        "cancel must not release still-running worker lease"
    );
    drop(first);
    let third = store.create().expect("worker exit releases admission");
    assert_ne!(third.job.snapshot().id, second.job.snapshot().id);
}

#[test]
fn pruning_keeps_eight_latest_terminal_and_all_inflight() {
    let store = JobStore::new();
    let active = store.create().unwrap();
    let active_id = active.job.snapshot().id;
    let mut terminal_ids = Vec::new();
    for _ in 0..12 {
        let lease = store.create().unwrap();
        terminal_ids.push(lease.job.snapshot().id);
        assert!(lease.job.start("parsing"));
        lease.job.complete_with(|| "synthetic-result".into());
        drop(lease);
        store.prune();
    }
    assert!(store.get(&active_id).is_some());
    for id in &terminal_ids[..4] {
        assert!(store.get(id).is_none(), "old terminal {id}");
    }
    for id in &terminal_ids[4..] {
        assert!(store.get(id).is_some(), "retained terminal {id}");
    }
    assert_eq!(
        store.current().unwrap().snapshot().id,
        *terminal_ids.last().unwrap()
    );
}

#[test]
fn publication_lock_orders_concurrent_cancel_without_false_acceptance() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = lease.job.clone();
    assert!(job.start("publishing"));
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let marker = Arc::new(AtomicBool::new(false));
    let publish_marker = marker.clone();
    let publishing_job = job.clone();
    let publisher = std::thread::spawn(move || {
        publishing_job.complete_with(|| {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            publish_marker.store(true, Ordering::SeqCst);
            "committed".into()
        })
    });
    entered_rx.recv().unwrap();
    let cancelling_job = job.clone();
    let canceller = std::thread::spawn(move || cancelling_job.cancel());
    release_tx.send(()).unwrap();
    let completed = publisher.join().unwrap();
    let cancellation = canceller.join().unwrap();
    assert!(marker.load(Ordering::SeqCst));
    assert_eq!(completed.state, JobState::Completed);
    assert_eq!(cancellation, completed);
    assert!(
        !cancellation.cancel_requested,
        "cancel after atomic publication was not accepted"
    );
}

#[tokio::test]
async fn subscription_snapshot_is_reconnectable_current_state() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    assert!(lease.job.start("parsing"));
    let mut watcher = lease.job.subscribe();
    assert_eq!(*watcher.borrow(), lease.job.snapshot());
    lease.job.set_stage("analyzing");
    watcher.changed().await.unwrap();
    assert_eq!(watcher.borrow().stage, "analyzing");
    lease.job.cancel();
    lease.job.complete_with(|| panic!("cancelled callback"));
    let reconnect = lease.job.subscribe();
    assert_eq!(reconnect.borrow().state, JobState::Cancelled);
    assert!(reconnect.borrow().is_terminal());
}
