use process_intelligence_rs::{
    import_provenance::ImportProvenance, service_preview::preview_xes, storage::sha256,
};

#[test]
fn original_bytes_and_policy_actions_are_bound_and_tampering_is_refused() {
    let bytes = include_bytes!("../fixtures/oracle-service/mixed.xes");
    let preview = preview_xes(bytes).unwrap();
    let original = String::from_utf8(bytes.to_vec()).unwrap();
    let provenance = ImportProvenance::capture(
        original,
        &preview,
        "user-1".into(),
        "project-1".into(),
        uuid::Uuid::new_v4().to_string(),
    )
    .unwrap();
    provenance.validate(&preview.log, &sha256(bytes)).unwrap();
    assert_eq!(provenance.original_utf8.as_bytes(), bytes);
    assert_eq!(provenance.source_cases, 2);
    assert_eq!(provenance.source_events, 5);
    assert_eq!(preview.log.cases[0].id, "case-0");
    assert_eq!(
        preview.log.cases[0]
            .events
            .iter()
            .map(|e| e.ordinal)
            .collect::<Vec<_>>(),
        vec![0, 4]
    );
    let encoded = serde_json::to_value(&provenance).unwrap();
    for field in ["policy", "source_sha256", "original_utf8"] {
        let mut altered = encoded.clone();
        altered[field] = serde_json::json!("changed");
        let altered: ImportProvenance = serde_json::from_value(altered).unwrap();
        assert!(
            altered.validate(&preview.log, &sha256(bytes)).is_err(),
            "{field}"
        );
    }
    let mut changed = provenance.clone();
    changed.actions[0].reasons.clear();
    assert!(changed.validate(&preview.log, &sha256(bytes)).is_err());
    changed = provenance.clone();
    changed.actions[0].case_index += 1;
    assert!(changed.validate(&preview.log, &sha256(bytes)).is_err());
    changed = provenance.clone();
    changed.schema_version += 1;
    assert!(changed.validate(&preview.log, &sha256(bytes)).is_err());
    let mut source = preview.log.clone();
    source.cases[0].events[0].activity = "other".into();
    assert!(provenance.validate(&source, &sha256(bytes)).is_err());
    let mut extra = encoded;
    extra["unknown"] = serde_json::json!(true);
    assert!(serde_json::from_value::<ImportProvenance>(extra).is_err());
}

#[test]
fn wholly_filtered_projection_cannot_be_confirmed() {
    let raw = include_str!("../fixtures/oracle-service/all-removed.xes");
    let preview = preview_xes(raw.as_bytes()).unwrap();
    assert!(preview.fully_filtered);
    assert!(
        ImportProvenance::capture(
            raw.into(),
            &preview,
            "user-1".into(),
            "project-1".into(),
            uuid::Uuid::new_v4().to_string()
        )
        .is_err()
    );
}
