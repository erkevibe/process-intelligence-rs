//! Agreed bounded external-file converters; product modules are unchanged.
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
    require(input.len() <= MAX_BYTES, "byte_limit")?;
    std::str::from_utf8(input).map_err(|_| Failure::new("utf8_required"))?;
    require(!input.contains(&0), "nul_forbidden")?;
    let converted = match (from, to) {
        ("xes", "csv") | ("csv", "xes") => logs::convert(from, input, allow)?,
        ("petri-json", "pnml") | ("pnml", "petri-json") => net::convert(from, input)?,
        _ => return Err(Failure::new("unsupported_direction")),
    };
    require(converted.payload.len() <= MAX_BYTES, "output_byte_limit")?;
    Ok(converted)
}
pub fn sources() -> Value {
    json!({"examples/pi_convert.rs":sha(include_bytes!("../pi_convert.rs")),"examples/conversion/mod.rs":sha(include_bytes!("mod.rs")),"examples/conversion/xml.rs":sha(include_bytes!("xml.rs")),"examples/conversion/logs.rs":sha(include_bytes!("logs.rs")),"examples/conversion/net.rs":sha(include_bytes!("net.rs")),"Cargo.lock":sha(include_bytes!("../../Cargo.lock")),"src/event_io.rs":sha(include_bytes!("../../src/event_io.rs")),"src/csv_io.rs":sha(include_bytes!("../../src/csv_io.rs")),"locked_process_mining":"0.6.2"})
}
