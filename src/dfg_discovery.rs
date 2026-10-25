//! Bounded directly-follows state machine. Captures observed adjacency, not concurrency.
use crate::{
    bpmn::{self, ModelFlow, ModelNode, NodeKind, ProcessModel},
    bpmn_quality::{self as quality, Issue, Limits, Result},
    domain::{EventLog, ImportError},
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

pub const ALGORITHM: &str = "directly_follows_state_machine_v1";
pub const PROFILE: &str = "full_log_state_machine_v1";
pub const MAX_CASES: usize = 1000;
pub const MAX_EVENTS: usize = 20000;
pub const MAX_VARIANTS: usize = 256;
pub const MAX_ACTIVITIES: usize = 32;
pub const MAX_TRACE: usize = 64;
pub type Variants = BTreeMap<Vec<String>, u64>;

pub fn rows(log: &EventLog) -> std::result::Result<Value, ImportError> {
    if log.cases.len() > MAX_CASES {
        return Err(ImportError::new(
            "full_log_limit",
            "Предел полного профиля: 1000 случаев и 20 000 событий.",
        ));
    }
    let mut variants = Variants::new();
    let mut events = 0usize;
    for case in &log.cases {
        events = events
            .checked_add(case.events.len())
            .ok_or_else(|| ImportError::new("full_log_limit", "Слишком много событий."))?;
        if events > MAX_EVENTS || case.events.len() > MAX_TRACE {
            return Err(ImportError::new(
                "full_log_limit",
                "Предел: 20 000 событий всего, 64 события в случае.",
            ));
        }
        *variants
            .entry(case.events.iter().map(|e| e.activity.clone()).collect())
            .or_default() += 1;
        if variants.len() > MAX_VARIANTS {
            return Err(ImportError::new("full_log_limit", "Предел: 256 вариантов."));
        }
    }
    let rows = json!(
        variants
            .iter()
            .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
            .collect::<Vec<_>>()
    );
    parse_rows(&rows).map_err(|_| {
        ImportError::new(
            "full_log_limit",
            "Не поддерживаются метки или размер журнала.",
        )
    })?;
    Ok(rows)
}
pub fn parse_rows(rows: &Value) -> Result<Variants> {
    let rows = rows
        .as_array()
        .ok_or_else(|| Issue::refused("expected_array"))?;
    if rows.len() > MAX_VARIANTS {
        return Err(Issue::refused("full_log_variant_limit"));
    }
    let mut result = Variants::new();
    let mut cases = 0u64;
    let mut events = 0u64;
    let mut labels = BTreeSet::new();
    for row in rows {
        let map = row
            .as_object()
            .ok_or_else(|| Issue::refused("expected_variant"))?;
        if map.len() != 2 || !map.contains_key("sequence") || !map.contains_key("frequency") {
            return Err(Issue::refused("variant_fields"));
        }
        let sequence = row["sequence"]
            .as_array()
            .ok_or_else(|| Issue::refused("expected_array"))?;
        let frequency = row["frequency"]
            .as_u64()
            .filter(|n| *n > 0 && *n <= MAX_CASES as u64)
            .ok_or_else(|| Issue::refused("full_log_frequency_limit"))?;
        if sequence.len() > MAX_TRACE {
            return Err(Issue::refused("full_log_trace_limit"));
        }
        let mut trace = Vec::with_capacity(sequence.len());
        for label in sequence {
            let s = label
                .as_str()
                .filter(|s| {
                    !s.trim().is_empty() && s.len() <= 200 && !s.chars().any(char::is_control)
                })
                .ok_or_else(|| Issue::refused("full_log_label_limit"))?;
            labels.insert(s);
            trace.push(s.to_owned());
        }
        cases += frequency;
        events += frequency * sequence.len() as u64;
        if cases > MAX_CASES as u64 || events > MAX_EVENTS as u64 || labels.len() > MAX_ACTIVITIES {
            return Err(Issue::refused("full_log_input_limit"));
        }
        if result.insert(trace, frequency).is_some() {
            return Err(Issue::refused("duplicate_variant"));
        }
    }
    Ok(result)
}
fn node(nodes: &mut Vec<ModelNode>, kind: NodeKind, label: String) -> String {
    let i = nodes.len();
    let id = format!("d{i}");
    nodes.push(ModelNode {
        id: id.clone(),
        kind,
        label,
        x: 100. + (i % 8) as f64 * 190.,
        y: 100. + (i / 8) as f64 * 140.,
        dimensions: None,
    });
    id
}
fn flow(flows: &mut Vec<ModelFlow>, source: &str, target: &str) {
    flows.push(ModelFlow {
        id: format!("e{}", flows.len()),
        source: source.into(),
        target: target.into(),
        label: String::new(),
        waypoints: vec![],
    });
}
pub fn discover(
    rows: &Value,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<ProcessModel> {
    let variants = parse_rows(rows)?;
    if variants.is_empty() {
        return Err(Issue::refused("no_data"));
    }
    checkpoint("discover")?;
    let labels: BTreeSet<_> = variants.keys().flatten().cloned().collect();
    let mut nodes = Vec::new();
    let mut flows = Vec::new();
    let start = node(&mut nodes, NodeKind::Start, "Начало".into());
    let end = node(&mut nodes, NodeKind::End, "Конец".into());
    let entry = node(&mut nodes, NodeKind::ExclusiveGateway, String::new());
    let exit = node(&mut nodes, NodeKind::ExclusiveGateway, String::new());
    flow(&mut flows, &start, &entry);
    flow(&mut flows, &exit, &end);
    let mut parts = BTreeMap::new();
    for label in labels {
        checkpoint("discover")?;
        let incoming = node(&mut nodes, NodeKind::ExclusiveGateway, String::new());
        let task = node(&mut nodes, NodeKind::Task, label.clone());
        let outgoing = node(&mut nodes, NodeKind::ExclusiveGateway, String::new());
        flow(&mut flows, &incoming, &task);
        flow(&mut flows, &task, &outgoing);
        parts.insert(label, (incoming, outgoing));
    }
    let mut edges = BTreeSet::new();
    for trace in variants.keys() {
        checkpoint("discover")?;
        if let (Some(first), Some(last)) = (trace.first(), trace.last()) {
            edges.insert((entry.clone(), parts[first].0.clone()));
            edges.insert((parts[last].1.clone(), exit.clone()));
            for pair in trace.windows(2) {
                edges.insert((parts[&pair[0]].1.clone(), parts[&pair[1]].0.clone()));
            }
        } else {
            edges.insert((entry.clone(), exit.clone()));
        }
    }
    for (a, b) in edges {
        flow(&mut flows, &a, &b);
    }
    if flows.len() > 256 {
        return Err(Issue::refused("full_log_model_limit"));
    }
    let model = ProcessModel {
        schema_version: 1,
        process_id: ALGORITHM.into(),
        name: "Непосредственные переходы: конечный автомат".into(),
        nodes,
        flows,
        discovery: None,
    };
    bpmn::validate(&model).map_err(|e| Issue::refused(&e.code))?;
    Ok(model)
}
pub fn limits() -> Limits {
    Limits {
        nodes: 512,
        arcs: 1024,
        markings: 1000,
        fitness: 1000,
        prefix: 1000,
        tau: 1000,
        equivalence: 1000,
    }
}
pub fn evaluate(
    model: &ProcessModel,
    rows: &Value,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    checkpoint("validate")?;
    let variants = parse_rows(rows)?;
    if model.nodes.len() > 128 || model.flows.len() > 256 {
        return Err(Issue::refused("full_log_model_limit"));
    }
    bpmn::validate(model).map_err(|e| Issue::refused(&e.code))?;
    let canonical = json!(
        variants
            .iter()
            .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
            .collect::<Vec<_>>()
    );
    let (net, _) = quality::bridge::from_model(model)?;
    let raw = serde_json::to_vec(
        &serde_json::to_value(&net).map_err(|_| Issue::refused("net_serialization"))?,
    )
    .map_err(|_| Issue::refused("net_serialization"))?;
    checkpoint("markings")?;
    let graph = quality::state::admit(&net, &quality::sha(&raw), limits())?;
    checkpoint("fitness")?;
    let fitness = quality::metrics::fitness(&net, &variants, limits());
    checkpoint("precision")?;
    let precision =
        quality::metrics::precision_compact(&graph, &variants, &fitness, limits(), checkpoint)?;
    let mut compact = json!({"status":fitness["status"]});
    for k in ["reason", "fitness", "integer_components", "costs", "scalar"] {
        if let Some(v) = fitness.get(k) {
            compact[k] = v.clone();
        }
    }
    let value = json!({"schema_version":1,"profile":PROFILE,"algorithm":ALGORITHM,"trace_count":variants.values().sum::<u64>(),"variant_count":variants.len(),"model_sha256":quality::sha(&serde_json::to_vec(model).map_err(|_|Issue::refused("model_serialization"))?),"variants_sha256":quality::sha(&serde_json::to_vec(&canonical).map_err(|_|Issue::refused("variant_serialization"))?),"metrics":{"fitness":compact,"precision":precision,"simplicity":quality::metrics::simplicity(&net)},"marking_states":graph.states.len(),"limits":limits(),"policy":"all_cases_no_sampling_adjacency_generalization_no_concurrency_inference"});
    if serde_json::to_vec(&value)
        .map_err(|_| Issue::refused("report_serialization"))?
        .len()
        > 64 * 1024
    {
        return Err(Issue::refused("full_log_report_limit"));
    }
    checkpoint("complete")?;
    Ok(value)
}
