//! Finite DI preservation contract with hand-declared geometry, not miner output.
use process_intelligence_rs::bpmn::{self, ModelFlow, NodeDimensions, ProcessModel};

const XML: &str = include_str!("../fixtures/sprint02/linear.bpmn");
const OLD_JSON: &str = r#"{"schema_version":1,"process_id":"p","name":"old","nodes":[{"id":"s","kind":"start","label":"","x":0.0,"y":0.0},{"id":"a","kind":"task","label":"A","x":100.0,"y":0.0},{"id":"e","kind":"end","label":"","x":300.0,"y":0.0}],"flows":[{"id":"sa","source":"s","target":"a","waypoints":[]},{"id":"ae","source":"a","target":"e","waypoints":[]}],"discovery":null}"#;

#[test]
fn actual_imported_sizes_and_waypoints_survive_xml_and_stored_json_roundtrips() {
    let model = bpmn::parse(XML.as_bytes()).unwrap();
    assert_eq!(
        model.nodes[0].effective_dimensions(),
        NodeDimensions {
            width: 36.0,
            height: 36.0
        }
    );
    assert_eq!(
        model.nodes[1].effective_dimensions(),
        NodeDimensions {
            width: 100.0,
            height: 80.0
        }
    );
    assert_eq!(model.nodes[2].dimensions, None);
    let waypoints = model
        .flows
        .iter()
        .find(|flow| flow.id == "ab")
        .unwrap()
        .waypoints
        .clone();
    let encoded = bpmn::serialize(&model).unwrap();
    assert!(encoded.contains("width=\"36\" height=\"36\""));
    assert!(encoded.contains("width=\"100\" height=\"80\""));
    let restored = bpmn::parse(encoded.as_bytes()).unwrap();
    assert_eq!(restored, model);
    assert_eq!(
        restored
            .flows
            .iter()
            .find(|flow| flow.id == "ab")
            .unwrap()
            .waypoints,
        waypoints
    );
    let stored = serde_json::to_vec(&model).unwrap();
    assert_eq!(
        serde_json::from_slice::<ProcessModel>(&stored).unwrap(),
        model
    );
}

#[test]
fn labels_and_positions_edit_without_resizing_and_original_is_untouched() {
    let original = bpmn::parse(XML.as_bytes()).unwrap();
    let mut edit = original.clone();
    edit.nodes[1].label = "Жаңа <label> & \"Ә\"".into();
    edit.nodes[1].x = -50.25;
    edit.nodes[1].y = 125.5;
    bpmn::validate_edit(&original, &edit).unwrap();
    assert_eq!(
        edit.nodes[1].effective_dimensions(),
        NodeDimensions {
            width: 100.0,
            height: 80.0
        }
    );
    assert_eq!(
        bpmn::parse(bpmn::serialize(&edit).unwrap().as_bytes()).unwrap(),
        edit
    );
    assert_eq!(original, bpmn::parse(XML.as_bytes()).unwrap());
}

#[test]
fn old_model_json_without_dimensions_keeps_its_exact_serialized_shape() {
    let old: ProcessModel = serde_json::from_str(OLD_JSON).unwrap();
    bpmn::validate(&old).unwrap();
    assert!(old.nodes.iter().all(|node| node.dimensions.is_none()));
    assert_eq!(serde_json::to_string(&old).unwrap(), OLD_JSON);
    assert_eq!(
        old.nodes[0].effective_dimensions(),
        NodeDimensions {
            width: 45.0,
            height: 45.0
        }
    );
    assert_eq!(
        old.nodes[1].effective_dimensions(),
        NodeDimensions {
            width: 120.0,
            height: 70.0
        }
    );
    assert_eq!(
        bpmn::parse(bpmn::serialize(&old).unwrap().as_bytes()).unwrap(),
        old
    );
}

