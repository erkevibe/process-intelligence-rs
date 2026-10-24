//! Actual router/background workers with a held CPU permit: deterministic
//! quota/permission changes after durable acceptance and before execution.
use crate::{
    jobs::{JobSnapshot, JobState},
    web::AppState,
};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    time::{Duration, Instant},
};
use tower::ServiceExt;

fn reopen_recovery_fixture(url: &str) -> AppState {
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        match AppState::open(3147, url.to_owned()) {
            Ok(state) => return state,
            Err(error) if error.code == "app_already_running" && Instant::now() < until => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error) => panic!("fresh application open: {error:?}"),
        }
    }
}

fn recovery_payload_snapshot(url: &str, project: &str) -> Value {
    let mut client = postgres::Client::connect(url, postgres::NoTls).unwrap();
    client.query_one("SELECT jsonb_build_object('records',(SELECT coalesce(jsonb_agg(jsonb_build_array(kind,resource_id,version,document) ORDER BY kind,resource_id),'[]') FROM public.pi_records WHERE project_id=$1),'quota',(SELECT to_jsonb(q) FROM public.pi_project_quota q WHERE project_id=$1),'policy',(SELECT document->'quota_policy' FROM public.pi_projects WHERE project_id=$1))", &[&project]).unwrap().get(0)
}

fn recovery_header_job(header: &crate::repository_v2::Header, kind: &str, id: &str) -> JobSnapshot {
    match kind {
        "generic" => header.durable_jobs[id].clone(),
        "conversion" => header.conversions[id].snapshot.clone(),
        "quality" => header.quality_jobs[id].snapshot.clone(),
        "discovery" => header.discovery_jobs[id].snapshot.clone(),
        _ => panic!("namespace"),
    }
}

