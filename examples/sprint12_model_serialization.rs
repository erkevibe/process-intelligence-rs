//! Finite public-fixture calibration, not runtime business-caller acceptance.
fn main() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/sprint02/linear.bpmn");
    let bytes = std::fs::read(path).expect("public fixture readable");
    assert!(bytes.len() <= 1024 * 1024);
    let model = process_intelligence_rs::bpmn::parse(&bytes).expect("fixed BPMN fixture");
    let typed = serde_json::to_vec(&model).unwrap();
    println!(
        "{}",
        serde_json::json!({
            "status":"PUBLIC_FIXTURE_TYPED_SERIALIZATION_CALIBRATION",
            "typed_model_sha256":process_intelligence_rs::storage::sha256(&typed),
            "model":serde_json::to_value(model).unwrap()
        })
    );
}
