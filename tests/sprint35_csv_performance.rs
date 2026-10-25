use process_intelligence_rs::{
    csv_io::{CsvMapping, NormalizationOrder},
    csv_performance::{Cohort, Report, analyze_csv},
};

fn mapping() -> CsvMapping {
    CsvMapping {
        case_column: "case".into(),
        activity_column: "activity".into(),
        timestamp_column: Some("end".into()),
        naive_timestamp_offset: None,
        lifecycle_column: None,
        delimiter: b',',
        order: NormalizationOrder::Source,
    }
}
fn cohort<'a>(report: &'a Report, kind: &str) -> &'a Cohort {
    report.cohorts.iter().find(|v| v.kind == kind).unwrap()
}

#[test]
fn exact_case_partition_preserves_nanosecond_boundary_and_signed_overlap() {
    let csv = b"case,activity,start,end\nf,A,2020-01-01T00:00:00Z,2020-01-01T01:00:00Z\nf,B,2020-01-01T00:30:00Z,2020-01-01T02:00:00Z\nf,A,2020-01-01T03:00:00Z,2020-01-01T04:00:00Z\nb,C,2020-01-01T00:00:00Z,2020-01-02T00:00:00Z\ns,D,2020-01-01T00:00:00Z,2020-01-02T00:00:00.000000001Z\n";
    let report = analyze_csv(csv, &mapping(), "start", 1).unwrap();
    let all = cohort(&report, "all");
    assert_eq!(
        (
            all.cases,
            all.events,
            all.activity_count,
            all.transition_count
        ),
        (3, 5, 4, 2)
    );
    assert_eq!(
        all.cycle.as_ref().unwrap().sum_nanoseconds,
        "187200000000001"
    );
    assert_eq!(cohort(&report, "fast").cases, 1);
    assert_eq!(cohort(&report, "boundary").cases, 1);
    assert_eq!(cohort(&report, "slow").cases, 1);
    assert_eq!(
        cohort(&report, "boundary")
            .cycle
            .as_ref()
            .unwrap()
            .min_nanoseconds,
        "86400000000000"
    );
    assert_eq!(
        cohort(&report, "slow")
            .cycle
            .as_ref()
            .unwrap()
            .min_nanoseconds,
        "86400000000001"
    );
    let a = all.activities.iter().find(|v| v.activity == "A").unwrap();
    assert_eq!((a.events, a.cases), (2, 1));
    assert_eq!(a.processing.sum_nanoseconds, "7200000000000");
    let overlap = all
        .transitions
        .iter()
        .find(|v| v.source == "A" && v.target == "B")
        .unwrap();
    assert_eq!(overlap.end_to_start.sum_nanoseconds, "-1800000000000");
    assert_eq!(overlap.end_to_start.negative_samples, 1);
    assert_eq!(all.negative_intervals, 1);
    assert_eq!(all.returns.len(), 1);
    assert_eq!((&*all.returns[0].source, &*all.returns[0].via), ("A", "B"));
    assert_eq!((all.returns[0].occurrences, all.returns[0].cases), (1, 1));
    assert!(!report.author_signature_verified);
    assert_eq!(report.method_sha256.len(), 64);
}

