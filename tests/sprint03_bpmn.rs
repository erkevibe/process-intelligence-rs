//! Independent structural-edit contract; manual expected s-a-c-b-e path.
use process_intelligence_rs::bpmn::{self, ModelFlow, ModelNode, NodeKind, Point, ProcessModel};
fn original() -> ProcessModel {
    bpmn::parse(include_bytes!("../fixtures/sprint02/linear.bpmn")).unwrap()
}
fn flow(id: &str, source: &str, target: &str) -> ModelFlow {
    ModelFlow {
        id: id.into(),
        source: source.into(),
        target: target.into(),
        waypoints: vec![],
    }
}
fn inserted() -> ProcessModel {
    let mut m = original();
    m.nodes.push(ModelNode {
        id: "c".into(),
        kind: NodeKind::Task,
        label: "Жаңа <task>\nline".into(),
        x: 123.5,
        y: -234.25,
    });
    m.flows.iter_mut().find(|f| f.id == "ab").unwrap().target = "c".into();
    m.flows.push(flow("cb", "c", "b"));
    m
}
#[test]
fn add_task_retarget_and_add_flow_roundtrip_exact_labels_ids_geometry() {
    let old = original();
    let mut edit = inserted();
    edit.flows
        .iter_mut()
        .find(|f| f.id == "cb")
        .unwrap()
        .waypoints = vec![Point { x: 1.25, y: -2.5 }, Point { x: 10.5, y: 20.75 }];
    bpmn::validate_edit(&old, &edit).unwrap();
    let xml = bpmn::serialize(&edit).unwrap();
    assert_eq!(bpmn::parse(xml.as_bytes()).unwrap(), edit);
    assert_eq!(
        edit.nodes.iter().find(|n| n.id == "c").unwrap().label,
        "Жаңа <task>\nline"
    );
    assert_eq!(
        edit.flows.iter().find(|f| f.id == "ab").unwrap().target,
        "c"
    );
    let expected = [
        ("sa", "s", "a"),
        ("ab", "a", "c"),
        ("cb", "c", "b"),
        ("be", "b", "e"),
    ];
    for (id, source, target) in expected {
        let f = edit.flows.iter().find(|f| f.id == id).unwrap();
        assert_eq!((&*f.source, &*f.target), (source, target));
    }
    assert_eq!(
        old,
        original(),
        "validation must not mutate stored original"
    );
}
#[test]
fn delete_task_and_incident_flows_with_explicit_reconnection_is_valid() {
    let old = inserted();
    let mut edit = old.clone();
    edit.nodes.retain(|n| n.id != "b");
    edit.flows.retain(|f| f.source != "b" && f.target != "b");
    edit.flows.push(flow("ce", "c", "e"));
    bpmn::validate_edit(&old, &edit).unwrap();
    assert_eq!(
        bpmn::parse(bpmn::serialize(&edit).unwrap().as_bytes()).unwrap(),
        edit
    );
}
#[test]
fn protected_node_delete_and_existing_kind_change_reject_even_valid_graph() {
    let old = original();
    let mut replacement = old.clone();
    replacement
        .nodes
        .iter_mut()
        .find(|n| n.id == "s")
        .unwrap()
        .id = "s_new".into();
    replacement
        .flows
        .iter_mut()
        .find(|f| f.id == "sa")
        .unwrap()
        .source = "s_new".into();
    bpmn::validate(&replacement).unwrap();
    assert_eq!(
        bpmn::validate_edit(&old, &replacement).unwrap_err().code,
        "bpmn_unsupported"
    );
    for kind in [NodeKind::ExclusiveGateway, NodeKind::ParallelGateway] {
        let mut m = old.clone();
        m.nodes.iter_mut().find(|n| n.id == "a").unwrap().kind = kind;
        bpmn::validate(&m).unwrap();
        assert!(bpmn::validate_edit(&old, &m).is_err());
        let mut removed = m.clone();
        removed.nodes.retain(|n| n.id != "a");
        removed.flows.retain(|f| f.id != "sa" && f.id != "ab");
        removed.flows.push(flow("sb", "s", "b"));
        bpmn::validate(&removed).unwrap();
        assert!(bpmn::validate_edit(&m, &removed).is_err());
    }
}
#[test]
fn new_non_task_and_process_identity_change_reject() {
    let old = original();
    for kind in [NodeKind::ExclusiveGateway, NodeKind::ParallelGateway] {
        let mut m = inserted();
        m.nodes.iter_mut().find(|n| n.id == "c").unwrap().kind = kind;
        bpmn::validate(&m).unwrap();
        assert!(bpmn::validate_edit(&old, &m).is_err());
    }
    let mut m = old.clone();
    m.process_id = "different_process".into();
    bpmn::validate(&m).unwrap();
    assert!(bpmn::validate_edit(&old, &m).is_err());
}
#[test]
fn dangling_duplicate_disconnected_nonfinite_and_unbounded_edits_reject() {
    let old = original();
    let mut cases = vec![];
    let mut m = inserted();
    m.flows.iter_mut().find(|f| f.id == "cb").unwrap().target = "missing".into();
    cases.push(m);
    let mut m = inserted();
    m.nodes.last_mut().unwrap().id = "a".into();
    cases.push(m);
    let mut m = inserted();
    m.flows.retain(|f| f.id != "cb");
    cases.push(m);
    let mut m = inserted();
    m.nodes.last_mut().unwrap().x = f64::NAN;
    cases.push(m);
    let mut m = inserted();
    m.nodes.last_mut().unwrap().label = "x".repeat(4097);
    cases.push(m);
    for m in cases {
        assert!(bpmn::validate_edit(&old, &m).is_err());
    }
    assert_eq!(old, original());
}
