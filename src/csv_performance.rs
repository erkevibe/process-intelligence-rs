//! Read-only CSV interval preview. Start/end pairs do not change stored events.
use crate::{
    csv_io::{self, CsvMapping, NormalizationOrder},
    domain::ImportError,
    storage::sha256,
};
use chrono::{DateTime, TimeDelta, Utc};
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::OnceLock,
};

const DETAILS: usize = 50;
const DAY_NANOS: i128 = 86_400_000_000_000;

#[derive(Debug, Serialize)]
pub struct DurationStats {
    pub samples: usize,
    pub sum_nanoseconds: String,
    pub min_nanoseconds: String,
    pub max_nanoseconds: String,
    pub negative_samples: usize,
    pub mean_seconds: f64,
}
#[derive(Default)]
struct Accumulator {
    count: usize,
    sum: i128,
    min: Option<i128>,
    max: Option<i128>,
    negative: usize,
}
impl Accumulator {
    fn add(&mut self, value: i128) {
        self.count += 1;
        self.sum += value;
        self.min = Some(self.min.map_or(value, |v| v.min(value)));
        self.max = Some(self.max.map_or(value, |v| v.max(value)));
        self.negative += usize::from(value < 0);
    }
    fn finish(self) -> Option<DurationStats> {
        Some(DurationStats {
            samples: self.count,
            sum_nanoseconds: self.sum.to_string(),
            min_nanoseconds: self.min?.to_string(),
            max_nanoseconds: self.max?.to_string(),
            negative_samples: self.negative,
            mean_seconds: self.sum as f64 / self.count as f64 / 1e9,
        })
    }
}
#[derive(Debug, Serialize)]
pub struct ActivityStats {
    pub activity: String,
    pub events: usize,
    pub cases: usize,
    pub processing: DurationStats,
}
#[derive(Default)]
struct Activity {
    events: usize,
    cases: usize,
    processing: Accumulator,
}
#[derive(Debug, Serialize)]
pub struct TransitionStats {
    pub source: String,
    pub target: String,
    pub cases: usize,
    pub end_to_start: DurationStats,
}
#[derive(Default)]
struct Transition {
    cases: usize,
    interval: Accumulator,
}
#[derive(Debug, Serialize)]
pub struct ReturnStats {
    pub source: String,
    pub via: String,
    pub occurrences: usize,
    pub cases: usize,
}
#[derive(Default)]
struct Returns {
    occurrences: usize,
    cases: usize,
}
#[derive(Debug, Serialize)]
pub struct Cohort {
    pub kind: &'static str,
    pub cases: usize,
    pub events: usize,
    pub cycle: Option<DurationStats>,
    pub activity_count: usize,
    pub transition_count: usize,
    pub return_pattern_count: usize,
    pub negative_intervals: usize,
    pub activities: Vec<ActivityStats>,
    pub transitions: Vec<TransitionStats>,
    pub returns: Vec<ReturnStats>,
    pub details_truncated: bool,
}
#[derive(Default)]
struct Group {
    cases: usize,
    events: usize,
    cycle: Accumulator,
    activities: BTreeMap<String, Activity>,
    transitions: BTreeMap<(String, String), Transition>,
    returns: BTreeMap<(String, String), Returns>,
}
struct Paired<'a> {
    activity: &'a str,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    ordinal: usize,
}
fn nanos(value: TimeDelta) -> i128 {
    i128::from(value.num_seconds()) * 1_000_000_000 + i128::from(value.subsec_nanos())
}
impl Group {
    fn add_case(&mut self, events: &[Paired<'_>], cycle: i128) {
        self.cases += 1;
        self.events += events.len();
        self.cycle.add(cycle);
        let mut activities = BTreeSet::new();
        for event in events {
            let activity = self.activities.entry(event.activity.into()).or_default();
            activity.events += 1;
            activity.processing.add(nanos(event.end - event.start));
            activities.insert(event.activity);
        }
        for name in activities {
            self.activities.get_mut(name).expect("seen activity").cases += 1;
        }
        let mut transitions = BTreeSet::new();
        for pair in events.windows(2) {
            let key = (pair[0].activity.to_owned(), pair[1].activity.to_owned());
            self.transitions
                .entry(key.clone())
                .or_default()
                .interval
                .add(nanos(pair[1].start - pair[0].end));
            transitions.insert(key);
        }
        for key in transitions {
            self.transitions
                .get_mut(&key)
                .expect("seen transition")
                .cases += 1;
        }
        let mut returns = BTreeSet::new();
        for triple in events.windows(3) {
            if triple[0].activity == triple[2].activity && triple[0].activity != triple[1].activity
            {
                let key = (triple[0].activity.to_owned(), triple[1].activity.to_owned());
                self.returns.entry(key.clone()).or_default().occurrences += 1;
                returns.insert(key);
            }
        }
        for key in returns {
            self.returns.get_mut(&key).expect("seen return").cases += 1;
        }
    }
    fn finish(self, kind: &'static str) -> Cohort {
        let (activity_count, transition_count, return_pattern_count) = (
            self.activities.len(),
            self.transitions.len(),
            self.returns.len(),
        );
        let negative_intervals = self.transitions.values().map(|v| v.interval.negative).sum();
        let mut activities: Vec<_> = self.activities.into_iter().collect();
        activities.sort_by(|(an, a), (bn, b)| {
            b.cases
                .cmp(&a.cases)
                .then(b.events.cmp(&a.events))
                .then(an.cmp(bn))
        });
        let mut transitions: Vec<_> = self.transitions.into_iter().collect();
        transitions.sort_by(|(ak, a), (bk, b)| {
            (b.interval.sum * a.interval.count as i128)
                .cmp(&(a.interval.sum * b.interval.count as i128))
                .then(b.interval.count.cmp(&a.interval.count))
                .then(ak.cmp(bk))
        });
        let mut returns: Vec<_> = self.returns.into_iter().collect();
        returns.sort_by(|(ak, a), (bk, b)| b.occurrences.cmp(&a.occurrences).then(ak.cmp(bk)));
        Cohort {
            kind,
            cases: self.cases,
            events: self.events,
            cycle: self.cycle.finish(),
            activity_count,
            transition_count,
            return_pattern_count,
            negative_intervals,
            details_truncated: [activity_count, transition_count, return_pattern_count]
                .into_iter()
                .any(|n| n > DETAILS),
            activities: activities
                .into_iter()
                .take(DETAILS)
                .map(|(activity, value)| ActivityStats {
                    activity,
                    events: value.events,
                    cases: value.cases,
                    processing: value.processing.finish().expect("activity has events"),
                })
                .collect(),
            transitions: transitions
                .into_iter()
                .take(DETAILS)
                .map(|((source, target), value)| TransitionStats {
                    source,
                    target,
                    cases: value.cases,
                    end_to_start: value.interval.finish().expect("transition has events"),
                })
                .collect(),
            returns: returns
                .into_iter()
                .take(DETAILS)
                .map(|((source, via), value)| ReturnStats {
                    source,
                    via,
                    occurrences: value.occurrences,
                    cases: value.cases,
                })
                .collect(),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub schema_version: u8,
    pub status: &'static str,
    pub algorithm: &'static str,
    pub method_sha256: String,
    pub source_sha256: String,
    pub source_bytes: usize,
    pub case_column: String,
    pub activity_column: String,
    pub start_column: String,
    pub end_column: String,
    pub naive_timestamp_offset: Option<String>,
    pub order: NormalizationOrder,
    pub threshold_days: u32,
    pub detail_limit_per_cohort: usize,
    pub cohorts: Vec<Cohort>,
    pub author_signature_verified: bool,
}
fn refused(message: impl Into<String>) -> ImportError {
    ImportError::new("csv_performance", message)
}
fn method() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(|| {
        sha256(
            &serde_json::to_vec(&serde_json::json!({
                "algorithm":"csv_start_end_preview_v1",
                "performance_source":include_str!("csv_performance.rs").replace("\r\n","\n"),
                "csv_source":include_str!("csv_io.rs").replace("\r\n","\n"),
            }))
            .expect("method JSON"),
        )
    })
}

pub fn analyze_csv(
    input: &[u8],
    mapping: &CsvMapping,
    start_column: &str,
    threshold_days: u32,
) -> Result<Report, ImportError> {
    if !(1..=3650).contains(&threshold_days) {
        return Err(refused(
            "Граница длительности должна быть от 1 до 3650 дней.",
        ));
    }
    let end_column = mapping
        .timestamp_column
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| refused("Выберите колонку окончания в поле времени события."))?;
    if start_column.is_empty() || start_column == end_column {
        return Err(refused(
            "Выберите разные колонки начала и окончания действия.",
        ));
    }
    let mut end_mapping = mapping.clone();
    end_mapping.order = NormalizationOrder::Source;
    let end_log = csv_io::parse_csv(input, &end_mapping)?;
    let mut start_mapping = end_mapping;
    start_mapping.timestamp_column = Some(start_column.into());
    let start_log = csv_io::parse_csv(input, &start_mapping)?;
    let mut groups: [Group; 4] = std::array::from_fn(|_| Group::default());
    let threshold = i128::from(threshold_days) * DAY_NANOS;
    for (end_case, start_case) in end_log.cases.iter().zip(&start_log.cases) {
        let mut events = Vec::with_capacity(end_case.events.len());
        for (end, start) in end_case.events.iter().zip(&start_case.events) {
            let record = end.ordinal + 1;
            let (start_time, end_time) = start.timestamp.zip(end.timestamp).ok_or_else(|| {
                refused(format!(
                    "Запись {record}: нужны обе отметки начала и окончания."
                ))
            })?;
            if end_time < start_time {
                return Err(refused(format!(
                    "Запись {record}: окончание действия раньше его начала."
                )));
            }
            events.push(Paired {
                activity: &end.activity,
                start: start_time,
                end: end_time,
                ordinal: end.ordinal,
            });
        }
        if mapping.order == NormalizationOrder::Timestamp {
            events.sort_by_key(|e| (e.end, e.ordinal));
        }
        let earliest = events
            .iter()
            .map(|e| e.start)
            .min()
            .expect("CSV cases contain records");
        let latest = events
            .iter()
            .map(|e| e.end)
            .max()
            .expect("CSV cases contain records");
        let cycle = nanos(latest - earliest);
        let cohort = match cycle.cmp(&threshold) {
            std::cmp::Ordering::Less => 1,
            std::cmp::Ordering::Equal => 2,
            std::cmp::Ordering::Greater => 3,
        };
        groups[0].add_case(&events, cycle);
        groups[cohort].add_case(&events, cycle);
    }
    let status = if groups[0].cases == 0 {
        "no_data"
    } else {
        "measured"
    };
    Ok(Report {
        schema_version: 1,
        status,
        algorithm: "csv_start_end_preview_v1",
        method_sha256: method().into(),
        source_sha256: sha256(input),
        source_bytes: input.len(),
        case_column: mapping.case_column.clone(),
        activity_column: mapping.activity_column.clone(),
        start_column: start_column.into(),
        end_column: end_column.into(),
        naive_timestamp_offset: mapping.naive_timestamp_offset.clone(),
        order: mapping.order,
        threshold_days,
        detail_limit_per_cohort: DETAILS,
        cohorts: groups
            .into_iter()
            .zip(["all", "fast", "boundary", "slow"])
            .map(|(g, kind)| g.finish(kind))
            .collect(),
        author_signature_verified: false,
    })
}