#[test]
#[ignore = "fresh isolated S30_QUOTA_RECOVERY_URL pi_s30_quota_recovery and output required"]
fn postgres_queued_recovery_under_zero_quota_all_namespaces() {
    let url = std::env::var("S30_QUOTA_RECOVERY_URL").expect("isolated URL");
    {
        let mut client = postgres::Client::connect(&url, postgres::NoTls).unwrap();
        let row = client
            .query_one(
                "SELECT current_database(), to_regclass('public.pi_projects') IS NULL",
                &[],
            )
            .unwrap();
        assert!(row.get::<_, String>(0).starts_with("pi_s30_quota_recovery"));
        assert!(row.get::<_, bool>(1));
    }
    let output = std::path::PathBuf::from(std::env::var("S30_QUOTA_RECOVERY_EVIDENCE").unwrap());
    assert!(output.is_dir());
    let (token, project, log, model) = {
        let root = reopen_recovery_fixture(&url);
        let platform = root.platform.as_ref().unwrap();
        let token = platform
            .auth
            .setup("s30_recovery_owner", "S30RecoveryOwnerPassword123")
            .unwrap();
        let owner = platform.auth.actor(&token).unwrap();
        let mut state = platform.scope(&root, owner.clone()).unwrap();
        state.session = Some(token.clone());
        let mut seed = crate::project_quota::postgres_tests::fixture(&owner.project_id);
        let source = seed
            .discovery_jobs
            .values()
            .find(|m| m.snapshot.state == JobState::Completed && m.model_id.is_some())
            .unwrap();
        let log = source.log_id.clone();
        let model = source.model_id.clone().unwrap();
        seed.audit = Default::default();
        seed.organization = Default::default();
        seed.current.clear();
        seed.user_views.clear();
        seed.durable_jobs.clear();
        seed.conversions.clear();
        seed.conversion_artifacts.clear();
        seed.quality_jobs.clear();
        seed.quality_artifacts.clear();
        seed.quality_requests.clear();
        seed.discovery_jobs.clear();
        seed.discovery_artifacts.clear();
        seed.discovery_requests.clear();
        seed.current.insert(owner.id.clone(), log.clone());
        let mut repository = state.repository.lock().unwrap();
        seed.storage_revision = repository.storage_revision;
        state
            .commit_with_action(&mut seed, false, "repository_updated", vec![])
            .unwrap();
        *repository = seed;
        (token, owner.project_id, log, model)
    };
    let mut cases = vec![];
    for kind in ["generic", "conversion", "quality", "discovery"] {
        let (id, queued, payload) = {
            let root = reopen_recovery_fixture(&url);
            let platform = root.platform.as_ref().unwrap();
            let mut state = platform
                .scope(&root, platform.auth.actor(&token).unwrap())
                .unwrap();
            state.session = Some(token.clone());
            policy(&state, None);
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            let (held, id) = runtime.block_on(async {
                let held = state.cpu.clone().acquire_owned().await.unwrap();
                let id = submit(&root, &state, &token, kind, &log, &model).await;
                (held, id)
            });
            assert_eq!(state.cpu.available_permits(), 0);
            policy(&state, Some(0));
            let (_, value) = platform.database.project_header(&project).unwrap().unwrap();
            let header = crate::repository_v2::Header::parse(value).unwrap();
            let queued = recovery_header_job(&header, kind, &id);
            assert_eq!(queued.state, JobState::Queued);
            assert_eq!(queued.job_revision, 0);
            let payload = recovery_payload_snapshot(&url, &project);
            assert!(payload["quota"]["payload_used"].as_u64().unwrap() > 0);
            // Every worker is still awaiting the CPU permit, before try_start or
            // spawn_blocking. Shutdown drops those async tasks; no OS kill is claimed.
            runtime.shutdown_timeout(Duration::from_secs(2));
            assert_eq!(state.cpu.available_permits(), 0);
            assert_eq!(state.jobs.shared_slots().available_permits(), 2);
            drop(held);
            (id, queued, payload)
        }; // Drop every old AppState/platform/database clone before reopening.
        let (recovered, stable_header) = {
            let root = reopen_recovery_fixture(&url);
            let platform = root.platform.as_ref().unwrap();
            let state = platform
                .scope(&root, platform.auth.actor(&token).unwrap())
                .unwrap();
            let recovered = snapshots(&state, kind)
                .into_iter()
                .find(|j| j.id == id)
                .unwrap();
            assert_eq!(recovered.state, JobState::Failed);
            assert_eq!(recovered.stage, "interrupted");
            assert_eq!(recovered.error.as_ref().unwrap().code, "interrupted");
            assert_eq!(recovered.job_revision, queued.job_revision + 1);
            assert!(recovered.result_id.is_none());
            assert_eq!(
                state
                    .repository
                    .lock()
                    .unwrap()
                    .quota_policy
                    .as_ref()
                    .unwrap()
                    .payload_allowance,
                0
            );
            assert_eq!(recovery_payload_snapshot(&url, &project), payload);
            (
                recovered,
                platform.database.project_header(&project).unwrap().unwrap(),
            )
        };
        {
            let root = reopen_recovery_fixture(&url);
            let platform = root.platform.as_ref().unwrap();
            assert_eq!(
                platform.database.project_header(&project).unwrap().unwrap(),
                stable_header
            );
            let state = platform
                .scope(&root, platform.auth.actor(&token).unwrap())
                .unwrap();
            assert_eq!(
                snapshots(&state, kind)
                    .into_iter()
                    .find(|j| j.id == id)
                    .unwrap(),
                recovered
            );
            assert_eq!(recovery_payload_snapshot(&url, &project), payload);
        }
        cases.push(json!({"case":format!("{kind}_queued_recovered_under_zero_quota"),"job":id,"job_revision":recovered.job_revision,"payload_accounting_sha256":crate::storage::sha256(&serde_json::to_vec(&payload).unwrap())}));
        cases.push(
            json!({"case":format!("{kind}_repeated_startup_header_audit_and_payload_unchanged")}),
        );
    }
    std::fs::write(output.join("recovery-proof.json"), serde_json::to_vec_pretty(&json!({"status":"S30_QUOTA_QUEUED_RECOVERY_PASS","cases":cases,"scope":"persisted Queued with held CPU permit, async runtime shutdown and fresh AppState; no OS process-kill claim"})).unwrap()).unwrap();
}

