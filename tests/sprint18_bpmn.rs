//! Finite sequenceFlow name contract. No condition or execution semantics.
use process_intelligence_rs::bpmn::{self, ProcessModel};

const XML: &str = include_str!("../fixtures/sprint02/linear.bpmn");
const OLD_JSON: &str = r#"{"schema_version":1,"process_id":"p","name":"old","nodes":[{"id":"s","kind":"start","label":"","x":0.0,"y":0.0},{"id":"a","kind":"task","label":"A","x":100.0,"y":0.0},{"id":"e","kind":"end","label":"","x":300.0,"y":0.0}],"flows":[{"id":"sa","source":"s","target":"a","waypoints":[]},{"id":"ae","source":"a","target":"e","waypoints":[]}],"discovery":null}"#;

fn named(label_xml: &str) -> String {
    XML.replace(
        "id=\"ab\" sourceRef",
        &format!("id=\"ab\" name=\"{label_xml}\" sourceRef"),
    )
}

#[test]
fn unicode_xml_sensitive_whitespace_labels_preserve_graph_and_di_through_edit() {
    let original = bpmn::parse(
        named("  Қазақ &amp; &lt;да&gt; &quot;yes&quot; &apos;ok&apos;&#9;&#10;&#13; ").as_bytes(),
    )
    .unwrap();
    assert_eq!(
        original.flows[1].label,
        "  Қазақ & <да> \"yes\" 'ok'\t\n\r "
    );
    let mut edited = original.clone();
    edited.flows[1].label = "  Ә & <next> \"choice\"\t\n\r  ".into();
    edited.nodes[1].label = "Edited task".into();
    bpmn::validate_edit(&original, &edited).unwrap();
    let json = serde_json::to_string(&edited).unwrap();
    let persisted: ProcessModel = serde_json::from_str(&json).unwrap();
    let xml = bpmn::serialize(&persisted).unwrap();
    assert!(xml.contains("name=\"  Ә &amp; &lt;next&gt; &quot;choice&quot;&#9;&#10;&#13;  \""));
    assert_eq!(bpmn::parse(xml.as_bytes()).unwrap(), edited);
    assert_eq!(edited.flows[1].waypoints, original.flows[1].waypoints);
    assert_eq!(edited.nodes[1].dimensions, original.nodes[1].dimensions);
}

#[test]
fn old_json_and_empty_labels_keep_canonical_bytes_and_empty_xml_has_no_name() {
    let old: ProcessModel = serde_json::from_str(OLD_JSON).unwrap();
    assert!(old.flows.iter().all(|flow| flow.label.is_empty()));
    assert_eq!(serde_json::to_string(&old).unwrap(), OLD_JSON);
    let mut explicit: serde_json::Value = serde_json::from_str(OLD_JSON).unwrap();
    explicit["flows"][0]["label"] = serde_json::json!("");
    let explicit: ProcessModel = serde_json::from_value(explicit).unwrap();
    assert_eq!(serde_json::to_string(&explicit).unwrap(), OLD_JSON);
    let xml = bpmn::serialize(&old).unwrap();
    for line in xml
        .lines()
        .filter(|line| line.starts_with("<bpmn:sequenceFlow"))
    {
        assert!(!line.contains("name="));
    }
    assert_eq!(bpmn::parse(xml.as_bytes()).unwrap(), old);
    assert!(
        bpmn::parse(named("").as_bytes()).unwrap().flows[1]
            .label
            .is_empty()
    );
}

