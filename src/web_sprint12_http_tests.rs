// Finite in-process HTTP pipeline proof. CPU reservation controls scheduling;
// it is not a stock-executable TCP/browser or held final Auth instruction proof.
#[test]
#[ignore = "requires fresh owned S12_HTTP_DATABASE_URL and private S12_HTTP_EVIDENCE"]
fn actual_http_queue_cancel_and_project_safety() {
    use axum::{
        body::{Body, to_bytes},
        http::Request,
    };
    use tower::ServiceExt;
    let url = std::env::var("S12_HTTP_DATABASE_URL").expect("owned URL required; never print");
    let directory = std::path::PathBuf::from(std::env::var("S12_HTTP_EVIDENCE").unwrap());
    assert!(directory.is_dir() && std::fs::read_dir(&directory).unwrap().next().is_none());
    let root = AppState::open(3096, url.clone()).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(platform.auth.needs_setup());
    let session = platform
        .auth
        .setup("s12_http_owner", "S12HttpPassword123")
        .unwrap();
    let actor = platform.auth.actor(&session).unwrap();
    let project = actor.project_id.clone();
    let mut client = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap();
    let app = router(root.clone());
    let send = |label: &str, method: &str, route: &str, content_type: &str, body: Vec<u8>| {
        let started = chrono::Utc::now();
        let request = Request::builder()
            .method(method)
            .uri(route)
            .header("host", "127.0.0.1:3096")
            .header("origin", "http://127.0.0.1:3096")
            .header("cookie", format!("pi_session={session}"))
            .header("content-type", content_type)
            .body(Body::from(body))
            .unwrap();
        let (status, bytes) = runtime.block_on(async {
            let response = app.clone().oneshot(request).await.unwrap();
            let status = response.status().as_u16();
            let bytes = to_bytes(response.into_body(), 2 * 1024 * 1024)
                .await
                .unwrap()
                .to_vec();
            (status, bytes)
        });
        let finished = chrono::Utc::now();
        std::fs::write(directory.join(format!("{label}.body")), &bytes).unwrap();
        save(
            &directory,
            &format!("{label}.http.json"),
            &json!({"method":method,"route":route,"status":status,
            "started":started,"finished":finished,"bytes":bytes.len(),"sha256":crate::storage::sha256(&bytes)}),
        );
        (status, String::from_utf8(bytes).unwrap(), started, finished)
    };
    let form = "application/x-www-form-urlencoded";
    let before = snapshot(&mut client);
    save(&directory, "last-active-pre.json", &before);
    let refused = send(
        "last-active",
        "POST",
        &format!("/projects/{project}/archive"),
        form,
        b"revision=1".to_vec(),
    );
    assert_eq!(refused.0, 422);
    assert!(refused.1.contains("project_last_active"));
    let after = snapshot(&mut client);
    save(&directory, "last-active-post.json", &after);
    assert!(before == after, "refusal changed managed state");
    // Fixture foundation only: this native create has no HTTP producer credit.
    platform
        .auth
        .create_project(&actor, &session, "S12 HTTP fallback")
        .unwrap();
    let permit = root.cpu.clone().try_acquire_owned().unwrap();
    let before = snapshot(&mut client);
    save(&directory, "queue-pre.json", &before);
    let mut multipart=b"--s12-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"manual.xes\"\r\nContent-Type: application/xml\r\n\r\n".to_vec();
    multipart.extend_from_slice(include_bytes!("../fixtures/manual.xes"));
    multipart.extend_from_slice(b"\r\n--s12-boundary--\r\n");
    let queued = send(
        "queue",
        "POST",
        "/jobs",
        "multipart/form-data; boundary=s12-boundary",
        multipart,
    );
    assert_eq!(queued.0, 202);
    let after = snapshot(&mut client);
    save(&directory, "queue-post.json", &after);
    let job = json!({"id":"job-1","state":"queued","stage":"queued","job_revision":0,"cancel_requested":false,"result_id":null,"error":null});
    let mut allocator = before.clone();
    assert_eq!(
        before["pi_resource_sequence"],
        json!({"last_value":1,"log_cnt":0,"is_called":false})
    );
    allocator["pi_resource_sequence"] = json!({"last_value":1,"log_cnt":32,"is_called":true});
    verify_commit(
        &allocator,
        &after,
        &project,
        &actor.id,
        "job_updated",
        json!({"job-1":job}),
        vec!["job-1".into()],
        queued.2,
        queued.3,
    );
    save(&directory, "archive-pre.json", &after);
    let archived = send(
        "archive",
        "POST",
        &format!("/projects/{project}/archive"),
        form,
        b"revision=1".to_vec(),
    );
    assert_eq!(archived.0, 303);
    let archived_state = snapshot(&mut client);
    save(&directory, "archive-post.json", &archived_state);
    let current_actor = platform.auth.actor(&session).unwrap();
    assert_ne!(current_actor.project_id, project);
    let preview = platform
        .auth
        .deletion_preview(&current_actor, &session, &project)
        .unwrap();
    assert_eq!(preview.active_jobs, 1);
    save(
        &directory,
        "delete-preview.json",
        &serde_json::to_value(&preview).unwrap(),
    );
    let confirmation = format!(
        "confirmation_id={project}&phrase=%D0%A3%D0%94%D0%90%D0%9B%D0%98%D0%A2%D0%AC&revision=2&digest={}",
        preview.digest
    );
    let refused = send(
        "active-delete",
        "POST",
        &format!("/projects/{project}/delete"),
        form,
        confirmation.into_bytes(),
    );
    assert_eq!(refused.0, 422);
    assert!(refused.1.contains("project_jobs_active"));
    let after = snapshot(&mut client);
    save(&directory, "active-delete-post.json", &after);
    assert!(
        archived_state == after,
        "active-job refusal changed managed state"
    );
    let restored = send(
        "unarchive",
        "POST",
        &format!("/projects/{project}/unarchive"),
        form,
        b"revision=2".to_vec(),
    );
    assert_eq!(restored.0, 303);
    save(&directory, "unarchive-post.json", &snapshot(&mut client));
    assert_eq!(
        send(
            "open",
            "POST",
            &format!("/projects/{project}/open"),
            form,
            vec![]
        )
        .0,
        303
    );
    let before = snapshot(&mut client);
    save(&directory, "cancel-pre.json", &before);
    let cancelled = send("cancel", "POST", "/jobs/job-1/cancel", form, vec![]);
    assert_eq!(cancelled.0, 200);
    let after = snapshot(&mut client);
    save(&directory, "cancel-post.json", &after);
    let cancelled_job = json!({"id":"job-1","state":"cancelled","stage":"cancelled","job_revision":1,"cancel_requested":true,"result_id":null,"error":null});
    verify_commit(
        &before,
        &after,
        &project,
        &actor.id,
        "job_updated",
        json!({"job-1":cancelled_job.clone()}),
        vec!["job-1".into()],
        cancelled.2,
        cancelled.3,
    );
    drop(permit);
    let scoped = platform
        .scope(&root, platform.auth.actor(&session).unwrap())
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let observed = snapshot(&mut client);
        let (revision, _) = expected_header(&observed, &project);
        if revision == 3 {
            break;
        }
        assert!(
            revision == 2 && std::time::Instant::now() < deadline,
            "cancelled worker terminal persistence was not acknowledged"
        );
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let final_state = snapshot(&mut client);
    save(&directory, "worker-final.json", &final_state);
    assert!(
        final_state["pi_records"].as_array().unwrap().is_empty(),
        "cancelled upload published resources"
    );
    assert_eq!(
        scoped.jobs.get("job-1").unwrap().snapshot().state,
        JobState::Cancelled
    );
    assert!(
        final_state["pi_kv"] == after["pi_kv"],
        "worker changed Auth projection"
    );
    assert_eq!(
        final_state["pi_resource_sequence"],
        after["pi_resource_sequence"]
    );
    verify_commit(
        &after,
        &final_state,
        &project,
        &actor.id,
        "job_updated",
        json!({"job-1":cancelled_job}),
        vec!["job-1".into()],
        cancelled.3,
        chrono::Utc::now(),
    );
    save(
        &directory,
        "result.json",
        &json!({"status":"IN_PROCESS_HTTP_QUEUE_CANCEL_PROJECT_SAFETY_PASSED","cpu_reserved_before_http":true,
        "limits":["In-process real router/middleware/handlers and PostgreSQL; no stock TCP/browser credit","Archive/unarchive full raw evidence requires independent Auth delta reconstruction","Worker terminal persistence observed in PostgreSQL; thread exit not separately instrumented"]}),
    );
}
