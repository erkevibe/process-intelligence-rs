use process_intelligence_rs::web::{AppState, router};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();
    let port: u16 = std::env::var("PORT")
        .unwrap_or_else(|_| "3000".into())
        .parse()?;
    let state = if std::env::var("PI_EPHEMERAL").as_deref() == Ok("1") {
        tracing::warn!("ephemeral_mode_enabled");
        AppState::new(port)
    } else {
        let url=std::env::var("PI_DATABASE_URL").map_err(|_|std::io::Error::other("PI_DATABASE_URL is required. Run tools/run-windows.ps1 to start the local PostgreSQL platform."))?;
        tokio::task::spawn_blocking(move || AppState::open(port, url))
            .await?
            .map_err(|e| std::io::Error::other(e.message))?
    };
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    tracing::info!(port, version = env!("CARGO_PKG_VERSION"), "app_started");
    axum::serve(listener, router(state))
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
            tracing::info!("app_stopping");
        })
        .await?;
    Ok(())
}
