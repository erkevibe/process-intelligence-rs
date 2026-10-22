//! Pure provenance checks; no bridge admission, alignments or miner execution.
#[path = "../examples/quality/cohort.rs"]
#[allow(dead_code)]
mod cohort;
#[path = "../examples/quality/mod.rs"]
#[allow(dead_code)]
mod quality;
use serde_json::json;
#[test]
fn exact_lexical_projection_refuses_rehashed_replacement() {
    let raw = b"prefix REMOVE suffix";
    let expected = b"prefix  suffix";
    let report = json!({"projection_status":"projected","original_sha256":quality::sha(raw),"original_bytes":raw.len(),
        "projected_sha256":quality::sha(expected),"projected_bytes":expected.len(),
        "removed_spans":[{"byte_start":7,"byte_length":6,"subtree_sha256":quality::sha(b"REMOVE"),"raw_utf8":"REMOVE"}]});
    assert_eq!(cohort::reconstruct(raw, &report).unwrap(), expected);
    let mut changed = report.clone();
    changed["removed_spans"][0]["raw_utf8"] = json!("RENAME");
    assert!(cohort::reconstruct(raw, &changed).is_err());
    changed = report.clone();
    changed["removed_spans"][0]["byte_start"] = json!(usize::MAX);
    assert!(cohort::reconstruct(raw, &changed).is_err());
    changed = report.clone();
    changed["removed_spans"]
        .as_array_mut()
        .unwrap()
        .push(report["removed_spans"][0].clone());
    assert!(cohort::reconstruct(raw, &changed).is_err());
    changed = report.clone();
    changed["projected_sha256"] = json!(quality::sha(b"arbitrary replacement"));
    assert!(cohort::reconstruct(raw, &changed).is_err());
}
#[test]
fn frozen_cohort_has_original_eight_rows_and_training_only() {
    let corpus: serde_json::Value = serde_json::from_str(cohort::COHORT).unwrap();
    let rows = corpus["cases"].as_array().unwrap();
    assert_eq!(rows.len(), 8);
    let ids: std::collections::BTreeSet<_> =
        rows.iter().map(|row| row["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 8);
    for row in rows {
        assert!(row["source_input"]["heldout_log"].is_null());
    }
    assert!(rows.iter().find(|row| row["id"] == "empty-log").unwrap()["raw_bpmn"].is_null());
    let loop_row = rows.iter().find(|row| row["id"] == "self-loop").unwrap();
    assert!(
        !loop_row["static_features"]["standard_loop_elements"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}
#[test]
fn exact_cohort_policy_rejects_rehashed_semantic_deletion() {
    let raw = b"id=\"task\" <bpmndi:BPMNLabel/>";
    let valid = json!({"removed_spans":[{"byte_start":10,"byte_length":19,"raw_utf8":"<bpmndi:BPMNLabel/>"}]});
    // Derive the length from the exact admitted literal, avoiding a duplicated magic count.
    let mut valid = valid;
    valid["removed_spans"][0]["byte_length"] = json!(b"<bpmndi:BPMNLabel/>".len());
    cohort::cohort_spans(raw, &valid, b"<bpmndi:BPMNLabel/>", 1).unwrap();
    let forged_output = &raw[9..];
    let forged = json!({"projection_status":"projected","original_sha256":quality::sha(raw),"original_bytes":raw.len(),
        "projected_sha256":quality::sha(forged_output),"projected_bytes":forged_output.len(),
        "removed_spans":[{"byte_start":0,"byte_length":9,"raw_utf8":"id=\"task\"","subtree_sha256":quality::sha(&raw[..9])}]});
    assert_eq!(cohort::reconstruct(raw, &forged).unwrap(), forged_output);
    assert!(cohort::cohort_spans(raw, &forged, b"<bpmndi:BPMNLabel/>", 1).is_err());
    assert!(
        cohort::cohort_spans(raw, &json!({"removed_spans":[]}), b"<bpmndi:BPMNLabel/>", 1).is_err()
    );
}