async fn request(
    root: &AppState,
    token: &str,
    path: &str,
    content_type: &str,
    body: Vec<u8>,
) -> (u16, Vec<u8>) {
    let request = axum::http::Request::builder()
        .method("POST")
        .uri(path)
        .header("host", "127.0.0.1:3147")
        .header("origin", "http://127.0.0.1:3147")
        .header("accept", "application/json")
        .header("cookie", format!("pi_session={token}"))
        .header("content-type", content_type)
        .body(axum::body::Body::from(body))
        .unwrap();
    tokio::time::timeout(Duration::from_secs(15), async {
        let response = crate::web::router(root.clone())
            .oneshot(request)
            .await
            .unwrap();
        let status = response.status().as_u16();
        let bytes = axum::body::to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap();
        (status, bytes.to_vec())
    })
    .await
    .unwrap()
}
async fn get(root: &AppState, token: &str, path: &str) -> (u16, Vec<u8>) {
    let request = axum::http::Request::builder()
        .uri(path)
        .header("host", "127.0.0.1:3147")
        .header("cookie", format!("pi_session={token}"))
        .body(axum::body::Body::empty())
        .unwrap();
    let response = crate::web::router(root.clone())
        .oneshot(request)
        .await
        .unwrap();
    let status = response.status().as_u16();
    let raw = axum::body::to_bytes(response.into_body(), 2 * 1024 * 1024)
        .await
        .unwrap();
    (status, raw.to_vec())
}
fn restore_body(raw: &[u8]) -> Vec<u8> {
    format!("--s30-quota\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nQuotaRestore\r\n--s30-quota\r\nContent-Disposition: form-data; name=\"file\"; filename=\"project.json\"\r\nContent-Type: application/json\r\n\r\n{}\r\n--s30-quota--\r\n",std::str::from_utf8(raw).unwrap()).into_bytes()
}
fn multipart(conversion: bool) -> Vec<u8> {
    let input = if conversion {
        "case_id,activity\nc,A\nc,B\nc,C\n"
    } else {
        "<log><trace><string key=\"concept:name\" value=\"c\"/><event><string key=\"concept:name\" value=\"A\"/></event><event><string key=\"concept:name\" value=\"B\"/></event><event><string key=\"concept:name\" value=\"C\"/></event></trace></log>"
    };
    let mut body = String::new();
    if conversion {
        for (name, value) in [("from", "csv"), ("to", "xes")] {
            body.push_str(&format!(
                "--s30-quota\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            ));
        }
    }
    body.push_str(&format!("--s30-quota\r\nContent-Disposition: form-data; name=\"file\"; filename=\"quota.{}\"\r\nContent-Type: application/octet-stream\r\n\r\n{input}\r\n--s30-quota--\r\n",if conversion{"csv"}else{"xes"}));
    body.into_bytes()
}
fn snapshots(s: &AppState, kind: &str) -> Vec<JobSnapshot> {
    let r = s.repository.lock().unwrap();
    match kind {
        "generic" => r.durable_jobs.values().cloned().collect(),
        "conversion" => r.conversions.values().map(|m| m.snapshot.clone()).collect(),
        "quality" => r
            .quality_jobs
            .values()
            .map(|m| m.snapshot.clone())
            .collect(),
        "discovery" => r
            .discovery_jobs
            .values()
            .map(|m| m.snapshot.clone())
            .collect(),
        _ => panic!("namespace"),
    }
}
fn policy(s: &AppState, limit: Option<u64>) {
    let mut repo = s.repository.lock().unwrap();
    let mut next = repo.clone();
    next.quota_policy = limit.map(|payload_allowance| crate::project_quota::Policy {
        metric_version: 1,
        payload_allowance,
    });
    s.commit_with_action(&mut next, false, "quota_changed", vec![])
        .unwrap();
    *repo = next;
}
async fn submit(
    root: &AppState,
    s: &AppState,
    token: &str,
    kind: &str,
    log: &str,
    model: &str,
) -> String {
    let previous: BTreeSet<_> = snapshots(s, kind).iter().map(|j| j.id.clone()).collect();
    let (path, content_type, body) = match kind {
        "generic" => (
            "/jobs".into(),
            "multipart/form-data; boundary=s30-quota",
            multipart(false),
        ),
        "conversion" => (
            "/conversions".into(),
            "multipart/form-data; boundary=s30-quota",
            multipart(true),
        ),
        "quality" => {
            let revision = s
                .repository
                .lock()
                .unwrap()
                .get_model(s, model)
                .unwrap()
                .unwrap()
                .revision;
            (
                format!("/models/{model}/quality/jobs"),
                "application/x-www-form-urlencoded",
                format!(
                    "log_id={log}&revision={revision}&request_key={}",
                    crate::quality_store::request_key()
                )
                .into_bytes(),
            )
        }
        "discovery" => {
            let version = s
                .repository
                .lock()
                .unwrap()
                .get_log(s, log)
                .unwrap()
                .unwrap()
                .analysis_version;
            (
                format!("/logs/{log}/discovery/jobs"),
                "application/x-www-form-urlencoded",
                format!(
                    "analysis_version={version}&model_name=QuotaModel&request_key={}",
                    crate::quality_store::request_key()
                )
                .into_bytes(),
            )
        }
        _ => panic!("namespace"),
    };
    let (status, raw) = request(root, token, &path, content_type, body).await;
    assert!(
        matches!(status, 202 | 303),
        "{kind}:{status}:{}",
        String::from_utf8_lossy(&raw)
    );
    let jobs = snapshots(s, kind);
    let added: Vec<_> = jobs.iter().filter(|j| !previous.contains(&j.id)).collect();
    assert_eq!(added.len(), 1);
    assert_eq!(added[0].state, JobState::Queued);
    added[0].id.clone()
}
async fn terminal(s: &AppState, kind: &str, id: &str) -> JobSnapshot {
    let until = Instant::now() + Duration::from_secs(25);
    loop {
        let job = snapshots(s, kind).into_iter().find(|j| j.id == id).unwrap();
        if job.is_terminal() {
            return job;
        }
        assert!(Instant::now() < until, "{kind} remained nonterminal");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
#[test]
#[ignore = "fresh isolated S30_QUOTA_WORKFLOW_URL pi_s30_quota_workflow and output required"]
fn postgres_all_workflows_close_after_quota_fill_and_start_revocation() {
    let url = std::env::var("S30_QUOTA_WORKFLOW_URL").expect("isolated URL");
    {
        let mut c = postgres::Client::connect(&url, postgres::NoTls).unwrap();
        assert!(c.query_one("SELECT current_database() LIKE 'pi_s30_quota_workflow%' AND to_regclass('public.pi_projects') IS NULL",&[]).unwrap().get::<_,bool>(0));
    }
    let output = std::path::PathBuf::from(std::env::var("S30_QUOTA_WORKFLOW_EVIDENCE").unwrap());
    assert!(output.is_dir());
    let root = AppState::open(3147, url).unwrap();
    let p = root.platform.as_ref().unwrap().clone();
    let token = p
        .auth
        .setup("s30_owner", "S30QuotaOwnerPassword123")
        .unwrap();
    let owner = p.auth.actor(&token).unwrap();
    let mut s = p.scope(&root, owner.clone()).unwrap();
    s.session = Some(token.clone());
    let mut seed = crate::project_quota::postgres_tests::fixture(&owner.project_id);
    let source = seed
        .discovery_jobs
        .values()
        .find(|m| m.snapshot.state == JobState::Completed && m.model_id.is_some())
        .unwrap();
    let log = source.log_id.clone();
    let model = source.model_id.clone().unwrap();
    seed.audit = Default::default();
    seed.organization = Default::default();
    seed.current.clear();
    seed.user_views.clear();
    seed.durable_jobs.clear();
    seed.conversions.clear();
    seed.conversion_artifacts.clear();
    seed.quality_jobs.clear();
    seed.quality_artifacts.clear();
    seed.quality_requests.clear();
    seed.discovery_jobs.clear();
    seed.discovery_artifacts.clear();
    seed.discovery_requests.clear();
    seed.current.insert(owner.id.clone(), log.clone());
    {
        let mut repo = s.repository.lock().unwrap();
        seed.storage_revision = repo.storage_revision;
        s.commit_with_action(&mut seed, false, "repository_updated", vec![])
            .unwrap();
        *repo = seed;
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let mut cases = vec![];
    runtime.block_on(async{
        for kind in ["generic","conversion","quality","discovery"]{
            policy(&s,None);
            let held=s.cpu.clone().acquire_owned().await.unwrap();
            let id=submit(&root,&s,&token,kind,&log,&model).await;
            let used=p.database.quota_used(&owner.project_id).unwrap();
            let (logs,models)={let r=s.repository.lock().unwrap();(r.log_count(),r.model_count())};
            policy(&s,Some(0));drop(held);
            let done=terminal(&s,kind,&id).await;
            assert_eq!(done.state,JobState::Failed,"{kind}");assert_eq!(done.error.as_ref().unwrap().code,"project_quota","{kind}");assert!(done.result_id.is_none());
            assert_eq!(p.database.quota_used(&owner.project_id).unwrap(),used);
            let r=s.repository.lock().unwrap();assert_eq!((r.log_count(),r.model_count()),(logs,models));
            match kind{"conversion"=>{assert!(r.conversions[&id].payload_sha256.is_none() && r.conversions[&id].report_sha256.is_none());},"quality"=>assert!(r.quality_jobs[&id].report_sha256.is_none()),"discovery"=>assert!(r.discovery_jobs[&id].model_id.is_none() && r.discovery_jobs[&id].output_sha256.is_none()),_=>{}}
            cases.push(json!({"case":format!("{kind}_publication_quota_rollback_and_durable_failed"),"job":id,"payload_used":used}));
        }
        for kind in ["generic","conversion","quality","discovery"]{
            policy(&s,None);let held=s.cpu.clone().acquire_owned().await.unwrap();
            let id=submit(&root,&s,&token,kind,&log,&model).await;
            let used=p.database.quota_used(&owner.project_id).unwrap();policy(&s,Some(0));
            let prefix=match kind{"generic"=>"/jobs","conversion"=>"/conversions/jobs","quality"=>"/quality/jobs",_=>"/discovery/jobs"};
            let(status,raw)=request(&root,&token,&format!("{prefix}/{id}/cancel"),"application/x-www-form-urlencoded",vec![]).await;
            assert!(status<400,"cancel {kind}:{status}:{}",String::from_utf8_lossy(&raw));
            let done=terminal(&s,kind,&id).await;assert_eq!(done.state,JobState::Cancelled,"{kind}");
            assert_eq!(p.database.quota_used(&owner.project_id).unwrap(),used);drop(held);
            cases.push(json!({"case":format!("{kind}_cancelled_while_overlimit"),"job":id}));
        }
        policy(&s,None);
        p.auth.add_user(&owner,&token,"s30_editor","S30QuotaMemberPassword123").unwrap();
        p.auth.grant(&owner,&token,&owner.project_id,"s30_editor",crate::auth::Role::Editor).unwrap();
        let editor_token=p.auth.login("s30_editor","S30QuotaMemberPassword123").unwrap();p.auth.switch(&editor_token,&owner.project_id).unwrap();
        for kind in ["generic","conversion","quality","discovery"]{
            p.auth.grant(&owner,&token,&owner.project_id,"s30_editor",crate::auth::Role::Editor).unwrap();
            let mut editor=p.scope(&root,p.auth.actor(&editor_token).unwrap()).unwrap();editor.session=Some(editor_token.clone());
            let revision=s.repository.lock().unwrap().storage_revision;
            let(status,_)=request(&root,&editor_token,"/quota","application/x-www-form-urlencoded",format!("revision={revision}&payload_allowance=0&mode=enabled").into_bytes()).await;assert_eq!(status,403);
            let held=s.cpu.clone().acquire_owned().await.unwrap();let id=submit(&root,&editor,&editor_token,kind,&log,&model).await;
            p.auth.grant(&owner,&token,&owner.project_id,"s30_editor",crate::auth::Role::Viewer).unwrap();drop(held);
            let done=terminal(&s,kind,&id).await;assert_eq!(done.state,JobState::Failed,"{kind}");assert_eq!(done.error.as_ref().unwrap().code,"access_denied","{kind}");assert!(done.result_id.is_none());
            cases.push(json!({"case":format!("{kind}_revoked_before_start_durable_failed"),"job":id}));
        }
        let used=p.database.quota_used(&owner.project_id).unwrap();policy(&s,Some(used+65536));
        let(status,backup)=get(&root,&token,"/backup").await;assert_eq!(status,200);
        let bundle:Value=serde_json::from_slice(&backup).unwrap();assert_eq!(bundle["payload"]["quota_policy"]["payload_allowance"],used+65536);
        let before_projects:BTreeSet<_>=p.auth.projects(&owner).iter().map(|v|v.id.clone()).collect();
        let(status,raw)=request(&root,&token,"/restore","multipart/form-data; boundary=s30-quota",restore_body(&backup)).await;
        assert_eq!(status,200,"restore:{}",String::from_utf8_lossy(&raw));
        let added:Vec<_>=p.auth.projects(&owner).into_iter().filter(|v|!before_projects.contains(&v.id)).collect();assert_eq!(added.len(),1);
        let restored=crate::repository_v2::load_metadata(&p.database,&added[0].id).unwrap();
        assert_eq!(restored.quota_policy.as_ref().unwrap().payload_allowance,used+65536);
        assert!(p.database.quota_used(&added[0].id).unwrap()<=used+65536);
        cases.push(json!({"case":"project_json_restore_preserves_policy_and_recounts","restored_project":added[0].id}));
        policy(&s,Some(0));let(status,overfull)=get(&root,&token,"/backup").await;assert_eq!(status,200);
        let auth_before=p.database.read("auth").unwrap();let projects_before=p.auth.projects(&owner).len();
        let(status,_)=request(&root,&token,"/restore","multipart/form-data; boundary=s30-quota",restore_body(&overfull)).await;assert_eq!(status,413);
        assert_eq!(p.database.read("auth").unwrap(),auth_before);assert_eq!(p.auth.projects(&owner).len(),projects_before);
        let(status,after)=get(&root,&token,"/backup").await;assert_eq!(status,200);assert_eq!(after,overfull);
        cases.push(json!({"case":"overlimit_project_json_restore_refused_atomically_policy_not_disabled"}));
    });
    runtime.shutdown_timeout(Duration::from_secs(2));
    std::fs::write(output.join("workflow-proof.json"),serde_json::to_vec(&json!({"status":"S30_QUOTA_WORKFLOWS_PASS","cases":cases,"owner_only_policy":true,"scope":"actual router and background workers; in-process PostgreSQL; no browser or process-kill claim"})).unwrap()).unwrap();
}