#[test]
fn explicit_default_xml_sizes_normalize_to_absence_without_geometry_loss() {
    let default_xml = XML
        .replace("width=\"36\" height=\"36\"", "width=\"45\" height=\"45\"")
        .replace("width=\"100\" height=\"80\"", "width=\"120\" height=\"70\"");
    let model = bpmn::parse(default_xml.as_bytes()).unwrap();
    assert!(model.nodes.iter().all(|node| node.dimensions.is_none()));
    assert!(
        !serde_json::to_string(&model)
            .unwrap()
            .contains("dimensions")
    );
    assert_eq!(
        bpmn::parse(bpmn::serialize(&model).unwrap().as_bytes()).unwrap(),
        model
    );
    // A default-equivalent JSON spelling is not a resize. XML canonicalizes it.
    let mut equivalent = model.clone();
    equivalent.nodes[1].dimensions = Some(NodeDimensions {
        width: 120.0,
        height: 70.0,
    });
    bpmn::validate_edit(&model, &equivalent).unwrap();
    let reimported = bpmn::parse(bpmn::serialize(&equivalent).unwrap().as_bytes()).unwrap();
    assert_eq!(reimported, model);
}

#[test]
fn invalid_dimensions_reject_in_xml_and_json_models() {
    for value in ["0", "-1", "NaN", "inf", "1000001"] {
        let xml = XML.replace("width=\"100\"", &format!("width=\"{value}\""));
        assert!(
            bpmn::parse(xml.as_bytes()).is_err(),
            "invalid width accepted: {value}"
        );
    }
    let original = bpmn::parse(XML.as_bytes()).unwrap();
    for value in [0.0, -1.0, f64::NAN, f64::INFINITY, 1_000_001.0] {
        for dimensions in [
            NodeDimensions {
                width: value,
                height: 80.0,
            },
            NodeDimensions {
                width: 100.0,
                height: value,
            },
        ] {
            let mut model = original.clone();
            model.nodes[1].dimensions = Some(dimensions);
            assert_eq!(bpmn::validate(&model).unwrap_err().code, "bpmn_invalid");
        }
    }
    let mut boundary = original;
    boundary.nodes[1].dimensions = Some(NodeDimensions {
        width: 0.5,
        height: 1_000_000.0,
    });
    bpmn::validate(&boundary).unwrap();
    assert_eq!(
        bpmn::parse(bpmn::serialize(&boundary).unwrap().as_bytes()).unwrap(),
        boundary
    );
}

#[test]
fn size_loss_or_resize_of_existing_node_is_refused_but_task_deletion_is_valid() {
    let original = bpmn::parse(XML.as_bytes()).unwrap();
    for dimensions in [
        None,
        Some(NodeDimensions {
            width: 101.0,
            height: 80.0,
        }),
    ] {
        let mut edit = original.clone();
        edit.nodes[1].dimensions = dimensions;
        assert_eq!(
            bpmn::validate_edit(&original, &edit).unwrap_err().code,
            "bpmn_unsupported"
        );
    }
    let mut deletion = original.clone();
    deletion.nodes.retain(|node| node.id != "a");
    deletion
        .flows
        .retain(|flow| flow.source != "a" && flow.target != "a");
    deletion.flows.push(ModelFlow {
        id: "sb".into(),
        source: "s".into(),
        target: "b".into(),
        waypoints: vec![],
        label: String::new(),
    });
    bpmn::validate_edit(&original, &deletion).unwrap();
    assert_eq!(
        bpmn::parse(bpmn::serialize(&deletion).unwrap().as_bytes()).unwrap(),
        deletion
    );
}

#[test]
fn flow_names_are_preserved_by_the_agreed_label_extension() {
    let named = XML.replace(
        "id=\"ab\" sourceRef",
        "id=\"ab\" name=\"conditional choice\" sourceRef",
    );
    assert_eq!(
        bpmn::parse(named.as_bytes())
            .unwrap()
            .flows
            .iter()
            .find(|f| f.id == "ab")
            .unwrap()
            .label,
        "conditional choice"
    );
}

#[test]
fn conditions_and_unknown_dimension_fields_are_still_refused() {
    let condition = XML.replace("sourceRef=\"a\" targetRef=\"b\"/>", "sourceRef=\"a\" targetRef=\"b\"><b:conditionExpression>true</b:conditionExpression></b:sequenceFlow>");
    assert_eq!(
        bpmn::parse(condition.as_bytes()).unwrap_err().code,
        "bpmn_unsupported"
    );
    let mut json: serde_json::Value = serde_json::from_str(OLD_JSON).unwrap();
    json["nodes"][1]["dimensions"] =
        serde_json::json!({"width":100.0,"height":80.0,"script":"ignored?"});
    assert!(serde_json::from_value::<ProcessModel>(json).is_err());
}
