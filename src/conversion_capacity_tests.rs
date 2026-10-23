//! Controlled HTTP/body/lease regressions with real PostgreSQL, not a load benchmark.
use super::*;
use axum::body::{Body, Bytes, to_bytes};
use http_body::{Body as HttpBody, Frame, SizeHint};
use serde_json::{Value, json};
use std::sync::atomic::AtomicUsize;
use std::{
    collections::VecDeque,
    pin::Pin,
    task::{Context, Poll},
    time::{Duration, Instant},
};
use tower::ServiceExt;

struct ProbeBody {
    polls: Arc<AtomicUsize>,
    dropped: Arc<AtomicBool>,
    bytes: Arc<AtomicUsize>,
    frames: VecDeque<Bytes>,
    pending: bool,
}
impl HttpBody for ProbeBody {
    type Data = Bytes;
    type Error = Infallible;
    fn poll_frame(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        self.polls.fetch_add(1, Ordering::SeqCst);
        match self.frames.pop_front() {
            Some(data) => {
                self.bytes.fetch_add(data.len(), Ordering::SeqCst);
                Poll::Ready(Some(Ok(Frame::data(data))))
            }
            None if self.pending => Poll::Pending,
            None => Poll::Ready(None),
        }
    }
    fn size_hint(&self) -> SizeHint {
        SizeHint::default()
    }
}
impl Drop for ProbeBody {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
    }
}
fn probe(first: Option<Vec<u8>>, pending: bool) -> (Body, Arc<AtomicUsize>, Arc<AtomicBool>) {
    let polls = Arc::new(AtomicUsize::new(0));
    let dropped = Arc::new(AtomicBool::new(false));
    let frames = first.into_iter().map(Bytes::from).collect();
    (
        Body::new(ProbeBody {
            polls: polls.clone(),
            dropped: dropped.clone(),
            bytes: Arc::new(AtomicUsize::new(0)),
            frames,
            pending,
        }),
        polls,
        dropped,
    )
}
fn request(
    session: &str,
    route: &str,
    content_type: &str,
    length: Option<usize>,
    body: Body,
) -> Request {
    let mut builder = axum::http::Request::builder()
        .method("POST")
        .uri(route)
        .header("host", "127.0.0.1:3136")
        .header("origin", "http://127.0.0.1:3136")
        .header("cookie", format!("pi_session={session}"))
        .header("content-type", content_type);
    if let Some(n) = length {
        builder = builder.header(header::CONTENT_LENGTH, n);
    }
    builder.body(body).unwrap()
}
async fn call(app: &Router, request: Request) -> (u16, Vec<u8>) {
    tokio::time::timeout(Duration::from_millis(3000), async {
        let response = app.clone().oneshot(request).await.unwrap();
        let status = response.status().as_u16();
        (
            status,
            to_bytes(response.into_body(), 25 * 1024 * 1024)
                .await
                .unwrap()
                .to_vec(),
        )
    })
    .await
    .expect("prospective finite response bound, not a production SLO")
}
fn multipart(input: &[u8]) -> Vec<u8> {
    let mut body = b"--cap\r\nContent-Disposition: form-data; name=\"from\"\r\n\r\ncsv\r\n--cap\r\nContent-Disposition: form-data; name=\"to\"\r\n\r\nxes\r\n--cap\r\nContent-Disposition: form-data; name=\"file\"; filename=\"control.csv\"\r\n\r\n".to_vec();
    body.extend_from_slice(input);
    body.extend_from_slice(b"\r\n--cap--\r\n");
    body
}
fn upload_request(session: &str) -> Request {
    let body = multipart(include_bytes!("../fixtures/conversions/flat-unicode.csv"));
    request(
        session,
        "/conversions",
        "multipart/form-data; boundary=cap",
        Some(body.len()),
        Body::from(body),
    )
}
fn header_value(state: &AppState) -> Value {
    crate::repository_v2::header(&state.repository.lock().unwrap())
        .value()
        .unwrap()
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
async fn idle(state: &AppState) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while state.conversion_jobs.shared_slots().available_permits() != 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("actual worker exit releases permits");
}
async fn completed(state: &AppState, id: &str) {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let m = state.repository.lock().unwrap().conversions[id].clone();
            if m.snapshot.is_terminal() {
                assert_eq!(
                    m.snapshot.state,
                    JobState::Completed,
                    "{:?}",
                    m.snapshot.error
                );
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    idle(state).await;
}

fn observe(dir: &std::path::Path, observations: &mut Vec<Value>, value: Value) {
    observations.push(value);
    let path = dir.join(format!("checkpoint-{:02}.json", observations.len()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .unwrap();
    std::io::Write::write_all(
        &mut file,
        &serde_json::to_vec_pretty(
            &json!({"status":"PARTIAL_ASSERTED_CONTROLS_ONLY","observations":observations}),
        )
        .unwrap(),
    )
    .unwrap();
}
#[test]
#[ignore = "fresh owned pi_s21_capacity DB and S21_CAPACITY_DATABASE_URL/S21_CAPACITY_EVIDENCE"]
fn prebody_reservations_disconnect_handoff_and_retention_races() {
    let url = std::env::var("S21_CAPACITY_DATABASE_URL").unwrap();
    assert!(url.ends_with("/pi_s21_capacity"));
    let dir = std::path::PathBuf::from(std::env::var("S21_CAPACITY_EVIDENCE").unwrap());
    assert!(dir.is_dir() && std::fs::read_dir(&dir).unwrap().next().is_none());
    let root = AppState::open(3136, url.clone()).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(platform.auth.needs_setup());
    let session = platform
        .auth
        .setup("s21_capacity_owner", "CapacityFixturePassword123")
        .unwrap();
    let actor = platform.auth.actor(&session).unwrap();
    platform
        .auth
        .add_user(
            &actor,
            &session,
            "s21_capacity_viewer",
            "CapacityFixturePassword123",
        )
        .unwrap();
    platform
        .auth
        .grant(
            &actor,
            &session,
            &actor.project_id,
            "s21_capacity_viewer",
            crate::auth::Role::Viewer,
        )
        .unwrap();
    let viewer_session = platform
        .auth
        .login("s21_capacity_viewer", "CapacityFixturePassword123")
        .unwrap();
    platform
        .auth
        .switch(&viewer_session, &actor.project_id)
        .unwrap();
    let mut state = platform.scope(&root, actor.clone()).unwrap();
    state.session = Some(session.clone());
    let app = crate::web::router(root.clone());
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(3)
        .enable_all()
        .build()
        .unwrap();
    let mut observations = Vec::new();
    runtime.block_on(async {
        assert_eq!(call(&app, upload_request(&session)).await.0, 303);
        let seed = newest(&state); completed(&state, &seed).await;
        let (body, polls, _) = probe(None, true);
        assert_eq!(call(&app, request(&viewer_session, "/conversions", "multipart/form-data; boundary=cap", None, body)).await.0, 403);
        assert_eq!(polls.load(Ordering::SeqCst), 0); idle(&state).await;
        state.repository.lock().unwrap().conversion_artifacts.clear();
        let legacy = state.jobs.create().unwrap();
        let reserved = state.conversion_jobs.reserve().unwrap();
        let before = header_value(&state);
        let current = state.conversion_jobs.current().unwrap().snapshot();
        let fetches = HEAVY_FETCHES.load(Ordering::SeqCst);
        let (body, polls, dropped) = probe(None, true);
        let started = Instant::now();
        let (status, _) = call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", Some(18 * 1024 * 1024), body)).await;
        assert_eq!(status, 429); assert_eq!(polls.load(Ordering::SeqCst), 0); assert!(dropped.load(Ordering::SeqCst));
        observe(&dir, &mut observations, json!({"case":"occupied_upload","status":status,"body_polls":0,"elapsed_ms":started.elapsed().as_millis()}));
        assert_eq!(call(&app, request(&session, &format!("/conversions/jobs/{seed}/retry"), "application/x-www-form-urlencoded", Some(0), Body::empty())).await.0, 429);
        assert_eq!(HEAVY_FETCHES.load(Ordering::SeqCst), fetches);
        assert_eq!(header_value(&state), before);

        assert_eq!(state.conversion_jobs.current().unwrap().snapshot().id, current.id);
        drop(reserved); drop(legacy); idle(&state).await;

        let (body, polls, _) = probe(None, true);
        let limit = crate::event_io::Limits::default().max_bytes + 64 * 1024;
        assert_eq!(call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", Some(limit + 1), body)).await.0, 413);
        assert_eq!(polls.load(Ordering::SeqCst), 0); idle(&state).await;
        assert_eq!(call(&app, request(&session, "/conversions", "application/octet-stream", Some(0), Body::empty())).await.0, 422); idle(&state).await;
        for bad in [vec![255, 254], b"case,activity,timestamp,lifecycle\r\nonly,A\0,,\r\n".to_vec()] {
            let bytes = multipart(&bad);
            assert_eq!(call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", Some(bytes.len()), Body::from(bytes))).await.0, 422); idle(&state).await;
        }
        assert_eq!(header_value(&state), before);

        // Unknown-length body crosses the standard form cap in bounded frames.
        // The one frame that trips Limited is counted, not silently discarded.
        let bytes = Arc::new(AtomicUsize::new(0));
        let polls = Arc::new(AtomicUsize::new(0));
        let mut frames = VecDeque::new();
        frames.push_back(Bytes::from_static(b"--cap\r\nContent-Disposition: form-data; name=\"file\"; filename=\"oversized.csv\"\r\n\r\n"));
        for _ in 0..(limit / 65536 + 2) { frames.push_back(Bytes::from(vec![b' '; 65536])); }
        let body = Body::new(ProbeBody {polls:polls.clone(),dropped:Arc::new(AtomicBool::new(false)),bytes:bytes.clone(),frames,pending:false});
        assert_eq!(call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", None, body)).await.0, 413);
        assert!(bytes.load(Ordering::SeqCst) > limit && bytes.load(Ordering::SeqCst) <= limit + 65536);
        assert_eq!(header_value(&state), before); idle(&state).await;
        observe(&dir, &mut observations, json!({"case":"unknown_length_stream_cap","consumed_frame_bytes":bytes.load(Ordering::SeqCst),"form_limit":limit,"maximum_overrun_frame_bytes":65536,"body_polls":polls.load(Ordering::SeqCst)}));

        let partial = b"--cap\r\nContent-Disposition: form-data; name=\"file\"; filename=\"partial.csv\"\r\n\r\ncase,acti".to_vec();
        let (body, polls, dropped) = probe(Some(partial), true);
        let pending = runtime.spawn(app.clone().oneshot(request(&session, "/conversions", "multipart/form-data; boundary=cap", Some(1024), body)));
        tokio::time::timeout(Duration::from_secs(3), async {
            while polls.load(Ordering::SeqCst) < 2 || state.conversion_jobs.shared_slots().available_permits() != 1 { tokio::task::yield_now().await; }
        }).await.unwrap();
        pending.abort(); assert!(pending.await.unwrap_err().is_cancelled());
        idle(&state).await; assert!(dropped.load(Ordering::SeqCst)); assert_eq!(header_value(&state), before);
        assert_eq!(call(&app, upload_request(&session)).await.0, 303); completed(&state, &newest(&state)).await;
        observe(&dir, &mut observations, json!({"case":"partial_body_disconnect","body_polls":polls.load(Ordering::SeqCst),"permits_restored":2,"no_durable_header_change":true}));
    });

    // Persisted identifier exhaustion must refuse without changing the header or
    // consuming the reserved slot, including the MAX-1 two-ID boundary.
    let original_sequence = state.repository.lock().unwrap().sequence;
    for exhausted in [u64::MAX - 1, u64::MAX] {
        state.repository.lock().unwrap().sequence = exhausted;
        let before = header_value(&state);
        let reservation = reserve_conversion(&state).unwrap();
        let refused = accept_reserved(
            &state,
            reservation,
            Submission {
                from: "csv".into(),
                to: "xes".into(),
                input: Arc::from(
                    std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv"))
                        .unwrap(),
                ),
                filename: "exhausted.csv".into(),
                allow_loss: false,
                report_profile: None,
                retry_of: None,
            },
        );
        assert_eq!(refused.err().unwrap().code, "sequence_exhausted");
        assert_eq!(header_value(&state), before);
        assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 2);
    }
    state.repository.lock().unwrap().sequence = original_sequence;
    let before_store_exhaustion = header_value(&state);
    let mut exhausted_state = state.clone();
    exhausted_state.conversion_jobs = Arc::new(crate::jobs::JobStore::restore_with_slots(
        &[JobSnapshot {
            id: format!("job-{}", u64::MAX),
            state: JobState::Cancelled,
            stage: "cancelled".into(),
            job_revision: 1,
            cancel_requested: true,
            result_id: None,
            error: None,
        }],
        state.conversion_jobs.shared_slots(),
    ));
    let exhausted_reservation = reserve_conversion(&exhausted_state).unwrap();
    let refused = accept_reserved(
        &exhausted_state,
        exhausted_reservation,
        Submission {
            from: "csv".into(),
            to: "xes".into(),
            input: Arc::from(
                std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv"))
                    .unwrap(),
            ),
            filename: "restored-max.csv".into(),
            allow_loss: false,
            report_profile: None,
            retry_of: None,
        },
    )
    .err()
    .unwrap();
    assert_eq!(refused.code, "sequence_exhausted");
    assert_eq!(
        response_error(refused).status(),
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(header_value(&state), before_store_exhaustion);
    assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 2);
    let foreign = crate::jobs::JobStore::new().reserve().unwrap();
    let refused = accept_reserved(
        &state,
        foreign,
        Submission {
            from: "csv".into(),
            to: "xes".into(),
            input: Arc::from(
                std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv"))
                    .unwrap(),
            ),
            filename: "foreign-pool.csv".into(),
            allow_loss: false,
            report_profile: None,
            retry_of: None,
        },
    )
    .err()
    .unwrap();
    assert_eq!(refused.code, "job_reservation_pool");
    assert_eq!(
        response_error(refused).status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
    assert_eq!(header_value(&state), before_store_exhaustion);
    assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 2);
    observe(
        &dir,
        &mut observations,
        json!({"case":"restored_job_id_exhaustion_and_foreign_reservation","actual_admission_error_codes":["sequence_exhausted","job_reservation_pool"],"http_statuses":[422,500],"header_unchanged":true,"permits_restored":2,"global_postgres_sequence_gap_is_not_a_header_mutation":true}),
    );
    observe(
        &dir,
        &mut observations,
        json!({"case":"identifier_sequence_exhaustion","max_and_max_minus_one_refused":true,"header_unchanged":true,"permits_restored":2}),
    );
    platform
        .auth
        .grant(
            &actor,
            &session,
            &actor.project_id,
            "s21_capacity_viewer",
            crate::auth::Role::Editor,
        )
        .unwrap();
    let mut editor = platform
        .scope(&root, platform.auth.actor(&viewer_session).unwrap())
        .unwrap();
    editor.session = Some(viewer_session.clone());
    let reservation = reserve_conversion(&editor).unwrap();
    platform
        .auth
        .grant(
            &actor,
            &session,
            &actor.project_id,
            "s21_capacity_viewer",
            crate::auth::Role::Viewer,
        )
        .unwrap();
    let before_revocation = header_value(&state);
    let denied = accept_reserved(
        &editor,
        reservation,
        Submission {
            from: "csv".into(),
            to: "xes".into(),
            input: Arc::from(
                std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv"))
                    .unwrap(),
            ),
            filename: "revoked.csv".into(),
            allow_loss: false,
            report_profile: None,
            retry_of: None,
        },
    );
    assert_eq!(denied.err().unwrap().code, "access_denied");
    assert_eq!(header_value(&state), before_revocation);
    assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 2);
    observe(
        &dir,
        &mut observations,
        json!({"case":"rights_revoked_after_reservation","durable_header_unchanged":true,"permits_restored":2}),
    );

    // Synchronous PostgreSQL clients stay OUTSIDE Tokio::block_on. The application
    // request continues on the multi-thread runtime while its response waiter dies.
    let mut direct = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    let mut holder = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    direct.batch_execute("SET statement_timeout=5000; SET lock_timeout=2000; CREATE FUNCTION public.s21_capacity_accept_barrier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.kind='conversion' AND NEW.document->>'payload' IS NULL THEN PERFORM pg_advisory_xact_lock(21321002::bigint); END IF; RETURN NEW; END $$; CREATE TRIGGER s21_capacity_accept_barrier BEFORE INSERT OR UPDATE ON public.pi_records FOR EACH ROW EXECUTE FUNCTION public.s21_capacity_accept_barrier();").unwrap();
    holder
        .batch_execute("SELECT pg_advisory_lock(21321002::bigint)")
        .unwrap();
    let pending = runtime.spawn(app.clone().oneshot(upload_request(&session)));
    let until = Instant::now() + Duration::from_millis(1400);
    loop {
        let waiting: bool = direct.query_one("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=21321002 AND NOT granted)", &[]).unwrap().get(0);
        if waiting {
            break;
        }
        assert!(
            Instant::now() < until,
            "actual application accept must reach PostgreSQL barrier"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    let observed = Instant::now();
    pending.abort();
    runtime.block_on(async {
        assert!(pending.await.unwrap_err().is_cancelled());
    });
    holder
        .batch_execute("SELECT pg_advisory_unlock(21321002::bigint)")
        .unwrap();
    assert!(observed.elapsed() < Duration::from_millis(1500));
    direct.batch_execute("DROP TRIGGER s21_capacity_accept_barrier ON public.pi_records; DROP FUNCTION public.s21_capacity_accept_barrier()").unwrap();
    runtime.block_on(async {
        tokio::time::timeout(Duration::from_secs(10), async {
            while state.repository.lock().unwrap().conversions.len() < 3 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        completed(&state, &newest(&state)).await;
    });
    observe(
        &dir,
        &mut observations,
        json!({"case":"response_disconnect_during_actual_pg_accept","ungranted_wait_observed":true,"request_waiter_cancelled":true,"worker_completed_without_http_waiter":true,"lock_timeout_ms_unchanged":2000}),
    );

    runtime.block_on(async {
        let cpu = root.cpu.clone().acquire_owned().await.unwrap();
        assert_eq!(call(&app, upload_request(&session)).await.0, 303);
        let id = newest(&state);
        let legacy = state.jobs.create().unwrap();
        assert_eq!(call(&app, request(&session, &format!("/conversions/jobs/{id}/cancel"), "application/x-www-form-urlencoded", Some(0), Body::empty())).await.0, 303);
        let (body, polls, _) = probe(None, true);
        assert_eq!(call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", None, body)).await.0, 429);
        assert_eq!(polls.load(Ordering::SeqCst), 0);
        assert_eq!(state.conversion_jobs.shared_slots().available_permits(), 0);
        drop(cpu);
        tokio::time::timeout(Duration::from_secs(5), async {
            while state.conversion_jobs.shared_slots().available_permits() != 1 { tokio::task::yield_now().await; }
        }).await.unwrap();
        let after_exit = state.jobs.create().unwrap(); drop(after_exit); drop(legacy); idle(&state).await;
        assert_eq!(state.repository.lock().unwrap().conversions[&id].snapshot.state, JobState::Cancelled);
        observe(&dir, &mut observations, json!({"case":"cancelled_worker_keeps_real_lease_until_cpu_barrier_exit","busy_body_polls":0,"after_exit_capacity_restored":true}));

        while state.repository.lock().unwrap().conversions.len() < 7 {
            assert_eq!(call(&app, upload_request(&session)).await.0, 303); completed(&state, &newest(&state)).await;
        }
        let preflight_seven = reserve_conversion(&state).unwrap();
        assert_eq!(call(&app, upload_request(&session)).await.0, 303);
        let eighth = newest(&state);
        tokio::time::timeout(Duration::from_secs(10), async {
            while !state.repository.lock().unwrap().conversions[&eighth].snapshot.is_terminal() { tokio::task::yield_now().await; }
        }).await.unwrap();
        let before_full = header_value(&state);
        let refused = accept_reserved(&state, preflight_seven, Submission {from:"csv".into(),to:"xes".into(),input:Arc::from(std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv")).unwrap()),filename:"raced.csv".into(),allow_loss: false, report_profile: None,retry_of:None});
        assert_eq!(refused.err().unwrap().code, "conversion_capacity"); idle(&state).await;
        assert_eq!(header_value(&state), before_full);
        state.repository.lock().unwrap().conversion_artifacts.clear();
        let fetches = HEAVY_FETCHES.load(Ordering::SeqCst);
        let (body, polls, _) = probe(None, true);
        assert_eq!(call(&app, request(&session, "/conversions", "multipart/form-data; boundary=cap", None, body)).await.0, 422);
        assert_eq!(polls.load(Ordering::SeqCst), 0);
        assert_eq!(call(&app, request(&session, &format!("/conversions/jobs/{eighth}/retry"), "application/x-www-form-urlencoded", Some(0), Body::empty())).await.0, 422);
        assert_eq!(HEAVY_FETCHES.load(Ordering::SeqCst), fetches); assert_eq!(header_value(&state), before_full); idle(&state).await;
        let html = app.clone().oneshot(axum::http::Request::builder().uri("/conversions").header("host","127.0.0.1:3136").header("cookie",format!("pi_session={session}")).body(Body::empty()).unwrap()).await.unwrap();
        let html = String::from_utf8(to_bytes(html.into_body(), 1024*1024).await.unwrap().to_vec()).unwrap();
        assert!(html.contains("до 4 MiB") && html.contains("Сохранены все восемь попыток") && html.contains("platform-form platform-card"));
        // Explicit disposable-fixture deletion; no silent pruning.
        assert_eq!(call(&app, request(&session, &format!("/conversions/jobs/{eighth}/delete"), "application/x-www-form-urlencoded", Some(0), Body::empty())).await.0, 303);
        let retained = state.repository.lock().unwrap().conversions.keys().next().unwrap().clone();
        assert_eq!(call(&app, request(&session, &format!("/conversions/jobs/{retained}/retry"), "application/x-www-form-urlencoded", Some(0), Body::empty())).await.0, 303); completed(&state, &newest(&state)).await;
        observe(&dir, &mut observations, json!({"case":"retention_seven_to_eight_race_and_full_preflight","busy_body_polls":0,"busy_heavy_fetches":0,"same_header_after_refusals":true,"explicit_delete_then_retry_completed":true}));
    });
    // Storage deliberately fails closed after a database error. Keep this LAST;
    // removing the trigger must not be mistaken for restarting its worker.
    runtime.block_on(async {
        let disposable = newest(&state);
        assert_eq!(
            call(
                &app,
                request(
                    &session,
                    &format!("/conversions/jobs/{disposable}/delete"),
                    "application/x-www-form-urlencoded",
                    Some(0),
                    Body::empty()
                )
            )
            .await
            .0,
            303
        );
    });
    assert_eq!(state.repository.lock().unwrap().conversions.len(), 7);
    direct.batch_execute("CREATE FUNCTION public.s21_capacity_reject_accept() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.kind='conversion' THEN RAISE EXCEPTION 'intentional capacity admission rollback'; END IF; RETURN NEW; END $$; CREATE TRIGGER s21_capacity_reject_accept BEFORE INSERT OR UPDATE ON public.pi_records FOR EACH ROW EXECUTE FUNCTION public.s21_capacity_reject_accept();").unwrap();
    let before = header_value(&state);
    let fault_outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime.block_on(async {
            assert_eq!(call(&app, upload_request(&session)).await.0, 503);
            idle(&state).await;
        });
        assert_eq!(header_value(&state), before);
        assert_eq!(
            platform.database.health().unwrap_err().code,
            "storage_unavailable"
        );
        runtime.block_on(async {
            let (body, polls, _) = probe(None, true);
            assert_eq!(
                call(
                    &app,
                    request(
                        &session,
                        "/conversions",
                        "multipart/form-data; boundary=cap",
                        None,
                        body
                    )
                )
                .await
                .0,
                503
            );
            assert_eq!(polls.load(Ordering::SeqCst), 0);
            idle(&state).await;
        });
        assert_eq!(header_value(&state), before);
    }));
    direct.batch_execute("DROP TRIGGER s21_capacity_reject_accept ON public.pi_records; DROP FUNCTION public.s21_capacity_reject_accept()").unwrap();
    if let Err(panic) = fault_outcome {
        std::panic::resume_unwind(panic);
    }
    observe(
        &dir,
        &mut observations,
        json!({"case":"actual_database_admission_refusal_and_fail_closed","retention_before_failure":7,"http_status":503,"header_unchanged":true,"permits_restored":2,"subsequent_body_polls":0,"storage_worker_requires_restart":true,"fixture_trigger_removed_even_on_assertion_failure":true}),
    );
    std::fs::write(dir.join("capacity-proof.json"), serde_json::to_vec_pretty(&json!({"status":"ACTUAL_PG_HTTP_BODY_LEASE_AND_HANDOFF_CONTROLS_PASS","scope":"controlled in-process HTTP and PostgreSQL; not a TCP memory/load benchmark","observations":observations,"permits_at_end":state.conversion_jobs.shared_slots().available_permits(),"schema_version":3})).unwrap()).unwrap();
}
