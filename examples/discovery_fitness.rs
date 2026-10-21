//! Optional developer experiment: exact pinned Petri alignment fitness only.
//! `mine NEW_DIR`, then separate `align DIR NEW_RESULT_JSON` after hash review.
//! No BPMN bridge, precision, simplicity, external-tool replication or R4 closure.
use process_intelligence_rs::{
    discovery,
    domain::{Case, Event, EventLog},
};
use process_mining::{
    PetriNet,
    conformance::alignments::{self, AlignmentOptions},
    core::{
        event_data::case_centric::utils::activity_projection::EventLogActivityProjection,
        process_models::case_centric::petri_net::{ArcType, Marking},
    },
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io::Write,
    path::{Path, PathBuf},
    time::Instant,
};
use uuid::Uuid;

pub const CORPUS: &str = include_str!("../fixtures/discovery-fitness/corpus.json");
pub const MAX_MARKINGS: usize = 10_000;
type Result<T> = std::result::Result<T, String>;

pub fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn array(value: &Value) -> Result<&Vec<Value>> {
    value.as_array().ok_or_else(|| "expected_array".into())
}
fn string(value: &Value) -> Result<&str> {
    value.as_str().ok_or_else(|| "expected_string".into())
}
fn integer(value: &Value) -> Result<u64> {
    value.as_u64().ok_or_else(|| "expected_integer".into())
}
fn corpus() -> Result<Value> {
    serde_json::from_str(CORPUS).map_err(|e| e.to_string())
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    file.write_all(bytes).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())
}
fn json_bytes(value: &Value) -> Result<Vec<u8>> {
    serde_json::to_vec_pretty(value).map_err(|e| e.to_string())
}

/// Wide-integer exhaustive reachable-marking admission; budget failure is inconclusive.
/// This does not enumerate visible languages or calculate precision.
pub fn admit(net: &PetriNet, state_limit: usize) -> Result<Value> {
    if net.places.is_empty()
        || net.places.len() + net.transitions.len() > 128
        || net.arcs.len() > 256
        || state_limit == 0
    {
        return Err("net_or_marking_budget".into());
    }
    if net.places.keys().any(|id| net.transitions.contains_key(id)) {
        return Err("overlapping_ids".into());
    }
    let places: Vec<_> = net
        .places
        .keys()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let index: BTreeMap<_, _> = places.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let marking = |mark: &Marking| -> Result<Vec<u64>> {
        let mut out = vec![0; places.len()];
        for (id, count) in mark {
            let i = index.get(&id.0).ok_or("unknown_marking_place")?;
            if *count > 255 {
                return Err("marking_count_above255".into());
            }
            out[*i] = *count;
        }
        Ok(out)
    };
    let initial = marking(net.initial_marking.as_ref().ok_or("missing_initial")?)?;
    let finals = net.final_markings.as_ref().ok_or("missing_final")?;
    if finals.len() != 1 {
        return Err("exactly_one_final_required".into());
    }
    let final_marking = marking(&finals[0])?;
    let mut ends = BTreeSet::new();
    let mut ins: BTreeMap<Uuid, Vec<(usize, u64)>> =
        net.transitions.keys().map(|id| (*id, vec![])).collect();
    let mut outs = ins.clone();
    for arc in &net.arcs {
        if arc.weight == 0 || arc.weight > 255 {
            return Err("arc_weight_outside1to255".into());
        }
        let (from, to) = match arc.from_to {
            ArcType::PlaceTransition(p, t) => {
                let pindex = *index.get(&p).ok_or("unknown_arc_place")?;
                ins.get_mut(&t)
                    .ok_or("unknown_arc_transition")?
                    .push((pindex, arc.weight as u64));
                (p, t)
            }
            ArcType::TransitionPlace(t, p) => {
                let pindex = *index.get(&p).ok_or("unknown_arc_place")?;
                outs.get_mut(&t)
                    .ok_or("unknown_arc_transition")?
                    .push((pindex, arc.weight as u64));
                (t, p)
            }
        };
        if !ends.insert((from, to)) {
            return Err("duplicate_arc_endpoints".into());
        }
    }
    let mut seen = BTreeSet::from([initial.clone()]);
    let mut queue = VecDeque::from([initial]);
    let mut max_token = 0;
    while let Some(current) = queue.pop_front() {
        max_token = max_token.max(*current.iter().max().unwrap_or(&0));
        for (id, inputs) in &ins {
            if inputs.iter().any(|(i, w)| current[*i] < *w) {
                continue;
            }
            let mut next = current.clone();
            for (i, w) in inputs {
                next[*i] -= *w;
            }
            for (i, w) in &outs[id] {
                next[*i] = next[*i].checked_add(*w).ok_or("wide_token_overflow")?;
                if next[*i] > 255 {
                    return Err("reachable_marking_above255".into());
                }
            }
            if !seen.contains(&next) {
                if seen.len() >= state_limit {
                    return Err("reachable_marking_budget_inconclusive".into());
                }
                seen.insert(next.clone());
                queue.push_back(next);
            }
        }
    }
    if !seen.contains(&final_marking) {
        return Err("final_marking_unreachable".into());
    }
    Ok(
        json!({"status":"exhaustive_reachable_marking_admission","markings":seen.len(),"max_tokens_per_place":max_token,"limit":state_limit}),
    )
}

