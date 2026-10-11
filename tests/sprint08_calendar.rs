use chrono::{DateTime, NaiveDate, Utc};
use process_intelligence_rs::calendar::{CalendarSpec, business_millis};

// Frozen manual UTC intersections before calendar implementation. Do not derive
// expectations by asking chrono-tz/the production calendar for its own result.
const MANUAL_FIXTURES: &str = r#"[
 {"name":"berlin_regular_friday","zone":"Europe/Berlin","weekday":5,"open":540,"close":1080,"start":"2026-03-27T00:00:00Z","end":"2026-03-28T00:00:00Z","millis":32400000},
 {"name":"berlin_spring_01_04","zone":"Europe/Berlin","weekday":7,"open":60,"close":240,"start":"2026-03-28T23:00:00Z","end":"2026-03-29T22:00:00Z","millis":7200000},
 {"name":"berlin_fall_01_04","zone":"Europe/Berlin","weekday":7,"open":60,"close":240,"start":"2026-10-24T22:00:00Z","end":"2026-10-25T23:00:00Z","millis":14400000},
 {"name":"berlin_spring_09_18","zone":"Europe/Berlin","weekday":7,"open":540,"close":1080,"start":"2026-03-28T23:00:00Z","end":"2026-03-29T22:00:00Z","millis":32400000},
 {"name":"berlin_fall_09_18","zone":"Europe/Berlin","weekday":7,"open":540,"close":1080,"start":"2026-10-24T22:00:00Z","end":"2026-10-25T23:00:00Z","millis":32400000},
 {"name":"berlin_spring_full_day","zone":"Europe/Berlin","weekday":7,"open":0,"close":1440,"start":"2026-03-28T23:00:00Z","end":"2026-03-29T22:00:00Z","millis":82800000},
 {"name":"berlin_fall_full_day","zone":"Europe/Berlin","weekday":7,"open":0,"close":1440,"start":"2026-10-24T22:00:00Z","end":"2026-10-25T23:00:00Z","millis":90000000},
 {"name":"kathmandu_nonhour","zone":"Asia/Kathmandu","weekday":1,"open":540,"close":1080,"start":"2026-05-31T18:15:00Z","end":"2026-06-01T18:15:00Z","millis":32400000},
 {"name":"kathmandu_local_monday_utc_sunday","zone":"Asia/Kathmandu","weekday":1,"open":0,"close":60,"start":"2026-05-31T18:15:00Z","end":"2026-05-31T19:15:00Z","millis":3600000},
 {"name":"kathmandu_local_holiday","zone":"Asia/Kathmandu","weekday":1,"open":0,"close":1440,"start":"2026-05-31T18:15:00Z","end":"2026-06-01T18:15:00Z","holiday":"2026-06-01","millis":0},
 {"name":"kathmandu_end_1440","zone":"Asia/Kathmandu","weekday":1,"open":0,"close":1440,"start":"2026-05-31T18:15:00Z","end":"2026-06-01T18:15:00Z","millis":86400000},
 {"name":"berlin_clip_45_minutes","zone":"Europe/Berlin","weekday":1,"open":540,"close":1080,"start":"2026-06-01T07:30:00Z","end":"2026-06-01T08:15:00Z","millis":2700000},
 {"name":"berlin_halfopen_close","zone":"Europe/Berlin","weekday":1,"open":540,"close":1080,"start":"2026-06-01T16:00:00Z","end":"2026-06-01T17:00:00Z","millis":0},
 {"name":"berlin_gap_open","zone":"Europe/Berlin","weekday":7,"open":150,"close":240,"start":"2026-03-28T23:00:00Z","end":"2026-03-29T22:00:00Z","error":"calendar_boundary"},
 {"name":"berlin_gap_close","zone":"Europe/Berlin","weekday":7,"open":60,"close":150,"start":"2026-03-28T23:00:00Z","end":"2026-03-29T22:00:00Z","error":"calendar_boundary"},
 {"name":"berlin_fold_open","zone":"Europe/Berlin","weekday":7,"open":150,"close":240,"start":"2026-10-24T22:00:00Z","end":"2026-10-25T23:00:00Z","error":"calendar_boundary"},
 {"name":"berlin_fold_close","zone":"Europe/Berlin","weekday":7,"open":60,"close":150,"start":"2026-10-24T22:00:00Z","end":"2026-10-25T23:00:00Z","error":"calendar_boundary"},
 {"name":"unknown_zone","zone":"Unknown/Nowhere","weekday":1,"open":540,"close":1080,"start":"2026-06-01T00:00:00Z","end":"2026-06-02T00:00:00Z","error":"calendar_timezone"},
 {"name":"inconsistent_offset","zone":"Europe/Berlin","offset":60,"weekday":1,"open":540,"close":1080,"start":"2026-06-01T00:00:00Z","end":"2026-06-02T00:00:00Z","error":"calendar_timezone"}
]"#;

