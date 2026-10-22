//! Standalone generic, bounded converter; no product runtime or external engine changes.
mod conversion;
use conversion::{Failure, MAX_BYTES, require, sha};
use serde_json::json;
use std::{
    fs,
    io::{Read, Write},
    path::Path,
};
fn no_reparse(path: &Path) -> conversion::Result<()> {
    let metadata = fs::symlink_metadata(path).map_err(|_| Failure::new("input_missing"))?;
    require(
        !metadata.file_type().is_symlink(),
        "reparse_input_forbidden",
    )?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        require(
            metadata.file_attributes() & 0x400 == 0,
            "reparse_input_forbidden",
        )?;
    }
    Ok(())
}
fn read(path: &Path) -> conversion::Result<Vec<u8>> {
    no_reparse(path)?;
    let metadata = fs::metadata(path).map_err(|_| Failure::new("input_missing"))?;
    require(
        metadata.is_file() && metadata.len() <= MAX_BYTES as u64,
        "regular_bounded_input_required",
    )?;
    let file = fs::File::open(path).map_err(|_| Failure::new("input_read"))?;
    let mut data = Vec::new();
    file.take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut data)
        .map_err(|_| Failure::new("input_read"))?;
    require(data.len() <= MAX_BYTES, "byte_limit")?;
    Ok(data)
}
fn write_new(path: &Path, data: &[u8], created: &mut bool) -> std::io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    *created = true;
    file.write_all(data)?;
    file.sync_all()
}
fn publish(
    output: &Path,
    payload: Option<(&str, &[u8])>,
    report: &[u8],
) -> Result<(), Box<dyn std::error::Error>> {
    require(!output.exists(), "fresh_output_directory_required")?;
    let parent = output
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    no_reparse(parent)?;
    fs::create_dir(output)?;
    let pending_report = output.join(".report.pending");
    let pending_payload = output.join(".payload.pending");
    let report_path = output.join("report.json");
    let payload_path = payload.map(|(extension, _)| output.join(format!("payload.{extension}")));
    let (
        mut report_pending_created,
        mut payload_pending_created,
        mut report_published,
        mut payload_published,
    ) = (false, false, false, false);
    let result = (|| -> std::io::Result<()> {
        if let Some((_, bytes)) = payload {
            write_new(&pending_payload, bytes, &mut payload_pending_created)?;
        }
        write_new(&pending_report, report, &mut report_pending_created)?;
        // Exclusive hard-link publication cannot overwrite an injected existing target.
        // Both complete, synchronized files exist before either name is published.
        fs::hard_link(&pending_report, &report_path)?;
        report_published = true;
        if let Some(path) = &payload_path {
            fs::hard_link(&pending_payload, path)?;
            payload_published = true;
        }
        fs::remove_file(&pending_report)?;
        report_pending_created = false;
        if payload.is_some() {
            fs::remove_file(&pending_payload)?;
            payload_pending_created = false;
        }
        Ok(())
    })();
    if result.is_err() {
        if report_pending_created {
            let _ = fs::remove_file(&pending_report);
        }
        if payload_pending_created {
            let _ = fs::remove_file(&pending_payload);
        }
        if report_published {
            let _ = fs::remove_file(&report_path);
        }
        if payload_published && let Some(path) = payload_path {
            let _ = fs::remove_file(path);
        }
        let _ = fs::remove_dir(output);
    }
    result.map_err(Into::into)
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    if !(args.len() == 5 || args.len() == 6 && args[5] == "--allow-metadata-loss") {
        return Err(
            "usage: pi_convert FROM TO INPUT NEW_OUTPUT_DIRECTORY [--allow-metadata-loss]".into(),
        );
    }
    let from = args[1].to_str().ok_or("format_utf8")?;
    let to = args[2].to_str().ok_or("format_utf8")?;
    let input = Path::new(&args[3]);
    let output = Path::new(&args[4]);
    let allow = args.len() == 6;
    let source = read(input)?;
    let source_hash = sha(&source);
    let conversion = conversion::convert(from, to, &source, allow);
    // Re-read the actual input before publication. No original bytes are written as a sidecar.
    require(sha(&read(input)?) == source_hash, "source_changed")?;
    let mut report = json!({"schema_version":1,"method_sha256":conversion::METHOD,"from":from,"to":to,"allow_metadata_loss":allow,"input_sha256":source_hash,"input_bytes":source.len(),"sources":conversion::sources(),"target_sha256":null,"target_bytes":null,"payload_file":null,"not_general_format_support":true});
    match conversion {
        Ok(result) => {
            report["status"] = json!("converted");
            report["reason"] = result
                .evidence
                .get("reason")
                .cloned()
                .unwrap_or_else(|| json!("full_graph_bijection"));
            report["target_sha256"] = json!(sha(&result.payload));
            report["target_bytes"] = json!(result.payload.len());
            report["payload_file"] = json!(format!("payload.{}", result.extension));
            report["evidence"] = result.evidence;
            let bytes = serde_json::to_vec_pretty(&report)?;
            require(bytes.len() <= 4 * 1024 * 1024, "report_byte_limit")?;
            publish(output, Some((result.extension, &result.payload)), &bytes)?;
        }
        Err(error) => {
            report["status"] = json!(error.status);
            report["reason"] = json!(error.reason);
            report["details"] = error.details;
            let bytes = serde_json::to_vec_pretty(&report)?;
            require(bytes.len() <= 4 * 1024 * 1024, "report_byte_limit")?;
            publish(output, None, &bytes)?;
            std::process::exit(2);
        }
    }
    Ok(())
}
