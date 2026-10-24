//! Diagnostic for a fixed trusted corpus; never called by the application.
use process_intelligence_rs::service_preview::preview_xes;
use process_mining::core::event_data::case_centric::xes::{XESImportOptions, import_xes_slice};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--trusted-corpus")) {
        return Err("usage: full_service_observer --trusted-corpus FIXTURE".into());
    }
    let path = PathBuf::from(args.next().ok_or("fixture required")?);
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    let mut bytes = Vec::new();
    File::open(&path)?
        .take(20 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 20 * 1024 * 1024 {
        return Err("fixture byte limit".into());
    }
    let sha256 = format!("{:x}", Sha256::digest(&bytes));
    let preview = match preview_xes(&bytes) {
        Ok(value) => json!({"status":"ok", "value":value}),
        Err(error) => json!({"status":"rejected", "error":error}),
    };
    // The raw parser is observed separately from actual application admission.
    // No arbitrary external input or parser-security claim is made here.
    let mut reader = quick_xml::Reader::from_reader(bytes.as_slice());
    let mut safe_for_raw_observation = true;
    loop {
        match reader.read_event() {
            Ok(quick_xml::events::Event::DocType(_)) => {
                safe_for_raw_observation = false;
                break;
            }
            Ok(quick_xml::events::Event::Eof) => break,
            Err(_) => {
                safe_for_raw_observation = false;
                break;
            }
            _ => {}
        }
    }
    let raw = if safe_for_raw_observation {
        match std::panic::catch_unwind(|| {
            import_xes_slice(
                &bytes,
                false,
                XESImportOptions {
                    verbose: false,
                    sort_events_with_timestamp_key: None,
                    ..Default::default()
                },
            )
        }) {
            Ok(Ok(log)) => json!({"status":"ok", "log":log}),
            Ok(Err(_)) => json!({"status":"rejected", "code":"rust4pm_parse_error"}),
            Err(_) => json!({"status":"rejected", "code":"rust4pm_parser_panic"}),
        }
    } else {
        json!({"status":"not_in_run", "code":"doctype_or_malformed_xml"})
    };
    println!(
        "{}",
        json!({
            "schema_version":1,
            "input_sha256":sha256,
            "scope":"Fixed trusted corpus only; raw Rust4PM observation is separate from application preview admission; no persistence",
            "raw_rust4pm":raw,
            "preview":preview
        })
    );
    Ok(())
}
