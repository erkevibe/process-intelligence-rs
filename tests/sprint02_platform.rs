//! Real PostgreSQL tests: run explicitly with QA_DATABASE_URL pointing to isolated fresh QA DB.
use axum::{
    Router,
    body::{Body, to_bytes},
    http::Request,
};
use process_intelligence_rs::{
    storage::Database,
    web::{AppState, router},
};
use serde_json::{Value, json};
use tower::ServiceExt;
fn url() -> String {
    std::env::var("QA_DATABASE_URL")
        .expect("QA_DATABASE_URL must identify private isolated QA database; never print it")
}
async fn app() -> Router {
    let u = url();
    router(
        tokio::task::spawn_blocking(move || AppState::open(3000, u))
            .await
            .unwrap()
            .unwrap(),
    )
}
async fn send(
    a: &Router,
    method: &str,
    path: &str,
    cookie: &str,
    ctype: &str,
    body: Vec<u8>,
) -> (u16, String, String) {
    let mut r = Request::builder()
        .method(method)
        .uri(path)
        .header("host", "127.0.0.1:3000");
    if !cookie.is_empty() {
        r = r.header("cookie", cookie);
    }
    if !ctype.is_empty() {
        r = r.header("content-type", ctype);
    }
    let response = a
        .clone()
        .oneshot(r.body(Body::from(body)).unwrap())
        .await
        .unwrap();
    let status = response.status().as_u16();
    let cookie = response
        .headers()
        .get("set-cookie")
        .and_then(|v| v.to_str().ok())
        .map(|v| v.split(';').next().unwrap().to_string())
        .unwrap_or_default();
    let text = String::from_utf8(
        to_bytes(response.into_body(), 32 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    (status, text, cookie)
}
async fn form(a: &Router, path: &str, cookie: &str, body: &str) -> (u16, String, String) {
    send(
        a,
        "POST",
        path,
        cookie,
        "application/x-www-form-urlencoded",
        body.as_bytes().to_vec(),
    )
    .await
}
async fn get(a: &Router, path: &str, cookie: &str) -> (u16, String, String) {
    send(a, "GET", path, cookie, "", vec![]).await
}
fn mp(data: &[u8]) -> Vec<u8> {
    let mut b =
        b"--qa-s2\r\nContent-Disposition: form-data; name=\"file\"; filename=\"same.xes\"\r\n\r\n"
            .to_vec();
    b.extend(data);
    b.extend(b"\r\n--qa-s2--\r\n");
    b
}
fn id_in(text: &str, prefix: &str) -> String {
    let pos = text.find(prefix).expect("expected resource ID in HTML");
    text[pos..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect()
}
#[test]
#[ignore = "requires isolated PostgreSQL QA_DATABASE_URL; must run for sprint acceptance"]
fn database_compare_and_swap_batch_rollback() {
    let db = Database::connect(url()).unwrap();
    let suffix = uuid::Uuid::new_v4().simple().to_string();
    let a = format!("qa/{suffix}/a");
    let b = format!("qa/{suffix}/b");
    assert_eq!(db.write(&a, 0, json!({"value":1})).unwrap(), 1);
    assert_eq!(
        db.write(&a, 0, json!({"value":2})).unwrap_err().code,
        "storage_conflict"
    );
    assert!(
        db.write_batch(vec![(b.clone(), 0, json!(3)), (a.clone(), 99, json!(4))])
            .is_err()
    );
    assert!(db.read(&b).unwrap().is_none());
    assert_eq!(db.read(&a).unwrap().unwrap(), (1, json!({"value":1})));
    let fresh = Database::connect(url()).unwrap();
    assert_eq!(fresh.read(&a).unwrap().unwrap().1, json!({"value":1}));
    let first = db.next_id().unwrap();
    assert!(fresh.next_id().unwrap() > first);
}
#[tokio::test]
#[ignore = "requires fresh isolated PostgreSQL QA_DATABASE_URL; no production DB allowed"]
async fn actual_sessions_cross_user_restart_corrupt_restore_and_logout() {
    let a = app().await;
    let (status, _, owner) = form(
        &a,
        "/setup",
        "",
        "username=qa_owner&password=QAownerPassword123",
    )
    .await;
    assert!(
        (300..400).contains(&status),
        "setup fresh DB required: {status}"
    );
    assert!(!owner.is_empty());
    for name in ["qa_other", "qa_viewer"] {
        let (s, _, _) = form(
            &a,
            "/users",
            &owner,
            &format!("username={name}&password=QAmemberPassword123"),
        )
        .await;
        assert!((300..400).contains(&s));
    }
    let project = id_in(&get(&a, "/projects", &owner).await.1, "project-");
    let (s, _, other) = form(
        &a,
        "/login",
        "",
        "username=qa_other&password=QAmemberPassword123",
    )
    .await;
    assert!((300..400).contains(&s));
    assert_eq!(
        form(&a, &format!("/projects/{project}/open"), &other, "")
            .await
            .0,
        403
    );
    let (s, _, _) = send(
        &a,
        "POST",
        "/logs",
        &owner,
        "multipart/form-data; boundary=qa-s2",
        mp(include_bytes!("../fixtures/manual.xes")),
    )
    .await;
    assert_eq!(s, 200);
    let log = id_in(&get(&a, "/logs", &owner).await.1, "log-");
    let export_path = format!("/logs/{log}/export");
    let original: Value = serde_json::from_str(&get(&a, &export_path, &owner).await.1).unwrap();
    assert_eq!(original["analysis"]["events"], 10);
    for path in [
        format!("/logs/{log}"),
        export_path.clone(),
        format!("/logs/{log}/tools"),
    ] {
        let (s, body, _) = get(&a, &path, &other).await;
        assert!([403, 404].contains(&s), "cross-user route {path} status{s}");
        assert!(!body.contains("same.xes"));
    }
    let (s, _, _) = form(
        &a,
        &format!("/projects/{project}/members"),
        &owner,
        "username=qa_viewer&role=viewer",
    )
    .await;
    assert!((300..400).contains(&s));
    let (_, _, viewer) = form(
        &a,
        "/login",
        "",
        "username=qa_viewer&password=QAmemberPassword123",
    )
    .await;
    assert!(
        (300..400).contains(
            &form(&a, &format!("/projects/{project}/open"), &viewer, "")
                .await
                .0
        )
    );
    assert_eq!(get(&a, &export_path, &viewer).await.0, 200);
    assert_eq!(form(&a, "/demo", &viewer, "").await.0, 403);
    assert_eq!(
        form(&a, &format!("/logs/{log}/filter"), &viewer, "")
            .await
            .0,
        403
    );
    let (_, backup, _) = get(&a, "/backup", &owner).await;
    assert!(!backup.contains("password_hash"));
    assert!(!backup.contains("pi_session"));
    let mut corrupt: Value = serde_json::from_str(&backup).unwrap();
    corrupt["schema_version"] = json!(999);
    let projects_before = get(&a, "/projects", &owner).await.1;
    assert_eq!(
        send(
            &a,
            "POST",
            "/restore",
            &owner,
            "multipart/form-data; boundary=qa-s2",
            mp(&serde_json::to_vec(&corrupt).unwrap())
        )
        .await
        .0,
        422
    );
    assert_eq!(
        get(&a, "/projects", &owner)
            .await
            .1
            .matches("/open")
            .count(),
        projects_before.matches("/open").count()
    );
    assert_eq!(
        serde_json::from_str::<Value>(&get(&a, &export_path, &owner).await.1).unwrap(),
        original
    );
    let u = url();
    let mut invalid_view: Value = serde_json::from_str(&backup).unwrap();
    invalid_view["payload"]["logs"][&log]["threshold"] = json!(0);
    invalid_view["digest_sha256"] = json!(process_intelligence_rs::storage::sha256(
        &serde_json::to_vec(&invalid_view["payload"]).unwrap()
    ));
    assert_eq!(
        send(
            &a,
            "POST",
            "/restore",
            &owner,
            "multipart/form-data; boundary=qa-s2",
            mp(&serde_json::to_vec(&invalid_view).unwrap())
        )
        .await
        .0,
        422,
        "correct digest must not excuse invalid persisted threshold"
    );
    assert_eq!(
        get(&a, "/projects", &owner)
            .await
            .1
            .matches("/open")
            .count(),
        projects_before.matches("/open").count()
    );
    assert_eq!(
        serde_json::from_str::<Value>(&get(&a, &export_path, &owner).await.1).unwrap(),
        original
    );
    let second = tokio::task::spawn_blocking(move || AppState::open(3000, u))
        .await
        .unwrap();
    assert!(
        matches!(second,Err(ref error) if error.code=="app_already_running"),
        "same database must reject simultaneous app instance"
    );
    drop(a);
    // Worker shutdown releases the connection-owned lease; this is test synchronization only.
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    let restarted = app().await;
    assert_eq!(
        serde_json::from_str::<Value>(&get(&restarted, &export_path, &owner).await.1).unwrap(),
        original
    );
    assert_eq!(get(&restarted, &export_path, &other).await.0, 404);
    assert!((300..400).contains(&form(&restarted, "/logout", &owner, "").await.0));
    assert_eq!(get(&restarted, &export_path, &owner).await.0, 403);
}
