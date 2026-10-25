use crate::web::{AppState, router};
use axum::{
    body::Body,
    http::{Request, StatusCode, header},
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

async fn request(
    state: &AppState,
    method: &str,
    path: &str,
    body: &str,
    cookie: Option<&str>,
    accept: &str,
    content_type: &str,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header(header::HOST, "127.0.0.1:3139")
        .header(header::ORIGIN, "http://127.0.0.1:3139")
        .header(header::ACCEPT, accept)
        .header(header::CONTENT_TYPE, content_type);
    if let Some(cookie) = cookie {
        req = req.header(header::COOKIE, cookie);
    }
    let response = router(state.clone())
        .oneshot(req.body(Body::from(body.to_owned())).unwrap())
        .await
        .unwrap();
    let (parts, body) = response.into_parts();
    (
        parts.status,
        parts.headers,
        body.collect().await.unwrap().to_bytes().to_vec(),
    )
}
async fn form(
    state: &AppState,
    path: &str,
    body: &str,
    cookie: &str,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    request(
        state,
        "POST",
        path,
        body,
        Some(cookie),
        "application/json",
        "application/x-www-form-urlencoded",
    )
    .await
}
async fn backup(state: &AppState, cookie: &str) -> Vec<u8> {
    let (status, _, raw) = request(
        state,
        "GET",
        "/backup",
        "",
        Some(cookie),
        "application/json",
        "text/plain",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    raw
}
async fn upload(state: &AppState, cookie: &str) -> String {
    let body = "--S35\r\nContent-Disposition: form-data; name=\"file\"; filename=\"fixture.csv\"\r\nContent-Type: text/csv\r\n\r\ncase,activity,start,end\nc,<script>alert(1)</script>,2020-01-01T00:00:00,2020-01-01T00:01:00\nc,B,2020-01-01T00:02:00,2020-01-01T00:03:00\r\n--S35--\r\n";
    let (status, _, raw) = request(
        state,
        "POST",
        "/csv/preview",
        body,
        Some(cookie),
        "text/html",
        "multipart/form-data; boundary=S35",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let html = String::from_utf8(raw).unwrap();
    assert!(html.contains("name=\"naive_timestamp_offset\""));
    assert!(html.contains("name=\"start_timestamp_column\""));
    let token = html
        .split_once("name=\"token\" value=\"")
        .unwrap()
        .1
        .split('"')
        .next()
        .unwrap();
    assert_eq!(token.len(), 32);
    token.into()
}
fn fields(token: &str) -> String {
    format!(
        "token={token}&case_column=case&activity_column=activity&timestamp_column=end&start_timestamp_column=start&naive_timestamp_offset=%2B00%3A00&lifecycle_column=&order=source&threshold_days=28&cohort=all"
    )
}

#[tokio::test]
#[ignore = "requires explicitly owned fresh S35_CSV_DATABASE_URL; never use a working database"]
async fn postgres_csv_preview_is_read_only_scoped_bounded_and_consumed_on_import() {
    assert_eq!(std::env::var("S35_CSV_OWNED_FIXTURE").as_deref(), Ok("yes"));
    let url = std::env::var("S35_CSV_DATABASE_URL").expect("fresh fixture URL");
    let config: postgres::Config = url.parse().unwrap();
    assert_eq!(config.get_dbname(), Some("pi_s35_csv_test"));
    assert_eq!(config.get_user(), Some("pi_s35_test"));
    assert!(
        matches!(config.get_hosts(), [postgres::config::Host::Tcp(host)] if host == "127.0.0.1")
    );
    let fixture_url = url.clone();
    let count: i64 = tokio::task::spawn_blocking(move || {
        let mut check = postgres::Client::connect(&fixture_url, postgres::NoTls).unwrap();
        check
            .query_one(
                "SELECT count(*) FROM pg_tables WHERE schemaname='public'",
                &[],
            )
            .unwrap()
            .get(0)
    })
    .await
    .unwrap();
    assert_eq!(count, 0, "fixture must be a newly created empty database");
    let state = tokio::task::spawn_blocking(move || AppState::open(3139, url).unwrap())
        .await
        .unwrap();
    let (status, headers, _) = request(
        &state,
        "POST",
        "/setup",
        "username=s35_owner&password=S35OwnerFixturePassword123",
        None,
        "application/json",
        "application/x-www-form-urlencoded",
    )
    .await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    let owner = headers[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let token = upload(&state, &owner).await;
    let params = fields(&token);
    let before = backup(&state, &owner).await;
    let (status, headers, raw) = form(
        &state,
        "/csv/performance",
        &(params.clone() + "&output=json"),
        &owner,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(headers[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        headers[header::CONTENT_DISPOSITION],
        "attachment; filename=csv-performance.json"
    );
    let report: Value = serde_json::from_slice(&raw).unwrap();
    assert_eq!(report["cohorts"][0]["cases"], 1);
    assert_eq!(report["cohorts"][0]["events"], 2);
    assert_eq!(
        report["cohorts"][0]["cycle"]["sum_nanoseconds"],
        "180000000000"
    );
    assert!(!String::from_utf8_lossy(&raw).contains(&token));
    assert_eq!(backup(&state, &owner).await, before);
    let (status, _, html) = request(
        &state,
        "POST",
        "/csv/performance",
        &params,
        Some(&owner),
        "text/html",
        "application/x-www-form-urlencoded",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let html = String::from_utf8(html).unwrap();
    assert!(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
    assert!(!html.contains("<script>alert(1)</script>"));
    assert!(html.contains("В журнал импортируется одна отметка"));
    let cpu = state.cpu.clone().acquire_owned().await.unwrap();
    assert_eq!(
        form(&state, "/csv/performance", &params, &owner).await.0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    drop(cpu);
    let slots = state
        .platform
        .as_ref()
        .unwrap()
        .payload_slots
        .clone()
        .acquire_many_owned(2)
        .await
        .unwrap();
    assert_eq!(
        form(&state, "/csv/performance", &params, &owner).await.0,
        StatusCode::SERVICE_UNAVAILABLE
    );
    drop(slots);
    assert_eq!(backup(&state, &owner).await, before);
    let too_large = format!("{params}&padding={}", "x".repeat(65536));
    assert_eq!(
        form(&state, "/csv/performance", &too_large, &owner).await.0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    // A different authenticated actor must not reuse this source token.
    assert_eq!(
        form(
            &state,
            "/users",
            "username=s35_other&password=S35OtherFixturePassword123",
            &owner
        )
        .await
        .0,
        StatusCode::SEE_OTHER
    );
    let (status, headers, _) = request(
        &state,
        "POST",
        "/login",
        "username=s35_other&password=S35OtherFixturePassword123",
        None,
        "application/json",
        "application/x-www-form-urlencoded",
    )
    .await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    let other = headers[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let (status, _, raw) = form(&state, "/csv/performance", &params, &other).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        serde_json::from_slice::<Value>(&raw).unwrap()["code"],
        "preview_expired"
    );
    let project = state
        .platform
        .as_ref()
        .unwrap()
        .auth
        .actor(owner.strip_prefix("pi_session=").unwrap())
        .unwrap()
        .project_id;
    assert_eq!(
        form(
            &state,
            &format!("/projects/{project}/members"),
            "username=s35_other&role=viewer",
            &owner
        )
        .await
        .0,
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        form(&state, &format!("/projects/{project}/open"), "", &other)
            .await
            .0,
        StatusCode::SEE_OTHER
    );
    assert_eq!(
        form(&state, "/csv/performance", &params, &other).await.0,
        StatusCode::FORBIDDEN
    );
    let before_import = backup(&state, &owner).await;
    assert_eq!(
        form(
            &state,
            "/csv/performance",
            &params.replace("%2B00%3A00", "%2B14%3A01"),
            &owner
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(backup(&state, &owner).await, before_import);
    let (status, _, _) = form(&state, "/csv/import", &params, &owner).await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    assert_eq!(
        form(&state, "/csv/performance", &params, &owner).await.0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let second = upload(&state, &owner).await;
    state
        .platform
        .as_ref()
        .unwrap()
        .pending
        .lock()
        .unwrap()
        .get_mut(&second)
        .unwrap()
        .expires = 0;
    let (status, _, raw) = form(&state, "/csv/performance", &fields(&second), &owner).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        serde_json::from_slice::<Value>(&raw).unwrap()["code"],
        "preview_expired"
    );
}
