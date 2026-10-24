use super::*;
use crate::{
    auth::Role,
    domain::{Case, Event},
    mining::analyze,
};
use axum::{
    body::{Body, to_bytes},
    http::Request,
};
use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
};
use tower::ServiceExt;

fn log(sequences: &[&[&str]]) -> EventLog {
    EventLog {
        name: None,
        warnings: vec![],
        cases: sequences
            .iter()
            .enumerate()
            .map(|(i, sequence)| Case {
                id: format!("case-{i}"),
                name: None,
                events: sequence
                    .iter()
                    .enumerate()
                    .map(|(ordinal, activity)| Event {
                        ordinal,
                        activity: (*activity).into(),
                        timestamp: None,
                        lifecycle: None,
                    })
                    .collect(),
            })
            .collect(),
    }
}
#[test]
fn borrowed_log_limits_and_html_escaping() {
    let data = log(&[&["A", "B", "C"], &["A", "B", "C"]]);
    assert_eq!(
        rows(&data).unwrap(),
        json!([{"sequence":["A","B","C"],"frequency":2}])
    );
    let mut large = data.clone();
    large.cases = (0..65)
        .map(|index| {
            let mut case = data.cases[0].clone();
            case.id = format!("oversize-{index}");
            case
        })
        .collect();
    assert_eq!(rows(&large).unwrap_err().code, "quality_log_limit");
    let markup = panel(
        &json!({"model_name":"<script>bad()</script>","log_name":"\"<img onerror=x>","report":{"metrics":{"fitness":{"status":"requires_fitting_log"},"precision":{"status":"requires_fitting_log"},"simplicity":{"status":"measured","scalar":1}}}}),
    );
    assert!(!markup.contains("<script>"));
    assert!(!markup.contains("<img"));
    assert!(markup.contains("&lt;script&gt;"));
    assert!(markup.contains("все выбранные трассы"));
    assert!(!markup.contains("<small>requires_fitting_log"));
    assert!(!markup.contains("трасс: null"));
    assert!(markup.contains("расчёт не выполнен"));
}

struct Client {
    app: Router,
    session: String,
    output: PathBuf,
    sequence: AtomicUsize,
}
impl Client {
    async fn request(
        &self,
        method: &str,
        path: &str,
        body: &str,
        mode: &str,
    ) -> (u16, String, Vec<u8>) {
        let mut builder = Request::builder()
            .method(method)
            .uri(path)
            .header("host", "127.0.0.1:3146")
            .header("origin", "http://127.0.0.1:3146")
            .header("cookie", format!("pi_session={}", self.session))
            .header("content-type", "application/x-www-form-urlencoded");
        if mode == "json" {
            builder = builder.header("accept", "application/json");
        }
        if mode == "sse" {
            builder = builder.header("Datastar-Request", "true");
        }
        let response = tokio::time::timeout(
            Duration::from_secs(15),
            self.app
                .clone()
                .oneshot(builder.body(Body::from(body.to_owned())).unwrap()),
        )
        .await
        .unwrap()
        .unwrap();
        let status = response.status().as_u16();
        let content_type = response
            .headers()
            .get("content-type")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let raw = to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec();
        let index = self.sequence.fetch_add(1, Ordering::SeqCst);
        std::fs::write(self.output.join(format!("{index:03}.body")), &raw).unwrap();
        std::fs::write(self.output.join(format!("{index:03}.json")),serde_json::to_vec_pretty(&json!({"method":method,"path":path,"mode":mode,"status":status,"content_type":content_type,"bytes":raw.len(),"sha256":crate::storage::sha256(&raw)})).unwrap()).unwrap();
        (status, content_type, raw)
    }
}
fn snapshot(state: &AppState) -> Value {
    let platform = state.platform.as_ref().unwrap();
    let project = &state.actor.as_ref().unwrap().project_id;
    let mut records = Vec::new();
    for (kind, id) in platform.database.record_keys(project).unwrap() {
        records.push(json!({"id":id,"records":platform.database.resource_records(project,&id,&[kind.as_str()]).unwrap()}));
    }
    json!({"header":platform.database.project_header(project).unwrap(),"records":records})
}
fn seed_log(state: &AppState, data: EventLog, name: &str) -> String {
    crate::web::store_log(
        state,
        data.clone(),
        analyze(&data),
        name.into(),
        0,
        crate::storage::sha256(serde_json::to_vec(&data).unwrap().as_slice()),
        crate::csv_io::NormalizationOrder::Source,
        None,
    )
    .unwrap()
    .id
}