/// Deterministic IDs implement the frozen symbolic manual nets, not mined graphs.
pub fn manual_net(spec: &Value) -> Result<PetriNet> {
    let mut net = PetriNet::new();
    let mut places = BTreeMap::new();
    let mut transitions = BTreeMap::new();
    for (i, name) in array(&spec["places"])?.iter().enumerate() {
        places.insert(
            string(name)?.to_owned(),
            net.add_place(Some(Uuid::from_u128(i as u128 + 1))),
        );
    }
    let labels = spec["transitions"].as_object().ok_or("transition_object")?;
    for (i, (name, label)) in labels.iter().enumerate() {
        let label = if label.is_null() {
            None
        } else {
            Some(string(label)?.to_owned())
        };
        transitions.insert(
            name.clone(),
            net.add_transition(label, Some(Uuid::from_u128(i as u128 + 1001))),
        );
    }
    for edge in array(&spec["arcs"])? {
        let edge = array(edge)?;
        if edge.len() != 2 {
            return Err("manual_edge_pair".into());
        }
        let from = string(&edge[0])?;
        let to = string(&edge[1])?;
        let arc = if let (Some(p), Some(t)) = (places.get(from), transitions.get(to)) {
            ArcType::place_to_transition(*p, *t)
        } else if let (Some(t), Some(p)) = (transitions.get(from), places.get(to)) {
            ArcType::transition_to_place(*t, *p)
        } else {
            return Err("manual_edge_reference".into());
        };
        net.add_arc(arc, Some(1));
    }
    let marking = |value: &Value| -> Result<Marking> {
        value
            .as_object()
            .ok_or("manual_marking")?
            .iter()
            .map(|(id, n)| Ok((*places.get(id).ok_or("manual_marking_place")?, integer(n)?)))
            .collect()
    };
    net.initial_marking = Some(marking(&spec["initial"])?);
    net.final_markings = Some(vec![marking(&spec["final"])?]);
    Ok(net)
}

/// Evaluation projection retains activities absent from the net/training log.
pub fn projection(variants: &Value) -> Result<EventLogActivityProjection> {
    let mut counts: BTreeMap<Vec<String>, u64> = BTreeMap::new();
    let mut traces = 0u64;
    let mut events = 0u64;
    for variant in array(variants)? {
        let sequence = array(&variant["sequence"])?;
        let frequency = integer(&variant["frequency"])?;
        if sequence.len() > 64 || frequency == 0 || frequency > 64 {
            return Err("evaluation_variant_limit".into());
        }
        let mut labels = Vec::new();
        for label in sequence {
            let text = string(label)?;
            if text.is_empty() || text.len() > 200 {
                return Err("evaluation_label_limit".into());
            }
            labels.push(text.to_owned());
        }
        traces = traces.checked_add(frequency).ok_or("evaluation_overflow")?;
        events = events
            .checked_add(
                frequency
                    .checked_mul(sequence.len() as u64)
                    .ok_or("evaluation_overflow")?,
            )
            .ok_or("evaluation_overflow")?;
        *counts.entry(labels).or_default() += frequency;
    }
    if traces == 0 || traces > 64 || events > 500 || counts.len() > 32 {
        return Err("evaluation_log_limit".into());
    }
    let activities: Vec<String> = counts
        .keys()
        .flatten()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let act_to_index = activities
        .iter()
        .enumerate()
        .map(|(i, label)| (label.clone(), i))
        .collect();
    let mapped = counts
        .into_iter()
        .map(|(labels, freq)| {
            (
                labels
                    .iter()
                    .map(|label| activities.binary_search(label).expect("collected_activity"))
                    .collect(),
                freq,
            )
        })
        .collect();
    Ok(EventLogActivityProjection {
        activities,
        act_to_index,
        traces: mapped,
    })
}

