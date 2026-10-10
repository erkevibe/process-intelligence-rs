//! Independent event projection oracle; expected counts are hand derived.
use process_intelligence_rs::{
    event_io::parse_xes,
    filters::{FilterSpec, apply},
    mining::analyze,
};

fn spec() -> FilterSpec {
    FilterSpec {
        case_activity: None,
        min_events: None,
        max_events: None,
        retain_activities: vec![],
        remove_activities: vec![],
    }
}
fn source() -> process_intelligence_rs::domain::EventLog {
    parse_xes(include_bytes!("../fixtures/manual.xes")).unwrap()
}

#[test]
fn removal_reconnects_and_source_is_immutable() {
    let log = source();
    let before = serde_json::to_value(&log).unwrap();
    let mut f = spec();
    f.remove_activities = vec!["B".into()];
    let projected = apply(&log, &f).unwrap();
    let a = analyze(&projected);
    assert_eq!((a.cases, a.events, a.activities), (4, 8, 2));
    assert_eq!(
        projected
            .cases
            .iter()
            .map(|c| c
                .events
                .iter()
                .map(|e| e.activity.as_str())
                .collect::<Vec<_>>())
            .collect::<Vec<_>>(),
        vec![
            vec!["A", "C"],
            vec!["A", "C"],
            vec!["A", "C"],
            vec!["A", "A"]
        ]
    );
    assert_eq!(a.edges.iter().map(|e| e.count).sum::<u64>(), 4);
    assert_eq!(serde_json::to_value(&log).unwrap(), before);
}

#[test]
fn retain_preserves_empty_cases_and_variants() {
    let mut f = spec();
    f.retain_activities = vec!["B".into()];
    let p = apply(&source(), &f).unwrap();
    let a = analyze(&p);
    assert_eq!((a.cases, a.events, a.activities), (4, 2, 1));
    assert!(a.edges.is_empty());
    assert_eq!(
        a.variants
            .iter()
            .find(|v| v.sequence.is_empty())
            .unwrap()
            .count,
        2
    );
    assert_eq!(
        a.variants
            .iter()
            .find(|v| v.sequence == ["B"])
            .unwrap()
            .count,
        2
    );
}

#[test]
fn case_predicates_are_and_on_original_events_before_projection() {
    let mut f = spec();
    f.case_activity = Some("B".into());
    f.min_events = Some(3);
    f.max_events = Some(3);
    f.remove_activities = vec!["B".into()];
    let p = apply(&source(), &f).unwrap();
    let a = analyze(&p);
    assert_eq!((a.cases, a.events, a.activities), (2, 4, 2));
    assert!(
        p.cases
            .iter()
            .all(|c| c.events.iter().map(|e| e.activity.as_str()).eq(["A", "C"]))
    );
    assert_eq!(a.edges.len(), 1);
    assert_eq!(a.edges[0].count, 2);
}

#[test]
fn invalid_conflict_and_length_range_reject() {
    let mut f = spec();
    f.retain_activities = vec!["B".into()];
    f.remove_activities = vec!["B".into()];
    assert!(apply(&source(), &f).is_err());
    let mut f = spec();
    f.min_events = Some(3);
    f.max_events = Some(2);
    assert!(apply(&source(), &f).is_err());
}
