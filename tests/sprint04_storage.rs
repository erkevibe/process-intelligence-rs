use process_intelligence_rs::storage::Database;
use serde_json::json;
fn url() -> String {
    let s = std::env::var("S4_QA_DATABASE_URL").expect("isolated S4_QA_DATABASE_URL required");
    assert!(
        s.split_whitespace().any(|p| p.starts_with("dbname=pi_s4_")),
        "only isolated pi_s4 DB"
    );
    s
}
#[test]
#[ignore = "actual isolated fresh pi_s4_* database only; independent reserved/CAS atomicity"]
fn reserved_legacy_is_unwritable_and_generic_batch_conflict_is_atomic() {
    let db = Database::connect(url()).unwrap();
    assert_eq!(
        db.read("repository/foreign").unwrap_err().code,
        "legacy_reserved"
    );
    assert_eq!(
        db.write("repository/foreign", 0, json!({}))
            .unwrap_err()
            .code,
        "legacy_reserved"
    );
    db.write("qa/s4-cas-anchor", 0, json!({"old": 1})).unwrap();
    let e = db
        .write_batch(vec![
            ("qa/s4-first".into(), 0, json!("must rollback")),
            ("qa/s4-cas-anchor".into(), 99, json!({"new": 2})),
        ])
        .unwrap_err();
    assert_eq!(e.code, "storage_conflict");
    assert!(db.read("qa/s4-first").unwrap().is_none());
    assert_eq!(
        db.read("qa/s4-cas-anchor").unwrap().unwrap(),
        (1, json!({"old": 1}))
    );
    db.health().unwrap();
}
#[test]
#[ignore = "actual isolated fresh pi_s4_* database only; normalized restore transaction"]
fn normalized_project_creation_rolls_back_when_generic_batch_conflicts() {
    let db = Database::connect(url()).unwrap();
    let empty = json!({"logs": {}, "current": {}, "sequence": 0, "user_views": {}, "models": {}, "durable_jobs": {}});
    db.write("qa/s4-project-anchor", 0, json!(1)).unwrap();
    let e = db
        .write_batch(vec![
            ("repository/project-qa-s4-rollback".into(), 0, empty.clone()),
            ("qa/s4-project-anchor".into(), 999, json!(2)),
        ])
        .unwrap_err();
    assert_eq!(e.code, "storage_conflict");
    assert_eq!(
        db.write_batch(vec![(
            "repository/project-qa-s4-rollback".into(),
            0,
            empty.clone()
        )])
        .unwrap(),
        vec![1]
    );
    let e = db
        .write_batch(vec![("repository/project-qa-s4-rollback".into(), 0, empty)])
        .unwrap_err();
    assert_eq!(e.code, "storage_conflict");
    assert_eq!(
        db.write_batch(vec![(
            "repository/project-qa-s4-rollback".into(),
            1,
            json!({})
        )])
        .unwrap_err()
        .code,
        "legacy_reserved"
    );
    db.health().unwrap();
}
