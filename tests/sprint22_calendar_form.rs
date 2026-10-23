//! Independent finite HTTP contract checks for semantic calendar-form rejection.
//! No PostgreSQL/role-revocation claim: live auth/storage checks are separate.
use axum::{
    Router,
    body::{Body, to_bytes},
    http::{Request, StatusCode, header},
};
use process_intelligence_rs::web::{AppState, router};
use serde_json::Value;
use tower::ServiceExt;

const NOT_SAVED: &str = "Настройки не сохранены.";
const SAVED_RESULTS: &str = "Результаты по последнему сохранённому календарю";

fn encode(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn calendar_form(zone: &str, offset: &str, start: &str, end: &str) -> String {
    [
        ("timezone", zone),
        ("offset_minutes", offset),
        ("weekdays", "7"),
        ("start_minute", start),
        ("end_minute", end),
        ("holidays", ""),
    ]
    .into_iter()
    .map(|(key, value)| format!("{key}={}", encode(value)))
    .collect::<Vec<_>>()
    .join("&")
}

fn post(path: &str, body: String, accepts: &[&str]) -> Request<Body> {
    let mut request = Request::builder()
        .method("POST")
        .uri(path)
        .header(header::HOST, "127.0.0.1:3000")
        .header(header::ORIGIN, "http://127.0.0.1:3000")
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .body(Body::from(body))
        .unwrap();
    for value in accepts {
        request
            .headers_mut()
            .append(header::ACCEPT, value.parse().unwrap());
    }
    request
}

async fn text(response: axum::response::Response) -> String {
    String::from_utf8(
        to_bytes(response.into_body(), 2 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap()
}

async fn exported(app: &Router) -> Value {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/logs/log-1/export")
                .header(header::HOST, "127.0.0.1:3000")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    serde_json::from_str(&text(response).await).unwrap()
}

async fn fixture(start: &str, end: &str) -> Router {
    let app = router(AppState::new(3000));
    let xes = format!(
        r#"<?xml version="1.0"?><log><trace><string key="concept:name" value="calendar"/><event><string key="concept:name" value="begin"/><date key="time:timestamp" value="{start}"/></event><event><string key="concept:name" value="end"/><date key="time:timestamp" value="{end}"/></event></trace></log>"#
    );
    let multipart = format!(
        "--calendar-qa\r\nContent-Disposition: form-data; name=\"file\"; filename=\"calendar.xes\"\r\nContent-Type: application/xml\r\n\r\n{xes}\r\n--calendar-qa--\r\n"
    );
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/logs")
                .header(header::HOST, "127.0.0.1:3000")
                .header(header::ORIGIN, "http://127.0.0.1:3000")
                .header(
                    header::CONTENT_TYPE,
                    "multipart/form-data; boundary=calendar-qa",
                )
                .body(Body::from(multipart))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::OK,
        "fixed tiny XES must import"
    );
    assert_eq!(exported(&app).await["analysis"]["events"], 2);
    app
}

#[tokio::test]
async fn explicit_accept_negotiation_preserves_json_defaults_and_saved_export() {
    let app = fixture("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z").await;
    let before = exported(&app).await;
    // Fixed protocol expectations, not derived from a production parser.
    let cases: &[(&[&str], bool)] = &[
        (&[], false),
        (&["application/json"], false),
        (&["*/*"], false),
        (&["text/*"], false),
        (&["text/html"], true),
        (&["Text/Html; charset=utf-8"], true),
        (&["text/html;q=1.000"], true),
        (&["text/html;q=0.001"], true),
        (&["text/html;q=0"], false),
        (&["text/html;q=0.000"], false),
        (&["text/html;q=1, application/json;q=0.001"], false),
        (&["application/json;q=1, text/html;q=0.2"], false),
        (&["application/json;q=0, text/html;q=1"], true),
        (&["text/html", "application/json;q=0.1"], false),
        (&["application/json;q=0", "text/html;q=0.5"], true),
        (&["text/html;q=bogus"], false),
        (&["text/html;q=1.001"], false),
        (&["text/html;q=0.0001"], false),
        (&["text/html;q=.5"], false),
        (&["text/html;q=-1"], false),
        (&["text/html", "application/json;q=bad"], false),
        (&["text/html;q=0.5;q=0.7"], false),
    ];
    let mut default_json = None;
    for (accepts, html) in cases {
        let response = app
            .clone()
            .oneshot(post(
                "/logs/log-1/calendar",
                calendar_form("Unknown/Nowhere", "0", "60", "240"),
                accepts,
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "{accepts:?}"
        );
        let content_type = response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .to_owned();
        if *html {
            assert!(content_type.starts_with("text/html"), "{accepts:?}");
            assert!(
                response.headers()[header::CACHE_CONTROL]
                    .to_str()
                    .unwrap()
                    .contains("no-store")
            );
            assert!(
                response.headers()[header::VARY]
                    .to_str()
                    .unwrap()
                    .split(',')
                    .any(|v| v.trim().eq_ignore_ascii_case("accept"))
            );
            let body = text(response).await;
            assert!(body.contains("role=\"alert\""));
            assert!(body.contains(NOT_SAVED) && body.contains(SAVED_RESULTS));
            assert!(body.contains("Unknown/Nowhere"));
        } else {
            assert!(content_type.starts_with("application/json"), "{accepts:?}");
            let raw = text(response).await;
            if let Some(expected) = &default_json {
                assert_eq!(
                    &raw, expected,
                    "JSON negotiation changed serialized error bytes"
                );
            } else {
                default_json = Some(raw.clone());
            }
            let body: Value = serde_json::from_str(&raw).unwrap();
            assert_eq!(body["code"], "calendar_timezone");
        }
        assert_eq!(
            exported(&app).await,
            before,
            "rejection changed saved export: {accepts:?}"
        );
    }
    let mut invalid_utf8 = post(
        "/logs/log-1/calendar",
        calendar_form("Unknown/Nowhere", "0", "60", "240"),
        &["text/html"],
    );
    invalid_utf8.headers_mut().append(
        header::ACCEPT,
        axum::http::HeaderValue::from_bytes(&[0xff]).unwrap(),
    );
    let response = app.clone().oneshot(invalid_utf8).await.unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("application/json")
    );
    assert_eq!(
        serde_json::from_str::<Value>(&text(response).await).unwrap()["code"],
        "calendar_timezone"
    );
    assert_eq!(exported(&app).await, before);
}

#[tokio::test]
async fn malicious_draft_and_semantic_integer_extremes_are_safe_and_not_saved() {
    let app = fixture("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z").await;
    let before = exported(&app).await;
    let malicious = "Unknown/\"><script>calendar_probe()</script>&";
    let response = app
        .clone()
        .oneshot(post(
            "/logs/log-1/calendar",
            calendar_form(malicious, "0", "60", "240"),
            &["text/html"],
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body = text(response).await;
    assert!(body.contains("&lt;script&gt;calendar_probe()&lt;/script&gt;"));
    assert!(body.contains("&quot;") && body.contains("&amp;"));
    assert!(!body.contains("<script>calendar_probe()"));
    assert!(body.contains(NOT_SAVED) && body.contains(SAVED_RESULTS));
    for (offset, start, needle) in [
        ("-2147483648", "60", "-2147483648"),
        ("0", "4294967295", "4294967295"),
    ] {
        let response = app
            .clone()
            .oneshot(post(
                "/logs/log-1/calendar",
                calendar_form("", offset, start, "240"),
                &["text/html"],
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body = text(response).await;
        assert!(body.contains(NOT_SAVED) && body.contains(needle));
    }
    assert_eq!(exported(&app).await, before);
}

#[tokio::test]
async fn overlong_draft_and_form_extractor_rejection_stay_non_html() {
    let app = fixture("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z").await;
    let before = exported(&app).await;
    let response = app
        .clone()
        .oneshot(post(
            "/logs/log-1/calendar",
            calendar_form(&"A".repeat(16385), "0", "60", "240"),
            &["text/html"],
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("application/json")
    );
    assert_eq!(
        serde_json::from_str::<Value>(&text(response).await).unwrap()["code"],
        "calendar_timezone"
    );
    let response = app
        .clone()
        .oneshot(post(
            "/logs/log-1/calendar",
            calendar_form("Europe/Berlin", "not-an-integer", "60", "240"),
            &["text/html"],
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        !response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("text/html")
    );
    assert!(!text(response).await.contains(NOT_SAVED));
    assert_eq!(exported(&app).await, before);
}

#[tokio::test]
async fn missing_log_does_not_disclose_or_render_a_draft() {
    let app = fixture("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z").await;
    let before = exported(&app).await;
    let response = app
        .clone()
        .oneshot(post(
            "/logs/log-missing/calendar",
            calendar_form("Unknown/Nowhere", "0", "60", "240"),
            &["text/html"],
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert!(
        response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("application/json")
    );
    let body = text(response).await;
    assert_eq!(
        serde_json::from_str::<Value>(&body).unwrap()["code"],
        "not_found"
    );
    assert!(!body.contains("Unknown/Nowhere") && !body.contains(SAVED_RESULTS));
    assert_eq!(exported(&app).await, before);
}

#[tokio::test]
async fn rejected_draft_then_valid_correction_preserves_manual_gap_fold_durations() {
    for (begin, end, expected) in [
        ("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z", 7_200_000),
        ("2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z", 14_400_000),
    ] {
        let app = fixture(begin, end).await;
        let response = app
            .clone()
            .oneshot(post(
                "/logs/log-1/calendar",
                calendar_form("Europe/Berlin", "0", "60", "240"),
                &["text/html"],
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SEE_OTHER);
        assert_eq!(response.headers()[header::LOCATION], "/logs/log-1/tools");
        let saved = exported(&app).await;
        assert_eq!(saved["business_durations"][0]["business_millis"], expected);
        let response = app
            .clone()
            .oneshot(post(
                "/logs/log-1/calendar",
                calendar_form("Europe/Berlin", "60", "60", "240"),
                &["text/html"],
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body = text(response).await;
        assert!(body.contains(NOT_SAVED) && body.contains(SAVED_RESULTS));
        assert!(body.contains(if expected == 7_200_000 {
            "2 ч"
        } else {
            "4 ч"
        }));
        assert_eq!(exported(&app).await, saved);
        let response = app
            .clone()
            .oneshot(post(
                "/logs/log-1/calendar",
                calendar_form("Europe/Berlin", "0", "60", "240"),
                &["application/json"],
            ))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::SEE_OTHER,
            "valid correction stays303 even for JSON client"
        );
        assert_eq!(
            exported(&app).await["business_durations"],
            saved["business_durations"]
        );
    }
}

#[tokio::test]
async fn optional_defaults_and_calendar_parse_errors_preserve_saved_context() {
    let app = fixture("2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z").await;
    let response = app
        .clone()
        .oneshot(post(
            "/logs/log-1/calendar",
            "offset_minutes=0&weekdays=7&start_minute=60&end_minute=240".into(),
            &["text/html"],
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
    let saved = exported(&app).await;
    assert!(saved["parameters"]["calendar"]["timezone"].is_null());
    assert_eq!(
        saved["parameters"]["calendar"]["holidays"],
        serde_json::json!([])
    );
    assert_eq!(
        saved["business_durations"][0]["business_millis"],
        10_800_000
    );
    for (key, value) in [("weekdays", "bad<day>"), ("holidays", "bad<date>")] {
        let mut body = calendar_form("", "0", "60", "240");
        body = if key == "weekdays" {
            body.replace("weekdays=7", &format!("weekdays={}", encode(value)))
        } else {
            body.replace("holidays=", &format!("holidays={}", encode(value)))
        };
        let response = app
            .clone()
            .oneshot(post("/logs/log-1/calendar", body.clone(), &["text/html"]))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let html = text(response).await;
        assert!(html.contains(NOT_SAVED) && html.contains(SAVED_RESULTS));
        assert!(!html.contains(value));
        assert!(html.contains(if key == "weekdays" {
            "bad&lt;day&gt;"
        } else {
            "bad&lt;date&gt;"
        }));
        let response = app
            .clone()
            .oneshot(post("/logs/log-1/calendar", body, &[]))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(
            serde_json::from_str::<Value>(&text(response).await).unwrap()["code"],
            "calendar"
        );
        assert_eq!(exported(&app).await, saved);
    }
}
