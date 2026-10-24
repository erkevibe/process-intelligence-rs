use crate::{
    configuration::PublicOrigin,
    web::{AppState, router},
};
use axum::{
    body::Body,
    http::{HeaderValue, Request, StatusCode, header},
};
use tower::ServiceExt;
#[tokio::test]
async fn exact_public_origin_and_local_defaults_reject_spoofed_or_malformed_headers() {
    async fn run(
        state: AppState,
        method: &str,
        host: &str,
        origins: &[HeaderValue],
        extra: &[(&str, &str)],
    ) -> StatusCode {
        let mut req = Request::builder()
            .method(method)
            .uri("/health")
            .header(header::HOST, host)
            .body(Body::empty())
            .unwrap();
        for origin in origins {
            req.headers_mut().append(header::ORIGIN, origin.clone());
        }
        for (k, v) in extra {
            req.headers_mut().insert(
                axum::http::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                HeaderValue::from_str(v).unwrap(),
            );
        }
        router(state).oneshot(req).await.unwrap().status()
    }
    let local = AppState::new(3147);
    assert_eq!(
        run(local.clone(), "GET", "localhost:3147", &[], &[]).await,
        StatusCode::OK
    );
    assert_eq!(
        run(
            local.clone(),
            "GET",
            "process.example",
            &[],
            &[("x-forwarded-host", "localhost:3147")]
        )
        .await,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        run(local.clone(), "GET", "localhost:443", &[], &[]).await,
        StatusCode::BAD_REQUEST
    );
    let public = local
        .with_public_origin(Some(
            PublicOrigin::parse("https://PROCESS.example:443/").unwrap(),
        ))
        .unwrap();
    assert_eq!(
        run(public.clone(), "GET", "process.example", &[], &[]).await,
        StatusCode::OK
    );
    let good = HeaderValue::from_static("https://process.example");
    for host in ["process.example:443", "PROCESS.EXAMPLE:443"] {
        assert_eq!(
            run(public.clone(), "GET", host, &[], &[]).await,
            StatusCode::OK
        );
        assert_eq!(
            run(
                public.clone(),
                "POST",
                host,
                std::slice::from_ref(&good),
                &[]
            )
            .await,
            StatusCode::METHOD_NOT_ALLOWED
        );
    }
    for host in [
        "process.example:444",
        "process.example:0443",
        "process.example:443:443",
        "user@process.example:443",
        "process.example.evil:443",
    ] {
        assert_eq!(
            run(public.clone(), "GET", host, &[], &[]).await,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        run(
            public.clone(),
            "POST",
            "process.example:443",
            &[HeaderValue::from_static("https://process.example:443")],
            &[]
        )
        .await,
        StatusCode::FORBIDDEN
    );
    for (origin, authority) in [
        ("https://localhost", "localhost"),
        ("https://[::1]", "[::1]"),
    ] {
        let state = AppState::new(3147)
            .with_public_origin(Some(PublicOrigin::parse(origin).unwrap()))
            .unwrap();
        for host in [authority.to_owned(), format!("{authority}:443")] {
            assert_eq!(
                run(state.clone(), "GET", &host, &[], &[]).await,
                StatusCode::OK
            );
        }
    }
    let nondefault = AppState::new(3147)
        .with_public_origin(Some(
            PublicOrigin::parse("https://process.example:8443").unwrap(),
        ))
        .unwrap();
    assert_eq!(
        run(nondefault.clone(), "GET", "process.example:8443", &[], &[]).await,
        StatusCode::OK
    );
    for host in [
        "process.example",
        "process.example:443",
        "process.example:8443:443",
    ] {
        assert_eq!(
            run(nondefault.clone(), "GET", host, &[], &[]).await,
            StatusCode::BAD_REQUEST
        );
    }
    assert_eq!(
        run(
            public.clone(),
            "POST",
            "process.example",
            std::slice::from_ref(&good),
            &[]
        )
        .await,
        StatusCode::METHOD_NOT_ALLOWED
    );
    assert_eq!(
        run(public.clone(), "POST", "process.example", &[], &[]).await,
        StatusCode::METHOD_NOT_ALLOWED
    );
    for bad in [
        HeaderValue::from_static("https://evil.example"),
        HeaderValue::from_static("null"),
        HeaderValue::from_static("http://process.example"),
        HeaderValue::from_bytes(&[0xff]).unwrap(),
    ] {
        assert_eq!(
            run(
                public.clone(),
                "POST",
                "process.example",
                &[bad],
                &[("x-forwarded-proto", "https")]
            )
            .await,
            StatusCode::FORBIDDEN
        );
    }
    assert_eq!(
        run(
            public.clone(),
            "POST",
            "process.example",
            &[good.clone(), good.clone()],
            &[]
        )
        .await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        run(
            public.clone(),
            "POST",
            "process.example",
            &[good],
            &[("sec-fetch-site", "cross-site")]
        )
        .await,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        run(
            public.clone(),
            "GET",
            "evil.example",
            &[],
            &[
                ("x-forwarded-host", "process.example"),
                ("x-forwarded-proto", "https")
            ]
        )
        .await,
        StatusCode::BAD_REQUEST
    );
    let mut duplicate = Request::builder()
        .uri("/health")
        .header(header::HOST, "process.example")
        .body(Body::empty())
        .unwrap();
    duplicate
        .headers_mut()
        .append(header::HOST, HeaderValue::from_static("evil.example"));
    assert_eq!(
        router(public).oneshot(duplicate).await.unwrap().status(),
        StatusCode::BAD_REQUEST
    );
    assert!(
        AppState::new(3147)
            .with_public_origin(Some(PublicOrigin::parse("https://localhost:3147").unwrap()))
            .is_err()
    );
}
