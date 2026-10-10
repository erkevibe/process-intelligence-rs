use process_intelligence_rs::{
    csv_io::{CsvMapping, NormalizationOrder, parse_csv, preview},
    mining::analyze,
};

#[test]
fn csv_matches_independently_authored_equivalent_xes_semantics() {
    let csv = parse_csv(
        include_bytes!("../fixtures/sprint02/order.csv"),
        &mapping(NormalizationOrder::Source),
    )
    .unwrap();
    let xes = process_intelligence_rs::event_io::parse_xes(include_bytes!(
        "../fixtures/sprint02/order-source.xes"
    ))
    .unwrap();
    assert_eq!(
        serde_json::to_value(analyze(&csv)).unwrap(),
        serde_json::to_value(analyze(&xes)).unwrap()
    );
    for (c, x) in csv.cases.iter().zip(&xes.cases) {
        assert_eq!(c.name, x.name);
        assert_eq!(
            c.events
                .iter()
                .map(|e| (&e.activity, e.timestamp, &e.lifecycle))
                .collect::<Vec<_>>(),
            x.events
                .iter()
                .map(|e| (&e.activity, e.timestamp, &e.lifecycle))
                .collect::<Vec<_>>()
        );
    }
    // Original CSV physical source ordinals and per-case XES ordinals differ by design.
}
fn mapping(order: NormalizationOrder) -> CsvMapping {
    CsvMapping {
        case_column: "case".into(),
        activity_column: "activity".into(),
        timestamp_column: Some("time".into()),
        lifecycle_column: Some("lifecycle".into()),
        delimiter: b',',
        order,
    }
}
#[test]
fn exact_source_and_stable_timestamp_order() {
    let bytes = include_bytes!("../fixtures/sprint02/order.csv");
    let source = parse_csv(bytes, &mapping(NormalizationOrder::Source)).unwrap();
    let sorted = parse_csv(bytes, &mapping(NormalizationOrder::Timestamp)).unwrap();
    assert_eq!(
        source
            .cases
            .iter()
            .map(|c| c
                .events
                .iter()
                .map(|e| e.activity.as_str())
                .collect::<Vec<_>>())
            .collect::<Vec<_>>(),
        vec![vec!["A", "C", "B"], vec!["A", "B"]]
    );
    assert_eq!(
        sorted
            .cases
            .iter()
            .map(|c| c
                .events
                .iter()
                .map(|e| e.activity.as_str())
                .collect::<Vec<_>>())
            .collect::<Vec<_>>(),
        vec![vec!["C", "B", "A"], vec!["A", "B"]]
    );
    for log in [&source, &sorted] {
        let a = analyze(log);
        assert_eq!((a.cases, a.events, a.activities), (2, 5, 3));
        assert_eq!(a.edges.iter().map(|e| e.count).sum::<u64>(), 3);
    }
    assert_eq!(
        sorted.cases[0].events[0].ordinal,
        source.cases[0].events[1].ordinal
    );
    assert_eq!(
        sorted.cases[0].events[1].ordinal,
        source.cases[0].events[2].ordinal
    );
    assert_eq!(
        sorted.cases[0].events[0].timestamp.unwrap().to_rfc3339(),
        "2026-10-12T04:00:00+00:00"
    );
    assert_eq!(
        sorted.cases[0].events[0].lifecycle.as_deref(),
        Some("start")
    );
}
#[test]
fn quoted_unicode_newline_spaces_and_preview() {
    let bytes = include_bytes!("../fixtures/sprint02/quoted.csv");
    let p = preview(bytes, b';').unwrap();
    assert_eq!(p.headers, vec!["case", "activity", "time"]);
    assert_eq!(p.rows.len(), 3);
    assert_eq!(p.rows[1][1], "two\nlines");
    let mut m = mapping(NormalizationOrder::Source);
    m.delimiter = b';';
    m.lifecycle_column = None;
    let log = parse_csv(bytes, &m).unwrap();
    assert_eq!(log.cases.len(), 2);
    assert_eq!(log.cases[0].events[0].activity, "Әрекет;бір");
    assert_eq!(log.cases[1].events[0].activity, "say \"yes\"");
    assert_eq!(analyze(&log).events, 3);
}
#[test]
fn timestamp_policy_missing_invalid_and_row_context() {
    let m = mapping(NormalizationOrder::Timestamp);
    for value in ["", "bad", "2026-10-12T09:00:00"] {
        let data = format!("case,activity,time,lifecycle\nc,A,{value},complete\n");
        let err = parse_csv(data.as_bytes(), &m).unwrap_err();
        assert!(err.message.contains("2"), "row context: {err}");
    }
    let mut source = mapping(NormalizationOrder::Source);
    source.timestamp_column = None;
    assert!(parse_csv(b"case,activity,lifecycle\nc,A,complete\n", &source).is_ok());
    let err=parse_csv(b"case,activity,time,lifecycle\nc,\"two\nlines\",2026-10-12T09:00:00Z,complete\nc,,2026-10-12T10:00:00Z,complete\n",&mapping(NormalizationOrder::Source)).unwrap_err();
    assert!(
        err.message.contains("4"),
        "physical row after quoted newline: {err}"
    );
}
#[test]
fn mapping_and_duplicate_header_reject() {
    let mut m = mapping(NormalizationOrder::Source);
    m.activity_column = "missing".into();
    assert!(parse_csv(include_bytes!("../fixtures/sprint02/order.csv"), &m).is_err());
    assert!(
        parse_csv(
            b"case,activity,time,lifecycle,activity\nc,A,2026-10-12T09:00:00Z,complete,B\n",
            &mapping(NormalizationOrder::Source)
        )
        .is_err()
    );
}
