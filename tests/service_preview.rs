use process_intelligence_rs::{
    event_io::{Limits, parse_xes},
    service_preview::{preview_xes, preview_xes_checked},
};

#[test]
fn preview_explains_actions_and_preserves_source_identity() {
    let bytes = include_bytes!("../fixtures/oracle-service/mixed.xes");
    assert_eq!(parse_xes(bytes).unwrap_err().code, "missing_activity");
    let p = preview_xes(bytes).unwrap();
    assert_eq!((p.source_cases, p.source_events), (2, 5));
    assert_eq!(p.log.cases.len(), 1);
    assert_eq!(p.log.cases[0].id, "case-0");
    assert_eq!(
        p.log.cases[0]
            .events
            .iter()
            .map(|e| (e.ordinal, e.activity.as_str(), e.lifecycle.as_deref()))
            .collect::<Vec<_>>(),
        vec![(0, "A", Some("complete")), (4, "D", Some("START"))]
    );
    assert_eq!(
        p.changes
            .iter()
            .filter(|c| c.action == "default_lifecycle")
            .count(),
        3
    );
    assert_eq!(
        p.changes
            .iter()
            .filter(|c| c.action == "remove_event")
            .count(),
        3
    );
    assert_eq!(p.changes.last().unwrap().case_index, 1);
}

#[test]
fn limits_and_cancel_apply_before_removal() {
    let input = include_bytes!("../fixtures/oracle-service/all-removed.xes");
    for (limits, code) in [
        (
            Limits {
                max_events: 0,
                ..Limits::default()
            },
            "event_limit",
        ),
        (
            Limits {
                max_cases: 1,
                ..Limits::default()
            },
            "case_limit",
        ),
        (
            Limits {
                max_bytes: 1,
                ..Limits::default()
            },
            "byte_limit",
        ),
    ] {
        assert_eq!(
            preview_xes_checked(input, limits, &|| false)
                .unwrap_err()
                .code,
            code
        );
    }
    assert_eq!(
        preview_xes_checked(input, Limits::default(), &|| true)
            .unwrap_err()
            .code,
        "cancelled"
    );
    assert!(preview_xes(input).unwrap().fully_filtered);
    let oversized=b"<log><trace><event><string key='concept:name' value='ABCDE'/><string key='lifecycle:transition' value='suspend'/></event></trace></log>";
    assert_eq!(
        preview_xes_checked(
            oversized,
            Limits {
                max_activity_bytes: 4,
                ..Limits::default()
            },
            &|| false
        )
        .unwrap_err()
        .code,
        "activity_limit"
    );
}

#[test]
fn normalized_values_are_stable_and_input_is_untouched() {
    let input = include_bytes!("../fixtures/oracle-service/case-lifecycle.xes");
    let original = input.to_vec();
    let first = preview_xes(input).unwrap();
    let second = preview_xes(input).unwrap();
    assert!(first.changes.is_empty());
    assert_eq!(first.log, second.log);
    assert_eq!(input.as_slice(), original);
    assert_eq!(
        first.log,
        parse_xes(input)
            .map(|mut l| {
                l.warnings = first.log.warnings.clone();
                l
            })
            .unwrap()
    );
}

#[test]
fn strict_admission_still_rejects_unsafe_or_ambiguous_inputs() {
    for (input, code) in [
        (
            include_bytes!("../fixtures/oracle-service/wrong-time-type.xes").as_slice(),
            "invalid_timestamp",
        ),
        (
            include_bytes!("../fixtures/oracle-service/duplicate-name.xes").as_slice(),
            "duplicate_key",
        ),
        (
            include_bytes!("../fixtures/oracle-service/wrong-lifecycle-type.xes").as_slice(),
            "invalid_lifecycle",
        ),
    ] {
        assert_eq!(preview_xes(input).unwrap_err().code, code);
        assert_eq!(parse_xes(input).unwrap_err().code, code);
    }
    assert_eq!(
        preview_xes(b"<!DOCTYPE log [<!ENTITY a 'A'>]><log/>")
            .unwrap_err()
            .code,
        "doctype"
    );
    assert_eq!(
        preview_xes(b"<log><global scope='event'/></log>")
            .unwrap_err()
            .code,
        "unsupported_format"
    );
}
