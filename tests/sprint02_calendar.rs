use chrono::{DateTime, NaiveDate, Utc};
use process_intelligence_rs::calendar::{CalendarSpec, business_millis};
fn t(s: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
}
fn spec() -> CalendarSpec {
    CalendarSpec {
        offset_minutes: 300,
        weekdays: vec![1, 2, 3, 4, 5],
        start_minute: 540,
        end_minute: 1080,
        holidays: vec![],
    }
}
#[test]
fn actual_fixed_offset_weekend_and_half_open_boundaries() {
    let s = spec();
    for (start, end, hours) in [
        ("2026-10-09T17:00:00+05:00", "2026-10-12T10:00:00+05:00", 2),
        ("2026-10-12T09:00:00+05:00", "2026-10-12T18:00:00+05:00", 9),
        ("2026-10-09T18:00:00+05:00", "2026-10-12T09:00:00+05:00", 0),
        ("2026-10-12T00:00:00+05:00", "2026-10-12T09:00:00+05:00", 0),
    ] {
        assert_eq!(
            business_millis(t(start), t(end), &s).unwrap(),
            hours * 3_600_000
        );
    }
}
#[test]
fn holiday_and_partition_additivity() {
    let mut s = spec();
    s.holidays = vec![NaiveDate::from_ymd_opt(2026, 10, 12).unwrap()];
    assert_eq!(
        business_millis(
            t("2026-10-09T17:00:00+05:00"),
            t("2026-10-13T10:00:00+05:00"),
            &s
        )
        .unwrap(),
        7_200_000
    );
    let s = spec();
    let a = t("2026-10-09T17:20:00+05:00");
    let b = t("2026-10-11T12:00:00+05:00");
    let c = t("2026-10-12T10:15:00+05:00");
    assert_eq!(
        business_millis(a, c, &s).unwrap(),
        business_millis(a, b, &s).unwrap() + business_millis(b, c, &s).unwrap()
    );
    assert_eq!(business_millis(a, a, &s).unwrap(), 0);
}
#[test]
fn negative_span_and_invalid_policy_reject() {
    let a = t("2026-10-12T09:00:00Z");
    let b = t("2026-10-12T10:00:00Z");
    assert!(business_millis(b, a, &spec()).is_err());
    let mut s = spec();
    s.start_minute = 1080;
    s.end_minute = 540;
    assert!(business_millis(a, b, &s).is_err());
    let mut s = spec();
    s.weekdays = vec![0];
    assert!(business_millis(a, b, &s).is_err());
}

#[test]
fn extreme_chrono_and_calendar_collection_limits_return_error_without_panic() {
    let mut s = spec();
    s.offset_minutes = 840;
    assert!(business_millis(DateTime::<Utc>::MAX_UTC, DateTime::<Utc>::MAX_UTC, &s).is_err());
    let a = t("2026-10-12T09:00:00Z");
    let b = t("2026-10-12T10:00:00Z");
    let mut s = spec();
    s.weekdays = vec![8];
    assert!(business_millis(a, b, &s).is_err());
    let mut s = spec();
    s.weekdays = vec![1; 8];
    assert!(business_millis(a, b, &s).is_err());
    let mut s = spec();
    s.holidays = vec![NaiveDate::from_ymd_opt(2026, 10, 12).unwrap(); 3661];
    assert!(business_millis(a, b, &s).is_err());
}
