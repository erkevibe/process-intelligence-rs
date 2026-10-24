//! Second-phase Alpha profiles, fixed before validation. No server integration.
use process_intelligence_rs::{
    bpmn::{self, ModelFlow, ModelNode, NodeKind, ProcessModel},
    bpmn_quality::{self as quality, Issue, facade, state},
    discovery,
    domain::{Case, Event, EventLog},
};
use process_mining::{PetriNet, core::process_models::case_centric::petri_net::ArcType};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
    time::Instant,
};
use uuid::Uuid;

struct ProfileResult {
    config: process_mining::discovery::case_centric::alphappp::full::AlphaPPPConfig,
    library: &'static str,
    net: PetriNet,
}
fn discover_profile(
    log: &EventLog,
    profile: &str,
) -> Result<ProfileResult, process_intelligence_rs::domain::ImportError> {
    use process_mining::discovery::case_centric::alphappp::full::{
        AlphaPPPConfig, alphappp_discover_petri_net,
    };
    let fail = |code| {
        process_intelligence_rs::domain::ImportError::new(
            code,
            "Bounded Alpha profile refused the training input.",
        )
    };
    if log.cases.is_empty() || log.cases.len() > discovery::MAX_CASES {
        return Err(fail("discovery_limit"));
    }
    let mut variants = quality::metrics::Variants::new();
    let mut events = 0usize;
    let mut activities = BTreeSet::new();
    for case in &log.cases {
        if case.events.is_empty() {
            return Err(fail("discovery_empty"));
        }
        events += case.events.len();
        if events > discovery::MAX_EVENTS {
            return Err(fail("discovery_limit"));
        }
        let mut sequence = Vec::new();
        for event in &case.events {
            let label = &event.activity;
            if label.trim().is_empty()
                || label.len() > 200
                || label == "__START"
                || label == "__END"
                || label.starts_with("__SILENT__")
            {
                return Err(fail("discovery_activity"));
            }
            activities.insert(label.clone());
            sequence.push(label.clone());
        }
        *variants.entry(sequence).or_default() += 1;
    }
    if activities.len() > discovery::MAX_ACTIVITIES || variants.len() > discovery::MAX_VARIANTS {
        return Err(fail("discovery_limit"));
    }
    let projection = quality::metrics::projection(&variants);
    let mut config = AlphaPPPConfig::default();
    if profile == "alpha-repair" {
        config.absolute_df_clean_thresh = 1;
        config.relative_df_clean_thresh = 0.0;
    } else if profile != "alpha-default" {
        return Err(fail("unknown_profile"));
    }
    let net = std::panic::catch_unwind(|| alphappp_discover_petri_net(&projection, config))
        .map_err(|_| fail("discovery_upstream"))?;
    Ok(ProfileResult {
        config,
        library: "process_mining@0.6.2",
        net,
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Weighted {
    trace: Vec<String>,
    count: u64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    id: String,
    train: Vec<Weighted>,
    held_out: Vec<Weighted>,
    #[serde(default)]
    diagnostic_only: Vec<Weighted>,
}
fn rows(values: &[Weighted]) -> Value {
    Value::Array(
        values
            .iter()
            .map(|v| json!({"sequence":v.trace,"frequency":v.count}))
            .collect(),
    )
}
fn log(values: &[Weighted]) -> Result<EventLog, Box<dyn std::error::Error>> {
    facade::validate_rows(&rows(values))?;
    let mut cases = Vec::new();
    for v in values {
        for _ in 0..v.count {
            cases.push(Case {
                id: format!("case-{}", cases.len()),
                name: None,
                events: v
                    .trace
                    .iter()
                    .enumerate()
                    .map(|(ordinal, activity)| Event {
                        ordinal,
                        activity: activity.clone(),
                        timestamp: None,
                        lifecycle: None,
                    })
                    .collect(),
            });
        }
    }
    Ok(EventLog {
        name: Some("Frozen synthetic training only".into()),
        cases,
        warnings: vec![],
    })
}
fn node(id: String, kind: NodeKind, label: String, index: usize) -> ModelNode {
    ModelNode {
        id,
        kind,
        label,
        x: 100.0 + ((index % 8) * 170) as f64,
        y: 100.0 + ((index / 8) * 130) as f64,
        dimensions: None,
    }
}
/// Colour refinement removes upstream random UUIDs. Ambiguous symmetry is an
/// explicit refusal, not an arbitrary UUID-dependent canonicalization claim.
fn canonical_ids(net: &PetriNet) -> Result<BTreeMap<Uuid, usize>, Issue> {
    let mut base = BTreeMap::new();
    for id in net.places.keys() {
        let initial = net
            .initial_marking
            .as_ref()
            .and_then(|m| m.iter().find(|(p, _)| p.0 == *id).map(|(_, n)| *n))
            .unwrap_or(0);
        let final_ = net
            .final_markings
            .as_ref()
            .and_then(|ms| ms.first())
            .and_then(|m| m.iter().find(|(p, _)| p.0 == *id).map(|(_, n)| *n))
            .unwrap_or(0);
        base.insert(*id, json!(["place", initial, final_]).to_string());
    }
    for (id, t) in &net.transitions {
        base.insert(*id, json!(["transition", t.label]).to_string());
    }
    let ranks = |signatures: &BTreeMap<Uuid, String>| {
        let ordered: BTreeMap<_, _> = signatures
            .values()
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .enumerate()
            .map(|(i, s)| (s, i))
            .collect();
        signatures
            .iter()
            .map(|(id, s)| (*id, ordered[s]))
            .collect::<BTreeMap<_, _>>()
    };
    let mut colors = ranks(&base);
    for _ in 0..base.len() {
        let mut signatures = BTreeMap::new();
        for id in base.keys() {
            let (mut ins, mut outs) = (Vec::new(), Vec::new());
            for a in &net.arcs {
                let (from, to) = match a.from_to {
                    ArcType::PlaceTransition(a, b) | ArcType::TransitionPlace(a, b) => (a, b),
                };
                if to == *id {
                    ins.push((colors[&from], a.weight));
                }
                if from == *id {
                    outs.push((colors[&to], a.weight));
                }
            }
            ins.sort();
            outs.sort();
            signatures.insert(*id, json!([base[id], colors[id], ins, outs]).to_string());
        }
        let next = ranks(&signatures);
        if next == colors {
            break;
        }
        colors = next;
    }
    if colors.values().collect::<BTreeSet<_>>().len() != colors.len() {
        return Err(Issue::unsupported("ambiguous_canonical_node_symmetry"));
    }
    Ok(colors)
}
fn to_bpmn(net: &PetriNet, graph: &state::Graph) -> Result<ProcessModel, Issue> {
    if net.arcs.iter().any(|a| a.weight != 1) {
        return Err(Issue::unsupported("weighted_petri_arc"));
    }
    if graph.states.iter().flatten().any(|n| *n > 1) {
        return Err(Issue::unsupported("petri_not_one_safe"));
    }
    let single = |m: &process_mining::core::process_models::case_centric::petri_net::Marking| {
        if m.len() != 1 {
            return Err(Issue::unsupported("single_workflow_marking_required"));
        }
        let (p, n) = m.iter().next().expect("one entry");
        if *n != 1 {
            return Err(Issue::unsupported("single_workflow_token_required"));
        }
        Ok(p.0)
    };
    let initial = single(
        net.initial_marking
            .as_ref()
            .ok_or_else(|| Issue::refused("initial_marking"))?,
    )?;
    let finals = net
        .final_markings
        .as_ref()
        .ok_or_else(|| Issue::refused("final_marking"))?;
    if finals.len() != 1 {
        return Err(Issue::unsupported("one_final_required"));
    }
    let final_ = single(&finals[0])?;
    if initial == final_ {
        return Err(Issue::unsupported("distinct_source_sink_required"));
    }
    if net.arcs.iter().any(|a| match a.from_to {
        ArcType::TransitionPlace(_, p) => p == initial,
        ArcType::PlaceTransition(p, _) => p == final_,
    }) {
        return Err(Issue::unsupported("workflow_source_sink_required"));
    }
    let colors = canonical_ids(net)?;
    let mut ordered: Vec<_> = colors.iter().map(|(id, color)| (*color, *id)).collect();
    ordered.sort();
    let mut model = ProcessModel {
        schema_version: 1,
        process_id: "alpha_experiment".into(),
        name: "Alpha+++ experimental Petri conversion".into(),
        nodes: vec![],
        flows: vec![],
        discovery: None,
    };
    let mut incoming = BTreeMap::new();
    let mut outgoing = BTreeMap::new();
    for a in &net.arcs {
        let (from, to) = match a.from_to {
            ArcType::PlaceTransition(a, b) | ArcType::TransitionPlace(a, b) => (a, b),
        };
        *incoming.entry(to).or_insert(0usize) += 1;
        *outgoing.entry(from).or_insert(0usize) += 1;
    }
    let mut inputs = BTreeMap::new();
    let mut outputs = BTreeMap::new();
    let mut edges = BTreeSet::new();
    for (color, id) in ordered {
        if net.places.contains_key(&id) {
            let name = format!("p{color}");
            model.nodes.push(node(
                name.clone(),
                NodeKind::ExclusiveGateway,
                String::new(),
                model.nodes.len(),
            ));
            inputs.insert(id, name.clone());
            outputs.insert(id, name);
        } else {
            let t = &net.transitions[&id];
            let name = format!("t{color}");
            let kind = if t.label.is_some() {
                NodeKind::Task
            } else {
                NodeKind::ParallelGateway
            };
            model.nodes.push(node(
                name.clone(),
                kind,
                t.label.clone().unwrap_or_default(),
                model.nodes.len(),
            ));
            let mut input = name.clone();
            let mut output = name.clone();
            if t.label.is_some() && incoming.get(&id).copied().unwrap_or(0) > 1 {
                input = format!("join{color}");
                model.nodes.push(node(
                    input.clone(),
                    NodeKind::ParallelGateway,
                    String::new(),
                    model.nodes.len(),
                ));
                edges.insert((input.clone(), name.clone()));
            }
            if t.label.is_some() && outgoing.get(&id).copied().unwrap_or(0) > 1 {
                output = format!("split{color}");
                model.nodes.push(node(
                    output.clone(),
                    NodeKind::ParallelGateway,
                    String::new(),
                    model.nodes.len(),
                ));
                edges.insert((name, output.clone()));
            }
            inputs.insert(id, input);
            outputs.insert(id, output);
        }
    }
    for a in &net.arcs {
        let (from, to) = match a.from_to {
            ArcType::PlaceTransition(a, b) | ArcType::TransitionPlace(a, b) => (a, b),
        };
        edges.insert((outputs[&from].clone(), inputs[&to].clone()));
    }
    model.nodes.push(node(
        "start".into(),
        NodeKind::Start,
        String::new(),
        model.nodes.len(),
    ));
    model.nodes.push(node(
        "end".into(),
        NodeKind::End,
        String::new(),
        model.nodes.len(),
    ));
    edges.insert(("start".into(), inputs[&initial].clone()));
    edges.insert((outputs[&final_].clone(), "end".into()));
    model.flows = edges
        .into_iter()
        .enumerate()
        .map(|(i, (source, target))| ModelFlow {
            id: format!("f{i}"),
            source,
            target,
            waypoints: vec![],
            label: String::new(),
        })
        .collect();
    bpmn::validate(&model).map_err(|e| Issue::refused(&e.code))?;
    Ok(model)
}
struct Output<'a> {
    path: &'a Path,
    total: usize,
    count: usize,
}
impl Output<'_> {
    fn raw(&mut self, name: &str, raw: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
        self.total += raw.len();
        self.count += 1;
        if raw.len() > 8 * 1024 * 1024 || self.total > 16 * 1024 * 1024 || self.count > 16 {
            return Err("experiment output cap".into());
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.path.join(name))?;
        file.write_all(raw)?;
        Ok(())
    }
    fn json(
        &mut self,
        name: &str,
        value: &impl serde::Serialize,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.raw(name, &serde_json::to_vec(value)?)
    }
}
fn score(model: &ProcessModel, rows: &Value) -> Value {
    let started = Instant::now();
    match facade::evaluate_model(model, rows, &Value::Null, &mut |_| {
        if started.elapsed().as_secs() >= 30 {
            Err(Issue::cap("experiment_deadline"))
        } else {
            Ok(())
        }
    }) {
        Ok(v) => json!({"status":"evaluated","report":v}),
        Err(e) => json!({"status":"not_evaluated","issue":e}),
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 || !matches!(args[1].as_str(), "alpha-default" | "alpha-repair") {
        return Err(
            "miner_alpha_profiles alpha-default|alpha-repair INPUT_JSON NEW_EMPTY_DIR".into(),
        );
    }
    let mut bytes = Vec::new();
    fs::File::open(&args[2])?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err("input cap".into());
    }
    let input: Input = serde_json::from_slice(&bytes)?;
    let train = rows(&input.train);
    let held = rows(&input.held_out);
    let diagnostic = rows(&input.diagnostic_only);
    facade::validate_rows(&train)?;
    facade::validate_rows(&held)?;
    facade::validate_rows(&diagnostic)?;
    let train_log = log(&input.train)?;
    let path = Path::new(&args[3]);
    if !path.is_dir() || fs::read_dir(path)?.next().is_some() {
        return Err("new empty output required".into());
    }
    let mut out = Output {
        path,
        total: 0,
        count: 0,
    };
    out.json("train.json", &train)?;
    out.json("held-out.json", &held)?;
    out.json("diagnostic-only.json", &diagnostic)?;
    let mut result = json!({"schema_version":1,"case":input.id,"algorithm":args[1],"input_sha256":quality::sha(&bytes),"held_out_supplied_to_miner":false,"application_profile":1000});
    if train_log.cases.is_empty() {
        result["status"] = json!("no_data");
        result["discovery_invoked"] = json!(false);
        out.json("result.json", &result)?;
        return Ok(());
    }
    let started = Instant::now();
    let model = if args[1] == "observed" {
        match bpmn::discover(&train_log) {
            Ok(m) => Ok(m),
            Err(e) => Err(json!({"status":"discovery_refused","error":e})),
        }
    } else {
        match discover_profile(&train_log, &args[1]) {
            Err(e) => Err(json!({"status":"discovery_refused","error":e})),
            Ok(found) => {
                result["config"] = serde_json::to_value(found.config)?;
                result["library"] = json!(found.library);
                let value = serde_json::to_value(&found.net)?;
                let raw = serde_json::to_vec(&value)?;
                out.raw("upstream-net.json", &raw)?;
                match state::admit(
                    &found.net,
                    &quality::sha(&raw),
                    facade::application_limits(&Value::Null)?,
                ) {
                    Err(e) => Err(json!({"status":"upstream_net_not_admitted","issue":e})),
                    Ok(graph) => {
                        out.json("upstream-graph.json", &graph)?;
                        match to_bpmn(&found.net, &graph) {
                            Ok(m) => Ok(m),
                            Err(e) => Err(json!({"status":"conversion_refused","issue":e})),
                        }
                    }
                }
            }
        }
    };
    result["discovery_and_conversion_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
    match model {
        Err(error) => {
            result["outcome"] = error;
            result["status"] = json!("not_modelled");
        }
        Ok(model) => {
            out.json("model.json", &model)?;
            let xml = bpmn::serialize(&model)?;
            out.raw("model.bpmn", xml.as_bytes())?;
            let imported = bpmn::parse(xml.as_bytes())?;
            out.json("reimported-model.json", &imported)?;
            let (net, _) = quality::bridge::from_model(&model)?;
            let value = serde_json::to_value(&net)?;
            let raw = serde_json::to_vec(&value)?;
            out.raw("bpmn-net.json", &raw)?;
            match state::admit(
                &net,
                &quality::sha(&raw),
                facade::application_limits(&Value::Null)?,
            ) {
                Ok(graph) => {
                    out.json("bpmn-graph.json", &graph)?;
                    result["reachable_states"] = json!(graph.states.len());
                }
                Err(e) => {
                    result["bpmn_admission_issue"] = serde_json::to_value(e)?;
                }
            }
            let training = score(&model, &train);
            let control = score(&model, &held);
            let imported_control = score(&imported, &held);
            result["export_reimport_status_identical"] = json!(
                control["status"] == imported_control["status"]
                    && control["issue"] == imported_control["issue"]
            );
            result["export_reimport_metrics_identical"] =
                if control["status"] == "evaluated" && imported_control["status"] == "evaluated" {
                    json!(control["report"]["metrics"] == imported_control["report"]["metrics"])
                } else {
                    Value::Null
                };
            if !input.diagnostic_only.is_empty() {
                result["diagnostic_only"] = score(&model, &diagnostic);
            }
            result["training"] = training;
            result["held_out"] = control;
            result["reimported_held_out"] = imported_control;
            result["model_sha256"] = json!(quality::sha(&serde_json::to_vec(&model)?));
            result["status"] = json!("modelled");
        }
    }
    out.json("result.json", &result)?;
    println!(
        "{}",
        json!({"status":result["status"],"case":result["case"],"algorithm":result["algorithm"]})
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use process_mining::core::process_models::case_centric::petri_net::Marking;
    fn net(parallel: bool, duplicate: bool) -> PetriNet {
        let mut net = PetriNet::new();
        let s = net.add_place(None);
        let e = net.add_place(None);
        let a = net.add_transition(Some("A".into()), None);
        let d = net.add_transition(Some("D".into()), None);
        net.add_arc(ArcType::place_to_transition(s, a), None);
        net.add_arc(ArcType::transition_to_place(d, e), None);
        for label in if parallel { vec!["B", "C"] } else { vec!["B"] } {
            let p = net.add_place(None);
            let q = net.add_place(None);
            let t = net.add_transition(Some(label.into()), None);
            net.add_arc(ArcType::transition_to_place(a, p), None);
            net.add_arc(ArcType::place_to_transition(p, t), None);
            net.add_arc(ArcType::transition_to_place(t, q), None);
            net.add_arc(ArcType::place_to_transition(q, d), None);
            if duplicate {
                let other = net.add_place(None);
                net.add_arc(ArcType::transition_to_place(a, other), None);
                net.add_arc(ArcType::place_to_transition(other, t), None);
            }
        }
        net.initial_marking = Some(Marking::from([(s, 1)]));
        net.final_markings = Some(vec![Marking::from([(e, 1)])]);
        net
    }
    fn graph(net: &PetriNet) -> state::Graph {
        let raw = serde_json::to_vec(&serde_json::to_value(net).unwrap()).unwrap();
        state::admit(
            net,
            &quality::sha(&raw),
            facade::application_limits(&Value::Null).unwrap(),
        )
        .unwrap()
    }
    fn fitness(model: &ProcessModel, trace: &[&str]) -> f64 {
        let score = score(model, &json!([{"sequence":trace,"frequency":1}]));
        score["report"]["metrics"]["fitness"]["fitness"]["log_fitness"]
            .as_f64()
            .unwrap()
    }
    #[test]
    fn linear_conversion_roundtrip_and_uuid_independent_identity() {
        let first = net(false, false);
        let second = net(false, false);
        let one = to_bpmn(&first, &graph(&first)).unwrap();
        let two = to_bpmn(&second, &graph(&second)).unwrap();
        assert_eq!(one, two);
        assert_eq!(fitness(&one, &["A", "B", "D"]), 1.0);
        let xml = bpmn::serialize(&one).unwrap();
        let imported = bpmn::parse(xml.as_bytes()).unwrap();
        assert_eq!(fitness(&imported, &["A", "B", "D"]), 1.0);
        assert!(fitness(&imported, &["A", "D"]) < 1.0);
    }
    #[test]
    fn parallel_conversion_preserves_both_orders_and_join_requirement() {
        let source = net(true, false);
        let model = to_bpmn(&source, &graph(&source)).unwrap();
        assert_eq!(fitness(&model, &["A", "B", "C", "D"]), 1.0);
        assert_eq!(fitness(&model, &["A", "C", "B", "D"]), 1.0);
        assert!(fitness(&model, &["A", "B", "D"]) < 1.0);
        assert!(fitness(&model, &["A", "D", "B", "C"]) < 1.0);
    }
    #[test]
    fn ambiguous_symmetry_and_weighted_arcs_are_explicit_refusals() {
        let mut source = net(false, true);
        let saved = graph(&source);
        assert_eq!(
            to_bpmn(&source, &saved).unwrap_err().reason,
            "ambiguous_canonical_node_symmetry"
        );
        source.arcs[0].weight = 2;
        assert_eq!(
            to_bpmn(&source, &saved).unwrap_err().reason,
            "weighted_petri_arc"
        );
    }
}
