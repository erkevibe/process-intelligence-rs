use super::state::Graph;
use super::{Issue, Limits, Result, array, integer, status, text};
use process_mining::{
    PetriNet,
    conformance::alignments::{self, AlignmentOptions},
    core::event_data::case_centric::utils::activity_projection::EventLogActivityProjection,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub type Variants = BTreeMap<Vec<String>, u64>;
pub fn variants(rows: &Value) -> Result<Variants> {
    let mut result = Variants::new();
    let mut traces = 0;
    let mut events = 0;
    for row in array(rows)? {
        let sequence: Vec<String> = array(&row["sequence"])?
            .iter()
            .map(|value| Ok(text(value)?.to_owned()))
            .collect::<Result<_>>()?;
        let frequency = integer(&row["frequency"])?;
        if frequency == 0
            || frequency > 64
            || sequence.len() > 64
            || sequence.iter().any(|s| s.is_empty() || s.len() > 200)
        {
            return Err(Issue::refused("evaluation_variant_limit"));
        }
        traces += frequency;
        events += frequency * sequence.len() as u64;
        *result.entry(sequence).or_default() += frequency;
        if traces > 64 || events > 500 || result.len() > 32 {
            return Err(Issue::refused("evaluation_log_limit"));
        }
    }
    Ok(result)
}
pub fn projection(variants: &Variants) -> EventLogActivityProjection {
    let activities: Vec<_> = variants
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
    let traces = variants
        .iter()
        .map(|(sequence, frequency)| {
            (
                sequence
                    .iter()
                    .map(|label| activities.binary_search(label).expect("collected_label"))
                    .collect(),
                *frequency,
            )
        })
        .collect();
    EventLogActivityProjection {
        activities,
        act_to_index,
        traces,
    }
}
pub fn fitness(net: &PetriNet, variants: &Variants, limits: Limits) -> Value {
    if variants.is_empty() {
        return status("no_data");
    }
    let projection = projection(variants);
    let options = AlignmentOptions {
        max_states: Some(limits.fitness),
        ..AlignmentOptions::default()
    };
    let alignments = alignments::align_variants(net, &projection, &options);
    let empty = alignments::align_empty_trace(net, &options);
    let fitness = alignments::compute_fitness(&alignments, net, &options);
    match (&empty, &fitness) {
        (Ok(empty), Ok(fitness)) => {
            let trace_count: u64 = variants.values().sum();
            let events: u64 = variants.iter().map(|(s, f)| s.len() as u64 * f).sum();
            let denominator = events + trace_count * u64::from(empty.cost);
            json!({"status":"measured","projection":projection,"alignments":alignments,"empty_alignment":empty,"fitness":fitness,"integer_components":{"traces":trace_count,"events":events,"empty_cost":empty.cost,"weighted_total_cost":fitness.total_costs,"log_denominator":denominator},"costs":{"model":1,"log":1,"sync":0,"tau":0}})
        }
        _ => {
            json!({"status":"inconclusive","reason":"fitness_search_failure","projection":projection,"alignments":alignments,"empty_alignment":empty,"aggregate":fitness,"scalar":null})
        }
    }
}
pub fn tau_closure(
    graph: &Graph,
    adjacency: &[Vec<usize>],
    starts: &BTreeSet<usize>,
    limit: usize,
) -> Result<BTreeSet<usize>> {
    if starts.len() > limit {
        return Err(Issue::cap("tau_closure_budget"));
    }
    let mut seen = starts.clone();
    let mut queue: VecDeque<_> = starts.iter().copied().collect();
    while let Some(state) = queue.pop_front() {
        for index in &adjacency[state] {
            let edge = &graph.edges[*index];
            if edge.label.is_none() && !seen.contains(&edge.to) {
                if seen.len() >= limit {
                    return Err(Issue::cap("tau_closure_budget"));
                }
                seen.insert(edge.to);
                queue.push_back(edge.to);
            }
        }
    }
    Ok(seen)
}
fn prefix_stops(
    graph: &Graph,
    adjacency: &[Vec<usize>],
    prefix: &[String],
    limit: usize,
    retain_witness: bool,
) -> Result<(BTreeSet<usize>, Value)> {
    let mut distances = BTreeMap::from([((graph.initial_state, 0usize), 0u64)]);
    let mut queue = BTreeSet::from([(0u64, graph.initial_state, 0usize)]);
    let mut stops = BTreeSet::new();
    let mut best = None;
    let mut settled = BTreeSet::new();
    while let Some((cost, marking, position)) = queue.pop_first() {
        if best.is_some_and(|bound| cost > bound) {
            break;
        }
        if distances[&(marking, position)] != cost || !settled.insert((marking, position)) {
            continue;
        }
        if position == prefix.len() {
            best = Some(cost);
            stops.insert(marking);
            continue;
        }
        for edge_index in &adjacency[marking] {
            let edge = &graph.edges[*edge_index];
            let (next_position, increment) = match &edge.label {
                None => (position, 1u64),
                Some(label) if label == &prefix[position] => (position + 1, 0),
                _ => continue,
            };
            let next = (edge.to, next_position);
            let next_cost = cost + increment;
            if distances.get(&next).is_none_or(|old| next_cost < *old) {
                if !distances.contains_key(&next) && distances.len() >= limit {
                    return Err(Issue::cap("prefix_search_budget")
                        .with(json!({"prefix":prefix,"discovered_states":distances.len()})));
                }
                distances.insert(next, next_cost);
                queue.insert((next_cost, edge.to, next_position));
            }
        }
    }
    if stops.is_empty() {
        return Err(Issue::refused("unreplayable_fitting_prefix"));
    }
    if !retain_witness {
        return Ok((stops, Value::Null));
    }
    let states:Vec<_>=distances.iter().map(|((marking,position),cost)|json!({"marking_state":marking,"position":position,"minimum_tau_cost":cost,"settled":settled.contains(&(*marking,*position))})).collect();
    Ok((
        stops,
        json!({"minimum_tau_cost":best,"search_states":states}),
    ))
}
pub fn precision(
    graph: &Graph,
    variants: &Variants,
    fitness: &Value,
    limits: Limits,
) -> Result<Value> {
    precision_impl(graph, variants, fitness, limits, true, &mut |_| Ok(()))
}

/// Same numerical calculation without retaining per-prefix search witnesses.
/// The checkpoint is cooperative; it cannot interrupt an upstream alignment call.
pub fn precision_compact(
    graph: &Graph,
    variants: &Variants,
    fitness: &Value,
    limits: Limits,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    precision_impl(graph, variants, fitness, limits, false, checkpoint)
}

fn precision_impl(
    graph: &Graph,
    variants: &Variants,
    fitness: &Value,
    limits: Limits,
    retain_witness: bool,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    if variants.is_empty() {
        return Ok(status("no_data"));
    }
    if fitness["status"] != "measured" {
        return Ok(json!({"status":"inconclusive","reason":"fitness_not_measured","scalar":null}));
    }
    if fitness["fitness"]["total_costs"].as_u64() != Some(0) {
        let unfit_frequency: u64 = fitness["alignments"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| row["result"]["Ok"]["cost"].as_u64() != Some(0))
            .filter_map(|row| row["frequency"].as_u64())
            .sum();
        return Ok(
            json!({"status":"requires_fitting_log","nonfitting_trace_frequency":unfit_frequency,"scalar":null,"policy":"no_silent_prefix_dropping"}),
        );
    }
    let adjacency = graph.adjacency();
    let mut prefixes = BTreeMap::<Vec<String>, (u64, BTreeSet<String>)>::new();
    let mut starts = BTreeSet::new();
    let traces: u64 = variants.values().sum();
    for (sequence, frequency) in variants {
        if let Some(first) = sequence.first() {
            starts.insert(first.clone());
        }
        for length in 1..sequence.len() {
            let row = prefixes.entry(sequence[..length].to_vec()).or_default();
            row.0 += frequency;
            row.1.insert(sequence[length].clone());
        }
    }
    let mut rows = Vec::new();
    let mut activated = 0u64;
    let mut escaping = 0u64;
    let mut add = |prefix: Vec<String>,
                   weight: u64,
                   observed: BTreeSet<String>,
                   stops: BTreeSet<usize>,
                   search: Value|
     -> Result<()> {
        checkpoint("precision_prefix")?;
        let closure = tau_closure(graph, &adjacency, &stops, limits.tau)?;
        let labels: BTreeSet<_> = closure
            .iter()
            .flat_map(|state| adjacency[*state].iter())
            .filter_map(|index| graph.edges[*index].label.clone())
            .collect();
        let escaped: Vec<_> = labels.difference(&observed).cloned().collect();
        activated += weight * labels.len() as u64;
        escaping += weight * escaped.len() as u64;
        if retain_witness {
            rows.push(json!({"prefix":prefix,"weight":weight,"observed_next_labels":observed,"stop_markings":stops,"tau_closure_markings":closure,"activated_labels":labels,"escaping_labels":escaped,"search":search}));
        }
        Ok(())
    };
    add(
        vec![],
        traces,
        starts,
        BTreeSet::from([graph.initial_state]),
        json!({"minimum_tau_cost":0,"policy":"empty_prefix_initial_marking"}),
    )?;
    for (prefix, (frequency, next)) in prefixes {
        let (stops, search) =
            prefix_stops(graph, &adjacency, &prefix, limits.prefix, retain_witness)?;
        add(prefix, frequency, next, stops, search)?;
    }
    if activated == 0 {
        return Ok(
            json!({"status":"not_applicable_no_activated_labels","scalar":null,"prefixes":rows,"activated_weight":0,"escaping_weight":0}),
        );
    }
    Ok(
        json!({"status":"measured","scalar":1.0-escaping as f64/activated as f64,"numerator":activated-escaping,"denominator":activated,"activated_weight":activated,"escaping_weight":escaping,"prefixes":rows,"policy":"proper_prefix_all_min_tau_stop_states_label_union_fitting_log_v1"}),
    )
}
fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        let next = a % b;
        a = b;
        b = next;
    }
    a
}
pub fn simplicity(net: &PetriNet) -> Value {
    let vertices = (net.places.len() + net.transitions.len()) as u64;
    let arcs = net.arcs.len() as u64;
    let (numerator, denominator) = if 2 * arcs <= 2 * vertices {
        (1, 1)
    } else {
        let denominator = 2 * arcs - vertices;
        let divisor = gcd(vertices, denominator);
        (vertices / divisor, denominator / divisor)
    };
    json!({"status":"measured","metric":"inverse_mean_arc_degree","k":2,"places":net.places.len(),"transitions":net.transitions.len(),"arcs":arcs,"mean_degree_numerator":2*arcs,"mean_degree_denominator":vertices,"numerator":numerator,"denominator":denominator,"scalar":numerator as f64/denominator as f64,"representation":"exact_hashed_net_no_reduction"})
}
pub fn score(net: &PetriNet, graph: &Graph, rows: &Value, limits: Limits) -> Result<Value> {
    let variants = variants(rows)?;
    let fitness = fitness(net, &variants, limits);
    let precision = match precision(graph, &variants, &fitness, limits) {
        Ok(value) => value,
        Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
    };
    Ok(json!({"fitness":fitness,"precision":precision,"simplicity":simplicity(net)}))
}
