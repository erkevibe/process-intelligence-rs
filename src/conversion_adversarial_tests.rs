//! Development-authored adversarial PostgreSQL cases; no browser or process-kill claim.
use super::*;
use axum::{
    body::{Body, to_bytes},
    http::Request,
};
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::Duration,
};
use tower::ServiceExt;
const PASSWORD: &str = "S21AdversarialPassword123";
const LEASE: i64 = 5785256839849804116;
fn input() -> Arc<str> {
    Arc::from(
        std::str::from_utf8(include_bytes!("../fixtures/conversions/flat-unicode.csv")).unwrap(),
    )
}
fn scope(root: &AppState, session: &str) -> AppState {
    let p = root.platform.as_ref().unwrap();
    let mut s = p.scope(root, p.auth.actor(session).unwrap()).unwrap();
    s.session = Some(session.into());
    s
}
fn pair(input: &str) -> (String, String) {
    let result = crate::conversion::convert("csv", "xes", input.as_bytes(), false);
    let report = String::from_utf8(
        crate::conversion::report_bytes("csv", "xes", input.as_bytes(), false, &result).unwrap(),
    )
    .unwrap();
    (String::from_utf8(result.unwrap().payload).unwrap(), report)
}
fn admitted(state: &AppState) -> (crate::jobs::JobLease, ConversionMeta) {
    let (lease, m) = accept(
        state,
        "csv".into(),
        "xes".into(),
        input(),
        "manual.csv".into(),
        false,
        None,
    )
    .unwrap();
    assert!(lease.job.start("converting"));
    persist(state, &lease.job.snapshot(), None).unwrap();
    (lease, m)
}
fn publish(
    state: &AppState,
    job: &crate::jobs::Job,
    m: &ConversionMeta,
    payload: String,
    report: String,
) -> Result<JobSnapshot, ImportError> {
    job.try_complete_durable_with(
        |before| {
            let mut done = before.clone();
            done.state = JobState::Completed;
            done.stage = "completed".into();
            done.result_id = Some(m.artifact_id.clone());
            done.job_revision += 1;
            persist(state, &done, Some((Some(payload), report)))?;
            Ok(m.artifact_id.clone())
        },
        |failed| persist(state, failed, None),
    )
}
fn completed(state: &AppState) -> ConversionMeta {
    let (lease, m) = admitted(state);
    let (payload, report) = pair(&input());
    assert_eq!(
        publish(state, &lease.job, &m, payload, report)
            .unwrap()
            .state,
        JobState::Completed
    );
    drop(lease);
    state.repository.lock().unwrap().conversions[&m.snapshot.id].clone()
}
fn managed(db: &mut postgres::Client) -> Value {
    db.query_one("SELECT jsonb_build_object('sequence',(SELECT to_jsonb(s) FROM (SELECT last_value,is_called FROM public.pi_resource_sequence) s),'kv',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY key),'[]'::jsonb) FROM public.pi_kv t),'projects',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY project_id),'[]'::jsonb) FROM public.pi_projects t),'records',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id),'[]'::jsonb) FROM public.pi_records t))",&[]).unwrap().get(0)
}
fn save(dir: &std::path::Path, name: &str, v: &Value) {
    std::fs::write(dir.join(name), serde_json::to_vec_pretty(v).unwrap()).unwrap()
}
struct Http {
    app: Router,
    session: String,
    dir: PathBuf,
    index: AtomicUsize,
}
impl Http {
    async fn send(&self, method: &str, path: &str, ctype: &str, body: Vec<u8>) -> (u16, Vec<u8>) {
        let n = self.index.fetch_add(1, Ordering::SeqCst);
        let req = Request::builder()
            .method(method)
            .uri(path)
            .header("host", "127.0.0.1:3135")
            .header("origin", "http://127.0.0.1:3135")
            .header("cookie", format!("pi_session={}", self.session))
            .header("content-type", ctype)
            .body(Body::from(body))
            .unwrap();
        let (status, bytes) = tokio::time::timeout(Duration::from_secs(15), async {
            let r = self.app.clone().oneshot(req).await.unwrap();
            (
                r.status().as_u16(),
                to_bytes(r.into_body(), 25 * 1024 * 1024)
                    .await
                    .unwrap()
                    .to_vec(),
            )
        })
        .await
        .expect("finite HTTP/SSE deadline");
        std::fs::write(self.dir.join(format!("{n:03}.body")), &bytes).unwrap();
        save(
            &self.dir,
            &format!("{n:03}.json"),
            &json!({"method":method,"route":path,"status":status,"sha256":crate::conversion::sha(&bytes),"bytes":bytes.len()}),
        );
        (status, bytes)
    }
    async fn get(&self, path: &str) -> (u16, Vec<u8>) {
        self.send("GET", path, "application/octet-stream", vec![])
            .await
    }
    async fn post(&self, path: &str) -> (u16, Vec<u8>) {
        self.send("POST", path, "application/x-www-form-urlencoded", vec![])
            .await
    }
    async fn restore(&self, bytes: &[u8]) -> (u16, Vec<u8>) {
        let mut body=b"--adversarial\r\nContent-Disposition: form-data; name=\"file\"; filename=\"backup.json\"\r\nContent-Type: application/json\r\n\r\n".to_vec();
        body.extend_from_slice(bytes);
        body.extend_from_slice(b"\r\n--adversarial--\r\n");
        self.send(
            "POST",
            "/restore",
            "multipart/form-data; boundary=adversarial",
            body,
        )
        .await
    }
}
// Deliberately holds the actual publication mutex before its actual repository/
// Auth/PG callback. The caller changes rights/archive after receiving entered.
fn gated(
    state: &AppState,
    lease: &crate::jobs::JobLease,
    m: &ConversionMeta,
) -> (
    mpsc::Receiver<()>,
    mpsc::SyncSender<()>,
    std::thread::JoinHandle<Result<JobSnapshot, ImportError>>,
) {
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    let state = state.clone();
    let m = m.clone();
    let job = lease.job.clone();
    let (payload, report) = pair(&input());
    let worker = std::thread::spawn(move || {
        job.try_complete_durable_with(
            |before| {
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                let mut done = before.clone();
                done.state = JobState::Completed;
                done.stage = "completed".into();
                done.result_id = Some(m.artifact_id.clone());
                done.job_revision += 1;
                persist(&state, &done, Some((Some(payload), report)))?;
                Ok(m.artifact_id)
            },
            |failed| persist(&state, failed, None),
        )
    });
    (entered_rx, release_tx, worker)
}
#[test]
#[ignore = "fresh owned pi_s21_adversarial DB; S21_ADVERSARIAL_DATABASE_URL and empty S21_ADVERSARIAL_EVIDENCE"]
fn revoked_archived_publication_backup_semantics_and_exact_delete() {
    let url = std::env::var("S21_ADVERSARIAL_DATABASE_URL").unwrap();
    assert!(url.ends_with("/pi_s21_adversarial"));
    let dir = PathBuf::from(std::env::var("S21_ADVERSARIAL_EVIDENCE").unwrap());
    assert!(dir.is_dir() && std::fs::read_dir(&dir).unwrap().next().is_none());
    let root = AppState::open(3135, url.clone()).unwrap();
    let p = root.platform.as_ref().unwrap().clone();
    assert!(p.auth.needs_setup());
    let session = p.auth.setup("s21_adv_owner", PASSWORD).unwrap();
    let owner = p.auth.actor(&session).unwrap();
    let project = owner.project_id.clone();
    let state = scope(&root, &session);
    let one = completed(&state);
    let two = completed(&state);
    let baseline = load_artifact(&p.database, &project, &two).unwrap();
    p.auth
        .add_user(&owner, &session, "s21_adv_editor", PASSWORD)
        .unwrap();
    p.auth
        .grant(
            &owner,
            &session,
            &project,
            "s21_adv_editor",
            crate::auth::Role::Editor,
        )
        .unwrap();
    let editor_session = p.auth.login("s21_adv_editor", PASSWORD).unwrap();
    p.auth.switch(&editor_session, &project).unwrap();
    let editor = scope(&root, &editor_session);
    let (lease, m) = admitted(&editor);
    let (entered, release, worker) = gated(&editor, &lease, &m);
    entered.recv_timeout(Duration::from_secs(5)).unwrap();
    p.auth
        .grant(
            &owner,
            &session,
            &project,
            "s21_adv_editor",
            crate::auth::Role::Viewer,
        )
        .unwrap();
    release.send(()).unwrap();
    let denied = worker.join().unwrap().unwrap_err();
    assert_eq!(denied.code, "access_denied");
    assert_eq!(lease.job.snapshot().state, JobState::Running);
    let durable = crate::repository_v2::load_metadata(&p.database, &project).unwrap();
    assert_eq!(
        durable.conversions[&m.snapshot.id].snapshot.state,
        JobState::Running
    );
    let a = load_artifact(&p.database, &project, &durable.conversions[&m.snapshot.id]).unwrap();
    assert!(a.payload.is_none() && a.report.is_none());
    lease
        .job
        .try_cancel_with(|s| persist(&state, s, None))
        .unwrap();
    drop(lease);
    let (lease, m) = admitted(&state);
    let (entered, release, worker) = gated(&state, &lease, &m);
    entered.recv_timeout(Duration::from_secs(5)).unwrap();
    let fallback = p
        .auth
        .create_project(&owner, &session, "S21 adversarial fallback")
        .unwrap();
    let revision = p
        .auth
        .all_projects()
        .into_iter()
        .find(|q| q.id == project)
        .unwrap()
        .revision;
    p.auth
        .set_archived(&owner, &session, &project, true, revision)
        .unwrap();
    release.send(()).unwrap();
    assert_eq!(worker.join().unwrap().unwrap_err().code, "access_denied");
    let fallback_actor = p.auth.actor(&session).unwrap();
    assert_eq!(fallback_actor.project_id, fallback);
    let preview = p
        .auth
        .deletion_preview(&fallback_actor, &session, &project)
        .unwrap();
    assert_eq!(preview.active_jobs, 1);
    let deletion = p
        .auth
        .delete_project(
            &fallback_actor,
            &session,
            &project,
            crate::auth::ProjectDeletionConfirmation {
                id: &project,
                phrase: "УДАЛИТЬ",
                revision: preview.revision,
                digest: &preview.digest,
            },
        )
        .unwrap_err();
    assert_eq!(deletion.code, "project_jobs_active");
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let http = Http {
        app: crate::web::router(root.clone()),
        session: session.clone(),
        dir: dir.clone(),
        index: AtomicUsize::new(0),
    };
    runtime.block_on(async {
        for part in ["payload", "report", "events"] {
            let response = http
                .get(&format!("/conversions/jobs/{}/{part}", one.snapshot.id))
                .await;
            assert!(
                matches!(response.0, 403 | 404),
                "crossproject {part}: {}",
                response.0
            );
        }
    });
    p.auth
        .set_archived(&fallback_actor, &session, &project, false, preview.revision)
        .unwrap();
    p.auth.switch(&session, &project).unwrap();
    let current = scope(&root, &session);
    lease
        .job
        .try_cancel_with(|s| persist(&current, s, None))
        .unwrap();
    drop(lease);
    assert_eq!(
        load_artifact(
            &p.database,
            &project,
            &current.repository.lock().unwrap().conversions[&m.snapshot.id]
        )
        .unwrap()
        .payload,
        None
    );
    let mut direct = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    // Enter Tokio only for HTTP futures. Synchronous postgres::Client owns its
    // own runtime and must execute after each block_on has returned.
    let backup = runtime.block_on(http.get("/backup"));
    assert_eq!(backup.0, 200);
    let bundle: Value = serde_json::from_slice(&backup.1).unwrap();
    assert!(bundle["payload"]["conversion_artifacts"][&one.artifact_id]["payload"].is_string());
    let projects = p
        .auth
        .all_projects()
        .into_iter()
        .map(|q| q.id)
        .collect::<BTreeSet<_>>();
    assert_eq!(runtime.block_on(http.restore(&backup.1)).0, 200);
    let restored = p
        .auth
        .all_projects()
        .into_iter()
        .find(|q| !projects.contains(&q.id))
        .unwrap();
    let full = crate::repository_v2::load(&p.database, &restored.id).unwrap();
    let restored_one = &full.conversions[&one.snapshot.id];
    let restored_a = &full.conversion_artifacts[&one.artifact_id];
    validate_artifact(restored_one, restored_a).unwrap();
    assert_eq!(restored_one.payload_sha256, one.payload_sha256);
    assert_eq!(restored_one.report_sha256, one.report_sha256);
    // Forge the semantic report while consistently recomputing every outer
    // digest. Checksums alone must not make a lying report acceptable.
    let mut forged = bundle.clone();
    let mut report: Value = serde_json::from_str(
        forged["payload"]["conversion_artifacts"][&one.artifact_id]["report"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    report["from"] = json!("pnml");
    let report = serde_json::to_string(&report).unwrap();
    forged["payload"]["conversion_artifacts"][&one.artifact_id]["report"] = json!(report);
    forged["payload"]["conversions"][&one.snapshot.id]["report_sha256"] =
        json!(crate::conversion::sha(report.as_bytes()));
    forged["digest_sha256"] = json!(crate::conversion::sha(
        &serde_json::to_vec(&forged["payload"]).unwrap()
    ));
    let before = managed(&mut direct);
    save(&dir, "corrupt-before.json", &before);
    let refused = runtime.block_on(http.restore(&serde_json::to_vec(&forged).unwrap()));
    assert_eq!(refused.0, 422);
    assert!(
        String::from_utf8(refused.1)
            .unwrap()
            .contains("repository_corrupt")
    );
    let after = managed(&mut direct);
    save(&dir, "corrupt-after.json", &after);
    assert_eq!(before, after);
    // A coherently rehashed backup must not inject a revision which recovery
    // cannot increment. Retain a valid source-only Running artifact so this
    // exercises the revision boundary rather than an unrelated pair mismatch.
    let mut overflow = bundle;
    let meta = &mut overflow["payload"]["conversions"][&one.snapshot.id];
    meta["snapshot"]["state"] = json!("running");
    meta["snapshot"]["stage"] = json!("converting");
    meta["snapshot"]["result_id"] = Value::Null;
    meta["snapshot"]["job_revision"] = json!(u64::MAX);
    meta["payload_sha256"] = Value::Null;
    meta["report_sha256"] = Value::Null;
    overflow["payload"]["conversion_artifacts"][&one.artifact_id]["payload"] = Value::Null;
    overflow["payload"]["conversion_artifacts"][&one.artifact_id]["report"] = Value::Null;
    overflow["digest_sha256"] = json!(crate::conversion::sha(
        &serde_json::to_vec(&overflow["payload"]).unwrap()
    ));
    let before = managed(&mut direct);
    save(&dir, "revision-before.json", &before);
    let refused = runtime.block_on(http.restore(&serde_json::to_vec(&overflow).unwrap()));
    assert_eq!(refused.0, 422);
    assert!(
        String::from_utf8(refused.1)
            .unwrap()
            .contains("repository_corrupt")
    );
    let after = managed(&mut direct);
    save(&dir, "revision-after.json", &after);
    assert_eq!(before, after);
    assert_eq!(
        runtime
            .block_on(http.post(&format!("/conversions/jobs/{}/delete", one.snapshot.id)))
            .0,
        303
    );
    assert_eq!(direct.query_one("SELECT count(*) FROM public.pi_records WHERE project_id=$1 AND kind='conversion' AND resource_id=$2", &[&project, &one.artifact_id]).unwrap().get::<_, i64>(0), 0);
    let still = load_artifact(&p.database, &project, &two).unwrap();
    assert_eq!(still.payload, baseline.payload);
    assert_eq!(still.report, baseline.report);
    // Delete the separate restored project, including every new conversion
    // record kind. The original project is the independently preserved control.
    let retained_conversions: i64 = direct
        .query_one(
            "SELECT count(*) FROM public.pi_records WHERE project_id=$1 AND kind='conversion'",
            &[&restored.id],
        )
        .unwrap()
        .get(0);
    assert!(retained_conversions > 0);
    assert!(full.conversions.values().all(|m| m.snapshot.is_terminal()));
    let current_owner = p.auth.actor(&session).unwrap();
    let restored_revision = p
        .auth
        .all_projects()
        .into_iter()
        .find(|q| q.id == restored.id)
        .unwrap()
        .revision;
    p.auth
        .set_archived(
            &current_owner,
            &session,
            &restored.id,
            true,
            restored_revision,
        )
        .unwrap();
    let preview = p
        .auth
        .deletion_preview(&current_owner, &session, &restored.id)
        .unwrap();
    assert_eq!(preview.active_jobs, 0);
    p.auth
        .delete_project(
            &current_owner,
            &session,
            &restored.id,
            crate::auth::ProjectDeletionConfirmation {
                id: &restored.id,
                phrase: "УДАЛИТЬ",
                revision: preview.revision,
                digest: &preview.digest,
            },
        )
        .unwrap();
    assert!(!p.auth.all_projects().iter().any(|q| q.id == restored.id));
    let remaining_projects: i64 = direct
        .query_one(
            "SELECT count(*) FROM public.pi_projects WHERE project_id=$1",
            &[&restored.id],
        )
        .unwrap()
        .get(0);
    let remaining_records: i64 = direct
        .query_one(
            "SELECT count(*) FROM public.pi_records WHERE project_id=$1",
            &[&restored.id],
        )
        .unwrap()
        .get(0);
    assert_eq!((remaining_projects, remaining_records), (0, 0));
    let original = load_artifact(&p.database, &project, &two).unwrap();
    assert_eq!(original.payload, baseline.payload);
    assert_eq!(original.report, baseline.report);
    save(
        &dir,
        "project-delete-proof.json",
        &json!({"deleted_project":restored.id,"conversion_records_before":retained_conversions,"active_jobs_before":preview.active_jobs,"project_rows_after":remaining_projects,"all_record_rows_after":remaining_records,"auth_project_absent":true,"original_pair_unchanged":true}),
    );
    save(
        &dir,
        "result.json",
        &json!({"status":"passed","scope":"actual PG authorization/archive publication fences, backup/restore and explicit deletion; development authored","http_requests":http.index.load(Ordering::SeqCst)}),
    );
}

#[test]
#[ignore = "fresh owned pi_s21_fault DB; S21_FAULT_DATABASE_URL and empty S21_FAULT_EVIDENCE"]
fn postgres_failure_rolls_back_pair_and_failed_worker_reopens_recovered() {
    let url = std::env::var("S21_FAULT_DATABASE_URL").unwrap();
    assert!(url.ends_with("/pi_s21_fault"));
    let dir = PathBuf::from(std::env::var("S21_FAULT_EVIDENCE").unwrap());
    assert!(dir.is_dir() && std::fs::read_dir(&dir).unwrap().next().is_none());
    let mut direct = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    let (session, project, job_id, old_id, old_sha) = {
        let root = AppState::open(3135, url.clone()).unwrap();
        let p = root.platform.as_ref().unwrap().clone();
        assert!(p.auth.needs_setup());
        let session = p.auth.setup("s21_fault_owner", PASSWORD).unwrap();
        let state = scope(&root, &session);
        let project = state.actor.as_ref().unwrap().project_id.clone();
        let old = completed(&state);
        let (lease, m) = admitted(&state);
        let before = managed(&mut direct);
        save(&dir, "rollback-before.json", &before);
        direct.batch_execute("CREATE FUNCTION public.s21_reject_conversion_payload() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.kind='conversion' AND NEW.document->>'payload' IS NOT NULL THEN RAISE EXCEPTION 's21 intentional payload publication failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER s21_reject_conversion_payload BEFORE INSERT OR UPDATE ON public.pi_records FOR EACH ROW EXECUTE FUNCTION public.s21_reject_conversion_payload();").unwrap();
        let (payload, report) = pair(&input());
        let result = publish(&state, &lease.job, &m, payload, report);
        // Remove the deliberate schema perturbation before any strict startup.
        direct.batch_execute("DROP TRIGGER s21_reject_conversion_payload ON public.pi_records; DROP FUNCTION public.s21_reject_conversion_payload();").unwrap();
        assert_eq!(result.unwrap_err().code, "storage_unavailable");
        assert_eq!(p.database.health().unwrap_err().code, "storage_unavailable");
        assert_ne!(lease.job.snapshot().state, JobState::Completed);
        let after = managed(&mut direct);
        save(&dir, "rollback-after.json", &after);
        assert_eq!(before, after, "all managed transaction rows rolled back");
        let row: Value = direct
            .query_one(
                "SELECT document FROM public.pi_projects WHERE project_id=$1",
                &[&project],
            )
            .unwrap()
            .get(0);
        assert_eq!(
            row["conversions"][&m.snapshot.id]["snapshot"]["state"],
            "running"
        );
        let record:Value=direct.query_one("SELECT document FROM public.pi_records WHERE project_id=$1 AND kind='conversion' AND resource_id=$2",&[&project,&m.artifact_id]).unwrap().get(0);
        assert!(record["payload"].is_null() && record["report"].is_null());
        drop(lease);
        (
            session,
            project,
            m.snapshot.id,
            old.snapshot.id,
            old.payload_sha256.unwrap(),
        )
    };
    // Database has no custom Drop/join: dropping every Sender lets the worker's
    // finite receive loop exit. Verify actual advisory lease release before reopen.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let acquired: bool = direct
            .query_one("SELECT pg_try_advisory_lock($1)", &[&LEASE])
            .unwrap()
            .get(0);
        if acquired {
            assert!(
                direct
                    .query_one("SELECT pg_advisory_unlock($1)", &[&LEASE])
                    .unwrap()
                    .get::<_, bool>(0)
            );
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "old worker lease did not exit"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let reopened = AppState::open(3135, url).unwrap();
    let state = scope(&reopened, &session);
    let repo = state.repository.lock().unwrap();
    let interrupted = &repo.conversions[&job_id];
    assert_eq!(interrupted.snapshot.state, JobState::Failed);
    assert_eq!(interrupted.snapshot.stage, "interrupted");
    let a = artifact(&state, &repo, interrupted).unwrap();
    assert!(a.payload.is_none() && a.report.is_none());
    assert_eq!(a.input.as_ref(), input().as_ref());
    let old = &repo.conversions[&old_id];
    let old = load_artifact(&reopened.platform.as_ref().unwrap().database, &project, old).unwrap();
    assert_eq!(
        crate::conversion::sha(old.payload.as_ref().unwrap().as_bytes()),
        old_sha
    );
    save(
        &dir,
        "result.json",
        &json!({"status":"passed","scope":"actual trigger-induced PG rollback, fail-closed worker, all handles dropped, actual AppState reopen/interrupted recovery; no process-kill claim","interrupted_job":job_id}),
    );
}
