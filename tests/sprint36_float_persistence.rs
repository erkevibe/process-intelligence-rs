#[test]
fn nonfitting_report_scalars_survive_lossless_json_roundtrip() {
    let original = serde_json::json!({"log_fitness":0.9995242626070409_f64,"average_fitness":0.9996220710506425_f64,"perfectly_fitting_frac":0.9920634920634921_f64});
    let bytes = serde_json::to_vec(&original).unwrap();
    let loaded: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        serde_json::to_vec(&loaded).unwrap(),
        bytes,
        "Saved report hashes require exact floating-point readback, including nonfitting fitness values"
    );
}
