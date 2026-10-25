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

pub(crate) fn profile_valid(profile: Option<&str>) -> bool {
    profile.is_none() || profile == Some(PROFILE)
}
pub(crate) fn rows_for(
    log: &EventLog,
    profile: Option<&str>,
) -> std::result::Result<Value, ImportError> {
    match profile {
        None => crate::bpmn_quality_preview::rows(log),
        Some(PROFILE) => rows(log),
        _ => Err(ImportError::new(
            "unsupported_profile",
            "Выберите поддерживаемый профиль.",
        )),
    }
}
pub(crate) fn variants_for(rows: &Value, profile: Option<&str>) -> Result<Variants> {
    match profile {
        None => {
            quality::facade::validate_rows(rows)?;
            quality::metrics::variants(rows)
        }
        Some(PROFILE) => parse_rows(rows),
        _ => Err(Issue::refused("unsupported_profile")),
    }
}
pub fn method_sha256() -> &'static str {
    static HASH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    HASH.get_or_init(||quality::sha(&serde_json::to_vec(&json!({"algorithm":ALGORITHM,"profile":PROFILE,"source":include_str!("dfg_discovery.rs").replace("\r\n","\n"),"bridge":include_str!("full_log_bridge.rs").replace("\r\n","\n"),"legacy_quality_method":crate::quality_store::method_sha256(),"limits":limits()})).expect("method JSON")))
}
pub(crate) fn quality_method(profile: Option<&str>) -> &'static str {
    if profile == Some(PROFILE) {
        method_sha256()
    } else {
        crate::quality_store::method_sha256()
    }
}
pub(crate) fn evaluate_for(
    model: &ProcessModel,
    rows: &Value,
    profile: Option<&str>,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    match profile {
        None => quality::facade::evaluate_model(model, rows, &Value::Null, checkpoint),
        Some(PROFILE) => evaluate(model, rows, checkpoint),
        _ => Err(Issue::refused("unsupported_profile")),
    }
}
pub(crate) fn result_core(result: Result<Value>, profile: Option<&str>) -> Value {
    if profile.is_none() {
        return quality::saved::result_core(result);
    }
    match result {
        Ok(v) => v,
        Err(issue) => {
            json!({"schema_version":1,"profile":PROFILE,"metrics":{"fitness":issue,"precision":{"status":"inconclusive","reason":"model_not_admitted"},"simplicity":{"status":"inconclusive","reason":"model_not_admitted"}}})
        }
    }
}

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
    evaluate_inner(model, rows, checkpoint).map_err(|mut issue| {
        issue.details = Value::Null;
        issue
    })
}
fn evaluate_inner(
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
    let (net, _) = crate::full_log_bridge::from_model(model)?;
    let raw = serde_json::to_vec(
        &serde_json::to_value(&net).map_err(|_| Issue::refused("net_serialization"))?,
    )
    .map_err(|_| Issue::refused("net_serialization"))?;
    checkpoint("markings")?;
    let graph = quality::state::admit(&net, &quality::sha(&raw), limits())?;
    prove_state_machine_soundness(&graph)?;
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
    let value = json!({"schema_version":1,"profile":PROFILE,"evaluation_method":"flow_place_alignment_precision_single_token_v1","trace_count":variants.values().sum::<u64>(),"variant_count":variants.len(),"model_sha256":quality::sha(&serde_json::to_vec(model).map_err(|_|Issue::refused("model_serialization"))?),"variants_sha256":quality::sha(&serde_json::to_vec(&canonical).map_err(|_|Issue::refused("variant_serialization"))?),"metrics":{"fitness":compact,"precision":precision,"simplicity":quality::metrics::simplicity(&net)},"marking_states":graph.states.len(),"limits":limits(),"soundness":{"one_safety":true,"option_to_complete":true,"proper_completion":true,"no_dead_transitions":true,"scope":"enumerated_reachable_markings_for_this_model"},"policy":"all_cases_no_sampling_single_token_no_training_independence_claim"});
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

fn prove_state_machine_soundness(graph: &quality::state::Graph) -> Result<()> {
    if graph.final_states.len() != 1 || graph.states.iter().any(|m| m.iter().sum::<u64>() != 1) {
        return Err(Issue::refused("full_log_not_single_token"));
    }
    let mut reverse = vec![Vec::new(); graph.states.len()];
    let mut live = BTreeSet::new();
    for edge in &graph.edges {
        reverse[edge.to].push(edge.from);
        live.insert(&edge.transition);
    }
    let mut done = BTreeSet::from([graph.final_states[0]]);
    let mut todo = vec![graph.final_states[0]];
    while let Some(s) = todo.pop() {
        for previous in &reverse[s] {
            if done.insert(*previous) {
                todo.push(*previous);
            }
        }
    }
    if done.len() != graph.states.len()
        || live.len() != graph.transitions.len()
        || graph.edges.iter().any(|e| e.from == graph.final_states[0])
    {
        return Err(Issue::refused("full_log_not_sound"));
    }
    Ok(())
}

pub(crate) fn optional_profile<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<String>, D::Error> {
    use serde::Deserialize;
    let value = Option::<String>::deserialize(deserializer)?;
    Ok(value.filter(|s| !s.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn rows(sequences: &[(&[&str], u64)]) -> Value {
        json!(
            sequences
                .iter()
                .map(|(s, n)| json!({"sequence":s,"frequency":n}))
                .collect::<Vec<_>>()
        )
    }
    #[test]
    fn full_profile_counts_limits_and_duplicate_rows_are_explicit() {
        assert!(parse_rows(&rows(&[(&["A"], 625)])).is_ok());
        for bad in [
            rows(&[(&["A"], 1001)]),
            rows(&[(&["A"], 0)]),
            rows(&[(&["A"], u64::MAX)]),
            rows(&[(&["A"], 1), (&["A"], 1)]),
            rows(&[(&["\n"], 1)]),
        ] {
            assert!(parse_rows(&bad).is_err(), "{bad}");
        }
        let long = vec!["A"; 65];
        assert!(parse_rows(&rows(&[(&long, 1)])).is_err());
        let labels: Vec<_> = (0..33).map(|i| i.to_string()).collect();
        let too_many = json!(
            labels
                .iter()
                .map(|s| json!({"sequence":[s],"frequency":1}))
                .collect::<Vec<_>>()
        );
        assert!(parse_rows(&too_many).is_err());
        assert!(parse_rows(&rows(&[(&vec!["A"; 64], 313)])).is_err());
    }
    #[test]
    fn loop_and_empty_case_fit_and_bridge_matches_historical_semantics() {
        let input = rows(&[(&["A", "B", "A", "C"], 2), (&[], 1)]);
        let model = discover(&input, &mut |_| Ok(())).unwrap();
        let (old, _) = quality::bridge::from_model(&model).unwrap();
        let (new, _) = crate::full_log_bridge::from_model(&model).unwrap();
        assert_eq!(
            serde_json::to_value(old).unwrap(),
            serde_json::to_value(new).unwrap()
        );
        let report = evaluate(&model, &input, &mut |_| Ok(())).unwrap();
        assert_eq!(
            report["metrics"]["fitness"]["integer_components"]["weighted_total_cost"],
            0
        );
        let xml = bpmn::serialize(&model).unwrap();
        let imported = bpmn::parse(xml.as_bytes()).unwrap();
        assert_eq!(
            report["metrics"],
            evaluate(&imported, &input, &mut |_| Ok(())).unwrap()["metrics"]
        );
    }
    #[test]
    fn adjacency_generalization_is_measured_instead_of_claimed_exact() {
        let input = rows(&[(&["A", "B", "C"], 1), (&["D", "B", "E"], 1)]);
        let model = discover(&input, &mut |_| Ok(())).unwrap();
        let report = evaluate(&model, &input, &mut |_| Ok(())).unwrap();
        assert!(report["metrics"]["precision"]["scalar"].as_f64().unwrap() < 1.0);
        let unseen = rows(&[(&["A", "B", "E"], 1)]);
        assert_eq!(
            evaluate(&model, &unseen, &mut |_| Ok(())).unwrap()["metrics"]["fitness"]["integer_components"]
                ["weighted_total_cost"],
            0
        );
        let mut reversed = input.as_array().unwrap().clone();
        reversed.reverse();
        assert_eq!(
            serde_json::to_value(&model).unwrap(),
            serde_json::to_value(discover(&json!(reversed), &mut |_| Ok(())).unwrap()).unwrap()
        );
    }
    #[test]
    fn cancellation_precedes_construction() {
        let error = discover(&rows(&[(&["A"], 1)]), &mut |_| {
            Err(Issue::refused("cancelled"))
        })
        .unwrap_err();
        assert_eq!(error.reason, "cancelled");
    }

    #[test]
    fn empty_only_language_has_no_invented_precision_and_unsupported_models_are_bounded() {
        let input = rows(&[(&[], 625)]);
        let model = discover(&input, &mut |_| Ok(())).unwrap();
        let report = evaluate(&model, &input, &mut |_| Ok(())).unwrap();
        assert_eq!(
            report["metrics"]["fitness"]["integer_components"]["weighted_total_cost"],
            0
        );
        assert!(report["metrics"]["precision"]["scalar"].is_null());
        assert_ne!(report["metrics"]["precision"]["status"], "measured");
        let parallel =
            crate::bpmn::parse(include_bytes!("../fixtures/quality/parallel.bpmn")).unwrap();
        let result = evaluate(&parallel, &rows(&[(&["A", "B"], 1)]), &mut |_| Ok(()));
        assert!(result.is_err());
        assert!(result.unwrap_err().details.is_null());
    }
}
