use crate::domain::ImportError;
use chrono::{
    DateTime, Datelike, Duration, FixedOffset, LocalResult, NaiveDate, NaiveDateTime, NaiveTime,
    Offset, TimeZone, Utc,
};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CalendarSpec {
    pub offset_minutes: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
    pub weekdays: Vec<u32>,
    pub start_minute: u32,
    pub end_minute: u32,
    pub holidays: Vec<NaiveDate>,
}
impl Default for CalendarSpec {
    fn default() -> Self {
        Self {
            offset_minutes: 0,
            timezone: None,
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
    let named_zone = spec
        .timezone
        .as_deref()
        .map(|name| {
            if spec.offset_minutes != 0 || name.is_empty() || name.len() > 128 {
                return Err(ImportError::new(
                    "calendar_timezone",
                    "Для именованной зоны укажите известное имя и нулевое фиксированное смещение.",
                ));
            }
            name.parse::<Tz>().map_err(|_| {
                ImportError::new("calendar_timezone", "Неизвестная именованная часовая зона.")
            })
        })
        .transpose()?;
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
    if let Some(zone) = named_zone {
        return named_business_millis(start, end, spec, zone);
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
    let mut total: i64 = 0;
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
                total = total
                    .checked_add((right - left).num_milliseconds())
                    .ok_or_else(calendar_limit)?;
            }
        }
        let Some(next) = date.succ_opt() else { break };
        date = next;
    }
    Ok(total)
}

fn calendar_limit() -> ImportError {
    ImportError::new(
        "calendar_limit",
        "Время или диапазон находится за пределами календаря.",
    )
}

fn checked_named_local(instant: DateTime<Utc>, zone: Tz) -> Result<NaiveDateTime, ImportError> {
    // DateTime::naive_local can panic near chrono's representable limits.
    let seconds = zone
        .offset_from_utc_datetime(&instant.naive_utc())
        .fix()
        .local_minus_utc();
    instant
        .naive_utc()
        .checked_add_signed(Duration::seconds(i64::from(seconds)))
        .ok_or_else(calendar_limit)
}

fn named_boundary(zone: Tz, local: NaiveDateTime) -> Result<DateTime<Utc>, ImportError> {
    match zone.from_local_datetime(&local) {
        LocalResult::Single(value) => Ok(value.with_timezone(&Utc)),
        LocalResult::Ambiguous(_, _) | LocalResult::None => Err(ImportError::new(
            "calendar_boundary",
            "Рабочая граница неоднозначна или не существует в выбранной часовой зоне. Измените расписание.",
        )),
    }
}

fn named_business_millis(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    spec: &CalendarSpec,
    zone: Tz,
) -> Result<i64, ImportError> {
    if start == end {
        return Ok(0);
    }
    let local_start = checked_named_local(start, zone)?;
    let local_end = checked_named_local(end, zone)?;
    let first = local_start.date();
    let endpoint_date = local_end.date();
    if endpoint_date < first || (endpoint_date == first && local_end.time() == NaiveTime::MIN) {
        return Err(ImportError::new(
            "calendar_boundary",
            "Интервал возвращается к предыдущей локальной дате или повторной полуночи. Исторический переход линии дат не поддерживается.",
        ));
    }
    // Preserve the old endpoint-date span limit before half-open iteration.
    if (endpoint_date - first).num_days() > 3660 {
        return Err(calendar_limit());
    }
    let last = if local_end.time() == NaiveTime::MIN {
        endpoint_date.pred_opt().ok_or_else(calendar_limit)?
    } else {
        endpoint_date
    };
    let mut date = first;
    let mut total: i64 = 0;
    while date <= last {
        if spec.weekdays.contains(&date.weekday().number_from_monday())
            && !spec.holidays.contains(&date)
        {
            let midnight = date.and_hms_opt(0, 0, 0).ok_or_else(calendar_limit)?;
            let open = midnight
                .checked_add_signed(Duration::minutes(i64::from(spec.start_minute)))
                .ok_or_else(calendar_limit)?;
            // 1440 is explicitly next LOCAL midnight, not midnight plus24 UTC hours.
            let close = midnight
                .checked_add_signed(Duration::minutes(i64::from(spec.end_minute)))
                .ok_or_else(calendar_limit)?;
            let from = named_boundary(zone, open)?;
            let to = named_boundary(zone, close)?;
            let left = start.max(from);
            let right = end.min(to);
            if right > left {
                total = total
                    .checked_add((right - left).num_milliseconds())
                    .ok_or_else(calendar_limit)?;
            }
        }
        if date == last {
            break;
        }
        date = date.succ_opt().ok_or_else(calendar_limit)?;
    }
    Ok(total)
}
