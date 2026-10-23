//! QA-authored real-PG compact-profile lifecycle tests. Root registers after pinned build closes.
//! Must be a child module of conversion_workflow; no production hooks are added.
use super::*;
use axum::body::{Body, to_bytes};
use serde_json::json;
use std::{path::PathBuf, sync::mpsc, time::Duration};
use tower::ServiceExt;
const PASSWORD: &str = "S23SyntheticLifecyclePassword123";
fn scope(root: &AppState, session: &str) -> AppState {
    let platform = root.platform.as_ref().unwrap();
    let mut state = platform
        .scope(root, platform.auth.actor(session).unwrap())
        .unwrap();
    state.session = Some(session.into());
    state
}
fn input() -> Arc<str> {
    Arc::from(
        std::str::from_utf8(include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/fixtures/conversions/flat-unicode.csv"
        )))
        .unwrap(),
    )
}
fn submission() -> Submission {
    Submission {
        from: "csv".into(),
        to: "xes".into(),
        input: input(),
        filename: "compact.csv".into(),
        allow_loss: false,
        report_profile: Some(crate::conversion::compact::PROFILE.into()),
        retry_of: None,
    }
}
fn newest(state: &AppState) -> String {
    state
        .repository
        .lock()
        .unwrap()
        .conversions
        .keys()
        .max_by_key(|id| id.strip_prefix("job-").unwrap().parse::<u128>().unwrap())
        .unwrap()
        .clone()
}
fn req(session: &str, method: &str, route: &str, multipart: bool) -> Request {
    let body = if multipart {
        let mut bytes=b"--compact\r\nContent-Disposition: form-data; name=\"from\"\r\n\r\ncsv\r\n--compact\r\nContent-Disposition: form-data; name=\"to\"\r\n\r\nxes\r\n--compact\r\nContent-Disposition: form-data; name=\"compact_report\"\r\n\r\non\r\n--compact\r\nContent-Disposition: form-data; name=\"file\"; filename=\"compact.csv\"\r\n\r\n".to_vec();
        bytes.extend_from_slice(input().as_bytes());
        bytes.extend_from_slice(b"\r\n--compact--\r\n");
        bytes
    } else {
        vec![]
    };
    axum::http::Request::builder()
        .method(method)
        .uri(route)
        .header("host", "127.0.0.1:3143")
        .header("origin", "http://127.0.0.1:3143")
        .header("cookie", format!("pi_session={session}"))
        .header(
            "content-type",
            if multipart {
                "multipart/form-data; boundary=compact"
            } else {
                "application/x-www-form-urlencoded"
            },
        )
        .body(Body::from(body))
        .unwrap()
}
async fn call(app: &Router, request: Request) -> u16 {
    tokio::time::timeout(Duration::from_secs(5), async {
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status().as_u16();
        to_bytes(response.into_body(), 4 * 1024 * 1024)
            .await
            .unwrap();
        status
    })
    .await
    .unwrap()
}
async fn idle(state: &AppState) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while state.conversion_jobs.shared_slots().available_permits() != 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap()
}
fn unpaired(state: &AppState, id: &str) -> ConversionMeta {
    let platform = state.platform.as_ref().unwrap();
    let project = &state.actor.as_ref().unwrap().project_id;
    let stored = crate::repository_v2::load_metadata(&platform.database, project).unwrap();
    let meta = stored.conversions[id].clone();
    assert_eq!(
        meta.report_profile.as_deref(),
        Some(crate::conversion::compact::PROFILE)
    );
    let artifact = load_artifact(&platform.database, project, &meta).unwrap();
    assert_eq!(artifact.input.as_bytes(), input().as_bytes());
    assert!(artifact.payload.is_none() && artifact.report.is_none());
    meta
}
#[test]
#[ignore = "fresh Root-owned pi_s23_lifecycle01 and S23_LIFECYCLE_DATABASE_URL/S23_LIFECYCLE_EVIDENCE"]
fn compact_real_worker_cancel_revoke_and_final_publication_fence() {
    let url = std::env::var("S23_LIFECYCLE_DATABASE_URL").unwrap();
    assert!(url.ends_with("/pi_s23_lifecycle01"));
    let dir = PathBuf::from(std::env::var("S23_LIFECYCLE_EVIDENCE").unwrap());
    assert!(dir.is_dir() && std::fs::read_dir(&dir).unwrap().next().is_none());
    let root = AppState::open(3143, url).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(platform.auth.needs_setup());
    let session = platform
        .auth
        .setup("s23_lifecycle_owner", PASSWORD)
        .unwrap();
    let owner = platform.auth.actor(&session).unwrap();
    let project = owner.project_id.clone();
    let state = scope(&root, &session);
    let app = crate::web::router(root.clone());
    platform
        .auth
        .add_user(&owner, &session, "s23_lifecycle_editor", PASSWORD)
        .unwrap();
    platform
        .auth
        .grant(
            &owner,
            &session,
            &project,
            "s23_lifecycle_editor",
            crate::auth::Role::Editor,
        )
        .unwrap();
    let editor_session = platform
        .auth
        .login("s23_lifecycle_editor", PASSWORD)
        .unwrap();
    platform.auth.switch(&editor_session, &project).unwrap();
    let editor = scope(&root, &editor_session);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(3)
        .enable_all()
        .build()
        .unwrap();
    let cancelled = runtime.block_on(async {
        let cpu = root.cpu.clone().acquire_owned().await.unwrap();
        assert_eq!(
            call(&app, req(&session, "POST", "/conversions", true)).await,
            303
        );
        let id = newest(&state);
        assert_eq!(unpaired(&state, &id).snapshot.state, JobState::Queued);
        assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 1);
        assert_eq!(
            call(
                &app,
                req(
                    &session,
                    "POST",
                    &format!("/conversions/jobs/{id}/cancel"),
                    false
                )
            )
            .await,
            303
        );
        assert_eq!(
            state.conversion_jobs.shared_slots().available_permits(),
            1,
            "cancel must not release real worker lease early"
        );
        drop(cpu);
        idle(&state).await;
        assert_eq!(unpaired(&state, &id).snapshot.state, JobState::Cancelled);
        for part in ["payload", "report"] {
            assert_eq!(
                call(
                    &app,
                    req(
                        &session,
                        "GET",
                        &format!("/conversions/jobs/{id}/{part}"),
                        false
                    )
                )
                .await,
                404
            );
        }
        id
    });
    let revoked = runtime.block_on(async {
        let cpu = root.cpu.clone().acquire_owned().await.unwrap();
        assert_eq!(
            call(&app, req(&editor_session, "POST", "/conversions", true)).await,
            303
        );
        let id = newest(&state);
        unpaired(&state, &id);
        platform
            .auth
            .grant(
                &owner,
                &session,
                &project,
                "s23_lifecycle_editor",
                crate::auth::Role::Viewer,
            )
            .unwrap();
        drop(cpu);
        idle(&state).await;
        let meta = unpaired(&state, &id);
        assert_ne!(meta.snapshot.state, JobState::Completed);
        assert_eq!(
            call(
                &app,
                req(
                    &session,
                    "POST",
                    &format!("/conversions/jobs/{id}/cancel"),
                    false
                )
            )
            .await,
            303
        );
        assert_eq!(unpaired(&state, &id).snapshot.state, JobState::Cancelled);
        id
    });
    platform
        .auth
        .grant(
            &owner,
            &session,
            &project,
            "s23_lifecycle_editor",
            crate::auth::Role::Editor,
        )
        .unwrap();
    let reservation = reserve_conversion(&editor).unwrap();
    let (lease, meta) = accept_reserved(&editor, reservation, submission()).unwrap();
    assert!(lease.job.start("converting"));
    persist(&editor, &lease.job.snapshot(), None).unwrap();
    let converted = crate::conversion::convert("csv", "xes", input().as_bytes(), false);
    let report = String::from_utf8(
        crate::conversion::report_bytes_profile(
            "csv",
            "xes",
            input().as_bytes(),
            false,
            &converted,
            true,
        )
        .unwrap(),
    )
    .unwrap();
    let payload = String::from_utf8(converted.unwrap().payload).unwrap();
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let worker_state = editor.clone();
    let job = lease.job.clone();
    let artifact_id = meta.artifact_id.clone();
    let worker = std::thread::spawn(move || {
        job.try_complete_durable_with(
            |before| {
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let mut done = before.clone();
                done.state = JobState::Completed;
                done.stage = "completed".into();
                done.result_id = Some(artifact_id.clone());
                done.job_revision += 1;
                persist(&worker_state, &done, Some((Some(payload), report)))?;
                Ok(artifact_id)
            },
            |failed| persist(&worker_state, failed, None),
        )
    });
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    platform
        .auth
        .grant(
            &owner,
            &session,
            &project,
            "s23_lifecycle_editor",
            crate::auth::Role::Viewer,
        )
        .unwrap();
    release_tx.send(()).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err().code, "access_denied");
    let durable = unpaired(&state, &meta.snapshot.id);
    assert_eq!(durable.snapshot.state, JobState::Running);
    lease
        .job
        .try_cancel_with(|snapshot| persist(&state, snapshot, None))
        .unwrap();
    drop(lease);
    let proof = json!({"status":"ACTUAL_COMPACT_PROFILE_LIFECYCLE_REQUIRES_INDEPENDENT_ACCEPTANCE",
        "profile":crate::conversion::compact::PROFILE,"cancelled_job":cancelled,"revoked_real_worker_job":revoked,
        "revoked_publication_callback_job":meta.snapshot.id,"source_sha256":crate::conversion::sha(input().as_bytes()),
        "limits":["Real PostgreSQL and actual Axum request/worker for cancellation and preworker revocation.",
        "Final callback race is a controlled publication closure with product-encoded pair, not a real app process crash.",
        "Stock compact process crash/restart is a separate mandatory gate."]});
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(dir.join("lifecycle-proof.json"))
        .unwrap();
    use std::io::Write;
    file.write_all(&serde_json::to_vec_pretty(&proof).unwrap())
        .unwrap();
}
