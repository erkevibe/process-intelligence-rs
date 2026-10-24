use super::{Issue, Result, array, integer, text};
use crate::bpmn::{self, NodeKind, ProcessModel};
use process_mining::{
    PetriNet,
    core::process_models::case_centric::petri_net::{ArcType, Marking, PlaceID, TransitionID},
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use uuid::Uuid;

pub fn from_xml(xml: &[u8]) -> Result<(PetriNet, Value)> {
    let model = bpmn::parse(xml)
        .map_err(|error| Issue::refused(&error.code).with(json!({"message":error.message})))?;
    from_model(&model)
}
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
            if net.places.len() + net.transitions.len() >= 128 {
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
            if net.arcs.len() > 256 {
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

pub fn manual(spec: &Value) -> Result<PetriNet> {
    let mut net = PetriNet::new();
    let mut places = BTreeMap::<String, PlaceID>::new();
    let mut transitions = BTreeMap::<String, TransitionID>::new();
    for (index, name) in array(&spec["places"])?.iter().enumerate() {
        if places
            .insert(
                text(name)?.into(),
                net.add_place(Some(Uuid::from_u128(index as u128 + 1))),
            )
            .is_some()
        {
            return Err(Issue::refused("duplicate_place"));
        }
    }
    let labels = spec["transitions"]
        .as_object()
        .ok_or_else(|| Issue::refused("manual_transitions"))?;
    for (index, (name, label)) in labels.iter().enumerate() {
        transitions.insert(
            name.clone(),
            net.add_transition(
                if label.is_null() {
                    None
                } else {
                    Some(text(label)?.to_owned())
                },
                Some(Uuid::from_u128(index as u128 + 10001)),
            ),
        );
    }
    for edge in array(&spec["arcs"])? {
        let edge = array(edge)?;
        if edge.len() != 3 {
            return Err(Issue::refused("manual_arc"));
        }
        let from = text(&edge[0])?;
        let to = text(&edge[1])?;
        let weight = u32::try_from(integer(&edge[2])?).map_err(|_| Issue::refused("arc_weight"))?;
        let arc = if let (Some(p), Some(t)) = (places.get(from), transitions.get(to)) {
            ArcType::place_to_transition(*p, *t)
        } else if let (Some(t), Some(p)) = (transitions.get(from), places.get(to)) {
            ArcType::transition_to_place(*t, *p)
        } else {
            return Err(Issue::refused("manual_arc_reference"));
        };
        net.add_arc(arc, Some(weight));
    }
    let marking = |value: &Value| -> Result<Marking> {
        value
            .as_object()
            .ok_or_else(|| Issue::refused("manual_marking"))?
            .iter()
            .map(|(id, n)| {
                Ok((
                    *places
                        .get(id)
                        .ok_or_else(|| Issue::refused("unknown_marking_place"))?,
                    integer(n)?,
                ))
            })
            .collect()
    };
    net.initial_marking = Some(marking(&spec["initial"])?);
    net.final_markings = Some(
        array(&spec["finals"])?
            .iter()
            .map(marking)
            .collect::<Result<_>>()?,
    );
    Ok(net)
}