fn expected_rows(spec: &Value, cases: &[Value]) -> Result<Value> {
    let id = string(&spec["id"])?;
    if id == "M09" {
        let rows: Result<Vec<Value>> = array(&spec["aggregate_case_ids"])?
            .iter()
            .map(|id| {
                let found = cases
                    .iter()
                    .find(|row| row["id"] == *id)
                    .ok_or("aggregate_case_missing")?;
                Ok(json!({"sequence":found["sequence"],"frequency":found["frequency"]}))
            })
            .collect();
        Ok(Value::Array(rows?))
    } else {
        Ok(json!([{"sequence":spec["sequence"],"frequency":spec["frequency"]}]))
    }
}

fn rational(value: &Value) -> Result<f64> {
    let raw = string(value)?;
    let parts: Vec<_> = raw.split('/').collect();
    let numerator = parts[0].parse::<f64>().map_err(|_| "rational_numerator")?;
    let denominator = if parts.len() == 2 {
        parts[1]
            .parse::<f64>()
            .map_err(|_| "rational_denominator")?
    } else if parts.len() == 1 {
        1.0
    } else {
        return Err("rational_parts".into());
    };
    if !numerator.is_finite() || !denominator.is_finite() || denominator <= 0.0 {
        return Err("rational_nonfinite".into());
    }
    Ok(numerator / denominator)
}

/// Always call wide marking admission before the u8 upstream search.
pub fn evaluate(net: &PetriNet, variants: &Value, max_states: usize) -> Result<Value> {
    let admission = admit(net, MAX_MARKINGS)?;
    let projection = projection(variants)?;
    let options = AlignmentOptions {
        max_states: Some(max_states),
        ..AlignmentOptions::default()
    };
    let begin = Instant::now();
    let alignments = alignments::align_variants(net, &projection, &options);
    let empty = match alignments::align_empty_trace(net, &options) {
        Ok(value) => value,
        Err(error) => {
            return Ok(
                json!({"status":"inconclusive","stage":"empty_alignment","error":error,"admission":admission,"projection":projection,"alignments":alignments,"elapsed_alignment_group_ns":begin.elapsed().as_nanos()}),
            );
        }
    };
    let fitness = match alignments::compute_fitness(&alignments, net, &options) {
        Ok(value) => value,
        Err(error) => {
            return Ok(
                json!({"status":"inconclusive","stage":"aggregate","error":error,"admission":admission,"projection":projection,"alignments":alignments,"empty_alignment":empty,"elapsed_alignment_group_ns":begin.elapsed().as_nanos()}),
            );
        }
    };
    let elapsed = begin.elapsed().as_nanos();
    let mut total_cost = 0u64;
    let mut total_traces = 0u64;
    let mut denominator = 0u64;
    let mut perfect = 0u64;
    let mut average_sum = 0.0;
    for variant in &alignments {
        let result = variant
            .result
            .as_ref()
            .map_err(|e| format!("variant_alignment_inconclusive:{e}"))?;
        let den = variant.activities.len() as u64 + u64::from(empty.cost);
        total_cost += variant.frequency * u64::from(result.cost);
        total_traces += variant.frequency;
        denominator += variant.frequency * den;
        if result.cost == 0 {
            perfect += variant.frequency;
        }
        average_sum += variant.frequency as f64
            * if den == 0 {
                1.0
            } else {
                1.0 - result.cost as f64 / den as f64
            };
    }
    let independent_log = if denominator == 0 {
        1.0
    } else {
        1.0 - total_cost as f64 / denominator as f64
    };
    let independent_average = average_sum / total_traces as f64;
    let independent_perfect = perfect as f64 / total_traces as f64;
    if fitness.total_costs != total_cost
        || (fitness.log_fitness - independent_log).abs() > 1e-12
        || (fitness.average_fitness - independent_average).abs() > 1e-12
        || (fitness.perfectly_fitting_frac - independent_perfect).abs() > 1e-12
    {
        return Err("independent_weighting_mismatch".into());
    }
    Ok(
        json!({"status":"measured","admission":admission,"projection":projection,"alignments":alignments,"empty_alignment":empty,"fitness":fitness,"integer_check":{"weighted_total_cost":total_cost,"traces":total_traces,"denominator":denominator,"perfect_traces":perfect},"elapsed_alignment_group_ns":elapsed,"memory_measurement":null,"memory_policy":"OS supervisor may record process peak separately; absent here, not zero"}),
    )
}

