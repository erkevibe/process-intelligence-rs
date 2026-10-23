//! Shared bounded file conversions. Cancellation is cooperative; third-party calls finish before the next check.
pub mod compact;
pub mod logs;
pub mod net;
pub mod xml;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
pub const MAX_BYTES: usize = 20 * 1024 * 1024;
pub const METHOD: &str = "49dc32d1f4219965ea57cc79caa9355974269fab989cc38d09173c8e734e619b";
pub type Result<T> = std::result::Result<T, Failure>;
#[derive(Debug, Clone, Serialize)]
pub struct Failure {
    pub status: String,
    pub reason: String,
    pub details: Value,
}
impl Failure {
    pub fn new(reason: &str) -> Self {
        Self {
            status: "refused".into(),
            reason: reason.into(),
            details: Value::Null,
        }
    }
    pub fn detail(mut self, value: Value) -> Self {
        self.details = value;
        self
    }
    pub fn inconclusive(reason: &str) -> Self {
        Self {
            status: "inconclusive".into(),
            reason: reason.into(),
            details: Value::Null,
        }
    }
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.status, self.reason)
    }
}
impl std::error::Error for Failure {}
pub fn require(value: bool, reason: &str) -> Result<()> {
    if value {
        Ok(())
    } else {
        Err(Failure::new(reason))
    }
}
pub fn sha(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
pub fn xml_chars(value: &str) -> bool {
    value.chars().all(|c|matches!(c,'\u{9}'|'\u{a}'|'\u{d}'|'\u{20}'..='\u{d7ff}'|'\u{e000}'..='\u{fffd}'|'\u{10000}'..='\u{10ffff}'))
}
#[derive(Debug)]
pub struct Converted {
    pub payload: Vec<u8>,
    pub extension: &'static str,
    pub evidence: Value,
}
pub fn convert(from: &str, to: &str, input: &[u8], allow: bool) -> Result<Converted> {
    check_cancelled()?;
    require(input.len() <= MAX_BYTES, "byte_limit")?;
    std::str::from_utf8(input).map_err(|_| Failure::new("utf8_required"))?;
    require(!input.contains(&0), "nul_forbidden")?;
    let converted = match (from, to) {
        ("xes", "csv") | ("csv", "xes") => logs::convert(from, input, allow)?,
        ("petri-json", "pnml") | ("pnml", "petri-json") => net::convert(from, input)?,
        _ => return Err(Failure::new("unsupported_direction")),
    };
    check_cancelled()?;
    require(converted.payload.len() <= MAX_BYTES, "output_byte_limit")?;
    Ok(converted)
}
pub fn sources() -> Value {
    json!({"examples/pi_convert.rs":sha(include_bytes!("../../examples/pi_convert.rs")),"src/conversion/mod.rs":sha(include_bytes!("mod.rs")),"src/conversion/xml.rs":sha(include_bytes!("xml.rs")),"src/conversion/logs.rs":sha(include_bytes!("logs.rs")),"src/conversion/net.rs":sha(include_bytes!("net.rs")),"Cargo.lock":sha(include_bytes!("../../Cargo.lock")),"src/event_io.rs":sha(include_bytes!("../event_io.rs")),"src/csv_io.rs":sha(include_bytes!("../csv_io.rs")),"locked_process_mining":"0.6.2"})
}

use std::{
    cell::RefCell,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
thread_local! {
    static CANCELLATION: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
}
struct CancellationScope(Option<Arc<AtomicBool>>);
impl Drop for CancellationScope {
    fn drop(&mut self) {
        CANCELLATION.with(|slot| {
            slot.replace(self.0.take());
        });
    }
}
pub(crate) fn check_cancelled() -> Result<()> {
    let cancelled = CANCELLATION.with(|slot| {
        slot.borrow()
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::Acquire))
    });
    if cancelled {
        Err(Failure {
            status: "cancelled".into(),
            reason: "cancelled".into(),
            details: Value::Null,
        })
    } else {
        Ok(())
    }
}
/// Runs synchronously on the calling worker. Nested scopes restore their previous token,
/// including during unwinding. Third-party parsers/exporters are not forcibly interrupted.
pub fn convert_with_cancel(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    cancelled: Arc<AtomicBool>,
) -> Result<Converted> {
    let _scope = CancellationScope(CANCELLATION.with(|slot| slot.replace(Some(cancelled))));
    let result = convert(from, to, input, allow);
    check_cancelled()?;
    result
}
pub const MAX_REPORT_BYTES: usize = 4 * 1024 * 1024;
/// Identical semantic report for the CLI and durable web artifact.
pub fn report(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    conversion: &Result<Converted>,
) -> Result<Value> {
    let report = logical_report(from, to, input, allow, conversion);
    require(
        serde_json::to_vec(&report)
            .map_err(|_| Failure::new("report_serialization"))?
            .len()
            <= MAX_REPORT_BYTES,
        "report_byte_limit",
    )?;
    Ok(report)
}
fn logical_report(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    conversion: &Result<Converted>,
) -> Value {
    let mut report = json!({"schema_version":1,"method_sha256":METHOD,"from":from,"to":to,"allow_metadata_loss":allow,"input_sha256":sha(input),"input_bytes":input.len(),"sources":sources(),"target_sha256":null,"target_bytes":null,"payload_file":null,"not_general_format_support":true});
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
            report["evidence"] = result.evidence.clone();
        }
        Err(error) => {
            report["status"] = json!(error.status);
            report["reason"] = json!(error.reason);
            report["details"] = error.details.clone();
        }
    }
    report
}
pub fn report_bytes(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    conversion: &Result<Converted>,
) -> Result<Vec<u8>> {
    let bytes = serde_json::to_vec_pretty(&report(from, to, input, allow, conversion)?)
        .map_err(|_| Failure::new("report_serialization"))?;
    require(bytes.len() <= MAX_REPORT_BYTES, "report_byte_limit")?;
    Ok(bytes)
}
/// Explicit reversible transport; the default API above remains schema 1.
pub fn report_bytes_profile(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    conversion: &Result<Converted>,
    compact: bool,
) -> Result<Vec<u8>> {
    if !compact {
        return report_bytes(from, to, input, allow, conversion);
    }
    require(
        matches!((from, to), ("xes", "csv") | ("csv", "xes")),
        "compact_log_direction_required",
    )?;
    compact::encode(&logical_report(from, to, input, allow, conversion))
}
pub fn report_bytes_profile_with_cancel(
    from: &str,
    to: &str,
    input: &[u8],
    allow: bool,
    conversion: &Result<Converted>,
    compact: bool,
    cancelled: Arc<AtomicBool>,
) -> Result<Vec<u8>> {
    let _scope = CancellationScope(CANCELLATION.with(|slot| slot.replace(Some(cancelled))));
    let result = report_bytes_profile(from, to, input, allow, conversion, compact);
    check_cancelled()?;
    result
}
