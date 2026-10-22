//! Frozen, pre-execution scientific hypotheses. Runtime/native execution belongs to Root.
#[allow(dead_code)]
#[path = "../examples/quality/mod.rs"]
mod quality;
use quality::{Limits, bridge, metrics, state};
use serde_json::{Value, json};

fn ratio(value: &Value) -> f64 {
    let parts: Vec<_> = value.as_str().unwrap().split('/').collect();
    parts[0].parse::<f64>().unwrap()
        / parts
            .get(1)
            .map_or(1.0, |part| part.parse::<f64>().unwrap())
}
fn manual_scores(case: &Value, manifest: &Value) -> Value {
    let net =
        bridge::manual(&manifest["manual_nets"][case["manual_net"].as_str().unwrap()]).unwrap();
    let limits = Limits::lowered(&case["test_only_lower_caps"]).unwrap();
    let graph = state::admit(&net, "test-net", limits).unwrap();
    metrics::score(&net, &graph, &case["heldout_log"], limits).unwrap()
}
#[test]
fn frozen_manual_precisions_fitness_and_structural_components() {
    let manifest = quality::fixture();
    assert_eq!(
        quality::sha(quality::CORPUS.as_bytes()),
        "618708791670d89f730282ac0a7e0dd1eb39c59600a5362684bb71fdc3e40410"
    );
    for case in quality::pipeline::expanded_cases(&manifest).unwrap() {
        if case["id"].as_str().unwrap().starts_with("Q16") || case.get("manual_net").is_none() {
            continue;
        }
        let measured = manual_scores(&case, &manifest);
        let expected = &case["expected"];
        if let Some(fitness) = expected.get("fitness") {
            assert!(
                (measured["fitness"]["fitness"]["log_fitness"]
                    .as_f64()
                    .unwrap()
                    - ratio(fitness))
                .abs()
                    < 1e-12,
                "{} {measured:#}",
                case["id"]
            );
        }
        if let Some(precision) = expected.get("manual_precision") {
            assert!(
                (measured["precision"]["scalar"].as_f64().unwrap() - ratio(precision)).abs()
                    < 1e-12,
                "{} {measured:#}",
                case["id"]
            );
        }
        for (expected_key, actual_key) in [
            ("manual_activated", "activated_weight"),
            ("manual_escaping", "escaping_weight"),
        ] {
            if let Some(value) = expected.get(expected_key) {
                assert_eq!(&measured["precision"][actual_key], value, "{}", case["id"]);
            }
        }
        if let Some(simplicity) = expected.get("manual_simplicity") {
            assert!(
                (measured["simplicity"]["scalar"].as_f64().unwrap() - ratio(simplicity)).abs()
                    < 1e-12
            );
        }
        if let Some(status) = expected.get("precision_status") {
            assert_eq!(&measured["precision"]["status"], status);
        }
    }
}
#[test]
fn general_bridge_refusals_and_infinite_loop_marking_language() {
    let manifest = quality::fixture();
    let (net, map) = bridge::from_xml(include_bytes!("../fixtures/quality/loop.bpmn")).unwrap();
    assert_eq!(
        map["semantics"],
        "flow_place_task_visible_xor_pairs_and_all_v1"
    );
    let graph = state::admit(&net, "loop", Limits::default()).unwrap();
    // A directed cycle in the marking graph is retained; no trace-language enumeration.
    assert!(graph.edges.iter().any(|edge| edge.to <= edge.from));
    let measured = metrics::score(
        &net,
        &graph,
        &json!([{"sequence":["A","B","B","B","C"],"frequency":1}]),
        Limits::default(),
    )
    .unwrap();
    assert_eq!(measured["fitness"]["fitness"]["log_fitness"], 1.0);
    assert_eq!(
        bridge::from_xml(include_bytes!("../fixtures/quality/task_branch.bpmn"))
            .unwrap_err()
            .reason,
        "ordinary_task_degree"
    );
    assert_eq!(
        bridge::from_xml(include_bytes!("../fixtures/quality/blank_task.bpmn"))
            .unwrap_err()
            .reason,
        "empty_task_activity_label"
    );
    assert!(bridge::from_xml(include_bytes!("../fixtures/quality/condition.bpmn")).is_err());
    let (unicode, _) =
        bridge::from_xml(include_bytes!("../fixtures/quality/unicode_di.bpmn")).unwrap();
    let unicode_graph = state::admit(&unicode, "unicode", Limits::default()).unwrap();
    assert!(
        unicode_graph
            .transitions
            .iter()
            .any(|t| t.label.as_deref() == Some("Ә & <да> \"go\""))
    );
    assert_eq!(manifest["caps"]["prefix_search_states"], 100000);
}
#[test]
fn refusal_caps_no_data_and_tau_only_policies() {
    let manifest = quality::fixture();
    for (name, reason) in [
        ("MISSING_FINAL", "missing_final_marking"),
        ("MULTIPLE_FINAL", "exactly_one_final_marking_required"),
        ("MARKING256", "marking_count_above255"),
        ("WEIGHT256", "arc_weight_above255"),
        ("CLOSED_REGION", "reachable_marking_has_no_path_to_final"),
    ] {
        let net = bridge::manual(&manifest["manual_nets"][name]).unwrap();
        assert_eq!(
            state::admit(&net, "negative", Limits::default())
                .unwrap_err()
                .reason,
            reason
        );
    }
    let growing = bridge::manual(&manifest["manual_nets"]["GROWTH"]).unwrap();
    let error = state::admit(&growing, "grow", Limits::default()).unwrap_err();
    assert_eq!(error.status, "inconclusive");
    assert_eq!(error.reason, "token_bound_exceeded");
    let seq = bridge::manual(&manifest["manual_nets"]["SEQ"]).unwrap();
    let limits = Limits::lowered(&json!({"reachable_markings":1})).unwrap();
    assert_eq!(
        state::admit(&seq, "seq", limits).unwrap_err().reason,
        "reachable_marking_budget"
    );
    let graph = state::admit(&seq, "seq", Limits::default()).unwrap();
    let empty = metrics::score(&seq, &graph, &json!([]), Limits::default()).unwrap();
    assert_eq!(empty["fitness"]["status"], "no_data");
    assert_eq!(empty["precision"]["status"], "no_data");
    let prefix_cap = metrics::score(
        &seq,
        &graph,
        &json!([{"sequence":["A","B","C"],"frequency":1}]),
        Limits::lowered(&json!({"prefix_search_states":1})).unwrap(),
    )
    .unwrap();
    assert_eq!(prefix_cap["precision"]["status"], "inconclusive");
    assert_eq!(prefix_cap["precision"]["reason"], "prefix_search_budget");
    let tau = bridge::manual(&manifest["manual_nets"]["TAU_EXIT"]).unwrap();
    let graph = state::admit(&tau, "tau", Limits::default()).unwrap();
    let tau_score = metrics::score(
        &tau,
        &graph,
        &json!([{"sequence":[],"frequency":2}]),
        Limits::default(),
    )
    .unwrap();
    assert_eq!(tau_score["fitness"]["fitness"]["log_fitness"], 1.0);
    assert_eq!(tau_score["fitness"]["empty_alignment"]["cost"], 0);
    assert_eq!(
        tau_score["precision"]["status"],
        "not_applicable_no_activated_labels"
    );
    assert!(tau_score["precision"]["scalar"].is_null());
    let cap_score = metrics::score(
        &tau,
        &graph,
        &json!([{"sequence":[],"frequency":1}]),
        Limits::lowered(&json!({"tau_closure_markings":1})).unwrap(),
    )
    .unwrap();
    assert_eq!(cap_score["precision"]["reason"], "tau_closure_budget");
}
#[test]
fn family_subcases_are_concrete_and_unknown_activity_is_retained() {
    let manifest = quality::fixture();
    let expanded = quality::pipeline::expanded_cases(&manifest).unwrap();
    assert!(
        expanded
            .iter()
            .any(|case| case["id"] == "Q16-closed-nonfinal-region")
    );
    assert!(
        expanded
            .iter()
            .any(|case| case["id"] == "Q15-mixed-parallel")
    );
    let variants = metrics::variants(&json!([{"sequence":["A","X","C"],"frequency":1}])).unwrap();
    assert!(
        metrics::projection(&variants)
            .activities
            .contains(&"X".to_string())
    );
    let parent = expanded.iter().find(|case| case["id"] == "Q13").unwrap();
    let measured = manual_scores(parent, &manifest);
    assert_eq!(measured["precision"]["status"], "requires_fitting_log");
    assert_eq!(measured["precision"]["nonfitting_trace_frequency"], 2);
}