/// Check exact hand-calculated costs and ratios, with full raw results retained.
pub fn manual_suite(manifest: &Value) -> Result<Value> {
    let cases = array(&manifest["cases"])?;
    let mut results = Vec::new();
    let mut all_pass = true;
    for spec in cases
        .iter()
        .filter(|row| row["id"].as_str().is_some_and(|id| id.starts_with('M')))
    {
        let net_name = string(&spec["net"])?;
        let net = manual_net(&manifest["manual_nets"][net_name])?;
        let input = expected_rows(spec, cases)?;
        let result = evaluate(&net, &input, 100_000);
        let (measurement, pass) = match result {
            Ok(row) => {
                let pass = if row["status"] != "measured" {
                    false
                } else if spec["id"] == "M09" {
                    row["integer_check"]["weighted_total_cost"]
                        == spec["expected_weighted_total_cost"]
                        && row["integer_check"]["denominator"] == spec["expected_denominator"]
                        && row["integer_check"]["traces"] == spec["expected_trace_count"]
                        && (row["fitness"]["log_fitness"]
                            .as_f64()
                            .ok_or("fitness_number")?
                            - rational(&spec["expected_log_fitness"])?)
                        .abs()
                            <= 1e-12
                        && (row["fitness"]["average_fitness"]
                            .as_f64()
                            .ok_or("fitness_number")?
                            - rational(&spec["expected_average_trace_fitness"])?)
                        .abs()
                            <= 1e-12
                        && (row["fitness"]["perfectly_fitting_frac"]
                            .as_f64()
                            .ok_or("fitness_number")?
                            - rational(&spec["expected_perfect_fraction"])?)
                        .abs()
                            <= 1e-12
                } else {
                    row["alignments"][0]["result"]["Ok"]["cost"] == spec["expected_cost"]
                        && (row["fitness"]["log_fitness"]
                            .as_f64()
                            .ok_or("fitness_number")?
                            - rational(&spec["expected_fitness"])?)
                        .abs()
                            <= 1e-12
                };
                let pass = pass
                    && row["empty_alignment"]["cost"]
                        == manifest["manual_nets"][net_name]["empty_alignment_cost"];
                (row, pass)
            }
            Err(error) => (json!({"status":"inconclusive","error":error}), false),
        };
        all_pass &= pass;
        results
            .push(json!({"id":spec["id"],"expected":spec,"passed":pass,"measurement":measurement}));
    }
    Ok(json!({"all_manual_checks_pass":all_pass,"cases":results}))
}

fn training_log(variants: &Value) -> Result<EventLog> {
    let projection = projection(variants)?;
    let mut cases = Vec::new();
    for (indices, freq) in projection.traces {
        for _ in 0..freq {
            let events = indices
                .iter()
                .enumerate()
                .map(|(ordinal, index)| Event {
                    ordinal,
                    activity: projection.activities[*index].clone(),
                    timestamp: None,
                    lifecycle: None,
                })
                .collect();
            cases.push(Case {
                id: format!("training-{}", cases.len()),
                name: None,
                events,
            });
        }
    }
    Ok(EventLog {
        name: Some("frozen-training-only".into()),
        warnings: vec![],
        cases,
    })
}

