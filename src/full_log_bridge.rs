//! Separate larger bridge profile; historical bridge source stays frozen for report replay.
use crate::bpmn::{self, NodeKind, ProcessModel};
use crate::bpmn_quality::{Issue, Result};
use process_mining::{
    PetriNet,
    core::process_models::case_centric::petri_net::{ArcType, Marking, PlaceID, TransitionID},
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use uuid::Uuid;

pub fn from_model(model: &ProcessModel) -> Result<(PetriNet, Value)> {
    bpmn::validate(model).map_err(|_| Issue::refused("bpmn_invalid"))?;
    if model
        .nodes
        .iter()
        .filter(|n| n.kind == NodeKind::Start)
        .count()
        != 1
        || model
            .nodes
            .iter()
            .filter(|n| n.kind == NodeKind::End)
            .count()
            != 1
    {
        return Err(Issue::unsupported("exactly_one_start_end"));
    }
    let mut net = PetriNet::new();
    let mut flows = BTreeMap::new();
    for (index, flow) in model.flows.iter().enumerate() {
        flows.insert(
            flow.id.clone(),
            net.add_place(Some(Uuid::from_u128(index as u128 + 1))),
        );
    }
    let source = net.add_place(Some(Uuid::from_u128(model.flows.len() as u128 + 1)));
    let sink = net.add_place(Some(Uuid::from_u128(model.flows.len() as u128 + 2)));
    let mut next = 10001u128;
    let mut nodes = BTreeMap::<String, Vec<String>>::new();
    for node in &model.nodes {
        let incoming: Vec<_> = model
            .flows
            .iter()
            .filter(|f| f.target == node.id)
            .map(|f| flows[&f.id])
            .collect();
        let outgoing: Vec<_> = model
            .flows
            .iter()
            .filter(|f| f.source == node.id)
            .map(|f| flows[&f.id])
            .collect();
        let mut add = |ins: &[PlaceID], outs: &[PlaceID], label: Option<String>| -> Result<()> {
            if net.places.len() + net.transitions.len() >= 512 {
                return Err(Issue::cap("generated_node_budget"));
            }
            let transition = net.add_transition(label, Some(Uuid::from_u128(next)));
            next += 1;
            for place in ins {
                net.add_arc(ArcType::place_to_transition(*place, transition), Some(1));
            }
            for place in outs {
                net.add_arc(ArcType::transition_to_place(transition, *place), Some(1));
            }
            if net.arcs.len() > 1024 {
                return Err(Issue::cap("generated_arc_budget"));
            }
            nodes
                .entry(node.id.clone())
                .or_default()
                .push(transition.0.to_string());
            Ok(())
        };
        match node.kind {
            NodeKind::Task => {
                if incoming.len() != 1 || outgoing.len() != 1 {
                    return Err(Issue::unsupported("ordinary_task_degree"));
                }
                if node.label.is_empty() {
                    return Err(Issue::unsupported("empty_task_activity_label"));
                }
                add(&incoming, &outgoing, Some(node.label.clone()))?;
            }
            NodeKind::Start => {
                if !incoming.is_empty() || outgoing.len() != 1 {
                    return Err(Issue::unsupported("start_degree"));
                }
                add(&[source], &outgoing, None)?;
            }
            NodeKind::End => {
                if incoming.len() != 1 || !outgoing.is_empty() {
                    return Err(Issue::unsupported("end_degree"));
                }
                add(&incoming, &[sink], None)?;
            }
            NodeKind::ParallelGateway => {
                add(&incoming, &outgoing, None)?;
            }
            NodeKind::ExclusiveGateway => {
                for from in &incoming {
                    for to in &outgoing {
                        add(&[*from], &[*to], None)?;
                    }
                }
            }
        }
    }
    net.initial_marking = Some(Marking::from([(source, 1)]));
    net.final_markings = Some(vec![Marking::from([(sink, 1)])]);
    Ok((
        net,
        json!({"process_id":model.process_id,"node_transitions":nodes,"flow_places":flows.iter().map(|(key,value)|(key.clone(),value.0.to_string())).collect::<BTreeMap<_,_>>(),"source":source.0.to_string(),"sink":sink.0.to_string(),"semantics":"flow_place_task_visible_xor_pairs_and_all_v1","geometry_inert":true,"flow_gateway_labels_inert":true}),
    ))
}
