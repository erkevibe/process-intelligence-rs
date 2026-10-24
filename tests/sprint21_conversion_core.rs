//! Integration checks for the shared CLI/web converter. No product runtime is needed.
use process_intelligence_rs::conversion::{self, MAX_REPORT_BYTES};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
const CSV: &[u8] = include_bytes!("../fixtures/conversions/flat-unicode.csv");
#[test]
fn cancellation_is_not_a_format_refusal_and_scope_is_restored() {
    let token = Arc::new(AtomicBool::new(true));
    let refused =
        conversion::convert_with_cancel("csv", "xes", CSV, false, token.clone()).unwrap_err();
    assert_eq!(
        (refused.status.as_str(), refused.reason.as_str()),
        ("cancelled", "cancelled")
    );
    // Even an already-cancelled operation must leave the synchronous worker reusable.
    assert!(conversion::convert("csv", "xes", CSV, false).is_ok());
    token.store(false, Ordering::Release);
    assert!(conversion::convert_with_cancel("csv", "xes", CSV, false, token).is_ok());
}
#[test]
fn cancellation_token_is_isolated_between_workers() {
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let other = barrier.clone();
    let cancelled = std::thread::spawn(move || {
        other.wait();
        conversion::convert_with_cancel("csv", "xes", CSV, false, Arc::new(AtomicBool::new(true)))
            .unwrap_err()
            .reason
    });
    barrier.wait();
    let result =
        conversion::convert_with_cancel("csv", "xes", CSV, false, Arc::new(AtomicBool::new(false)))
            .unwrap();
    assert_eq!(result.extension, "xes");
    assert_eq!(cancelled.join().unwrap(), "cancelled");
}
#[test]
fn common_report_binds_actual_payload_and_preserves_refusal_details() {
    let result = conversion::convert("csv", "xes", CSV, false);
    let report = conversion::report("csv", "xes", CSV, false, &result).unwrap();
    let payload = &result.as_ref().unwrap().payload;
    assert_eq!(report["target_sha256"], conversion::sha(payload));
    assert_eq!(report["input_sha256"], conversion::sha(CSV));
    assert_eq!(report["payload_file"], "payload.xes");
    assert!(report["sources"]["src/conversion/logs.rs"].is_string());
    let bytes = conversion::report_bytes("csv", "xes", CSV, false, &result).unwrap();
    assert!(bytes.len() <= MAX_REPORT_BYTES);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap(),
        report
    );
    let failure =
        Err(conversion::Failure::new("test_refusal").detail(serde_json::json!({"kept":true})));
    let report = conversion::report("csv", "xes", CSV, false, &failure).unwrap();
    assert_eq!(report["status"], "refused");
    assert_eq!(report["details"]["kept"], true);
    assert!(report["target_sha256"].is_null());
    assert!(report["payload_file"].is_null());
}
#[test]
fn report_limit_applies_to_the_serialized_document() {
    let result = Ok(conversion::Converted {
        payload: Vec::new(),
        extension: "xes",
        evidence: serde_json::json!({"expanded": "\\".repeat(MAX_REPORT_BYTES)}),
    });
    assert_eq!(
        conversion::report_bytes("csv", "xes", CSV, false, &result)
            .unwrap_err()
            .reason,
        "report_byte_limit"
    );
}
