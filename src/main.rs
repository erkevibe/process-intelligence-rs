use process_intelligence_rs::web::{AppState, router};

#[tokio::main]
async fn main() -> Result<std::process::ExitCode, Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 2 && args[0] == "--verify-quality-report" {
        use std::io::Read;
        let file = std::fs::File::open(&args[1])?;
        let mut bytes = Vec::new();
        file.take(2 * 1024 * 1024 + 128 * 1024 + 16 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        let result = process_intelligence_rs::bpmn_quality::saved::verify_export_bytes(&bytes);
        return Ok(match result {
            Ok(value) => {
                println!("{value}");
                std::process::ExitCode::SUCCESS
            }
            Err(e) => {
                println!(
                    "{}",
                    serde_json::json!({"status":"quality_report_verification_refused","code":e.code,"message":e.message})
                );
                std::process::ExitCode::FAILURE
            }
        });
    }
    if !args.is_empty() {
        if args == ["--cleanup-storage-verify"] || args == ["--cleanup-storage-apply"] {
            let mode = if args[0] == "--cleanup-storage-verify" {
                "verify"
            } else {
                "apply"
            };
            let result =
                tokio::task::spawn_blocking(move || process_intelligence_rs::cleanup::run(mode))
                    .await?;
            return Ok(match result {
                Ok(value) => {
                    println!("{value}");
                    match value["outcome"].as_str() {
                        Some("cleanup_outcome_unconfirmed") => std::process::ExitCode::from(2),
                        Some("cleanup_committed_receipt_failed") => std::process::ExitCode::from(3),
                        Some("cleanup_verified" | "cleanup_empty" | "cleanup_committed") => {
                            std::process::ExitCode::SUCCESS
                        }
                        _ => std::process::ExitCode::FAILURE,
                    }
                }
                Err(error) => {
                    println!(
                        "{}",
                        serde_json::json!({"outcome":"cleanup_refused","code":error.code,"message":error.message})
                    );
                    std::process::ExitCode::FAILURE
                }
            });
        }
        if args != ["--migrate-storage"] {
            return Err(std::io::Error::other("Supported options: --migrate-storage, --cleanup-storage-verify, --cleanup-storage-apply, --verify-quality-report FILE").into());
        }
        let url = process_intelligence_rs::configuration::database_url()?;
        tokio::task::spawn_blocking(move || process_intelligence_rs::storage::migrate_offline(url))
            .await?
            .map_err(|e| std::io::Error::other(e.message))?;
        return Ok(std::process::ExitCode::SUCCESS);
    }
    let port: u16 = std::env::var("PORT")
        .unwrap_or_else(|_| "3000".into())
        .parse()?;
    let state = if std::env::var("PI_EPHEMERAL").as_deref() == Ok("1") {
        tracing::warn!("ephemeral_mode_enabled");
        AppState::new(port)
    } else {
        let url = process_intelligence_rs::configuration::database_url()?;
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
    Ok(std::process::ExitCode::SUCCESS)
}