fn utc(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

#[test]
fn frozen_manual_iana_utc_intersections_and_refusals() {
    let fixtures: Vec<serde_json::Value> = serde_json::from_str(MANUAL_FIXTURES).unwrap();
    assert_eq!(fixtures.len(), 19);
    for fixture in fixtures {
        let calendar: CalendarSpec = serde_json::from_value(serde_json::json!({
            "offset_minutes": fixture.get("offset").and_then(|v| v.as_i64()).unwrap_or(0),
            "timezone": fixture["zone"],
            "weekdays": [fixture["weekday"]],
            "start_minute": fixture["open"],
            "end_minute": fixture["close"],
            "holidays": fixture.get("holiday").map(|v| vec![v.clone()]).unwrap_or_default()
        }))
        .unwrap();
        let result = business_millis(
            utc(fixture["start"].as_str().unwrap()),
            utc(fixture["end"].as_str().unwrap()),
            &calendar,
        );
        if let Some(error) = fixture.get("error") {
            assert_eq!(
                result.unwrap_err().code,
                error.as_str().unwrap(),
                "{}",
                fixture["name"]
            );
        } else {
            assert_eq!(
                result.unwrap(),
                fixture["millis"].as_i64().unwrap(),
                "{}",
                fixture["name"]
            );
        }
    }
}

#[test]
fn legacy_json_roundtrip_and_fixedoffset_nonhour_unchanged() {
    let old = serde_json::json!({"offset_minutes":345,"weekdays":[1],"start_minute":0,"end_minute":60,"holidays":[]});
    let calendar: CalendarSpec = serde_json::from_value(old.clone()).unwrap();
    assert!(calendar.timezone.is_none());
    assert_eq!(serde_json::to_value(&calendar).unwrap(), old);
    assert_eq!(
        business_millis(
            utc("2026-05-31T18:15:00Z"),
            utc("2026-05-31T19:15:00Z"),
            &calendar
        )
        .unwrap(),
        3_600_000
    );
    assert!(CalendarSpec::default().timezone.is_none());
}

#[test]
fn checked_limits_empty_intervals_and_invalid_zone() {
    let mut calendar = CalendarSpec {
        timezone: Some("Europe/Berlin".into()),
        weekdays: vec![7],
        start_minute: 150,
        end_minute: 240,
        ..Default::default()
    };
    let instant = utc("2026-03-29T00:00:00Z");
    assert_eq!(business_millis(instant, instant, &calendar).unwrap(), 0);
    calendar.timezone = Some("".into());
    assert_eq!(
        business_millis(instant, instant, &calendar)
            .unwrap_err()
            .code,
        "calendar_timezone"
    );
    calendar.timezone = Some("Etc/GMT-1".into());
    assert_eq!(
        business_millis(
            DateTime::<Utc>::MAX_UTC - chrono::Duration::minutes(30),
            DateTime::<Utc>::MAX_UTC,
            &calendar
        )
        .unwrap_err()
        .code,
        "calendar_limit"
    );
    calendar.timezone = Some("UTC".into());
    let begin = NaiveDate::from_ymd_opt(2026, 1, 1)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();
    assert_eq!(
        business_millis(begin, begin + chrono::Duration::days(3661), &calendar)
            .unwrap_err()
            .code,
        "calendar_limit"
    );
}

#[test]
fn named_endexclusive_midnight_avoids_unrelated_next_day_gap() {
    let calendar = CalendarSpec {
        timezone: Some("Europe/Berlin".into()),
        weekdays: vec![7],
        start_minute: 150,
        end_minute: 240,
        ..Default::default()
    };
    // Saturday ends at Sunday midnight, before Sunday's nonexistent02:30 work boundary.
    assert_eq!(
        business_millis(
            utc("2026-03-28T12:00:00Z"),
            utc("2026-03-28T23:00:00Z"),
            &calendar
        )
        .unwrap(),
        0
    );
}

#[test]
fn repeated_midnight_refuses_but_same_date_fold_clipping_remains_valid() {
    let calendar = CalendarSpec {
        timezone: Some("Pacific/Apia".into()),
        weekdays: vec![1, 2, 3, 4, 5, 6, 7],
        start_minute: 0,
        end_minute: 1440,
        ..Default::default()
    };
    // IANA2025b australasia: Apia +12:33:04 until1892Jul05 local,
    // then -11:26:56: UTC11:26:56 repeats July04 local midnight.
    assert_eq!(
        business_millis(
            utc("1892-07-04T11:26:55Z"),
            utc("1892-07-04T11:26:56Z"),
            &calendar
        )
        .unwrap_err()
        .code,
        "calendar_boundary"
    );
    let calendar = CalendarSpec {
        timezone: Some("Europe/Berlin".into()),
        weekdays: vec![7],
        start_minute: 60,
        end_minute: 240,
        ..Default::default()
    };
    // UTC half an hour remains half an hour even as local02:45 returns to02:15.
    assert_eq!(
        business_millis(
            utc("2026-10-25T00:45:00Z"),
            utc("2026-10-25T01:15:00Z"),
            &calendar
        )
        .unwrap(),
        1_800_000
    );
}