#[test]
fn utf8_byte_boundary_applies_to_xml_and_direct_json_model() {
    for label in ["x".repeat(4096), "Ә".repeat(2048)] {
        let model = bpmn::parse(named(&label).as_bytes()).unwrap();
        assert_eq!(model.flows[1].label.len(), 4096);
        assert_eq!(
            bpmn::parse(bpmn::serialize(&model).unwrap().as_bytes()).unwrap(),
            model
        );
    }
    for label in [
        "x".repeat(4097),
        "Ә".repeat(2049),
        "bad\u{1}control".into(),
        "bad\u{fffe}".into(),
    ] {
        assert!(bpmn::parse(named(&label).as_bytes()).is_err());
        let mut model: ProcessModel = serde_json::from_str(OLD_JSON).unwrap();
        model.flows[0].label = label;
        let decoded: ProcessModel =
            serde_json::from_str(&serde_json::to_string(&model).unwrap()).unwrap();
        assert!(bpmn::validate(&decoded).is_err());
        assert!(bpmn::serialize(&decoded).is_err());
    }
}

#[test]
fn labels_do_not_enable_conditions_defaults_extensions_or_label_di() {
    let named_xml = named("true &amp;&amp; amount &gt; 10");
    assert!(bpmn::parse(named_xml.as_bytes()).is_ok());
    let cases = [
        named_xml.replace("targetRef=\"b\"/>", "targetRef=\"b\"><b:conditionExpression>true</b:conditionExpression></b:sequenceFlow>"),
        named_xml.replace("<b:task id=\"a\"", "<b:task default=\"ab\" id=\"a\""),
        named_xml.replace("<di:waypoint x=\"200\"", "<bd:BPMNLabel><dc:Bounds x=\"0\" y=\"0\" width=\"20\" height=\"10\"/></bd:BPMNLabel><di:waypoint x=\"200\""),
        named_xml.replace("id=\"ab\" name", "id=\"sa\" name"),
        named_xml.replace("sourceRef=\"a\" targetRef=\"b\"", "sourceRef=\"missing\" targetRef=\"b\""),
        named_xml.replace("id=\"ab\" name", "id=\"ab\" language=\"unsafe\" name"),
        named_xml.replace("http://www.omg.org/spec/BPMN/20100524/MODEL", "urn:wrong"),
        named_xml.replace("targetRef=\"b\"/>", "targetRef=\"b\"><![CDATA[true]]></b:sequenceFlow>"),
    ];
    for xml in cases {
        assert!(
            bpmn::parse(xml.as_bytes()).is_err(),
            "unexpected accepted XML: {xml}"
        );
    }
    let mut unknown: serde_json::Value = serde_json::from_str(OLD_JSON).unwrap();
    unknown["flows"][0]["condition"] = serde_json::json!("true");
    assert!(serde_json::from_value::<ProcessModel>(unknown).is_err());
}

#[test]
fn named_exclusive_branches_remain_text_and_graph_not_conditions() {
    let xml = r#"<b:definitions xmlns:b="http://www.omg.org/spec/BPMN/20100524/MODEL" targetNamespace="urn:test"><b:process id="p" isExecutable="false"><b:startEvent id="s"/><b:exclusiveGateway id="g"/><b:task id="a"/><b:task id="b"/><b:exclusiveGateway id="m"/><b:endEvent id="e"/><b:sequenceFlow id="sg" sourceRef="s" targetRef="g"/><b:sequenceFlow id="ga" name="yes" sourceRef="g" targetRef="a"/><b:sequenceFlow id="gb" name="no" sourceRef="g" targetRef="b"/><b:sequenceFlow id="am" sourceRef="a" targetRef="m"/><b:sequenceFlow id="bm" sourceRef="b" targetRef="m"/><b:sequenceFlow id="me" sourceRef="m" targetRef="e"/></b:process></b:definitions>"#;
    let original = bpmn::parse(xml.as_bytes()).unwrap();
    assert_eq!(original.flows[1].label, "yes");
    assert_eq!(original.flows[2].label, "no");
    assert_eq!(
        bpmn::parse(bpmn::serialize(&original).unwrap().as_bytes()).unwrap(),
        original
    );
    assert!(
        bpmn::parse(
            xml.replace(
                "<b:exclusiveGateway id=\"g\"/>",
                "<b:exclusiveGateway id=\"g\" default=\"gb\"/>"
            )
            .as_bytes()
        )
        .is_err()
    );
}
