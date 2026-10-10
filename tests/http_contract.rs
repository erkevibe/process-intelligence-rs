use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode},
};
use process_intelligence_rs::web::{AppState, router};
use serde_json::Value;
use tower::ServiceExt;

fn app() -> Router {
    router(AppState::new(3000))
}
fn request(
    method: &str,
    path: &str,
    content_type: Option<&str>,
    body: impl Into<Body>,
) -> Request<Body> {
    let mut r = Request::builder()
        .method(method)
        .uri(path)
        .header("host", "127.0.0.1:3000");
    if let Some(c) = content_type {
        r = r.header("content-type", c);
    }
    r.body(body.into()).unwrap()
}
async fn text(response: axum::response::Response) -> String {
    String::from_utf8(
        to_bytes(response.into_body(), 32 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap()
}
async fn exported(app: &Router) -> Value {
    let response = app
        .clone()
        .oneshot(request("GET", "/logs/log-1/export", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    serde_json::from_str(&text(response).await).unwrap()
}
fn multipart(data: &[u8]) -> Vec<u8> {
    let mut body=b"--qa-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"qa.xes\"\r\nContent-Type: application/xml\r\n\r\n".to_vec();
    body.extend_from_slice(data);
    body.extend_from_slice(b"\r\n--qa-boundary--\r\n");
    body
}

#[tokio::test]
async fn health_demo_exact_export_and_nonce_csp() {
    let app = app();
    let health = app
        .clone()
        .oneshot(request("GET", "/health", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(health.status(), StatusCode::OK);
    assert!(health.headers().contains_key("x-request-id"));
    assert_eq!(
        serde_json::from_str::<Value>(&text(health).await).unwrap()["status"],
        "ready"
    );
    let demo = app
        .clone()
        .oneshot(request("POST", "/demo", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(demo.status(), StatusCode::OK);
    let csp = demo
        .headers()
        .get("content-security-policy")
        .expect("CSP header")
        .to_str()
        .unwrap()
        .to_owned();
    assert!(!csp.contains("unsafe-eval"));
    assert!(csp.contains("'nonce-"));
    assert!(csp.contains("connect-src 'self'"));
    let html = text(demo).await;
    assert!(html.contains("log-1"));
    let export = exported(&app).await;
    assert!(export.get("schema_version").is_some());
    assert_eq!(export["analysis"]["cases"], 4);
    assert_eq!(export["analysis"]["events"], 10);
    assert_eq!(export["analysis"]["activities"], 3);
    let index = app
        .oneshot(request("GET", "/", None, Body::empty()))
        .await
        .unwrap();
    let next = index
        .headers()
        .get("content-security-policy")
        .unwrap()
        .to_str()
        .unwrap();
    assert_ne!(csp, next, "nonce unique per full page");
}

#[tokio::test]
async fn invalid_import_preserves_valid_analysis_and_export() {
    let app = app();
    let good = app
        .clone()
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(include_bytes!("../fixtures/manual.xes")),
        ))
        .await
        .unwrap();
    assert_eq!(good.status(), StatusCode::OK);
    let before = exported(&app).await;
    let bad = app
        .clone()
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(include_bytes!("../fixtures/invalid-malformed.xes")),
        ))
        .await
        .unwrap();
    assert_eq!(bad.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let html = text(bad).await;
    assert!(html.contains("log-1"));
    assert!(html.contains("graph-data"));
    assert!(html.contains("role=\"alert\""));
    assert_eq!(exported(&app).await, before);
    let visible = app
        .oneshot(request("GET", "/logs/log-1", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(visible.status(), StatusCode::OK);
}

#[tokio::test]
async fn threshold_sse_protocol_and_export_agree() {
    let app = app();
    let demo = app
        .clone()
        .oneshot(request("POST", "/demo", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(demo.status(), StatusCode::OK);
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/logs/log-1/view",
            Some("application/x-www-form-urlencoded"),
            "threshold=2",
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response.headers()["content-type"]
            .to_str()
            .unwrap()
            .starts_with("text/event-stream")
    );
    let sse = text(response).await;
    assert!(sse.contains("event: datastar-patch-elements"));
    assert!(sse.contains("data: elements "));
    // Datastar requires EACH line of multiline elements payload to repeat its named field.
    let mut elements = false;
    for line in sse.lines() {
        if line.is_empty() {
            elements = false;
            continue;
        }
        if line.starts_with("data: elements ") {
            elements = true;
            continue;
        }
        if elements && line.starts_with("data:") {
            panic!("unnamed continuation in elements payload: {line}");
        }
        if line.starts_with('<') {
            panic!("raw HTML outside SSE data framing");
        }
    }
    let e = exported(&app).await;
    assert_eq!(e["analysis"]["events"], 10);
    assert_eq!(e["view"]["min_edge_frequency"], 2);
    assert_eq!(e["view"]["edges"].as_array().unwrap().len(), 2);
    assert_eq!(e["view"]["nodes"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn invalid_view_selection_unknown_ids_host_and_origin() {
    let app = app();
    let demo = app
        .clone()
        .oneshot(request("POST", "/demo", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(demo.status(), StatusCode::OK);
    for (path, form, status) in [
        ("/logs/log-1/view", "threshold=0", StatusCode::BAD_REQUEST),
        (
            "/logs/log-1/selection",
            "kind=edge&id=missing",
            StatusCode::BAD_REQUEST,
        ),
        (
            "/logs/no-such-log/view",
            "threshold=1",
            StatusCode::NOT_FOUND,
        ),
    ] {
        let r = app
            .clone()
            .oneshot(request(
                "POST",
                path,
                Some("application/x-www-form-urlencoded"),
                form,
            ))
            .await
            .unwrap();
        assert_eq!(r.status(), status, "{path} {form}");
    }
    let host = Request::builder()
        .uri("/health")
        .header("host", "attacker.example:3000")
        .body(Body::empty())
        .unwrap();
    assert_eq!(
        app.clone().oneshot(host).await.unwrap().status(),
        StatusCode::BAD_REQUEST
    );
    for (name, value) in [
        ("origin", "https://attacker.example"),
        ("sec-fetch-site", "cross-site"),
    ] {
        let mut r = request("POST", "/demo", None, Body::empty());
        r.headers_mut().insert(name, value.parse().unwrap());
        assert_eq!(
            app.clone().oneshot(r).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
    }
    let get = app
        .oneshot(request(
            "GET",
            "/logs/no-such-log/export",
            None,
            Body::empty(),
        ))
        .await
        .unwrap();
    assert_eq!(get.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn encoded_markup_is_inert_html_and_original_json_data() {
    let app = app();
    let r = app
        .clone()
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(include_bytes!("../fixtures/semantics.xes")),
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::OK);
    let html = text(r).await;
    assert!(!html.contains("<img src=x onerror=alert(1)>"));
    assert!(html.contains("&lt;img"));
    let e = exported(&app).await;
    assert!(
        e["analysis"]["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["label"] == "<img src=x onerror=alert(1)>")
    );
}

#[tokio::test]
async fn byte_limit_is_413_before_xml_parse() {
    let app = app();
    let oversized = vec![b'x'; 20 * 1024 * 1024 + 1];
    let r = app
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(&oversized),
        ))
        .await
        .unwrap();
    assert_eq!(r.status(), StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test]
async fn whole_multipart_body_limit_returns_413_and_keeps_previous_export() {
    let app = app();
    let demo = app
        .clone()
        .oneshot(request("POST", "/demo", None, Body::empty()))
        .await
        .unwrap();
    assert_eq!(demo.status(), StatusCode::OK);
    let before = exported(&app).await;
    let oversized = vec![b'x'; 22 * 1024 * 1024];
    let response = app
        .clone()
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(&oversized),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::PAYLOAD_TOO_LARGE,
        "actual router status for whole multipart cap"
    );
    assert_eq!(exported(&app).await, before);
}

#[tokio::test]
async fn timestamp_error_has_one_based_case_event_context() {
    let app = app();
    let response = app
        .oneshot(request(
            "POST",
            "/logs",
            Some("multipart/form-data; boundary=qa-boundary"),
            multipart(include_bytes!("../fixtures/invalid-timestamp.xes")),
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        text(response).await.contains("Трасса 1, событие 1"),
        "user-visible one-based source location"
    );
}
