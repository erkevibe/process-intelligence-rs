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
        naive_timestamp_offset: None,
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

#[test]
fn naive_iso_dates_require_an_explicit_offset_and_keep_existing_offsets() {
    let bytes = b"case,activity,time,lifecycle\nc,A,2020-01-01T00:37:00.123456789,complete\nc,B,2020-01-01T01:00:00+03:00,complete\n";
    let mut m = mapping(NormalizationOrder::Source);
    assert_eq!(parse_csv(bytes, &m).unwrap_err().code, "csv_timestamp");
    m.naive_timestamp_offset = Some("+05:00".into());
    let log = parse_csv(bytes, &m).unwrap();
    assert_eq!(
        log.cases[0].events[0].timestamp.unwrap().to_rfc3339(),
        "2019-12-31T19:37:00.123456789+00:00"
    );
    assert_eq!(
        log.cases[0].events[1].timestamp.unwrap().to_rfc3339(),
        "2019-12-31T22:00:00+00:00"
    );
    assert_eq!(log.cases[0].events[0].ordinal, 0);
    assert_eq!(log.cases[0].events[1].ordinal, 1);
    assert_eq!(log.warnings.len(), 1);
    assert!(log.warnings[0].contains("Событий: 1."));
    assert!(log.warnings[0].contains("UTC+05:00"));
    // A supplied fallback does not alter an already unambiguous file or add a warning.
    let aware = b"case,activity,time,lifecycle\nc,A,2020-01-01T00:37:00Z,complete\n";
    let with_fallback = parse_csv(aware, &m).unwrap();
    m.naive_timestamp_offset = None;
    assert_eq!(with_fallback, parse_csv(aware, &m).unwrap());
}

#[test]
fn explicit_negative_and_fractional_offsets_have_stable_timestamp_order() {
    let bytes = b"case,activity,time,lifecycle\nc,A,2020-01-01T00:15:00,complete\nc,B,2020-01-01T03:45:00Z,start\nc,C,2020-01-01T00:10:00,complete\n";
    let mut m = mapping(NormalizationOrder::Timestamp);
    m.naive_timestamp_offset = Some("-03:30".into());
    let log = parse_csv(bytes, &m).unwrap();
    assert_eq!(
        log.cases[0]
            .events
            .iter()
            .map(|e| e.activity.as_str())
            .collect::<Vec<_>>(),
        vec!["C", "A", "B"]
    );
    assert_eq!(
        log.cases[0].events[0].timestamp.unwrap().to_rfc3339(),
        "2020-01-01T03:40:00+00:00"
    );
    assert_eq!(
        log.cases[0].events[1].timestamp,
        log.cases[0].events[2].timestamp
    );
    assert_eq!(log.cases[0].events[1].ordinal, 0);
    assert_eq!(log.cases[0].events[2].ordinal, 1);
    assert_eq!(log.cases[0].events[2].lifecycle.as_deref(), Some("start"));
}

#[test]
fn malformed_fallback_offsets_and_missing_time_mapping_are_refused() {
    let bytes = b"case,activity,time,lifecycle\nc,A,2020-01-01T00:00:00,complete\n";
    for offset in [
        "",
        "Z",
        "5:00",
        "+5:00",
        "05:00",
        "+14:01",
        "-14:30",
        "+15:00",
        "+05:60",
        "+05:00 ",
        " +05:00",
        "+aa:00",
        "UTC+05:00",
    ] {
        let mut m = mapping(NormalizationOrder::Source);
        m.naive_timestamp_offset = Some(offset.into());
        assert_eq!(
            parse_csv(bytes, &m).unwrap_err().code,
            "csv_timezone",
            "{offset}"
        );
    }
    for offset in ["+00:00", "-00:00", "+14:00", "-14:00", "+05:45"] {
        let mut m = mapping(NormalizationOrder::Source);
        m.naive_timestamp_offset = Some(offset.into());
        assert!(parse_csv(bytes, &m).is_ok(), "{offset}");
    }
    let mut m = mapping(NormalizationOrder::Source);
    m.naive_timestamp_offset = Some("+00:00".into());
    m.timestamp_column = None;
    assert_eq!(parse_csv(bytes, &m).unwrap_err().code, "csv_mapping");
}

#[test]
fn explicit_fallback_does_not_strip_invalid_timezone_suffixes_or_invent_missing_times() {
    let mut m = mapping(NormalizationOrder::Source);
    m.naive_timestamp_offset = Some("+00:00".into());
    for value in [
        "bad",
        "2020-02-30T00:00:00",
        "2020-01-01",
        "2020-01-01T00:00:00+05:99",
        "2020-01-01T00:00:00Zextra",
    ] {
        let bytes = format!("case,activity,time,lifecycle\nc,A,{value},complete\n");
        let error = parse_csv(bytes.as_bytes(), &m).unwrap_err();
        assert_eq!(error.code, "csv_timestamp");
        assert!(error.message.contains("2"));
    }
    let missing = b"case,activity,time,lifecycle\nc,A,,complete\n";
    assert!(
        parse_csv(missing, &m).unwrap().cases[0].events[0]
            .timestamp
            .is_none()
    );
    m.order = NormalizationOrder::Timestamp;
    assert_eq!(parse_csv(missing, &m).unwrap_err().code, "csv_timestamp");
}

#[test]
fn legacy_csv_mapping_serialization_remains_unchanged_without_fallback() {
    let legacy = serde_json::json!({"case_column":"case","activity_column":"activity","timestamp_column":"time","lifecycle_column":"lifecycle","delimiter":44,"order":"source"});
    let mut m: CsvMapping = serde_json::from_value(legacy.clone()).unwrap();
    assert_eq!(m.naive_timestamp_offset, None);
    assert_eq!(serde_json::to_value(&m).unwrap(), legacy);
    m.naive_timestamp_offset = Some("+00:00".into());
    assert_eq!(
        serde_json::to_value(&m).unwrap()["naive_timestamp_offset"],
        "+00:00"
    );
}