fn mine(directory: &Path) -> Result<()> {
    std::fs::create_dir(directory).map_err(|e| e.to_string())?;
    let manifest = corpus()?;
    let mut nets = Vec::new();
    for spec in array(&manifest["cases"])?
        .iter()
        .filter(|row| row["id"].as_str().is_some_and(|id| id.starts_with('A')))
    {
        let id = string(&spec["id"])?;
        let log = training_log(&spec["training"])?;
        let before = serde_json::to_vec(&log).map_err(|e| e.to_string())?;
        let begin = Instant::now();
        let discovered =
            discovery::discover(&log, &|| false).map_err(|e| format!("discovery_refused:{e:?}"))?;
        let elapsed = begin.elapsed().as_nanos();
        if serde_json::to_vec(&log).map_err(|e| e.to_string())? != before {
            return Err("training_input_mutated".into());
        }
        let net_bytes = serde_json::to_vec_pretty(&discovered.net).map_err(|e| e.to_string())?;
        let net_file = format!("{id}.net.json");
        let pnml_file = format!("{id}.pnml");
        write_new(&directory.join(&net_file), &net_bytes)?;
        write_new(&directory.join(&pnml_file), discovered.pnml.as_bytes())?;
        write_new(&directory.join(format!("{id}.training.json")), &before)?;
        nets.push(json!({"id":id,"net_file":net_file,"net_sha256":sha(&net_bytes),"pnml_file":pnml_file,"pnml_sha256":sha(discovered.pnml.as_bytes()),"training_sha256":sha(&before),"algorithm":discovered.algorithm,"library":discovered.library,"config":discovered.config,"projected_variants":discovered.variants,"elapsed_discovery_adapter_ns":elapsed,"admission":admit(&discovered.net,MAX_MARKINGS).unwrap_or_else(|e|json!({"status":"inconclusive","error":e}))}));
    }
    let bundle = json!({"schema_version":1,"phase":"mine_only_no_alignment","corpus_sha256":sha(CORPUS.as_bytes()),"observer_source_sha256":sha(include_bytes!("discovery_fitness.rs")),"nets":nets});
    write_new(&directory.join("bundle.json"), &json_bytes(&bundle)?)
}

fn safe_artifact(directory: &Path, name: &str) -> Result<PathBuf> {
    if name.contains('/')
        || name.contains('\\')
        || name.contains(':')
        || name == "."
        || name == ".."
    {
        return Err("unsafe_artifact_name".into());
    }
    Ok(directory.join(name))
}
fn read_bounded(path: &Path) -> Result<Vec<u8>> {
    if std::fs::metadata(path).map_err(|e| e.to_string())?.len() > 4 * 1024 * 1024 {
        return Err("artifact_byte_limit".into());
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("artifact_byte_limit".into());
    }
    Ok(bytes)
}
fn align(directory: &Path, output: &Path) -> Result<()> {
    let bundle_bytes = read_bounded(&directory.join("bundle.json"))?;
    let bundle: Value = serde_json::from_slice(&bundle_bytes).map_err(|e| e.to_string())?;
    if bundle["corpus_sha256"] != sha(CORPUS.as_bytes())
        || bundle["phase"] != "mine_only_no_alignment"
    {
        return Err("bundle_corpus_or_phase_mismatch".into());
    }
    let manifest = corpus()?;
    let manual = manual_suite(&manifest)?;
    let mut rows = Vec::new();
    for spec in array(&manifest["cases"])?
        .iter()
        .filter(|row| row["id"].as_str().is_some_and(|id| id.starts_with('A')))
    {
        let artifact = array(&bundle["nets"])?
            .iter()
            .find(|n| n["id"] == spec["id"])
            .ok_or("saved_net_missing")?;
        let net_bytes = read_bounded(&safe_artifact(directory, string(&artifact["net_file"])?)?)?;
        if artifact["net_sha256"] != sha(&net_bytes) {
            return Err("saved_net_hash_mismatch".into());
        }
        let net: PetriNet = serde_json::from_slice(&net_bytes).map_err(|e| e.to_string())?;
        let mut evaluations = Vec::new();
        for key in ["training", "diagnostic_held_out"] {
            let measurement = match evaluate(&net, &spec[key], 100_000) {
                Ok(row) => row,
                Err(error) => json!({"status":"inconclusive","error":error}),
            };
            evaluations
                .push(json!({"group":key,"frozen_input":spec[key],"measurement":measurement}));
        }
        rows.push(json!({"id":spec["id"],"net_sha256":artifact["net_sha256"],"frozen_ideal_hypothesis":spec,"evaluations":evaluations}));
    }
    let result = json!({"schema_version":1,"phase":"align_only_no_discovery","corpus_sha256":sha(CORPUS.as_bytes()),"bundle_sha256":sha(&bundle_bytes),"observer_source_sha256":sha(include_bytes!("discovery_fitness.rs")),"scope":manifest["scope"],"manual_reference_checks":manual,"actual_alpha_observations":rows,"not_acceptance":true});
    write_new(output, &json_bytes(&result)?)
}

fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    let result = match args.get(1).and_then(|s| s.to_str()) {
        Some("mine") if args.len() == 3 => mine(Path::new(&args[2])),
        Some("align") if args.len() == 4 => align(Path::new(&args[2]), Path::new(&args[3])),
        _ => Err("usage: discovery_fitness mine NEW_DIR | align SAVED_DIR NEW_RESULT_JSON".into()),
    };
    result.map_err(std::io::Error::other)?;
    Ok(())
}
