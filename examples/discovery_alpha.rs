use process_intelligence_rs::{discovery, domain::EventLog};
use sha2::{Digest, Sha256};
use std::io::Write;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("Usage: discovery_alpha INPUT_EVENTLOG_JSON NEW_OUTPUT_JSON".into());
    }
    if std::fs::metadata(&args[1])?.len() > 1_048_576 {
        return Err("Input exceeds 1MiB".into());
    }
    let bytes = std::fs::read(&args[1])?;
    if bytes.len() > 1_048_576 {
        return Err("Input exceeds 1MiB".into());
    }
    let log: EventLog = serde_json::from_slice(&bytes)?;
    let result = match discovery::discover(&log, &|| false) {
        Ok(result) => {
            serde_json::json!({"status":"ok","input_sha256":format!("{:x}",Sha256::digest(&bytes)),"discovery":result})
        }
        Err(error) => serde_json::json!({"status":"rejected","error":error}),
    };
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&args[2])?;
    out.write_all(&serde_json::to_vec_pretty(&result)?)?;
    out.write_all(b"\n")?;
    Ok(())
}
