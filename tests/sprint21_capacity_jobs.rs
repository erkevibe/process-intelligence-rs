//! Public API controls for admission before payload/job creation. No runtime or DB.
use process_intelligence_rs::jobs::{JobState, JobStore};
use std::sync::Arc;
use tokio::sync::Semaphore;

#[test]
fn reservations_hold_both_slots_without_phantom_jobs_or_id_advancement() {
    let store = JobStore::new();
    let first = store.reserve().unwrap();
    let second = store.reserve().unwrap();
    assert!(matches!(store.reserve(), Err("job_queue_full")));
    assert!(store.current().is_none());
    assert!(store.get("job-1").is_none());
    assert!(store.get("job-2").is_none());
    drop(first);
    drop(second);
    let first_job = store.create().unwrap();
    assert_eq!(first_job.job.snapshot().id, "job-1");
    assert_eq!(store.current().unwrap().snapshot().id, "job-1");
}

#[test]
fn actual_shared_import_conversion_pool_accepts_transfer_without_double_acquisition() {
    let pool = Arc::new(Semaphore::new(2));
    let imports = JobStore::restore_with_slots(&[], pool.clone());
    let conversions = JobStore::restore_with_slots(&[], pool.clone());
    let upload = imports.reserve().unwrap();
    let other = conversions.reserve().unwrap();
    assert_eq!(pool.available_permits(), 0);
    assert!(matches!(imports.create(), Err("job_queue_full")));
    // Both slots are already held. This succeeds only by consuming the existing
    // reservation rather than trying to acquire a third global permit.
    let worker = conversions
        .create_reserved(upload, Some("job-71".into()))
        .unwrap();
    assert_eq!(pool.available_permits(), 0);
    assert!(imports.current().is_none());
    assert!(imports.get("job-71").is_none());
    assert_eq!(conversions.current().unwrap().snapshot().id, "job-71");
    assert_eq!(worker.job.snapshot().state, JobState::Queued);
    worker.job.cancel();
    assert_eq!(worker.job.snapshot().state, JobState::Cancelled);
    assert!(matches!(imports.reserve(), Err("job_queue_full")));
    assert!(matches!(conversions.reserve(), Err("job_queue_full")));
    // Cancellation is terminal metadata, not proof of the actual worker's exit.
    drop(worker);
    assert_eq!(pool.available_permits(), 1);
    let next = imports.create().unwrap();
    assert_eq!(next.job.snapshot().id, "job-1");
    assert_eq!(pool.available_permits(), 0);
    drop(next);
    drop(other);
    assert_eq!(pool.available_permits(), 2);
}

#[test]
fn foreign_pool_rejection_restores_origin_without_touching_target_metadata() {
    let origin_pool = Arc::new(Semaphore::new(2));
    let target_pool = Arc::new(Semaphore::new(2));
    let origin = JobStore::restore_with_slots(&[], origin_pool.clone());
    let target = JobStore::restore_with_slots(&[], target_pool.clone());
    let reservation = origin.reserve().unwrap();
    assert_eq!(origin_pool.available_permits(), 1);
    assert!(matches!(
        target.create_reserved(reservation, Some("job-99".into())),
        Err("job_reservation_pool")
    ));
    assert_eq!(origin_pool.available_permits(), 2);
    assert_eq!(target_pool.available_permits(), 2);
    assert!(origin.current().is_none());
    assert!(target.current().is_none());
    assert!(target.get("job-99").is_none());
    assert_eq!(target.create().unwrap().job.snapshot().id, "job-1");
    assert_eq!(origin.create().unwrap().job.snapshot().id, "job-1");
}

#[test]
fn dropping_unpublished_reservation_preserves_existing_current_and_sequence() {
    let store = JobStore::new();
    let current = store.create().unwrap();
    let reservation = store.reserve().unwrap();
    assert!(matches!(store.create(), Err("job_queue_full")));
    assert_eq!(
        store.current().unwrap().snapshot().id,
        current.job.snapshot().id
    );
    drop(reservation);
    assert_eq!(store.current().unwrap().snapshot().id, "job-1");
    assert!(store.get("job-2").is_none());
    let next = store.create_with_id(None).unwrap();
    assert_eq!(next.job.snapshot().id, "job-2");
}

