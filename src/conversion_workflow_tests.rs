//! Development-authored finite PostgreSQL/HTTP regression exercise. This does not
//! claim a stock executable, TCP browser, or process-kill/restart verification.
use super::*;
use axum::{
    body::{Body, to_bytes},
    http::{HeaderMap, Request},
};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
use tower::ServiceExt;

struct Client {
    app: Router,
    session: String,
    evidence: PathBuf,
    sequence: AtomicUsize,
}
impl Client {
    async fn request(
        &self,
        method: &str,
        route: &str,
        content_type: &str,
        data: Vec<u8>,
    ) -> (u16, HeaderMap, Vec<u8>) {
        let sequence = self.sequence.fetch_add(1, Ordering::SeqCst);
        let started = chrono::Utc::now();
        let request = Request::builder()
            .method(method)
            .uri(route)
            .header("host", "127.0.0.1:3133")
            .header("origin", "http://127.0.0.1:3133")
            .header("cookie", format!("pi_session={}", self.session))
            .header("content-type", content_type)
            .body(Body::from(data))
            .unwrap();
        let (status, headers, bytes) = tokio::time::timeout(Duration::from_secs(15), async {
            let response = self.app.clone().oneshot(request).await.unwrap();
            let status = response.status().as_u16();
            let headers = response.headers().clone();
            let bytes = to_bytes(response.into_body(), 25 * 1024 * 1024)
                .await
                .unwrap()
                .to_vec();
            (status, headers, bytes)
        })
        .await
        .expect("finite HTTP/SSE deadline");
        std::fs::write(self.evidence.join(format!("{sequence:03}.body")), &bytes).unwrap();
        std::fs::write(self.evidence.join(format!("{sequence:03}.json")),serde_json::to_vec_pretty(&json!({
            "method":method,"route":route,"started":started,"finished":chrono::Utc::now(),"status":status,
            "bytes":bytes.len(),"sha256":crate::conversion::sha(&bytes),
            "content_type":headers.get("content-type").and_then(|h|h.to_str().ok()),
            "content_disposition":headers.get("content-disposition").and_then(|h|h.to_str().ok())
        })).unwrap()).unwrap();
        (status, headers, bytes)
    }
    async fn get(&self, route: &str) -> (u16, HeaderMap, Vec<u8>) {
        self.request("GET", route, "application/octet-stream", vec![])
            .await
    }
    async fn post(&self, route: &str) -> (u16, HeaderMap, Vec<u8>) {
        self.request("POST", route, "application/x-www-form-urlencoded", vec![])
            .await
    }
    async fn upload(
        &self,
        from: &str,
        to: &str,
        input: &[u8],
        allow: bool,
    ) -> (u16, HeaderMap, Vec<u8>) {
        let mut body=format!("--s21-boundary\r\nContent-Disposition: form-data; name=\"from\"\r\n\r\n{from}\r\n--s21-boundary\r\nContent-Disposition: form-data; name=\"to\"\r\n\r\n{to}\r\n").into_bytes();
        if allow {
            body.extend_from_slice(b"--s21-boundary\r\nContent-Disposition: form-data; name=\"allow_loss\"\r\n\r\non\r\n");
        }
        body.extend_from_slice(b"--s21-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"manual-source\"\r\nContent-Type: application/octet-stream\r\n\r\n");
        body.extend_from_slice(input);
        body.extend_from_slice(b"\r\n--s21-boundary--\r\n");
        self.request(
            "POST",
            "/conversions",
            "multipart/form-data; boundary=s21-boundary",
            body,
        )
        .await
    }
    async fn terminal(&self, id: &str) -> ConversionMeta {
        tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                let (status, _, bytes) = self.get(&format!("/conversions/jobs/{id}")).await;
                assert_eq!(status, 200);
                let m: ConversionMeta = serde_json::from_slice(&bytes).unwrap();
                if m.snapshot.is_terminal() {
                    return m;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("terminal task deadline")
    }
}
fn last_id(state: &AppState) -> String {
    state
        .repository
        .lock()
        .unwrap()
        .conversions
        .values()
        .max_by_key(|m| {
            m.snapshot
                .id
                .strip_prefix("job-")
                .unwrap()
                .parse::<u64>()
                .unwrap()
        })
        .unwrap()
        .snapshot
        .id
        .clone()
}
async fn idle(state: &AppState) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while state.conversion_jobs.shared_slots().available_permits() != 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("actual worker leases released");
}
fn manual(file: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("fixtures/conversions")
            .join(file),
    )
    .unwrap()
}

