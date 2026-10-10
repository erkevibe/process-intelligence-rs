//! Independent contract oracle: expected values are hand-derived in fixtures/*.expected.json.
use process_intelligence_rs::{
    domain::{Analysis, EventLog},
    event_io::{Limits, parse_xes, parse_xes_with_limits},
    mining::{analyze, graph_view},
};
use std::collections::BTreeMap;

fn manual() -> EventLog {
    parse_xes(include_bytes!("../fixtures/manual.xes")).expect("manual fixture")
}
fn labels(a: &Analysis) -> BTreeMap<String, (u64, u64, u64)> {
    a.nodes
        .iter()
        .map(|n| (n.label.clone(), (n.count, n.start_count, n.end_count)))
        .collect()
}
fn edges(a: &Analysis) -> BTreeMap<(String, String), u64> {
    let names: BTreeMap<_, _> = a
        .nodes
        .iter()
        .map(|n| (n.id.as_str(), n.label.as_str()))
        .collect();
    a.edges
        .iter()
        .map(|e| {
            (
                (
                    names[e.source.as_str()].into(),
                    names[e.target.as_str()].into(),
                ),
                e.count,
            )
        })
        .collect()
}
fn variants(a: &Analysis) -> BTreeMap<Vec<String>, u64> {
    a.variants
        .iter()
        .map(|v| (v.sequence.clone(), v.count))
        .collect()
}
fn invariants(log: &EventLog, a: &Analysis) {
    assert_eq!(
        a.variants.iter().map(|v| v.count).sum::<u64>(),
        a.cases as u64
    );
    assert_eq!(
        a.nodes.iter().map(|n| n.count).sum::<u64>(),
        a.events as u64
    );
    assert_eq!(
        a.edges.iter().map(|e| e.count).sum::<u64>(),
        log.cases
            .iter()
            .map(|c| c.events.len().saturating_sub(1) as u64)
            .sum::<u64>()
    );
    let nonempty = log.cases.iter().filter(|c| !c.events.is_empty()).count() as u64;
    assert_eq!(a.nodes.iter().map(|n| n.start_count).sum::<u64>(), nonempty);
    assert_eq!(a.nodes.iter().map(|n| n.end_count).sum::<u64>(), nonempty);
}

#[test]
fn exact_manual_oracle_and_distinct_duplicate_case_names() {
    let log = manual();
    let a = analyze(&log);
    assert_eq!((a.cases, a.events, a.activities), (4, 10, 3));
    assert_eq!(
        labels(&a),
        BTreeMap::from([
            ("A".into(), (5, 4, 1)),
            ("B".into(), (2, 0, 0)),
            ("C".into(), (3, 0, 3))
        ])
    );
    assert_eq!(
        edges(&a),
        BTreeMap::from([
            (("A".into(), "B".into()), 2),
            (("B".into(), "C".into()), 2),
            (("A".into(), "C".into()), 1),
            (("A".into(), "A".into()), 1)
        ])
    );
    assert_eq!(
        a.variants
            .iter()
            .map(|v| (v.sequence.clone(), v.count))
            .collect::<Vec<_>>(),
        vec![
            (vec!["A".into(), "B".into(), "C".into()], 2),
            (vec!["A".into(), "A".into()], 1),
            (vec!["A".into(), "C".into()], 1)
        ]
    );
    assert_ne!(log.cases[0].id, log.cases[1].id);
    invariants(&log, &a);
}

#[test]
fn empty_unicode_whitespace_lifecycle_and_timestamp_order() {
    let log = parse_xes(include_bytes!("../fixtures/semantics.xes")).unwrap();
    let a = analyze(&log);
    assert_eq!((a.cases, a.events, a.activities), (4, 4, 3));
    assert_eq!(
        labels(&a),
        BTreeMap::from([
            ("Қазақ".into(), (1, 1, 1)),
            (" A ".into(), (2, 1, 1)),
            ("<img src=x onerror=alert(1)>".into(), (1, 1, 1))
        ])
    );
    assert_eq!(
        edges(&a),
        BTreeMap::from([((" A ".into(), " A ".into()), 1)])
    );
    assert_eq!(variants(&a).get(&Vec::<String>::new()), Some(&1));
    assert_eq!(
        log.cases[2].events[0].timestamp.unwrap().to_rfc3339(),
        "2026-10-10T05:00:00+00:00"
    );
    assert_eq!(log.cases[2].events[0].lifecycle.as_deref(), Some("start"));
    assert_eq!(
        log.cases[2].events[1].lifecycle.as_deref(),
        Some("complete")
    );
    invariants(&log, &a);
}

#[test]
fn rejection_corpus() {
    for (name, data) in [
        (
            "malformed",
            include_bytes!("../fixtures/invalid-malformed.xes").as_slice(),
        ),
        (
            "empty",
            include_bytes!("../fixtures/invalid-empty-activity.xes").as_slice(),
        ),
        (
            "missing",
            include_bytes!("../fixtures/invalid-missing-activity.xes").as_slice(),
        ),
        (
            "duplicate",
            include_bytes!("../fixtures/invalid-duplicate-key.xes").as_slice(),
        ),
        (
            "timestamp",
            include_bytes!("../fixtures/invalid-timestamp.xes").as_slice(),
        ),
        (
            "timezone",
            include_bytes!("../fixtures/invalid-timezone.xes").as_slice(),
        ),
        (
            "doctype",
            include_bytes!("../fixtures/invalid-doctype.xes").as_slice(),
        ),
        (
            "global",
            include_bytes!("../fixtures/invalid-global-default.xes").as_slice(),
        ),
        (
            "container",
            include_bytes!("../fixtures/invalid-container.xes").as_slice(),
        ),
    ] {
        assert!(parse_xes(data).is_err(), "{name} must reject");
    }
}

