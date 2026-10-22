//! Manual pre-code fixtures and algebraic conservation; execution belongs to Root.
#[path = "../examples/conversion/mod.rs"]
#[allow(dead_code)]
mod conversion;
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path};
fn root() -> &'static Path {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/conversions"))
}
fn load(file: &str) -> Vec<u8> {
    std::fs::read(root().join(file)).unwrap()
}
#[test]
fn all_prospective_manual_cases_and_separate_inverse_calls() {
    let manifest: Value = serde_json::from_slice(&load("corpus.json")).unwrap();
    assert_eq!(manifest["method_sha256"], conversion::METHOD);
    assert_eq!(manifest["cases"].as_array().unwrap().len(), 57);
    for case in manifest["cases"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        let input = load(case["input"].as_str().unwrap());
        assert_eq!(
            conversion::sha(&input),
            case["input_sha256"],
            "{id} input pin"
        );
        let from = case["from"].as_str().unwrap();
        let to = case["to"].as_str().unwrap();
        let result = conversion::convert(
            from,
            to,
            &input,
            case["allow_metadata_loss"].as_bool().unwrap(),
        );
        if case["expected"]["status"] != "converted" {
            let failure = result.expect_err(id);
            assert_eq!(failure.status, case["expected"]["status"], "{id} status");
            assert_eq!(failure.reason, case["expected"]["reason"], "{id} reason");
            continue;
        }
        let actual = result.unwrap_or_else(|e| panic!("{id}: {e:?}"));
        let expected = &case["expected"]["manual_semantics"];
        if let Some(count) = expected.get("metadata_loss_count") {
            assert_eq!(
                &actual.evidence["metadata_loss_count"], count,
                "{id} losses"
            );
        }
        if let Some(core) = expected["core_file"].as_str() {
            let core: Value = serde_json::from_slice(&load(core)).unwrap();
            assert_eq!(actual.evidence["source_core"], core, "{id} source");
            assert_eq!(actual.evidence["target_core"], core, "{id} target");
        }
        if to == "csv"
            && let Some(target) = case["expected"]["direct_target_file"].as_str()
        {
            assert_eq!(actual.payload, load(target), "{id} direct bytes");
        }
        // This is a real separate opposite conversion on actual forward bytes, not report reconstruction.
        let inverse = conversion::convert(to, from, &actual.payload, false)
            .unwrap_or_else(|e| panic!("{id} actual inverse: {e:?}"));
        if let Some(core) = actual.evidence.get("source_core") {
            assert_eq!(&inverse.evidence["target_core"], core, "{id} inverse core");
        } else {
            let source: conversion::net::Graph =
                graph_from_report(&actual.evidence["source_graph"]);
            let returned = graph_from_report(&inverse.evidence["target_graph"]);
            let (map, _) = conversion::net::bijection(&source, &returned).unwrap();
            assert!(
                conversion::net::verify_map(&source, &returned, &map),
                "{id} inverse full graph"
            );
        }
    }
}
fn graph_from_report(value: &Value) -> conversion::net::Graph {
    let nodes = value["nodes"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(id, n)| {
            (
                id.clone(),
                conversion::net::Node {
                    id: id.clone(),
                    kind: n["kind"].as_str().unwrap().into(),
                    label: n["label"].as_str().map(str::to_owned),
                },
            )
        })
        .collect();
    let arcs = value["arcs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| conversion::net::Edge {
            source: e["source"].as_str().unwrap().into(),
            target: e["target"].as_str().unwrap().into(),
            weight: e["weight"].as_u64().unwrap() as u32,
        })
        .collect();
    fn mark(v: &Value) -> BTreeMap<String, u64> {
        v.as_object()
            .unwrap()
            .iter()
            .map(|(id, n)| (id.clone(), n.as_u64().unwrap()))
            .collect()
    }
    conversion::net::Graph {
        nodes,
        arcs,
        initial: (!value["initial"].is_null()).then(|| mark(&value["initial"])),
        finals: (!value["finals"].is_null()).then(|| {
            value["finals"]
                .as_array()
                .unwrap()
                .iter()
                .map(mark)
                .collect()
        }),
    }
}
#[test]
fn bijection_checks_weight_marking_and_labels_not_just_counts() {
    let (_, source) = conversion::net::json_graph(&load("weighted-cycle.json")).unwrap();
    let mut changed = source.clone();
    changed.arcs[0].weight += 1;
    assert!(conversion::net::bijection(&source, &changed).is_err());
    changed = source.clone();
    if let Some(value) = changed.initial.as_mut().unwrap().values_mut().next() {
        *value += 1;
    }
    assert!(conversion::net::bijection(&source, &changed).is_err());
    changed = source.clone();
    let id = changed
        .nodes
        .values()
        .find(|n| n.kind == "transition" && n.label.is_none())
        .unwrap()
        .id
        .clone();
    changed.nodes.get_mut(&id).unwrap().label = Some("Tau".into());
    assert!(conversion::net::bijection(&source, &changed).is_err());
    let map: BTreeMap<_, _> = source
        .nodes
        .keys()
        .map(|id| (id.clone(), id.clone()))
        .collect();
    assert!(conversion::net::verify_map(&source, &source, &map));
}
#[test]
fn metadata_and_xml_characters_cannot_silently_change_core() {
    let extra = b"case,activity,timestamp,lifecycle,blank\r\none,A,,,\r\n";
    assert_eq!(
        conversion::convert("csv", "xes", extra, false)
            .unwrap_err()
            .status,
        "loss_refused"
    );
    let allowed = conversion::convert("csv", "xes", extra, true).unwrap();
    assert_eq!(allowed.evidence["metadata_loss_count"], 0);
    let source = b"case,activity,timestamp,lifecycle\r\none,\"A\r\nB\tC & <x>\" ,,\r\n";
    assert!(
        conversion::convert("csv", "xes", source, false).is_err(),
        "spaces after closing quote must refuse"
    );
    let source = b"case,activity,timestamp,lifecycle\r\none,\"A\r\nB\tC & <x>\",,\r\n";
    let target = conversion::convert("csv", "xes", source, false).unwrap();
    assert_eq!(
        target.evidence["target_core"]["traces"][0]["events"][0]["activity"],
        "A\r\nB\tC & <x>"
    );
    assert!(
        std::str::from_utf8(&target.payload)
            .unwrap()
            .contains("&#13;&#10;")
    );
    let float=b"<log><trace><string key=\"concept:name\" value=\"one\"/><event><string key=\"concept:name\" value=\"A\"/><float key=\"probe\" value=\"-0.0\"/></event></trace></log>";
    let result = conversion::convert("xes", "csv", float, true).unwrap();
    assert_eq!(result.evidence["losses"][0]["value"], "-0.0");
    // This probes lexical loss reporting, not a fabricated f64 sign preservation claim.
    assert_eq!(result.evidence["metadata_loss_count"], json!(1));
}
#[test]
fn shortest_nanosecond_format_and_actual_declaration_presence() {
    for (source, expected) in [
        (".123400Z", ".1234Z"),
        (".123400000Z", ".1234Z"),
        (".000000001Z", ".000000001Z"),
        (".000000000Z", "Z"),
    ] {
        let input =
            format!("case,activity,timestamp,lifecycle\r\none,A,2026-10-22T01:02:03{source},\r\n");
        let output = conversion::convert("csv", "xes", input.as_bytes(), false).unwrap();
        let expected = format!("2026-10-22T01:02:03{expected}");
        assert_eq!(
            output.evidence["source_core"]["traces"][0]["events"][0]["timestamp"],
            expected
        );
        assert_eq!(
            output.evidence["target_core"]["traces"][0]["events"][0]["timestamp"],
            expected
        );
        assert!(
            std::str::from_utf8(&output.payload)
                .unwrap()
                .contains(&expected)
        );
        let inverse = conversion::convert("xes", "csv", &output.payload, false).unwrap();
        assert!(
            std::str::from_utf8(&inverse.payload)
                .unwrap()
                .contains(&expected)
        );
    }
    let no_declarations=b"<log><trace><string key=\"concept:name\" value=\"one\"/><event><string key=\"concept:name\" value=\"A\"/></event></trace></log>";
    let output = conversion::convert("xes", "csv", no_declarations, false).unwrap();
    assert_eq!(
        output.evidence["format_declarations"]["source"]["xes.version"],
        json!({"present":false,"value":null})
    );
    assert_eq!(
        output.evidence["format_declarations"]["source"]["xmlns"],
        json!({"present":false,"value":null})
    );
    assert_eq!(
        output.evidence["format_declarations"]["target"]["format"],
        "csv"
    );
    let inverse = conversion::convert("csv", "xes", &output.payload, false).unwrap();
    assert_eq!(
        inverse.evidence["format_declarations"]["target"]["xes.version"],
        json!({"present":true,"value":"1.0"})
    );
    assert_eq!(
        inverse.evidence["format_declarations"]["target"]["xmlns"],
        json!({"present":true,"value":"http://www.xes-standard.org/"})
    );
}
#[test]
fn c2_normalizations_are_actual_occurrences_with_complete_identity_and_renaming_maps() {
    fn check(result: &conversion::Converted, expected_places: u64, expected_tau: u64) {
        let inventory = &result.evidence["normalization_inventory"];
        let entries = inventory["entries"].as_array().unwrap();
        assert_eq!(
            inventory["entry_count"].as_u64().unwrap(),
            entries.len() as u64
        );
        let mut counts: BTreeMap<String, u64> = BTreeMap::new();
        for entry in entries {
            *counts
                .entry(entry["kind"].as_str().unwrap().into())
                .or_default() += 1;
            assert!(entry["locator"]["path"].as_str().unwrap().starts_with('/'));
            if entry["kind"] == "node_id_bijection" {
                assert_eq!(entry["side"], "source_to_target");
                assert_eq!(
                    entry["changed"],
                    entry["original_value"] != entry["normalized_value"]
                );
                assert_eq!(
                    result.evidence["node_bijection"][entry["source_graph_id"].as_str().unwrap()],
                    entry["target_graph_id"]
                );
                assert!(entry["counterpart_locator"].is_object());
            } else if entry["side"] == "source" {
                assert!(entry["original_value"].is_string());
                assert!(entry["normalized_value"].is_null());
            } else {
                assert_eq!(entry["side"], "target");
                assert!(entry["original_value"].is_null());
                assert!(entry["normalized_value"].is_string());
            }
        }
        assert_eq!(serde_json::to_value(&counts).unwrap(), inventory["counts"]);
        assert_eq!(counts.get("net_id"), Some(&1));
        assert_eq!(counts.get("page_id"), Some(&1));
        assert_eq!(counts.get("arc_id"), Some(&6));
        assert_eq!(counts.get("node_id_bijection"), Some(&5));
        assert_eq!(
            counts.get("place_display_name").copied().unwrap_or(0),
            expected_places
        );
        assert_eq!(
            counts.get("tau_local_node_id").copied().unwrap_or(0),
            expected_tau
        );
        let kinds = result.evidence["normalizations"].as_array().unwrap();
        assert_eq!(kinds.len(), counts.len());
        assert!(
            kinds
                .iter()
                .all(|kind| counts.contains_key(kind.as_str().unwrap()))
        );
    }
    let exported =
        conversion::convert("petri-json", "pnml", &load("weighted-cycle.json"), false).unwrap();
    check(&exported, 2, 1);
    let export_entries = exported.evidence["normalization_inventory"]["entries"]
        .as_array()
        .unwrap();
    assert!(
        export_entries
            .iter()
            .filter(|entry| entry["kind"] == "node_id_bijection")
            .all(|entry| entry["changed"] == false)
    );
    let imported =
        conversion::convert("pnml", "petri-json", &load("weighted-cycle.pnml"), false).unwrap();
    check(&imported, 1, 1);
    let mut no_tau: Value = serde_json::from_slice(&load("weighted-cycle.json")).unwrap();
    no_tau["transitions"]["00000000-0000-0000-0000-000000000005"]["label"] = json!("Visible");
    let without_tau = conversion::convert(
        "petri-json",
        "pnml",
        &serde_json::to_vec(&no_tau).unwrap(),
        false,
    )
    .unwrap();
    check(&without_tau, 2, 0);
    assert!(
        without_tau.evidence["normalization_inventory"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .all(|entry| entry["kind"] != "tau_local_node_id")
    );
    let input = String::from_utf8(load("weighted-cycle.pnml")).unwrap();
    let input = input.replace(
        "<name><text>00000000-0000-0000-0000-000000000001</text></name>",
        "",
    );
    let without_names = conversion::convert("pnml", "petri-json", input.as_bytes(), false).unwrap();
    check(&without_names, 0, 1);
}