#[test]
#[ignore = "fresh owned pi_s21_workflow DB; S21_WORKFLOW_DATABASE_URL and empty S21_WORKFLOW_EVIDENCE"]
fn durable_conversion_http_queue_artifacts_permissions_and_fences() {
    let url = std::env::var("S21_WORKFLOW_DATABASE_URL")
        .expect("owned PostgreSQL URL required; never print");
    assert!(
        url.contains("pi_s21_workflow"),
        "fresh dedicated database required"
    );
    let evidence = PathBuf::from(std::env::var("S21_WORKFLOW_EVIDENCE").unwrap());
    assert!(evidence.is_dir() && std::fs::read_dir(&evidence).unwrap().next().is_none());
    let root = AppState::open(3133, url).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(
        platform.auth.needs_setup(),
        "never reuse populated account DB"
    );
    let session = platform
        .auth
        .setup("s21_workflow_owner", "S21WorkflowOwnerPassword123")
        .unwrap();
    let actor = platform.auth.actor(&session).unwrap();
    let project = actor.project_id.clone();
    let mut scoped = platform.scope(&root, actor.clone()).unwrap();
    scoped.session = Some(session.clone());
    let client = Client {
        app: crate::web::router(root.clone()),
        session: session.clone(),
        evidence: evidence.clone(),
        sequence: AtomicUsize::new(0),
    };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(3)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        // Refuse unrepresentable JSONB input before job admission or SQL write.
        let nul=client.upload("csv","xes",b"case,activity,timestamp,lifecycle\nonly,A\0,,\n",false).await;
        assert_eq!(nul.0,422);assert!(String::from_utf8(nul.2).unwrap().contains("nul_forbidden"));
        assert!(scoped.repository.lock().unwrap().conversions.is_empty());assert_eq!(client.get("/health").await.0,200);
        // Admission classifier check, not a claim about physical network backpressure.
        let payload_a=platform.payload_slots.clone().try_acquire_owned().unwrap();
        let payload_b=platform.payload_slots.clone().try_acquire_owned().unwrap();
        assert_eq!(client.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,503);
        drop(payload_a);drop(payload_b);assert!(scoped.repository.lock().unwrap().conversions.is_empty());
        // A real CPU permit is the scheduling barrier. Cancel does not release the
        // actual pending worker lease; the third accepted task must still refuse.
        let gate=root.cpu.clone().acquire_owned().await.unwrap();
        let mut body=b"--legacy-s21\r\nContent-Disposition: form-data; name=\"file\"; filename=\"manual.xes\"\r\nContent-Type: application/xml\r\n\r\n".to_vec();
        body.extend_from_slice(include_bytes!("../fixtures/manual.xes"));body.extend_from_slice(b"\r\n--legacy-s21--\r\n");
        let legacy=client.request("POST","/jobs","multipart/form-data; boundary=legacy-s21",body).await;
        assert_eq!(legacy.0,202);let legacy_id=scoped.jobs.current().unwrap().snapshot().id;
        assert_eq!(client.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,303);
        let cancelled_id=last_id(&scoped);
        assert_eq!(client.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,429);
        assert_eq!(client.post(&format!("/conversions/jobs/{cancelled_id}/cancel")).await.0,303);
        assert_eq!(client.terminal(&cancelled_id).await.snapshot.state,JobState::Cancelled);
        assert_eq!(client.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,429);
        assert_eq!(client.get(&format!("/conversions/jobs/{cancelled_id}/payload")).await.0,404);
        assert_eq!(client.get(&format!("/conversions/jobs/{cancelled_id}/report")).await.0,404);
        let sse=client.get(&format!("/conversions/jobs/{cancelled_id}/events")).await;
        assert_eq!(sse.0,200);let sse=String::from_utf8(sse.2).unwrap();assert!(sse.contains("datastar-patch-elements")&&sse.contains("Отменено"));
        drop(gate);
        tokio::time::timeout(Duration::from_secs(15),async{loop{
            let (_,_,bytes)=client.get(&format!("/jobs/{legacy_id}")).await;let job:JobSnapshot=serde_json::from_slice(&bytes).unwrap();
            if job.is_terminal(){assert_eq!(job.state,JobState::Completed);break;}tokio::time::sleep(Duration::from_millis(10)).await;
        }}).await.unwrap();idle(&scoped).await;
        let mut completed=Vec::new();
        for (from,to,file) in [("xes","csv","flat-unicode.xes"),("csv","xes","flat-unicode.csv"),("petri-json","pnml","weighted-cycle.json"),("pnml","petri-json","weighted-cycle.pnml")] {
            assert_eq!(client.upload(from,to,&manual(file),false).await.0,303);
            let id=last_id(&scoped);let m=client.terminal(&id).await;
            assert_eq!(m.snapshot.state,JobState::Completed,"{from}->{to}: {:?}",m.snapshot.error);
            let payload=client.get(&format!("/conversions/jobs/{id}/payload")).await;
            let report=client.get(&format!("/conversions/jobs/{id}/report")).await;
            assert_eq!((payload.0,report.0),(200,200));
            assert!(payload.1["content-disposition"].to_str().unwrap().starts_with("attachment; filename=\"payload."));
            assert_eq!(payload.1["x-content-type-options"],"nosniff");
            let report:Value=serde_json::from_slice(&report.2).unwrap();
            assert_eq!(report["status"],"converted");assert_eq!(report["target_sha256"],crate::conversion::sha(&payload.2));
            assert_eq!(Some(crate::conversion::sha(&payload.2)),m.payload_sha256);
            // Reload the durable metadata and lazy resource from PostgreSQL. This
            // is storage reload, deliberately not labelled a process restart.
            let reload=crate::repository_v2::load_metadata(&platform.database,&project).unwrap();
            let stored=&reload.conversions[&id];let a=load_artifact(&platform.database,&project,stored).unwrap();
            assert_eq!(a.payload.as_ref().unwrap().as_bytes(),payload.2);
            assert_eq!(crate::conversion::sha(a.report.as_ref().unwrap().as_bytes()),m.report_sha256.clone().unwrap());
            let terminal=client.get(&format!("/conversions/jobs/{id}/events")).await;assert_eq!(terminal.0,200);assert!(String::from_utf8(terminal.2).unwrap().contains("Готово"));
            completed.push(id);idle(&scoped).await;
        }
        // A refusal still retains its useful, truthful report, without a payload.
        assert_eq!(client.upload("xes","csv",&manual("rich.xes"),false).await.0,303);
        let refused=last_id(&scoped);assert_eq!(client.terminal(&refused).await.snapshot.state,JobState::Failed);
        assert_eq!(client.get(&format!("/conversions/jobs/{refused}/payload")).await.0,404);
        let report=client.get(&format!("/conversions/jobs/{refused}/report")).await;assert_eq!(report.0,200);
        assert_eq!(serde_json::from_slice::<Value>(&report.2).unwrap()["status"],"loss_refused");idle(&scoped).await;
        // Retry creates a distinct retained attempt and preserves the original.
        assert_eq!(client.post(&format!("/conversions/jobs/{cancelled_id}/retry")).await.0,303);
        let retried=last_id(&scoped);assert_ne!(retried,cancelled_id);let m=client.terminal(&retried).await;
        assert_eq!(m.retry_of.as_deref(),Some(cancelled_id.as_str()));assert_eq!(m.snapshot.state,JobState::Completed);idle(&scoped).await;
        assert_eq!(client.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,303);
        let eighth=last_id(&scoped);assert_eq!(client.terminal(&eighth).await.snapshot.state,JobState::Completed);idle(&scoped).await;
        assert_eq!(scoped.repository.lock().unwrap().conversions.len(),8);
        // The newest admitted attempt stays first even after IDs cross 9/10.
        let page=client.get("/conversions").await;assert_eq!(page.0,200);
        let page=String::from_utf8(page.2).unwrap();
        let latest=page.find(&format!("id=\"conversion-{eighth}\"")).unwrap();
        for earlier in &completed {assert!(latest<page.find(&format!("id=\"conversion-{earlier}\"")).unwrap());}
        assert!(page.contains("aria-label=\"Из\"")&&page.contains("aria-label=\"В\""));
        let denied=client.upload("csv","xes",&manual("flat-unicode.csv"),false).await;assert_eq!(denied.0,422);assert!(String::from_utf8(denied.2).unwrap().contains("conversion_capacity"));
        assert_eq!(client.get(&format!("/conversions/jobs/{}/payload",completed[0])).await.0,200,"no automatic pruning");
        assert_eq!(client.post(&format!("/conversions/jobs/{refused}/delete")).await.0,303);
        assert_eq!(client.get(&format!("/conversions/jobs/{refused}/report")).await.0,404);
        assert_eq!(scoped.repository.lock().unwrap().conversions.len(),7);
        // Current permissions apply to UI, POST and downloads; expired login
        // cannot recover a payload by retaining its previous URL.
        platform.auth.add_user(&actor,&session,"s21_workflow_viewer","S21WorkflowViewerPassword123").unwrap();
        platform.auth.grant(&actor,&session,&project,"s21_workflow_viewer",crate::auth::Role::Viewer).unwrap();
        let viewer_session=platform.auth.login("s21_workflow_viewer","S21WorkflowViewerPassword123").unwrap();platform.auth.switch(&viewer_session,&project).unwrap();
        let viewer_dir=evidence.join("viewer");std::fs::create_dir(&viewer_dir).unwrap();
        let viewer=Client{app:client.app.clone(),session:viewer_session.clone(),evidence:viewer_dir,sequence:AtomicUsize::new(0)};
        let page=viewer.get("/conversions").await;assert_eq!(page.0,200);assert!(!String::from_utf8(page.2).unwrap().contains("Запустить преобразование"));
        assert_eq!(viewer.upload("csv","xes",&manual("flat-unicode.csv"),false).await.0,403);
        assert_eq!(viewer.post(&format!("/conversions/jobs/{}/delete",completed[0])).await.0,403);
        assert_eq!(viewer.get(&format!("/conversions/jobs/{}/payload",completed[0])).await.0,200);
        platform.auth.logout(&viewer_session).unwrap();assert_ne!(viewer.get(&format!("/conversions/jobs/{}/payload",completed[0])).await.0,200);
        // Free space for the two controlled publication-fence tasks below.
        for id in [&cancelled_id,&eighth] {assert_eq!(client.post(&format!("/conversions/jobs/{id}/delete")).await.0,303);}
        idle(&scoped).await;
        // A valid bounded conversion whose report exceeds its separate 4MiB
        // ceiling must terminate Failed without advertising a missing pair.
        let mut large=String::from("case,activity,timestamp,lifecycle\r\n");
        let activity="q".repeat(256);
        for _ in 0..10000 {large.push_str(&format!("only,{activity},,\r\n"));}
        let converted=crate::conversion::convert("csv","xes",large.as_bytes(),false);
        assert!(converted.is_ok(),"report-limit fixture must be a valid conversion");
        assert_eq!(crate::conversion::report_bytes("csv","xes",large.as_bytes(),false,&converted).unwrap_err().reason,"report_byte_limit");
        assert_eq!(client.upload("csv","xes",large.as_bytes(),false).await.0,303);
        let report_limited=last_id(&scoped);let limited=client.terminal(&report_limited).await;
        assert_eq!(limited.snapshot.state,JobState::Failed);assert_eq!(limited.snapshot.error.as_ref().unwrap().code,"report_byte_limit");
        assert!(limited.payload_sha256.is_none()&&limited.report_sha256.is_none());
        let a=load_artifact(&platform.database,&project,&limited).unwrap();assert_eq!(a.input.as_bytes(),large.as_bytes());
        idle(&scoped).await;
    });
    publication_fences(&scoped);
    std::fs::write(evidence.join("result.json"),serde_json::to_vec_pretty(&json!({"status":"passed","scope":"development in-process HTTP + actual PostgreSQL; no TCP/browser/process-kill claim","http_requests":client.sequence.load(Ordering::SeqCst),"project":project})).unwrap()).unwrap();
}

