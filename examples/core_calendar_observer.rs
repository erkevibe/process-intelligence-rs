//! Observe the real production calendar on the agreed, trusted frozen inputs.
use chrono::{DateTime, Utc};
use process_intelligence_rs::calendar::{self, CalendarSpec};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{fs::File, io::Read, path::PathBuf};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Input {
    schema_version: u8,
    id: String,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    calendar: CalendarSpec,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--trusted-corpus")) {
        return Err("usage: core_calendar_observer --trusted-corpus FIXTURE".into());
    }
    let path = PathBuf::from(args.next().ok_or("fixture required")?);
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err("fixture byte cap".into());
    }
    let input: Input = serde_json::from_slice(&bytes)?;
    if input.schema_version != 1 || input.id.is_empty() || input.id.len() > 80 {
        return Err("trusted fixture identity".into());
    }
    let before = serde_json::to_vec(&input)?;
    let result = calendar::business_millis(input.start, input.end, &input.calendar);
    let after = serde_json::to_vec(&input)?;
    let (outcome, duration, error) = match result {
        Ok(value) => ("duration", Some(value), None),
        Err(error) => ("refused", None, Some(error)),
    };
    println!(
        "{}",
        json!({
            "schema_version": 1, "id": input.id,
            "status": "ACTUAL_RUST_BUSINESS_CALENDAR_OBSERVED",
            "engine": "process_intelligence_rs::calendar::business_millis",
            "input_sha256": format!("{:x}", Sha256::digest(&bytes)),
            "iana_tzdb_version": chrono_tz::IANA_TZDB_VERSION,
            "outcome": outcome, "duration_millis": duration, "error": error,
            "configuration_unchanged": before == after,
            "source_input_before": serde_json::from_slice::<serde_json::Value>(&before)?,
            "source_input_after": serde_json::from_slice::<serde_json::Value>(&after)?,
            "source_input_before_sha256": format!("{:x}", Sha256::digest(&before)),
            "source_input_after_sha256": format!("{:x}", Sha256::digest(&after)),
            "scope": "Actual existing calendar API; elapsed UTC semantics and refusal policy preserved, not a legacy calendar implementation"
        })
    );
    Ok(())
}
