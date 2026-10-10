use crate::domain::ImportError;
use chrono::{DateTime, Datelike, Duration, FixedOffset, NaiveDate, TimeZone, Utc};
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CalendarSpec {
    pub offset_minutes: i32,
    pub weekdays: Vec<u32>,
    pub start_minute: u32,
    pub end_minute: u32,
    pub holidays: Vec<NaiveDate>,
}
impl Default for CalendarSpec {
    fn default() -> Self {
        Self {
            offset_minutes: 0,
            weekdays: vec![1, 2, 3, 4, 5],
            start_minute: 540,
            end_minute: 1080,
            holidays: Vec::new(),
        }
    }
}
pub fn business_millis(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    spec: &CalendarSpec,
) -> Result<i64, ImportError> {
    if !(-840..=840).contains(&spec.offset_minutes)
        || spec.start_minute >= spec.end_minute
        || spec.end_minute > 1440
        || spec.weekdays.iter().any(|d| !(1..=7).contains(d))
        || spec.weekdays.len() > 7
        || spec.holidays.len() > 3660
        || end < start
    {
        return Err(ImportError::new(
            "calendar_policy",
            "Неверный календарь или интервал.",
        ));
    }
    let zone = FixedOffset::east_opt(spec.offset_minutes * 60).expect("validated offset");
    let offset = Duration::minutes(spec.offset_minutes as i64);
    let first = start
        .naive_utc()
        .checked_add_signed(offset)
        .ok_or_else(|| {
            ImportError::new("calendar_limit", "Время находится за пределами календаря.")
        })?
        .date();
    let last = end
        .naive_utc()
        .checked_add_signed(offset)
        .ok_or_else(|| {
            ImportError::new("calendar_limit", "Время находится за пределами календаря.")
        })?
        .date();
    if (last - first).num_days() > 3660 {
        return Err(ImportError::new(
            "calendar_limit",
            "Интервал календаря ограничен десятью годами.",
        ));
    }
    let mut date = first;
    let mut total = 0;
    while date <= last {
        if spec.weekdays.contains(&date.weekday().number_from_monday())
            && !spec.holidays.contains(&date)
        {
            let midnight = date.and_hms_opt(0, 0, 0).expect("valid date");
            let open = midnight
                .checked_add_signed(Duration::minutes(spec.start_minute as i64))
                .ok_or_else(|| {
                    ImportError::new("calendar_limit", "Рабочий интервал за пределами календаря.")
                })?;
            let close = midnight
                .checked_add_signed(Duration::minutes(spec.end_minute as i64))
                .ok_or_else(|| {
                    ImportError::new("calendar_limit", "Рабочий интервал за пределами календаря.")
                })?;
            let from = zone
                .from_local_datetime(&open)
                .single()
                .ok_or_else(|| {
                    ImportError::new("calendar_limit", "Рабочий интервал за пределами UTC.")
                })?
                .with_timezone(&Utc);
            let to = zone
                .from_local_datetime(&close)
                .single()
                .ok_or_else(|| {
                    ImportError::new("calendar_limit", "Рабочий интервал за пределами UTC.")
                })?
                .with_timezone(&Utc);
            let left = start.max(from);
            let right = end.min(to);
            if right > left {
                total += (right - left).num_milliseconds();
            }
        }
        let Some(next) = date.succ_opt() else { break };
        date = next;
    }
    Ok(total)
}