fn restored_terminal(id: u64) -> process_intelligence_rs::jobs::JobSnapshot {
    process_intelligence_rs::jobs::JobSnapshot {
        id: format!("job-{id}"),
        state: JobState::Cancelled,
        stage: "cancelled".into(),
        job_revision: 1,
        cancel_requested: true,
        result_id: None,
        error: None,
    }
}

#[test]
fn restored_maximum_sequence_refuses_auto_and_explicit_without_metadata_or_permit_change() {
    let pool = Arc::new(Semaphore::new(2));
    let original = restored_terminal(u64::MAX);
    let store = JobStore::restore_with_slots(std::slice::from_ref(&original), pool.clone());
    assert_eq!(pool.available_permits(), 2);
    assert!(matches!(store.create(), Err("job_sequence_exhausted")));
    assert!(matches!(
        store.create_with_id(Some("job-42".into())),
        Err("job_sequence_exhausted")
    ));
    let reservation = store.reserve().unwrap();
    assert_eq!(pool.available_permits(), 1);
    assert!(matches!(
        store.create_reserved(reservation, None),
        Err("job_sequence_exhausted")
    ));
    assert_eq!(pool.available_permits(), 2);
    assert_eq!(store.current().unwrap().snapshot(), original);
    assert_eq!(store.get(&original.id).unwrap().snapshot(), original);
    assert!(store.get("job-0").is_none());
    assert!(store.get("job-1").is_none());
    assert!(store.get("job-42").is_none());
}

#[test]
fn last_representable_auto_id_is_created_once_then_all_further_attempts_fail_closed() {
    let pool = Arc::new(Semaphore::new(2));
    let original = restored_terminal(u64::MAX - 1);
    let store = JobStore::restore_with_slots(std::slice::from_ref(&original), pool.clone());
    let reservation = store.reserve().unwrap();
    let last = store.create_reserved(reservation, None).unwrap();
    assert_eq!(last.job.snapshot().id, format!("job-{}", u64::MAX));
    assert_eq!(pool.available_permits(), 1);
    let current = last.job.snapshot();
    assert!(matches!(store.create(), Err("job_sequence_exhausted")));
    assert_eq!(pool.available_permits(), 1);
    assert_eq!(store.current().unwrap().snapshot(), current);
    assert_eq!(store.get(&original.id).unwrap().snapshot(), original);
    drop(last);
    assert_eq!(pool.available_permits(), 2);
    assert!(matches!(
        store.create_with_id(Some("job-7".into())),
        Err("job_sequence_exhausted")
    ));
    assert_eq!(pool.available_permits(), 2);
    assert!(store.get("job-0").is_none());
    assert!(store.get("job-7").is_none());
}

#[test]
fn foreign_pool_is_rejected_before_even_an_exhausted_target_sequence() {
    let origin_pool = Arc::new(Semaphore::new(2));
    let target_pool = Arc::new(Semaphore::new(2));
    let origin = JobStore::restore_with_slots(&[], origin_pool.clone());
    let original = restored_terminal(u64::MAX);
    let target = JobStore::restore_with_slots(std::slice::from_ref(&original), target_pool.clone());
    let reservation = origin.reserve().unwrap();
    assert!(matches!(
        target.create_reserved(reservation, Some("job-9".into())),
        Err("job_reservation_pool")
    ));
    assert_eq!(origin_pool.available_permits(), 2);
    assert_eq!(target_pool.available_permits(), 2);
    assert_eq!(target.current().unwrap().snapshot(), original);
    assert!(target.get("job-9").is_none());
    assert!(origin.current().is_none());
}

#[test]
fn explicit_maximum_id_at_last_sequence_boundary_also_exhausts_without_wrapping() {
    let pool = Arc::new(Semaphore::new(2));
    let original = restored_terminal(u64::MAX - 1);
    let store = JobStore::restore_with_slots(&[original], pool.clone());
    let maximum = format!("job-{}", u64::MAX);
    let last = store
        .create_reserved(store.reserve().unwrap(), Some(maximum.clone()))
        .unwrap();
    assert_eq!(last.job.snapshot().id, maximum);
    let current = last.job.snapshot();
    drop(last);
    assert!(matches!(store.create(), Err("job_sequence_exhausted")));
    assert!(matches!(
        store.create_with_id(Some(maximum)),
        Err("job_sequence_exhausted")
    ));
    assert_eq!(store.current().unwrap().snapshot(), current);
    assert_eq!(pool.available_permits(), 2);
    assert!(store.get("job-0").is_none());
}
