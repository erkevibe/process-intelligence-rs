//! Owned PostgreSQL fixture; synthetic 625/9070/24/143 journal, never production.
use crate::web::{AppState, router};
use axum::{
    body::Body,
    http::{Request, StatusCode, header},
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

async fn request(
    state: &AppState,
    method: &str,
    path: &str,
    body: Vec<u8>,
    cookie: &str,
    ctype: &str,
) -> (u16, axum::http::HeaderMap, Vec<u8>) {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header(header::HOST, "127.0.0.1:3138")
        .header(header::ORIGIN, "http://127.0.0.1:3138")
        .header(header::ACCEPT, "application/json")
        .header(header::CONTENT_TYPE, ctype);
    if !cookie.is_empty() {
        request = request.header(header::COOKIE, cookie);
    }
    let result = router(state.clone())
        .oneshot(request.body(Body::from(body)).unwrap())
        .await
        .unwrap();
    let (parts, body) = result.into_parts();
    (
        parts.status.as_u16(),
        parts.headers,
        body.collect().await.unwrap().to_bytes().to_vec(),
    )
}
async fn form(
    state: &AppState,
    path: &str,
    body: &str,
    cookie: &str,
) -> (u16, axum::http::HeaderMap, Vec<u8>) {
    request(
        state,
        "POST",
        path,
        body.as_bytes().to_vec(),
        cookie,
        "application/x-www-form-urlencoded",
    )
    .await
}
async fn get(state: &AppState, path: &str, cookie: &str) -> Vec<u8> {
    let (s, _, b) = request(state, "GET", path, vec![], cookie, "text/plain").await;
    assert_eq!(s, 200, "{path}");
    b
}
fn hidden(html: &[u8], name: &str) -> String {
    String::from_utf8_lossy(html)
        .split_once(&format!("name=\"{name}\" value=\""))
        .unwrap()
        .1
        .split('"')
        .next()
        .unwrap()
        .into()
}
async fn wait(state: &AppState, path: &str, cookie: &str) -> Value {
    let end = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let v: Value = serde_json::from_slice(&get(state, path, cookie).await).unwrap();
        if v["snapshot"]["state"] == "completed" {
            return v;
        }
        assert!(
            !matches!(
                v["snapshot"]["state"].as_str(),
                Some("failed" | "cancelled" | "interrupted")
            ),
            "{v}"
        );
        assert!(std::time::Instant::now() < end);
        tokio::task::yield_now().await;
    }
}
fn synthetic() -> String {
    let mut xml = String::from("<log>");
    for i in 0..625 {
        let variant = i % 143;
        let length = if (53..133).contains(&variant) { 15 } else { 14 };
        xml.push_str(&format!(
            "<trace><string key=\"concept:name\" value=\"c{i}\"/>"
        ));
        for j in 0..length {
            let label = match j {
                0 => variant % 24,
                1..=8 => (variant >> (j - 1)) & 1,
                _ => j % 24,
            };
            xml.push_str(&format!(
                "<event><string key=\"concept:name\" value=\"A{label:02}\"/></event>"
            ));
        }
        xml.push_str("</trace>");
    }
    xml.push_str("</log>");
    xml
}
#[tokio::test]
#[ignore = "fresh explicitly owned S36_FULL_DATABASE_URL required"]
async fn postgres_full_log_http_publication_replay_restart_and_backup() {
    assert_eq!(
        std::env::var("S36_FULL_OWNED_FIXTURE").as_deref(),
        Ok("yes")
    );
    let url = std::env::var("S36_FULL_DATABASE_URL").expect("owned fixture URL");
    let config: postgres::Config = url.parse().unwrap();
    assert_eq!(config.get_dbname(), Some("pi_s36_full_test"));
    assert!(matches!(config.get_hosts(),[postgres::config::Host::Tcp(host)] if host=="127.0.0.1"));
    assert!(matches!(
        config.get_user(),
        Some("pi_s36_test" | "pi_s21_app")
    ));
    let cloned = url.clone();
    tokio::task::spawn_blocking(move || {
        let mut p = postgres::Client::connect(&cloned, postgres::NoTls).unwrap();
        let n: i64 = p
            .query_one(
                "SELECT count(*) FROM pg_tables WHERE schemaname='public'",
                &[],
            )
            .unwrap()
            .get(0);
        assert_eq!(n, 0);
    })
    .await
    .unwrap();
    let u = url.clone();
    let state = tokio::task::spawn_blocking(move || AppState::open(3138, u).unwrap())
        .await
        .unwrap();
    let (s, h, _) = form(
        &state,
        "/setup",
        "username=s36_owner&password=S36OwnedTestPassword123",
        "",
    )
    .await;
    assert_eq!(s, 303);
    let cookie = h[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let xml = synthetic();
    let log = crate::event_io::parse_xes(xml.as_bytes()).unwrap();
    let analysis = crate::mining::analyze(&log);
    assert_eq!(
        (
            analysis.cases,
            analysis.events,
            analysis.activities,
            analysis.variants.len()
        ),
        (625, 9070, 24, 143)
    );
    let body = format!(
        "--S36\r\nContent-Disposition: form-data; name=\"file\"; filename=\"full-synthetic.xes\"\r\nContent-Type: application/xml\r\n\r\n{xml}\r\n--S36--\r\n"
    );
    let (s, _, b) = request(
        &state,
        "POST",
        "/logs",
        body.into_bytes(),
        &cookie,
        "multipart/form-data; boundary=S36",
    )
    .await;
    assert_eq!(
        s,
        StatusCode::OK.as_u16(),
        "{}",
        String::from_utf8_lossy(&b)
    );
    let list = get(&state, "/logs", &cookie).await;
    let text = String::from_utf8_lossy(&list);
    let log_id = text
        .split("/logs/")
        .find_map(|s| {
            s.split('"')
                .next()
                .filter(|s| s.starts_with("log-") && !s.contains('/'))
        })
        .unwrap()
        .to_owned();
    let action = format!("/logs/{log_id}/discovery/jobs");
    let html = get(&state, &format!("/logs/{log_id}/discovery/new"), &cookie).await;
    let key = hidden(&html, "request_key");
    let version = hidden(&html, "analysis_version");
    let before = get(&state, "/backup", &cookie).await;
    let (s, _, _) = form(
        &state,
        &action,
        &format!("analysis_version={version}&model_name=full&request_key={key}"),
        &cookie,
    )
    .await;
    assert_eq!(s, 422);
    assert_eq!(before, get(&state, "/backup", &cookie).await);
    let fields = format!(
        "profile=full_log_state_machine_v1&analysis_version={version}&model_name=full&request_key={key}"
    );
    let (s, _, b) = form(&state, &action, &fields, &cookie).await;
    assert_eq!(s, 202, "{}", String::from_utf8_lossy(&b));
    let meta: Value = serde_json::from_slice(&b).unwrap();
    let job = meta["snapshot"]["id"].as_str().unwrap();
    let done = wait(&state, &format!("/discovery/jobs/{job}"), &cookie).await;
    let report = get(&state, &format!("/discovery/jobs/{job}/report"), &cookie).await;
    let report_json: Value = serde_json::from_slice(&report).unwrap();
    assert_eq!(report_json["algorithm"], crate::dfg_discovery::ALGORITHM);
    assert_eq!(
        report_json["artifact"]["output"]["training_report"]["trace_count"],
        625
    );
    let (s, _, replay) = form(&state, &action, &fields, &cookie).await;
    assert_eq!(s, 202);
    assert_eq!(
        serde_json::from_slice::<Value>(&replay).unwrap()["snapshot"]["id"],
        job
    );
    let model = done["model_id"].as_str().unwrap();
    let html = get(&state, &format!("/models/{model}/quality/new"), &cookie).await;
    let qfields = format!(
        "profile=full_log_state_machine_v1&log_id={log_id}&revision={}&request_key={}",
        hidden(&html, "revision"),
        hidden(&html, "request_key")
    );
    let (s, _, b) = form(
        &state,
        &format!("/models/{model}/quality/jobs"),
        &qfields,
        &cookie,
    )
    .await;
    assert_eq!(s, 202);
    let meta: Value = serde_json::from_slice(&b).unwrap();
    let quality = meta["snapshot"]["id"].as_str().unwrap();
    wait(&state, &format!("/quality/jobs/{quality}"), &cookie).await;
    let qreport = get(&state, &format!("/quality/jobs/{quality}/report"), &cookie).await;
    assert_eq!(
        crate::full_log_saved::verify_any(&qreport).unwrap()["numeric_replay"],
        true
    );
    let stable = get(&state, "/backup", &cookie).await;
    let project = done["source_project_id"].as_str().unwrap().to_owned();
    drop(state);
    let u = url.clone();
    let state = tokio::task::spawn_blocking(move || {
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match AppState::open(3138, u.clone()) {
                Ok(s) => break s,
                Err(e) if e.code == "app_already_running" && std::time::Instant::now() < until => {
                    std::thread::yield_now()
                }
                Err(e) => panic!("{}", e.code),
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(
        qreport,
        get(&state, &format!("/quality/jobs/{quality}/report"), &cookie).await
    );
    assert_eq!(
        report,
        get(&state, &format!("/discovery/jobs/{job}/report"), &cookie).await
    );
    assert_eq!(stable, get(&state, "/backup", &cookie).await);
    let db = state.platform.as_ref().unwrap().database.clone();
    tokio::task::spawn_blocking(move || {
        let repo = crate::repository_v2::load(&db, &project).unwrap();
        crate::platform::validate_backup(&repo).unwrap();
    })
    .await
    .unwrap();
    println!(
        "{}",
        json!({"status":"S36_FULL_LOG_HTTP_PG_RESTART_BACKUP_PASS","cases":625,"events":9070,"variants":143,"activities":24})
    );
}