#[test]
fn doubling_reordering_and_bijective_renaming() {
    let log = manual();
    let a = analyze(&log);
    let mut doubled = log.clone();
    let mut copy = log.cases.clone();
    for c in &mut copy {
        c.id = format!("copy-{}", c.id);
    }
    doubled.cases.extend(copy);
    let d = analyze(&doubled);
    assert_eq!((d.cases, d.events), (8, 20));
    assert_eq!(
        labels(&d),
        labels(&a)
            .into_iter()
            .map(|(k, (n, s, e))| (k, (n * 2, s * 2, e * 2)))
            .collect()
    );
    assert_eq!(
        edges(&d),
        edges(&a).into_iter().map(|(k, n)| (k, n * 2)).collect()
    );
    assert_eq!(
        variants(&d),
        variants(&a).into_iter().map(|(k, n)| (k, n * 2)).collect()
    );
    invariants(&doubled, &d);
    let mut reordered = log.clone();
    reordered.cases.reverse();
    let r = analyze(&reordered);
    assert_eq!(labels(&r), labels(&a));
    assert_eq!(edges(&r), edges(&a));
    assert_eq!(variants(&r), variants(&a));
    let map = BTreeMap::from([("A", "Ө"), ("B", "中"), ("C", "🦀")]);
    let mut renamed = log.clone();
    for c in &mut renamed.cases {
        for e in &mut c.events {
            e.activity = map[e.activity.as_str()].into();
        }
    }
    let renamed_analysis = analyze(&renamed);
    assert_eq!(
        edges(&renamed_analysis),
        edges(&a)
            .into_iter()
            .map(|((s, t), n)| ((map[s.as_str()].into(), map[t.as_str()].into()), n))
            .collect()
    );
    assert_eq!(
        labels(&renamed_analysis),
        labels(&a)
            .into_iter()
            .map(|(s, n)| (map[s.as_str()].into(), n))
            .collect()
    );
}

#[test]
fn valid_timestamp_shift_does_not_change_dfg() {
    let first=b"<log><trace><event><string key='concept:name' value='A'/><date key='time:timestamp' value='2026-10-10T10:00:00+05:00'/></event><event><string key='concept:name' value='B'/><date key='time:timestamp' value='2026-10-10T04:00:00Z'/></event></trace></log>";
    let shifted = String::from_utf8(first.to_vec())
        .unwrap()
        .replace("2026-10-10", "2026-10-11");
    let a = analyze(&parse_xes(first).unwrap());
    let b = analyze(&parse_xes(shifted.as_bytes()).unwrap());
    assert_eq!(edges(&a), BTreeMap::from([(("A".into(), "B".into()), 1)]));
    assert_eq!(edges(&b), edges(&a));
    assert_eq!(labels(&b), labels(&a));
    assert_eq!(variants(&b), variants(&a));
}

#[test]
fn threshold_keeps_nodes_counts_and_resets_hidden_selection() {
    let a = analyze(&manual());
    let baseline = edges(&a);
    let hidden = a.edges.iter().find(|e| e.count == 1).unwrap().id.clone();
    let view = graph_view(&a, "log", 7, 9, 2, Some(hidden)).unwrap();
    assert_eq!(view.nodes.len(), 3);
    assert_eq!(view.edges.len(), 2);
    assert!(view.edges.iter().all(|e| e.count == 2));
    assert!(view.selected_id.is_none());
    assert_eq!((view.analysis_version, view.view_revision), (7, 9));
    let node = a.nodes[0].id.clone();
    let empty = graph_view(&a, "log", 7, 10, 3, Some(node.clone())).unwrap();
    assert!(empty.edges.is_empty());
    assert_eq!(empty.nodes.len(), 3);
    assert_eq!(empty.selected_id, Some(node));
    assert!(graph_view(&a, "log", 7, 11, 0, None).is_err());
    assert!(graph_view(&a, "log", 7, 11, 4, None).is_err());
    assert_eq!(edges(&a), baseline);
}

#[test]
fn scaled_limits_exact_boundaries_and_multibyte_names() {
    let input=b"<log><trace><event><string key='concept:name' value='AB'/></event><event><string key='concept:name' value='CD'/></event></trace><trace/></log>";
    let make = |bytes, events, cases, activity| Limits {
        max_bytes: bytes,
        max_events: events,
        max_cases: cases,
        max_activity_bytes: activity,
    };
    assert!(parse_xes_with_limits(input, make(input.len(), 2, 2, 2)).is_ok());
    for limit in [
        make(input.len() - 1, 2, 2, 2),
        make(input.len(), 1, 2, 2),
        make(input.len(), 2, 1, 2),
        make(input.len(), 2, 2, 1),
    ] {
        assert!(parse_xes_with_limits(input, limit).is_err());
    }
    let unicode = "<log><trace><event><string key='concept:name' value='Қ'/></event></trace></log>";
    assert!(parse_xes_with_limits(unicode.as_bytes(), make(unicode.len(), 1, 1, 2)).is_ok());
    assert!(parse_xes_with_limits(unicode.as_bytes(), make(unicode.len(), 1, 1, 1)).is_err());
}

#[test]
fn default_limits_are_the_published_admission_contract() {
    let l = Limits::default();
    assert_eq!(l.max_bytes, 20 * 1024 * 1024);
    assert_eq!(l.max_events, 100000);
    assert_eq!(l.max_cases, 20000);
    assert_eq!(l.max_activity_bytes, 4096);
}
