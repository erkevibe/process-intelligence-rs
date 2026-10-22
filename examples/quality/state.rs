use super::{Issue, Limits, Result};
use process_mining::{
    PetriNet,
    core::process_models::case_centric::petri_net::{ArcType, Marking},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transition {
    pub id: String,
    pub label: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Edge {
    pub from: usize,
    pub to: usize,
    pub transition: String,
    pub label: Option<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Graph {
    pub schema_version: u32,
    pub net_sha256: String,
    pub places: Vec<String>,
    pub transitions: Vec<Transition>,
    pub initial_state: usize,
    pub final_states: Vec<usize>,
    pub states: Vec<Vec<u64>>,
    pub edges: Vec<Edge>,
}
impl Graph {
    pub fn adjacency(&self) -> Vec<Vec<usize>> {
        let mut out = vec![vec![]; self.states.len()];
        for (i, e) in self.edges.iter().enumerate() {
            out[e.from].push(i);
        }
        out
    }
}

pub fn admit(net: &PetriNet, net_sha: &str, limits: Limits) -> Result<Graph> {
    if net.places.is_empty() || net.places.len() + net.transitions.len() > limits.nodes {
        return Err(Issue::cap("generated_node_budget"));
    }
    if net.arcs.len() > limits.arcs {
        return Err(Issue::cap("generated_arc_budget"));
    }
    if net.places.keys().any(|id| net.transitions.contains_key(id)) {
        return Err(Issue::refused("overlapping_ids"));
    }
    let places: Vec<Uuid> = net
        .places
        .keys()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let place_index: BTreeMap<_, _> = places.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let transition_ids: Vec<_> = net
        .transitions
        .keys()
        .copied()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let mut incoming: BTreeMap<Uuid, Vec<(usize, u64)>> =
        transition_ids.iter().map(|id| (*id, vec![])).collect();
    let mut outgoing = incoming.clone();
    let mut seen_arcs = BTreeSet::new();
    for arc in &net.arcs {
        if arc.weight == 0 || arc.weight > 255 {
            return Err(Issue::refused("arc_weight_above255"));
        }
        let ends = match arc.from_to {
            ArcType::PlaceTransition(p, t) => {
                let index = *place_index
                    .get(&p)
                    .ok_or_else(|| Issue::refused("arc_place_reference"))?;
                incoming
                    .get_mut(&t)
                    .ok_or_else(|| Issue::refused("arc_transition_reference"))?
                    .push((index, u64::from(arc.weight)));
                (p, t)
            }
            ArcType::TransitionPlace(t, p) => {
                let index = *place_index
                    .get(&p)
                    .ok_or_else(|| Issue::refused("arc_place_reference"))?;
                outgoing
                    .get_mut(&t)
                    .ok_or_else(|| Issue::refused("arc_transition_reference"))?
                    .push((index, u64::from(arc.weight)));
                (t, p)
            }
        };
        if !seen_arcs.insert(ends) {
            return Err(Issue::refused("duplicate_arc_endpoints"));
        }
    }
    let marking = |mark: &Marking| -> Result<Vec<u64>> {
        let mut values = vec![0; places.len()];
        for (id, n) in mark {
            let index = *place_index
                .get(&id.0)
                .ok_or_else(|| Issue::refused("marking_place_reference"))?;
            if *n > 255 {
                return Err(Issue::refused("marking_count_above255"));
            }
            values[index] = *n;
        }
        Ok(values)
    };
    let initial = marking(
        net.initial_marking
            .as_ref()
            .ok_or_else(|| Issue::refused("missing_initial_marking"))?,
    )?;
    let finals = net
        .final_markings
        .as_ref()
        .ok_or_else(|| Issue::refused("missing_final_marking"))?;
    if finals.is_empty() {
        return Err(Issue::refused("missing_final_marking"));
    }
    if finals.len() != 1 {
        return Err(Issue::refused("exactly_one_final_marking_required"));
    }
    let final_marking = marking(&finals[0])?;
    let mut graph = Graph {
        schema_version: 1,
        net_sha256: net_sha.into(),
        places: places.iter().map(ToString::to_string).collect(),
        transitions: transition_ids
            .iter()
            .map(|id| Transition {
                id: id.to_string(),
                label: net.transitions[id].label.clone(),
            })
            .collect(),
        initial_state: 0,
        final_states: vec![],
        states: vec![initial.clone()],
        edges: vec![],
    };
    let mut ids = BTreeMap::from([(initial, 0usize)]);
    let mut cursor = 0;
    while cursor < graph.states.len() {
        let current = graph.states[cursor].clone();
        for transition in &transition_ids {
            if incoming[transition].iter().any(|(p, n)| current[*p] < *n) {
                continue;
            }
            let mut next = current.clone();
            for (p, n) in &incoming[transition] {
                next[*p] -= *n;
            }
            for (p, n) in &outgoing[transition] {
                next[*p] = next[*p]
                    .checked_add(*n)
                    .ok_or_else(|| Issue::cap("wide_token_overflow"))?;
                if next[*p] > 255 {
                    return Err(Issue::cap("token_bound_exceeded").with(json!({"partial_graph":graph,"overflowing_marking":next,"transition":transition})));
                }
            }
            let next_id = if let Some(id) = ids.get(&next) {
                *id
            } else {
                if graph.states.len() >= limits.markings {
                    return Err(
                        Issue::cap("reachable_marking_budget").with(json!({"partial_graph":graph}))
                    );
                }
                let id = graph.states.len();
                ids.insert(next.clone(), id);
                graph.states.push(next);
                id
            };
            graph.edges.push(Edge {
                from: cursor,
                to: next_id,
                transition: transition.to_string(),
                label: net.transitions[transition].label.clone(),
            });
        }
        cursor += 1;
    }
    let final_id = *ids
        .get(&final_marking)
        .ok_or_else(|| Issue::refused("final_marking_unreachable").with(json!({"graph":graph})))?;
    graph.final_states.push(final_id);
    let mut reverse = vec![vec![]; graph.states.len()];
    for edge in &graph.edges {
        reverse[edge.to].push(edge.from);
    }
    let mut can_finish = BTreeSet::from([final_id]);
    let mut queue = VecDeque::from([final_id]);
    while let Some(state) = queue.pop_front() {
        for source in &reverse[state] {
            if can_finish.insert(*source) {
                queue.push_back(*source);
            }
        }
    }
    if can_finish.len() != graph.states.len() {
        let dead: Vec<_> = (0..graph.states.len())
            .filter(|id| !can_finish.contains(id))
            .collect();
        return Err(Issue::refused("reachable_marking_has_no_path_to_final")
            .with(json!({"graph":graph,"nonfinal_closed_region_predecessors":dead})));
    }
    Ok(graph)
}