#[test]
#[ignore = "fresh owned pi_s25_quality_test database and empty S25_QUALITY_EVIDENCE required"]
fn postgres_http_permissions_revisions_filtered_log_and_dropped_client() {
    let url =
        std::env::var("S25_QUALITY_DATABASE_URL").expect("owned DB URL required; do not print");
    assert!(url.contains("/pi_s25_quality_test"));
    let output = PathBuf::from(std::env::var("S25_QUALITY_EVIDENCE").unwrap());
    assert!(output.is_dir() && std::fs::read_dir(&output).unwrap().next().is_none());
    let root = AppState::open(3146, url).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(platform.auth.needs_setup());
    let session = platform
        .auth
        .setup("s25_quality_owner", "S25QualityOwnerPassword123")
        .unwrap();
    let actor = platform.auth.actor(&session).unwrap();
    let project = actor.project_id.clone();
    let mut state = platform.scope(&root, actor.clone()).unwrap();
    state.session = Some(session.clone());
    let good = seed_log(
        &state,
        log(&[&["A", "B", "C"], &["A", "B", "C"], &["X"]]),
        "<img onerror=bad> · журнал",
    );
    let model = crate::platform::insert_model(
        &state,
        crate::bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap(),
        "<script>bad()</script> · модель".into(),
        Some(good.clone()),
    )
    .unwrap();
    let nonfitting = seed_log(
        &state,
        log(&[&["A", "B", "C"], &["X"]]),
        "another nonfitting log",
    );
    let mut oversized = log(&[&["A"]]);
    oversized.cases = (0..65)
        .map(|index| {
            let mut case = oversized.cases[0].clone();
            case.id = format!("oversize-{index}");
            case
        })
        .collect();
    let large = seed_log(&state, oversized, "65 traces");
    let empty = seed_log(&state, log(&[]), "empty");
    let unsupported = crate::platform::insert_model(
        &state,
        crate::bpmn::parse(include_bytes!("../fixtures/quality/task_branch.bpmn")).unwrap(),
        "unsupported".into(),
        None,
    )
    .unwrap();
    for (name, role) in [
        ("s25_quality_viewer", Role::Viewer),
        ("s25_quality_editor", Role::Editor),
    ] {
        platform
            .auth
            .add_user(&actor, &session, name, "S25QualityMemberPassword123")
            .unwrap();
        platform
            .auth
            .grant(&actor, &session, &project, name, role)
            .unwrap();
    }
    platform
        .auth
        .add_user(
            &actor,
            &session,
            "s25_quality_outsider",
            "S25QualityMemberPassword123",
        )
        .unwrap();
    let app = crate::web::router(root.clone());
    let client = Client {
        app: app.clone(),
        session: session.clone(),
        output: output.clone(),
        sequence: AtomicUsize::new(0),
    };
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(3)
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let route=format!("/models/{model}/quality");let body=format!("log_id={good}&revision=1");
        let before=snapshot(&state);
        let raw=client.request("POST",&route,&body,"json").await;assert_eq!(raw.0,200);
        let initial:Value=serde_json::from_slice(&raw.2).unwrap();assert_eq!(initial["report"]["trace_count"],3);assert!(initial["report"]["metrics"]["fitness"]["fitness"]["log_fitness"].as_f64().unwrap()<1.0);
        assert_eq!(initial["report"]["metrics"]["precision"]["status"],"requires_fitting_log");
        let html=client.request("GET",&route,"","html").await;assert_eq!(html.0,200);let html=String::from_utf8(html.2).unwrap();assert!(html.contains("window.piRunQuality"));assert!(!html.contains("<script>bad()"));
        let stream=client.request("POST",&route,&body,"sse").await;assert_eq!(stream.0,200);assert!(stream.1.starts_with("text/event-stream"));assert!(String::from_utf8(stream.2).unwrap().contains("datastar-patch-elements"));
        assert_eq!(client.request("POST",&route,&body,"html").await.0,200);
        assert_eq!(snapshot(&state),before,"preview must not write project data, jobs or audit history");
        // Actual filter endpoint changes data while preserving the original source.
        assert_eq!(client.request("POST",&format!("/logs/{good}/filter"),"case_activity=A&min_events=&max_events=&retain=&remove=","html").await.0,303);
        let other=client.request("POST",&route,&format!("log_id={nonfitting}&revision=1"),"json").await;assert_eq!(other.0,200);let other:Value=serde_json::from_slice(&other.2).unwrap();assert_eq!(other["on_construction_log"],false);assert_eq!(other["report"]["metrics"]["precision"]["status"],"requires_fitting_log");
        let filtered_before=snapshot(&state);
        let filtered=client.request("POST",&route,&body,"json").await;assert_eq!(filtered.0,200);let filtered:Value=serde_json::from_slice(&filtered.2).unwrap();
        assert_eq!(filtered["report"]["trace_count"],2);assert_eq!(filtered["report"]["metrics"]["fitness"]["fitness"]["log_fitness"],1.0);assert_eq!(filtered["on_construction_log"],true);assert_ne!(filtered["analysis_version"],initial["analysis_version"]);
        assert_eq!(state.repository.lock().unwrap().get_log_base(&state,&good).unwrap().unwrap().source.cases.len(),3);
        assert_eq!(snapshot(&state),filtered_before);
        assert_eq!(client.request("POST",&route,&format!("log_id={large}&revision=1"),"json").await.0,422);
        let declined=client.request("POST",&route,&format!("log_id={large}&revision=1"),"sse").await;let declined=String::from_utf8(declined.2).unwrap();assert!(declined.contains("64 трасс"));assert!(declined.contains("Оценка не получена"));
        let empty=client.request("POST",&route,&format!("log_id={empty}&revision=1"),"json").await;let empty:Value=serde_json::from_slice(&empty.2).unwrap();assert_eq!(empty["report"]["metrics"]["fitness"]["status"],"no_data");
        let bad=client.request("POST",&format!("/models/{unsupported}/quality"),&body,"json").await;let bad:Value=serde_json::from_slice(&bad.2).unwrap();assert_eq!(bad["report"]["metrics"]["fitness"]["status"],"quality_unsupported_semantics");
        assert_eq!(client.request("POST",&route,&format!("log_id={good}&revision=0"),"json").await.0,409);
        assert_eq!(client.request("POST",&route,&format!("log_id={good}&revision=1&extra=x"),"json").await.0,422);
        assert_eq!(client.request("POST",&route,&"x".repeat(4097),"json").await.0,413);
        let import=state.jobs.reserve().unwrap();let conversion=state.conversion_jobs.reserve().unwrap();
        assert_eq!(client.request("POST",&route,&body,"json").await.0,503);drop(import);drop(conversion);
        let cpu=state.cpu.clone().try_acquire_owned().unwrap();assert_eq!(client.request("POST",&route,&body,"json").await.0,503);drop(cpu);
        for (name,expected) in [("s25_quality_viewer",403),("s25_quality_outsider",404)] {
            let token=platform.auth.login(name,"S25QualityMemberPassword123").unwrap();
            if name.ends_with("viewer"){platform.auth.switch(&token,&project).unwrap();}
            let dir=output.join(name);std::fs::create_dir(&dir).unwrap();
            let member=Client{app:app.clone(),session:token,output:dir,sequence:AtomicUsize::new(0)};
            assert_eq!(member.request("POST",&route,&body,"json").await.0,expected);
        }
        let editor_session=platform.auth.login("s25_quality_editor","S25QualityMemberPassword123").unwrap();platform.auth.switch(&editor_session,&project).unwrap();
        let mut editor=platform.scope(&root,platform.auth.actor(&editor_session).unwrap()).unwrap();editor.session=Some(editor_session);
        let denied=compute(&editor,&model,&PreviewForm{log_id:good.clone(),revision:1},true,false,&mut |stage| {
            if stage=="publish" {platform.auth.grant(&actor,&session,&project,"s25_quality_editor",Role::Viewer).unwrap();}
        }).unwrap_err();assert_eq!(denied.code,"access_denied");
        // Publication checks actual committed revision, not only the initial form revision.
        let changed=compute(&state,&model,&PreviewForm{log_id:good.clone(),revision:1},true,false,&mut |stage| {
            if stage=="publish" {
                let mut repo=state.repository.lock().unwrap();let mut item=(*repo.get_model(&state,&model).unwrap().unwrap()).clone();let mut next=repo.clone();item.revision+=1;next.models.insert(model.clone(),Arc::new(item));state.commit_action_resources(&mut next,"model_saved",vec![model.clone()]).unwrap();*repo=next;
            }
        }).unwrap_err();assert_eq!(changed.code,"quality_conflict");
        let changed=compute(&state,&model,&PreviewForm{log_id:good.clone(),revision:2},true,false,&mut |stage| {
            if stage=="publish" {
                let mut repo=state.repository.lock().unwrap();let mut item=repo.get_log_base(&state,&good).unwrap().unwrap();let mut next=repo.clone();item.analysis_version=state.next_id(item.analysis_version+1).unwrap();next.logs.insert(good.clone(),item);state.commit_action_resources(&mut next,"filter_applied",vec![good.clone()]).unwrap();*repo=next;
            }
        }).unwrap_err();assert_eq!(changed.code,"quality_conflict");
        let stable=snapshot(&state);
        let (entered_tx,entered_rx)=mpsc::sync_channel(1);let(release_tx,release_rx)=mpsc::sync_channel(1);let mut receiver=Some(release_rx);
        let mut admitted=state.clone();admitted.payload_permit=Some(Arc::new(platform.payload_slots.clone().try_acquire_owned().unwrap()));
        let task=tokio::spawn(run_preview(admitted,model.clone(),PreviewForm{log_id:good.clone(),revision:2},true,false,move |stage| {
            if stage=="fitness" && let Some(receiver)=receiver.take() {entered_tx.send(()).unwrap();receiver.recv_timeout(Duration::from_secs(10)).unwrap();}
        }));
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();task.abort();
        assert_eq!(state.jobs.shared_slots().available_permits(),1);assert_eq!(state.cpu.available_permits(),0);assert_eq!(platform.payload_slots.available_permits(),1);
        let remaining=state.conversion_jobs.reserve().unwrap();assert!(state.jobs.reserve().is_err());
        release_tx.send(()).unwrap();drop(remaining);
        tokio::time::timeout(Duration::from_secs(5),async {while state.jobs.shared_slots().available_permits()!=2 || state.cpu.available_permits()!=1 || platform.payload_slots.available_permits()!=2 {tokio::time::sleep(Duration::from_millis(5)).await;}}).await.unwrap();
        assert_eq!(snapshot(&state),stable);assert!(state.jobs.current().is_none());
        std::fs::write(output.join("proof.json"),serde_json::to_vec_pretty(&json!({"status":"ACTUAL_FINITE_PG_HTTP_QUALITY_PREVIEW_CONTROLS_PASS","http_requests":client.sequence.load(Ordering::SeqCst),"filtered_data_verified":true,"project_snapshot_unchanged_for_preview":true,"role_revocation_before_publication":true,"model_and_log_revision_conflicts":true,"dropped_client_retains_worker_permits":true,"durable_quality_history_claimed":false,"physical_browser_claimed":false})).unwrap()).unwrap();
    });
}
