#[allow(dead_code)]
#[path = "../examples/quality/mod.rs"]
mod quality;
use process_intelligence_rs::{
    bpmn,
    bpmn_quality::{Issue, Limits, bridge, facade, metrics, state},
};
use serde_json::{Value, json};

fn without_prefixes(mut value: Value) -> Value {
    value.as_object_mut().unwrap().remove("prefixes");
    value
}

#[test]
fn compact_precision_preserves_all_frozen_numeric_and_status_results() {
    let manifest = quality::fixture();
    let mut groups = 0;
    for case in quality::pipeline::expanded_cases(&manifest).unwrap() {
        let limits = Limits::lowered(&case["test_only_lower_caps"]).unwrap();
        for (kind, key) in [("bridge", "model"), ("manual", "manual_net")] {
            let Some(name) = case[key].as_str() else {
                continue;
            };
            let net = if kind == "manual" {
                bridge::manual(&manifest["manual_nets"][name])
            } else {
                let model = manifest["models"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|row| row["id"] == name)
                    .unwrap();
                let xml = std::fs::read(format!(
                    "fixtures/quality/{}",
                    model["file"].as_str().unwrap()
                ))
                .unwrap();
                bridge::from_xml(&xml).map(|(net, _)| net)
            };
            let Ok(net) = net else { continue };
            let Ok(graph) = state::admit(&net, "test", limits) else {
                continue;
            };
            for group in ["training_log", "heldout_log"] {
                let variants = metrics::variants(&case[group]).unwrap();
                let fitness = metrics::fitness(&net, &variants, limits);
                let full = metrics::precision(&graph, &variants, &fitness, limits);
                let compact = metrics::precision_compact(
                    &graph,
                    &variants,
                    &fitness,
                    limits,
                    &mut |_| Ok(()),
                );
                match (full, compact) {
                    (Ok(full), Ok(compact)) => assert_eq!(
                        without_prefixes(full),
                        without_prefixes(compact),
                        "{} {kind} {group}",
                        case["id"]
                    ),
                    (Err(full), Err(compact)) => assert_eq!(
                        serde_json::to_value(full).unwrap(),
                        serde_json::to_value(compact).unwrap()
                    ),
                    other => panic!("precision status diverged: {other:?}"),
                }
                groups += 1;
            }
        }
    }
    assert_eq!(groups, 84);
}

#[test]
fn application_report_binds_inputs_and_has_no_search_witnesses() {
    let xml = include_bytes!("../fixtures/quality/linear.bpmn");
    let model = bpmn::parse(xml).unwrap();
    let rows = json!([{"sequence":["A","B","C"],"frequency":2}]);
    let result = facade::evaluate_model(&model, &rows, &Value::Null, &mut |_| Ok(())).unwrap();
    assert_eq!(result["metrics"]["fitness"]["fitness"]["log_fitness"], 1.0);
    assert_eq!(result["metrics"]["precision"]["scalar"], 1.0);
    assert!(result["metrics"]["precision"].get("prefixes").is_none());
    assert!(result["metrics"]["fitness"].get("alignments").is_none());
    assert!(serde_json::to_vec(&result).unwrap().len() < facade::MAX_REPORT_BYTES);
    assert_eq!(
        result,
        facade::evaluate_xml(xml, &rows, &Value::Null).unwrap()
    );
    let split =
        json!([{"sequence":["A","B","C"],"frequency":1},{"sequence":["A","B","C"],"frequency":1}]);
    assert_eq!(
        result["variants_sha256"],
        facade::evaluate_xml(xml, &split, &Value::Null).unwrap()["variants_sha256"]
    );
    let changed = json!([{"sequence":["A","B"],"frequency":2}]);
    assert_ne!(
        result["variants_sha256"],
        facade::evaluate_xml(xml, &changed, &Value::Null).unwrap()["variants_sha256"]
    );
    let empty = facade::evaluate_xml(xml, &json!([]), &Value::Null).unwrap();
    assert_eq!(empty["metrics"]["fitness"]["status"], "no_data");
    assert_eq!(empty["metrics"]["precision"]["status"], "no_data");
}

#[test]
fn facade_rejects_oversize_and_ambiguous_inputs_before_bridge() {
    for caps in [
        json!(false),
        json!([]),
        json!(""),
        json!({"fitness_search_states":1001}),
        json!({"prefix_search_states":0}),
        json!({"reachable_markings":true}),
        json!({"unknown":1}),
    ] {
        assert!(facade::application_limits(&caps).is_err(), "{caps}");
    }
    for rows in [
        json!([{"sequence":["A"],"frequency":false}]),
        json!([{"sequence":["A"],"frequency":1,"extra":0}]),
        json!([{"sequence":["A"],"frequency":65}]),
        json!([{"sequence":vec!["A";65],"frequency":1}]),
        json!([{"sequence":["x".repeat(201)],"frequency":1}]),
    ] {
        assert!(facade::validate_rows(&rows).is_err());
    }
    assert_eq!(
        facade::evaluate_xml(&vec![b' '; 1024 * 1024 + 1], &json!([]), &Value::Null)
            .unwrap_err()
            .reason,
        "evaluation_model_limit"
    );
    let xml = include_bytes!("../fixtures/quality/linear.bpmn");
    let mut model = bpmn::parse(xml).unwrap();
    model.nodes = vec![model.nodes[0].clone(); 129];
    assert_eq!(
        facade::evaluate_model(&model, &json!([]), &Value::Null, &mut |_| Ok(()))
            .unwrap_err()
            .reason,
        "evaluation_model_limit"
    );
}

#[test]
fn cancellation_is_propagated_including_precision_prefix_boundary() {
    let model = bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap();
    let rows = json!([{"sequence":["A","B","C"],"frequency":1}]);
    for target in [
        "validate",
        "bridge",
        "markings",
        "fitness",
        "precision",
        "precision_prefix",
        "complete",
    ] {
        let error = facade::evaluate_model(&model, &rows, &Value::Null, &mut |stage| {
            if stage == target {
                Err(Issue::refused("test_revoked"))
            } else {
                Ok(())
            }
        })
        .unwrap_err();
        assert_eq!(error.reason, "test_revoked", "{target}");
    }
    let report = facade::evaluate_model(
        &model,
        &rows,
        &json!({"fitness_search_states":1}),
        &mut |_| Ok(()),
    )
    .unwrap();
    assert_eq!(report["metrics"]["fitness"]["status"], "inconclusive");
    assert!(report["metrics"]["fitness"]["fitness"].is_null());
}

#[test]
fn application_errors_never_retain_partial_graphs_or_unbounded_messages() {
    let model = bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap();
    let rows = json!([{"sequence":["A","B","C"],"frequency":1}]);
    let error =
        facade::evaluate_model(&model, &rows, &json!({"reachable_markings":1}), &mut |_| {
            Ok(())
        })
        .unwrap_err();
    assert_eq!(error.reason, "reachable_marking_budget");
    assert!(error.details.is_null());
    assert!(serde_json::to_vec(&error).unwrap().len() < facade::MAX_REPORT_BYTES);
    let huge = facade::evaluate_model(&model, &rows, &Value::Null, &mut |_| {
        Err(Issue::refused(&"x".repeat(facade::MAX_REPORT_BYTES + 1))
            .with(json!({"private":"detail"})))
    })
    .unwrap_err();
    assert_eq!(huge.reason, "quality_error_limit");
    assert!(huge.details.is_null());
}
