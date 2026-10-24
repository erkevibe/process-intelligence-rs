//! Optional pinned upstream alignment experiment. No product/model-quality acceptance.
#[allow(dead_code)]
#[path = "../examples/discovery_fitness.rs"]
mod observer;
use process_mining::core::process_models::case_centric::petri_net::{ArcType, PlaceID};
use serde_json::{Value, json};
use uuid::Uuid;

fn manifest() -> Value {
    serde_json::from_str(observer::CORPUS).unwrap()
}
fn seq() -> process_mining::PetriNet {
    observer::manual_net(&manifest()["manual_nets"]["SEQ"]).unwrap()
}

#[test]
fn frozen_manual_costs_and_rationals_use_real_upstream_alignment() {
    assert_eq!(
        observer::sha(observer::CORPUS.as_bytes()),
        "fab7e1952bf5fab56c210023cd6d8b13fa4e19874ed5762330c78bbda68ce075"
    );
    let result = observer::manual_suite(&manifest()).unwrap();
    assert_eq!(result["cases"].as_array().unwrap().len(), 9);
    assert_eq!(result["all_manual_checks_pass"], true, "{result:#}");
}

#[test]
fn wide_marking_admission_refuses_narrowing_broken_refs_and_unproved_bounds() {
    let original = seq();
    let mut net = original.clone();
    net.final_markings = None;
    assert!(observer::admit(&net, 10_000).unwrap_err().contains("final"));
    let mut net = original.clone();
    let final_marking = net.final_markings.as_ref().unwrap()[0].clone();
    net.final_markings.as_mut().unwrap().push(final_marking);
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "exactly_one_final_required"
    );
    let mut net = original.clone();
    net.initial_marking = None;
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "missing_initial"
    );
    let mut net = original.clone();
    net.arcs[0].weight = 256;
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "arc_weight_outside1to255"
    );
    let mut net = original.clone();
    let mark = net.initial_marking.as_mut().unwrap();
    *mark.values_mut().next().unwrap() = 256;
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "marking_count_above255"
    );
    let mut net = original.clone();
    let transition = *net.transitions.keys().next().unwrap();
    net.add_arc(
        ArcType::PlaceTransition(Uuid::from_u128(999999), transition),
        Some(1),
    );
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "unknown_arc_place"
    );
    let mut net = original.clone();
    net.arcs.push(net.arcs[0].clone());
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "duplicate_arc_endpoints"
    );
    assert_eq!(
        observer::admit(&original, 1).unwrap_err(),
        "reachable_marking_budget_inconclusive"
    );
    // A source transition repeatedly produces a token; wider admission sees 256,
    // before the u8 aligner can truncate a marking or prune the overflowing move.
    let mut net = process_mining::PetriNet::new();
    let place = net.add_place(None);
    let growing = net.add_transition(None, None);
    net.initial_marking = Some(Default::default());
    net.final_markings = Some(vec![Default::default()]);
    net.add_arc(ArcType::TransitionPlace(growing.0, place.0), Some(1));
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "reachable_marking_above255"
    );
    let mut net = original;
    net.initial_marking
        .as_mut()
        .unwrap()
        .insert(PlaceID(Uuid::from_u128(999999)), 1);
    assert_eq!(
        observer::admit(&net, 10_000).unwrap_err(),
        "unknown_marking_place"
    );
}

#[test]
fn evaluation_projection_keeps_unknowns_and_limits_before_search() {
    let projected =
        observer::projection(&json!([{"sequence":["A","X","C"],"frequency":2}])).unwrap();
    assert!(projected.activities.iter().any(|a| a == "X"));
    assert_eq!(projected.traces[0].1, 2);
    for input in [
        json!([]),
        json!([{"sequence":["A"],"frequency":0}]),
        json!([{"sequence":vec!["A";65],"frequency":1}]),
        json!([{"sequence":["A"],"frequency":65}]),
    ] {
        assert!(observer::projection(&input).is_err());
    }
    let measured = observer::evaluate(
        &seq(),
        &json!([{"sequence":["A","X","C"],"frequency":1}]),
        100_000,
    )
    .unwrap();
    assert_eq!(measured["status"], "measured");
    assert_eq!(measured["integer_check"]["weighted_total_cost"], 2);
}

#[test]
fn state_cap_does_not_create_a_zero_or_survivor_fitness() {
    let result = observer::evaluate(
        &seq(),
        &json!([{"sequence":["A","B","C"],"frequency":1}]),
        1,
    )
    .unwrap();
    assert_eq!(result["status"], "inconclusive");
    assert!(result.get("fitness").is_none());
    assert!(result["alignments"].is_array());
}
