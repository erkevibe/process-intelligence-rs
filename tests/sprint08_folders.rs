use process_intelligence_rs::folders::{Folder, Organization};
use std::collections::{BTreeMap, BTreeSet};

const A: &str = "folder-00000000-0000-4000-8000-000000000001";
const B: &str = "folder-00000000-0000-4000-8000-000000000002";
const C: &str = "folder-00000000-0000-4000-8000-000000000003";
fn catalog() -> BTreeSet<String> {
    ["log-1".into(), "model-2".into()].into_iter().collect()
}
fn folder(name: &str, parent: Option<&str>) -> Folder {
    Folder {
        name: name.into(),
        parent: parent.map(str::to_owned),
    }
}

#[test]
fn frozen_manual_organization_sequence_preserves_ids_and_assignments() {
    let allowed = catalog();
    let mut org = Organization::default();
    assert!(org.is_empty());
    org.create(A, "  Главная  ", None, &allowed).unwrap();
    org.create(B, "Дочерняя", Some(A), &allowed).unwrap();
    org.assign("log-1", Some(B), &allowed).unwrap();
    assert_eq!(org.folders[A].name, "Главная");
    org.rename(B, "Переименована", &allowed).unwrap();
    org.move_folder(B, None, &allowed).unwrap();
    assert_eq!(
        org.folders.keys().cloned().collect::<Vec<_>>(),
        vec![A.to_owned(), B.to_owned()]
    );
    assert_eq!(org.assignments["log-1"], B);
    assert_eq!(org.folders[B].parent, None);
    org.assign("log-1", None, &allowed).unwrap();
    assert!(org.assignments.is_empty());
    assert!(allowed.contains("log-1"));
    org.delete_empty(B, &allowed).unwrap();
    org.delete_empty(A, &allowed).unwrap();
    assert!(org.is_empty());
}

#[test]
fn frozen_literal_malformed_snapshots_refuse_without_repair() {
    let allowed = catalog();
    let cases = [
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A","parent":"folder-00000000-0000-4000-8000-000000000002"},"folder-00000000-0000-4000-8000-000000000002":{"name":"B","parent":"folder-00000000-0000-4000-8000-000000000001"}},"assignments":{}}"#,
            "folder_cycle",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A","parent":"folder-00000000-0000-4000-8000-000000000001"}},"assignments":{}}"#,
            "folder_parent",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A","parent":"folder-00000000-0000-4000-8000-000000000003"}},"assignments":{}}"#,
            "folder_parent",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"Same"},"folder-00000000-0000-4000-8000-000000000002":{"name":"Same"}},"assignments":{}}"#,
            "folder_duplicate",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A"}},"assignments":{"log-999":"folder-00000000-0000-4000-8000-000000000001"}}"#,
            "folder_resource",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A"}},"assignments":{"log-1":"folder-00000000-0000-4000-8000-000000000002"}}"#,
            "folder_missing",
        ),
        (
            r#"{"folders":{"folder-not-a-uuid":{"name":"A"}},"assignments":{}}"#,
            "folder_policy",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-1000-8000-000000000001":{"name":"A"}},"assignments":{}}"#,
            "folder_policy",
        ),
        (
            r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":" A "}},"assignments":{}}"#,
            "folder_policy",
        ),
    ];
    for (raw, expected) in cases {
        let mut org: Organization = serde_json::from_str(raw).unwrap();
        let before = org.clone();
        assert_eq!(org.validate(&allowed).unwrap_err().code, expected);
        assert!(org.rename(A, "Repair attempt", &allowed).is_err());
        assert_eq!(org, before);
    }
    assert!(
        serde_json::from_str::<Organization>(r#"{"folders":{},"assignments":{},"unknown":true}"#)
            .is_err()
    );
    assert!(serde_json::from_str::<Organization>(r#"{"folders":{"folder-00000000-0000-4000-8000-000000000001":{"name":"A","unknown":true}},"assignments":{}}"#).is_err());
}

#[test]
fn failing_commands_preserve_complete_snapshot() {
    let allowed = catalog();
    let mut org = Organization::default();
    org.create(A, "Root", None, &allowed).unwrap();
    org.create(B, "Child", Some(A), &allowed).unwrap();
    org.assign("model-2", Some(B), &allowed).unwrap();
    let before = org.clone();
    assert_eq!(
        org.move_folder(A, Some(B), &allowed).unwrap_err().code,
        "folder_cycle"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.delete_empty(A, &allowed).unwrap_err().code,
        "folder_not_empty"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.delete_empty(B, &allowed).unwrap_err().code,
        "folder_not_empty"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.assign("log-999", Some(A), &allowed).unwrap_err().code,
        "folder_resource"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.assign("log-1", Some(C), &allowed).unwrap_err().code,
        "folder_missing"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.create(A, "Overwrite", None, &allowed).unwrap_err().code,
        "folder_duplicate"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.rename(B, "   ", &allowed).unwrap_err().code,
        "folder_policy"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.rename(B, &"я".repeat(101), &allowed).unwrap_err().code,
        "folder_policy"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.create("folder-bad", "Name", None, &allowed)
            .unwrap_err()
            .code,
        "folder_policy"
    );
    assert_eq!(org, before);
}

#[test]
fn names_are_sibling_scoped_case_sensitive_and_uuid_ids_stable() {
    let allowed = catalog();
    let mut org = Organization::default();
    org.create(A, "Same", None, &allowed).unwrap();
    org.create(B, "same", None, &allowed).unwrap();
    org.create(C, "Same", Some(A), &allowed).unwrap();
    let before = org.clone();
    assert_eq!(
        org.rename(B, " Same ", &allowed).unwrap_err().code,
        "folder_duplicate"
    );
    assert_eq!(org, before);
    assert_eq!(
        org.move_folder(C, None, &allowed).unwrap_err().code,
        "folder_duplicate"
    );
    assert_eq!(org, before);
    let roundtrip: Organization =
        serde_json::from_value(serde_json::to_value(&org).unwrap()).unwrap();
    assert_eq!(roundtrip, org);
}

#[test]
fn folder_count_is_bounded_and_orphan_catalog_refuses() {
    let allowed = catalog();
    let mut org = Organization::default();
    for n in 1..=128 {
        org.create(
            &format!("folder-00000000-0000-4000-8000-{n:012x}"),
            &format!("F{n}"),
            None,
            &allowed,
        )
        .unwrap();
    }
    let before = org.clone();
    assert_eq!(
        org.create(
            "folder-00000000-0000-4000-8000-000000000100",
            "Too many",
            None,
            &allowed
        )
        .unwrap_err()
        .code,
        "folder_policy"
    );
    assert_eq!(org, before);
    let org = Organization {
        folders: BTreeMap::from([(A.into(), folder("Root", None))]),
        assignments: BTreeMap::from([("log-1".into(), A.into())]),
    };
    assert_eq!(
        org.validate(&BTreeSet::from(["model-2".into()]))
            .unwrap_err()
            .code,
        "folder_resource"
    );
}
