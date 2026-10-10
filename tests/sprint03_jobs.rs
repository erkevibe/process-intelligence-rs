//! Independent commit-before-publication cancellation regression.
use process_intelligence_rs::{
    domain::ImportError,
    jobs::{JobState, JobStore},
};
#[test]
fn cancelled_is_durable_prediction_before_memory_and_watch_and_commit_failure_changes_nothing() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    assert!(job.start("parsing"));
    let before = job.snapshot();
    let mut watch = job.subscribe();
    watch.borrow_and_update();
    let failure = job.try_cancel_with(|predicted| {
        assert_eq!(predicted.state, JobState::Cancelled);
        assert_eq!(predicted.stage, "cancelled");
        assert!(predicted.cancel_requested);
        assert_eq!(predicted.job_revision, before.job_revision + 1);
        assert!(predicted.result_id.is_none());
        assert!(predicted.error.is_none());
        assert!(!watch.has_changed().unwrap());
        Err(ImportError::new(
            "qa_commit_denied",
            "Controlled independent commit refusal",
        ))
    });
    assert_eq!(failure.unwrap_err().code, "qa_commit_denied");
    assert_eq!(job.snapshot(), before);
    assert!(!job.control().is_cancelled());
    assert!(!watch.has_changed().unwrap());
    let mut durable = None;
    let terminal = job
        .try_cancel_with(|predicted| {
            assert!(!watch.has_changed().unwrap());
            durable = Some(predicted.clone());
            Ok(())
        })
        .unwrap();
    assert_eq!(durable.as_ref(), Some(&terminal));
    assert_eq!(terminal.state, JobState::Cancelled);
    assert!(watch.has_changed().unwrap());
    assert_eq!(*watch.borrow_and_update(), terminal);
    assert!(!job.start("late"));
    assert_eq!(
        job.complete_with(|| panic!("cancelled cannot publish result")),
        terminal
    );
    assert_eq!(job.fail("late", "ignored"), terminal);
    assert_eq!(job.cancel(), terminal);
}

#[test]
fn failed_terminal_commit_refusal_never_changes_memory_or_watch() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    assert!(job.start("parsing"));
    let before = job.snapshot();
    let mut watch = job.subscribe();
    watch.borrow_and_update();
    let failed = job.try_fail_with("bad_xml", "Controlled parser failure", |prediction| {
        assert_eq!(prediction.state, JobState::Failed);
        assert_eq!(prediction.job_revision, before.job_revision + 1);
        assert_eq!(prediction.error.as_ref().unwrap().code, "bad_xml");
        assert!(!watch.has_changed().unwrap());
        Err(ImportError::new(
            "qa_commit_denied",
            "Controlled independent commit refusal",
        ))
    });
    assert_eq!(failed.unwrap_err().code, "qa_commit_denied");
    assert_eq!(job.snapshot(), before);
    assert!(!watch.has_changed().unwrap());
    let mut durable = None;
    let terminal = job
        .try_fail_with("bad_xml", "Controlled parser failure", |prediction| {
            durable = Some(prediction.clone());
            Ok(())
        })
        .unwrap();
    assert_eq!(durable, Some(terminal.clone()));
    assert_eq!(terminal.state, JobState::Failed);
    assert!(terminal.result_id.is_none());
    assert_eq!(*watch.borrow_and_update(), terminal);
}

#[test]
fn completion_commit_error_requires_durable_failure_before_publication() {
    let store = JobStore::new();
    let lease = store.create().unwrap();
    let job = &lease.job;
    assert!(job.start("publishing"));
    let before = job.snapshot();
    let mut watch = job.subscribe();
    watch.borrow_and_update();
    let denied = job.try_complete_durable_with(
        |_| {
            Err(ImportError::new(
                "result_commit_denied",
                "Controlled result refusal",
            ))
        },
        |prediction| {
            assert_eq!(prediction.state, JobState::Failed);
            assert_eq!(prediction.job_revision, before.job_revision + 1);
            assert!(prediction.result_id.is_none());
            assert_eq!(
                prediction.error.as_ref().unwrap().code,
                "result_commit_denied"
            );
            assert!(!watch.has_changed().unwrap());
            Err(ImportError::new(
                "failure_commit_denied",
                "Controlled failure refusal",
            ))
        },
    );
    assert_eq!(denied.unwrap_err().code, "failure_commit_denied");
    assert_eq!(job.snapshot(), before);
    assert!(!watch.has_changed().unwrap());
    let mut durable = None;
    let terminal = job
        .try_complete_durable_with(
            |_| {
                Err(ImportError::new(
                    "result_commit_denied",
                    "Controlled result refusal",
                ))
            },
            |prediction| {
                durable = Some(prediction.clone());
                Ok(())
            },
        )
        .unwrap();
    assert_eq!(durable, Some(terminal.clone()));
    assert_eq!(terminal.state, JobState::Failed);
    assert!(terminal.result_id.is_none());
    assert_eq!(*watch.borrow_and_update(), terminal);
}