fn publication_fences(state: &AppState) {
    use std::sync::{atomic::AtomicBool, mpsc};
    let input: Arc<str> = Arc::from(String::from_utf8(manual("flat-unicode.csv")).unwrap());
    let (lease, m) = accept(
        state,
        "csv".into(),
        "xes".into(),
        input.clone(),
        "fence.csv".into(),
        false,
        None,
    )
    .unwrap();
    assert!(lease.job.start("converting"));
    persist(state, &lease.job.snapshot(), None).unwrap();
    let output = crate::conversion::convert("csv", "xes", input.as_bytes(), false);
    let report = String::from_utf8(
        crate::conversion::report_bytes("csv", "xes", input.as_bytes(), false, &output).unwrap(),
    )
    .unwrap();
    let payload = String::from_utf8(output.unwrap().payload).unwrap();
    let job = lease.job.clone();
    let committing = state.clone();
    let failure = state.clone();
    let artifact_id = m.artifact_id.clone();
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let completion = std::thread::spawn(move || {
        let result = job.try_complete_durable_with(
            |before| {
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let mut done = before.clone();
                done.state = JobState::Completed;
                done.stage = "completed".into();
                done.result_id = Some(artifact_id.clone());
                done.job_revision += 1;
                persist(&committing, &done, Some((Some(payload), report)))?;
                Ok(artifact_id)
            },
            |s| persist(&failure, s, None),
        );
        done_tx.send(result).unwrap();
    });
    entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let cancel_job = lease.job.clone();
    let cancelling = state.clone();
    let (cancel_started_tx, cancel_started_rx) = mpsc::sync_channel(1);
    let (cancel_tx, cancel_rx) = mpsc::sync_channel(1);
    let cancellation = std::thread::spawn(move || {
        cancel_started_tx.send(()).unwrap();
        cancel_tx
            .send(cancel_job.try_cancel_with(|s| persist(&cancelling, s, None)))
            .unwrap();
    });
    cancel_started_rx
        .recv_timeout(Duration::from_secs(5))
        .unwrap();
    // The completion callback demonstrably owns the actual job mutex here. Its
    // channel gate, not a timing sleep, orders publication before cancellation.
    assert!(matches!(
        cancel_rx.try_recv(),
        Err(mpsc::TryRecvError::Empty)
    ));
    release_tx.send(()).unwrap();
    assert_eq!(
        done_rx
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .unwrap()
            .state,
        JobState::Completed
    );
    assert_eq!(
        cancel_rx
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .unwrap()
            .state,
        JobState::Completed
    );
    completion.join().unwrap();
    cancellation.join().unwrap();
    let stored = crate::repository_v2::load_metadata(
        &state.platform.as_ref().unwrap().database,
        &state.actor.as_ref().unwrap().project_id,
    )
    .unwrap();
    assert_eq!(
        stored.conversions[&m.snapshot.id].snapshot.state,
        JobState::Completed
    );
    drop(lease);
    let (lease, m) = accept(
        state,
        "csv".into(),
        "xes".into(),
        input,
        "cancel-wins.csv".into(),
        false,
        None,
    )
    .unwrap();
    lease
        .job
        .try_cancel_with(|s| persist(state, s, None))
        .unwrap();
    let invoked = AtomicBool::new(false);
    let final_state = lease
        .job
        .try_complete_durable_with(
            |_| {
                invoked.store(true, Ordering::SeqCst);
                panic!("cancelled job must never enter publication")
            },
            |s| persist(state, s, None),
        )
        .unwrap();
    assert!(!invoked.load(Ordering::SeqCst));
    assert_eq!(final_state.state, JobState::Cancelled);
    let repo = state.repository.lock().unwrap();
    let a = artifact(state, &repo, &repo.conversions[&m.snapshot.id]).unwrap();
    assert!(a.payload.is_none() && a.report.is_none());
}