#[test]
fn timestamp_order_keeps_each_start_end_pair_together() {
    let csv = b"case,activity,start,end\nc,A,2020-01-01T10:00:00Z,2020-01-01T12:00:00Z\nc,B,2020-01-01T08:00:00Z,2020-01-01T09:00:00Z\nc,C,2020-01-01T11:00:00Z,2020-01-01T13:00:00Z\n";
    let mut m = mapping();
    let original = analyze_csv(csv, &m, "start", 28).unwrap();
    let source = cohort(&original, "all");
    assert_eq!(
        source.cycle.as_ref().unwrap().sum_nanoseconds,
        "18000000000000"
    );
    assert_eq!(
        source
            .transitions
            .iter()
            .find(|v| v.source == "A" && v.target == "B")
            .unwrap()
            .end_to_start
            .mean_seconds,
        -14400.0
    );
    m.order = NormalizationOrder::Timestamp;
    let sorted = analyze_csv(csv, &m, "start", 28).unwrap();
    let sorted = cohort(&sorted, "all");
    assert_eq!(
        sorted
            .transitions
            .iter()
            .find(|v| v.source == "B" && v.target == "A")
            .unwrap()
            .end_to_start
            .mean_seconds,
        3600.0
    );
    assert_eq!(
        sorted
            .transitions
            .iter()
            .find(|v| v.source == "A" && v.target == "C")
            .unwrap()
            .end_to_start
            .mean_seconds,
        -3600.0
    );
    assert_eq!(
        sorted
            .activities
            .iter()
            .find(|v| v.activity == "A")
            .unwrap()
            .processing
            .mean_seconds,
        7200.0
    );
    assert_eq!(
        sorted.cycle.as_ref().unwrap().sum_nanoseconds,
        source.cycle.as_ref().unwrap().sum_nanoseconds
    );
}

#[test]
fn empty_groups_have_no_duration_and_unknown_timestamps_are_not_zero() {
    let report = analyze_csv(b"case,activity,start,end\n", &mapping(), "start", 28).unwrap();
    assert_eq!(report.status, "no_data");
    assert!(
        report
            .cohorts
            .iter()
            .all(|g| g.cases == 0 && g.cycle.is_none())
    );
    for row in [
        "c,A,,2020-01-01T00:00:00Z",
        "c,A,2020-01-01T00:00:00Z,",
        "c,A,2020-01-02T00:00:00Z,2020-01-01T00:00:00Z",
    ] {
        let bytes = format!("case,activity,start,end\n{row}\n");
        let error = analyze_csv(bytes.as_bytes(), &mapping(), "start", 28).unwrap_err();
        assert_eq!(error.code, "csv_performance");
        assert!(error.message.contains("1"));
    }
    for cutoff in [0, 3651, u32::MAX] {
        assert!(analyze_csv(b"case,activity,start,end\n", &mapping(), "start", cutoff).is_err());
    }
    assert!(analyze_csv(b"case,activity,start,end\n", &mapping(), "end", 28).is_err());
}

#[test]
fn explicit_fallback_applies_to_each_column_without_replacing_aware_values() {
    let csv = b"case,activity,start,end\nc,A,2020-01-01T00:00:00,2020-01-01T00:00:00Z\n";
    let mut m = mapping();
    assert_eq!(
        analyze_csv(csv, &m, "start", 28).unwrap_err().code,
        "csv_timestamp"
    );
    m.naive_timestamp_offset = Some("+05:00".into());
    let report = analyze_csv(csv, &m, "start", 28).unwrap();
    assert_eq!(
        cohort(&report, "all").cycle.as_ref().unwrap().mean_seconds,
        18000.0
    );
    assert_eq!(report.naive_timestamp_offset.as_deref(), Some("+05:00"));
}

#[test]
fn truncated_details_keep_global_counts_and_overlaps() {
    let mut csv = String::from("case,activity,start,end\n");
    for i in 0..61 {
        csv.push_str(&format!(
            "c,A{i},2020-01-01T00:00:00Z,2020-01-01T00:00:01Z\n"
        ));
    }
    let report = analyze_csv(csv.as_bytes(), &mapping(), "start", 28).unwrap();
    let all = cohort(&report, "all");
    assert_eq!(
        (
            all.cases,
            all.events,
            all.activity_count,
            all.transition_count
        ),
        (1, 61, 61, 60)
    );
    assert_eq!(all.negative_intervals, 60);
    assert!(all.details_truncated);
    assert_eq!(all.activities.len(), report.detail_limit_per_cohort);
    assert_eq!(all.transitions.len(), report.detail_limit_per_cohort);
    assert_eq!(all.cycle.as_ref().unwrap().mean_seconds, 1.0);
}
