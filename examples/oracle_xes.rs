//! Observation adapter for public parser/normalization APIs, not a new runtime.
use process_intelligence_rs::{csv_io, event_io};
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&args[1]).expect("fixture readable");
    let result = event_io::parse_xes(&bytes).and_then(|mut log| {
        let order = match args.get(2).map(String::as_str) {
            Some("timestamp") => csv_io::NormalizationOrder::Timestamp,
            _ => csv_io::NormalizationOrder::Source,
        };
        csv_io::normalize(&mut log, order)?;
        Ok(log)
    });
    match result {
        Ok(log) => println!("{}", serde_json::json!({"status":"ok","log":log})),
        Err(error) => println!("{}", serde_json::json!({"status":"rejected","error":error})),
    }
}
