use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use process_intelligence_rs::{
    event_io::parse_xes_cancellable,
    web::{AppState, router},
};
use serde_json::Value;
use std::{
    collections::BTreeSet,
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
use tower::ServiceExt;
fn app() -> Router {
    router(AppState::new(3000))
}
fn req(method: &str, path: &str, form: Option<&str>, data: impl Into<Body>) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(path)
        .header("host", "127.0.0.1:3000");
    if let Some(t) = form {
        b = b.header("content-type", t);
    }
    b.body(data.into()).unwrap()
}
fn multipart(data: &[u8]) -> Vec<u8> {
    let mut b =
        b"--qa\r\nContent-Disposition: form-data; name=\"file\"; filename=\"qa.xes\"\r\n\r\n"
            .to_vec();
    b.extend_from_slice(data);
    b.extend_from_slice(b"\r\n--qa--\r\n");
    b
}
async fn text(r: axum::response::Response) -> String {
    String::from_utf8(
        to_bytes(r.into_body(), 32 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap()
}
async fn json(app: &Router, path: &str) -> Value {
    let r = app
        .clone()
        .oneshot(req("GET", path, None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    serde_json::from_str(&text(r).await).unwrap()
}
async fn upload(app: &Router, path: &str, data: &[u8]) -> String {
    let r = app
        .clone()
        .oneshot(req(
            "POST",
            path,
            Some("multipart/form-data; boundary=qa"),
            multipart(data),
        ))
        .await
        .unwrap();
    assert_eq!(
        r.status(),
        if path == "/jobs" {
            StatusCode::ACCEPTED
        } else {
            StatusCode::OK
        }
    );
    text(r).await
}
async fn mutation(app: &Router, path: &str, form: &str) {
    let r = app
        .clone()
        .oneshot(req(
            "POST",
            path,
            Some("application/x-www-form-urlencoded"),
            form.to_owned(),
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    let _ = text(r).await;
}
async fn terminal(app: &Router) -> Value {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let s = json(app, "/jobs/job-1").await;
            if ["completed", "failed", "cancelled"].contains(&s["state"].as_str().unwrap()) {
                break s;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("job terminates within test bound")
}

#[tokio::test]
async fn case_projection_empty_selfloop_hidden_edges_preserves_global_counts() {
    let app = app();
    upload(&app, "/logs", include_bytes!("../fixtures/semantics.xes")).await;
    let initial = json(&app, "/logs/log-1/export").await;
    let cases = initial["analysis"]["variants"].as_array().unwrap();
    let empty = cases
        .iter()
        .find(|v| v["sequence"].as_array().unwrap().is_empty())
        .unwrap()["case_ids"][0]
        .as_str()
        .unwrap();
    mutation(
        &app,
        "/logs/log-1/selection",
        &format!("kind=case&id={empty}"),
    )
    .await;
    let selected = json(&app, "/logs/log-1/export").await;
    assert_eq!(
        selected["selected_case"]["events"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
    assert_eq!(selected["view"]["selected_case_id"], empty);
    assert!(
        selected["view"]["case_highlight"]["node_ids"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        selected["view"]["case_highlight"]["edge_ids"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let selfloop = cases
        .iter()
        .find(|v| v["sequence"].as_array().unwrap().len() == 2)
        .unwrap()["case_ids"][0]
        .as_str()
        .unwrap();
    mutation(
        &app,
        "/logs/log-1/selection",
        &format!("kind=case&id={selfloop}"),
    )
    .await;
    let highlighted = json(&app, "/logs/log-1/export").await;
    assert_eq!(
        highlighted["selected_case"]["events"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        highlighted["view"]["case_highlight"]["node_ids"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        highlighted["view"]["case_highlight"]["edge_ids"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    mutation(&app, "/logs/log-1/view", "threshold=2").await;
    let hidden = json(&app, "/logs/log-1/export").await;
    assert_eq!(hidden["view"]["selected_case_id"], selfloop);
    assert!(
        hidden["view"]["case_highlight"]["edge_ids"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(hidden["analysis"], initial["analysis"]);
    let visible: BTreeSet<_> = hidden["view"]["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["id"].as_str().unwrap())
        .collect();
    assert!(
        hidden["view"]["case_highlight"]["node_ids"]
            .as_array()
            .unwrap()
            .iter()
            .all(|id| visible.contains(id.as_str().unwrap()))
    );
    let invalid = app
        .oneshot(req(
            "POST",
            "/logs/log-1/selection",
            Some("application/x-www-form-urlencoded"),
            "kind=case&id=not-a-case",
        ))
        .await
        .unwrap();
    assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn job_completion_reconnect_snapshot_and_local_guards() {
    let app = app();
    let html = upload(&app, "/jobs", include_bytes!("../fixtures/manual.xes")).await;
    assert!(html.contains("job-1"));
    let s = terminal(&app).await;
    assert_eq!(s["state"], "completed");
    let result = s["result_id"].as_str().unwrap();
    let e = json(&app, &format!("/logs/{result}/export")).await;
    assert_eq!(e["analysis"]["events"], 10);
    for _ in 0..2 {
        let response = app
            .clone()
            .oneshot(req("GET", "/jobs/job-1/events", None, Body::empty()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = tokio::time::timeout(Duration::from_secs(5), text(response))
            .await
            .unwrap();
        assert!(body.contains("Completed"));
        assert!(body.contains("analysis-panel"));
        assert!(
            body.find("analysis-panel").unwrap()
                < body.find("data-job-state=\"Completed\"").unwrap()
        );
    }
    let repeat = app
        .clone()
        .oneshot(req("POST", "/jobs/job-1/cancel", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&text(repeat).await).unwrap(),
        s
    );
    let mut foreign = req("POST", "/jobs/job-1/cancel", None, Body::empty());
    foreign
        .headers_mut()
        .insert("origin", "https://attacker.example".parse().unwrap());
    assert_eq!(
        app.clone().oneshot(foreign).await.unwrap().status(),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        app.oneshot(req("GET", "/jobs/missing/events", None, Body::empty()))
            .await
            .unwrap()
            .status(),
        StatusCode::NOT_FOUND
    );
}

#[tokio::test]
async fn job_failure_has_no_result_and_reconnect_terminal() {
    let app = app();
    upload(
        &app,
        "/jobs",
        include_bytes!("../fixtures/invalid-timestamp.xes"),
    )
    .await;
    let s = terminal(&app).await;
    assert_eq!(s["state"], "failed");
    assert!(s["result_id"].is_null());
    assert!(s["error"]["code"].is_string());
    let response = app
        .oneshot(req("GET", "/jobs/job-1/events", None, Body::empty()))
        .await
        .unwrap();
    assert!(text(response).await.contains("Failed"));
}

#[tokio::test]
async fn accepted_job_cancel_never_publishes_result() {
    let app = app();
    let mut large = String::from("<log><trace>");
    for _ in 0..100000 {
        large.push_str("<event><string key='concept:name' value='A'/></event>");
    }
    large.push_str("</trace></log>");
    upload(&app, "/jobs", large.as_bytes()).await;
    let response = app
        .clone()
        .oneshot(req("POST", "/jobs/job-1/cancel", None, Body::empty()))
        .await
        .unwrap();
    let cancelled: Value = serde_json::from_str(&text(response).await).unwrap();
    assert_eq!(
        cancelled["cancel_requested"], true,
        "sufficiently large real parser job must allow immediate cancel"
    );
    let s = terminal(&app).await;
    assert_eq!(s["state"], "cancelled");
    assert!(s["result_id"].is_null());
    assert_eq!(json(&app, "/jobs/job-1").await, s);
}

#[test]
fn cooperative_import_checks_actual_cancel_during_preflight() {
    let calls = AtomicUsize::new(0);
    let fixture = include_bytes!("../fixtures/manual.xes");
    let error =
        parse_xes_cancellable(fixture, &|| calls.fetch_add(1, Ordering::SeqCst) >= 2).unwrap_err();
    assert_eq!(error.code, "cancelled");
    assert!(calls.load(Ordering::SeqCst) >= 3);
}

#[tokio::test]
async fn old_completed_job_reconnect_does_not_replace_new_current_analysis() {
    let app = app();
    upload(&app, "/jobs", include_bytes!("../fixtures/manual.xes")).await;
    let old = terminal(&app).await;
    assert_eq!(old["state"], "completed");
    upload(&app, "/logs", include_bytes!("../fixtures/semantics.xes")).await;
    let new = json(&app, "/logs/log-2/export").await;
    assert_eq!(new["analysis"]["events"], 4);
    let reconnect = app
        .clone()
        .oneshot(req("GET", "/jobs/job-1/events", None, Body::empty()))
        .await
        .unwrap();
    let body = text(reconnect).await;
    assert!(body.contains("Completed"));
    assert!(
        !body.contains("analysis-panel"),
        "old result cannot patch newer current analysis"
    );
    assert_eq!(json(&app, "/logs/log-2/export").await, new);
}

#[tokio::test]
async fn upload_quota_rejects_third_body_before_buffering_and_keeps_health_responsive() {
    let app = app();
    let ready1 = std::sync::Arc::new(tokio::sync::Notify::new());
    let ready2 = std::sync::Arc::new(tokio::sync::Notify::new());
    let release1 = std::sync::Arc::new(tokio::sync::Notify::new());
    let release2 = std::sync::Arc::new(tokio::sync::Notify::new());
    let blocked_body = |ready: std::sync::Arc<tokio::sync::Notify>,
                        release: std::sync::Arc<tokio::sync::Notify>| {
        Body::from_stream(futures_util::stream::once(async move {
            ready.notify_one();
            release.notified().await;
            Ok::<_, std::io::Error>(multipart(include_bytes!("../fixtures/manual.xes")))
        }))
    };
    let a1 = app.clone();
    let body1 = blocked_body(ready1.clone(), release1.clone());
    let task1 = tokio::spawn(async move {
        a1.oneshot(req(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa"),
            body1,
        ))
        .await
        .unwrap()
    });
    let a2 = app.clone();
    let body2 = blocked_body(ready2.clone(), release2.clone());
    let task2 = tokio::spawn(async move {
        a2.oneshot(req(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa"),
            body2,
        ))
        .await
        .unwrap()
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        ready1.notified().await;
        ready2.notified().await;
    })
    .await
    .expect("both actual request body streams polled while admitted");
    let third = app
        .clone()
        .oneshot(req(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa"),
            Body::empty(),
        ))
        .await
        .unwrap();
    let third_status = third.status();
    let health = app
        .oneshot(req("GET", "/health", None, Body::empty()))
        .await
        .unwrap();
    let health_status = health.status();
    release1.notify_one();
    release2.notify_one();
    let _ = task1.await.unwrap();
    let _ = task2.await.unwrap();
    assert_eq!(
        third_status,
        StatusCode::TOO_MANY_REQUESTS,
        "admission quota must reject before third body buffering"
    );
    assert_eq!(health_status, StatusCode::OK);
}
