//! Independent closed-subset / observed-language oracle; never derives expectations from miner.
use process_intelligence_rs::{
    bpmn::{self, NodeKind, ProcessModel},
    event_io::parse_xes,
};
use std::collections::BTreeSet;
const XML: &str = include_str!("../fixtures/sprint02/linear.bpmn");
#[test]
fn semantic_labels_ids_positions_waypoints_roundtrip() {
    let m = bpmn::parse(XML.as_bytes()).unwrap();
    assert_eq!(m.process_id, "p");
    assert_eq!(m.name, "Қазақ & test");
    assert_eq!(m.nodes.len(), 4);
    assert_eq!(m.flows.len(), 3);
    let a = m.nodes.iter().find(|n| n.id == "a").unwrap();
    assert_eq!(a.label, "A & \"quote\"\nline");
    assert_eq!((a.x, a.y), (100.0, -20.25));
    let f = m.flows.iter().find(|f| f.id == "ab").unwrap();
    assert_eq!(f.waypoints.len(), 2);
    assert_eq!(f.waypoints[1].x, 300.5);
    assert_eq!(
        bpmn::parse(bpmn::serialize(&m).unwrap().as_bytes()).unwrap(),
        m
    );
    let mut edit = m.clone();
    edit.nodes.iter_mut().find(|n| n.id == "b").unwrap().label = "<html>\t\r\nӘ".into();
    assert_eq!(
        bpmn::parse(bpmn::serialize(&edit).unwrap().as_bytes()).unwrap(),
        edit
    );
}
#[test]
fn unsupported_semantics_and_wrong_namespaces_reject() {
    for xml in [XML.replace("http://www.omg.org/spec/BPMN/20100524/MODEL","urn:wrong"),XML.replace("isExecutable=\"false\"","isExecutable=\"true\""),XML.replace("<b:task id=\"b\" name=\"B\"/>","<b:userTask id=\"b\" name=\"B\"/>"),XML.replace("<b:startEvent id=\"s\"/>","<b:startEvent id=\"s\"><b:timerEventDefinition/></b:startEvent>"),XML.replace("<b:task id=\"b\" name=\"B\"/>","<b:task id=\"b\" name=\"B\"><b:extensionElements/></b:task>"),XML.replace("<b:task id=\"b\" name=\"B\"/>","<b:subProcess id=\"b\"/>"),XML.replace("sourceRef=\"a\" targetRef=\"b\"/>","sourceRef=\"a\" targetRef=\"b\"><b:conditionExpression>true</b:conditionExpression></b:sequenceFlow>"),XML.replace("name=\"B\"","name=\"B\" implementation=\"unsafe\""),XML.replace("<?xml version=\"1.0\" encoding=\"UTF-8\"?>","<!DOCTYPE definitions [<!ENTITY x SYSTEM \"file:///private\">]>")]{assert!(bpmn::parse(xml.as_bytes()).is_err(),"unsupported accepted: {xml}");}
}
#[test]
fn malformed_ids_references_and_di_reject() {
    for xml in [
        XML.replace("id=\"b\" name=\"B\"", "id=\"a\" name=\"B\""),
        XML.replace("id=\"ab\" sourceRef", "id=\"a\" sourceRef"),
        XML.replace("targetRef=\"b\"", "targetRef=\"missing\""),
        XML.replace("x=\"10.5\"", "x=\"NaN\""),
        XML.replace("width=\"36\"", "width=\"-1\""),
        XML.replace("bpmnElement=\"a\"", "bpmnElement=\"unknown\""),
        XML.replace("<di:waypoint x=\"300.5\" y=\"40\"/>", ""),
        XML.replace("</b:definitions>", ""),
        XML.replace("name=\"B\"", "name=\"B\u{1}\""),
    ] {
        assert!(
            bpmn::parse(xml.as_bytes()).is_err(),
            "invalid accepted: {xml}"
        );
    }
}
#[test]
fn both_gateway_kinds_roundtrip_and_domain_validation() {
    let mut m = bpmn::parse(XML.as_bytes()).unwrap();
    for kind in [NodeKind::ExclusiveGateway, NodeKind::ParallelGateway] {
        m.nodes.iter_mut().find(|n| n.id == "a").unwrap().kind = kind;
        assert_eq!(
            bpmn::parse(bpmn::serialize(&m).unwrap().as_bytes()).unwrap(),
            m
        );
    }
    let mut bad = m.clone();
    bad.nodes[0].x = f64::INFINITY;
    assert!(bpmn::validate(&bad).is_err());
    let mut bad = m.clone();
    bad.schema_version = 99;
    assert!(bpmn::validate(&bad).is_err());
    let mut bad = m;
    bad.nodes[0].label = "x".repeat(4097);
    assert!(bpmn::validate(&bad).is_err());
}
fn language(m: &ProcessModel) -> BTreeSet<Vec<String>> {
    fn visit(
        m: &ProcessModel,
        id: &str,
        mut word: Vec<String>,
        depth: usize,
        result: &mut BTreeSet<Vec<String>>,
    ) {
        assert!(depth < 100, "unexpected cyclic baseline");
        let n = m.nodes.iter().find(|n| n.id == id).unwrap();
        if n.kind == NodeKind::Task {
            word.push(n.label.clone());
        }
        if n.kind == NodeKind::End {
            result.insert(word);
            return;
        }
        for f in m.flows.iter().filter(|f| f.source == id) {
            visit(m, &f.target, word.clone(), depth + 1, result);
        }
    }
    let mut result = BTreeSet::new();
    for n in m.nodes.iter().filter(|n| n.kind == NodeKind::Start) {
        visit(m, &n.id, vec![], 0, &mut result);
    }
    result
}
#[test]
fn discovery_language_exact_observed_variants_including_empty_repeat() {
    let log = parse_xes(include_bytes!("../fixtures/manual.xes")).unwrap();
    let m = bpmn::discover(&log).unwrap();
    assert_eq!(
        language(&m),
        BTreeSet::from([
            vec!["A".into(), "B".into(), "C".into()],
            vec!["A".into(), "C".into()],
            vec!["A".into(), "A".into()]
        ])
    );
    assert!(m.discovery.is_some());
    assert!(!m.nodes.iter().any(|n| n.kind == NodeKind::ParallelGateway));
    let log=parse_xes(b"<log><trace/><trace><event><string key=\"concept:name\" value=\"A\"/></event></trace></log>").unwrap();
    let m = bpmn::discover(&log).unwrap();
    assert_eq!(language(&m), BTreeSet::from([vec![], vec!["A".into()]]));
    let mut expected = m.clone();
    expected.discovery = None;
    assert_eq!(
        bpmn::parse(bpmn::serialize(&m).unwrap().as_bytes()).unwrap(),
        expected
    );
}

#[test]
fn zero_cases_cannot_manufacture_an_observed_empty_variant() {
    let log = parse_xes(b"<log/>").unwrap();
    assert!(
        bpmn::discover(&log).is_err(),
        "zero observed cases is distinct from one observed empty trace"
    );
}
