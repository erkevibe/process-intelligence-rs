use process_intelligence_rs::service_preview::preview_xes;

#[test]
fn preview_reports_typed_metadata_without_changing_events_or_exposing_values() {
    let input = br#"<log>
      <extension name="Concept" prefix="concept" uri="http://www.xes-standard.org/concept.xes"/>
      <classifier name="Activity and lifecycle" keys="concept:name lifecycle:transition"/>
      <string key="concept:name" value="Original"/><string key="customer" value="PRIVATE_VALUE"/>
      <trace><string key="concept:name" value="Case A"/><int key="priority" value="7"/>
        <event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-01-01T15:00:00.123456+05:00"/>
          <float key="cost" value="1.5"/><boolean key="approved" value="true"/>
        </event>
        <event><string key="concept:name" value="B"/><date key="time:timestamp" value="2026-01-01T10:01:00Z"/>
          <string key="lifecycle:transition" value="suspend"/><float key="cost" value="2.5"/>
        </event>
      </trace></log>"#;
    let original = input.to_vec();
    let preview = preview_xes(input).unwrap();
    assert_eq!(input, original.as_slice());
    assert_eq!(preview.policy, "apromore-validateLog-bbf24df-preview-v1");
    assert_eq!(preview.log.name.as_deref(), Some("Original"));
    assert_eq!(preview.log.cases[0].name.as_deref(), Some("Case A"));
    assert_eq!(preview.log.cases[0].events.len(), 1);
    let event = &preview.log.cases[0].events[0];
    assert_eq!(event.activity, "A");
    assert_eq!(event.ordinal, 0);
    assert_eq!(
        event.timestamp.unwrap().to_rfc3339(),
        "2026-01-01T10:00:00.123456+00:00"
    );
    assert_eq!(event.lifecycle.as_deref(), Some("complete"));
    let report = &preview.projection_report;
    assert_eq!(report.basis, "all_source_attributes_before_event_filtering");
    assert_eq!(
        report.admission_profile,
        "flat_xes_no_global_defaults_or_nested_attributes"
    );
    assert_eq!(
        (
            report.omitted_log_attributes,
            report.omitted_trace_attributes,
            report.omitted_event_attributes
        ),
        (1, 1, 3)
    );
    assert_eq!(report.ignored_classifiers, 1);
    assert_eq!(report.omitted_extension_declarations, 1);
    assert_eq!(report.timestamp_offsets_normalized_to_utc, 1);
    assert_eq!(report.unlisted_attribute_occurrences, 0);
    let cost = report.attributes.iter().find(|a| a.key == "cost").unwrap();
    assert_eq!(
        (cost.scope, cost.value_type, cost.occurrences),
        ("event", "float", 2)
    );
    assert!(
        !serde_json::to_string(report)
            .unwrap()
            .contains("PRIVATE_VALUE")
    );
}

#[test]
fn report_limits_keep_exact_totals_and_repeat_counts() {
    let mut input = String::from(
        "<log><trace><event><string key='concept:name' value='A'/><date key='time:timestamp' value='2026-01-01T00:00:00Z'/>",
    );
    for index in 0..130 {
        input.push_str(&format!("<string key='m{index:03}' value='private'/>"));
    }
    input.push_str("<string key='m000' value='private'/><string key='m000' value='private'/>");
    input.push_str(&format!(
        "<string key='{}' value='private'/>",
        "x".repeat(257)
    ));
    input.push_str("</event></trace></log>");
    let preview = preview_xes(input.as_bytes()).unwrap();
    let report = &preview.projection_report;
    assert_eq!(report.omitted_event_attributes, 133);
    assert_eq!(report.attributes.len(), 128);
    assert_eq!(
        report
            .attributes
            .iter()
            .find(|a| a.key == "m000")
            .unwrap()
            .occurrences,
        3
    );
    assert_eq!(report.unlisted_attribute_occurrences, 3);
    assert_eq!(
        report
            .attributes
            .iter()
            .map(|a| a.occurrences)
            .sum::<usize>()
            + report.unlisted_attribute_occurrences,
        report.omitted_event_attributes
    );
    assert!(report.attributes.iter().all(|a| a.key.len() <= 256));
}

#[test]
fn report_does_not_claim_non_string_or_duplicate_names_are_preserved() {
    let input = br#"<log><int key="concept:name" value="7"/>
      <trace><string key="concept:name" value="First"/><string key="concept:name" value="Second"/>
      <event><string key="concept:name" value="A"/><date key="time:timestamp" value="2026-01-01T00:00:00Z"/></event>
      </trace></log>"#;
    let preview = preview_xes(input).unwrap();
    assert_eq!(preview.log.name, None);
    assert_eq!(preview.log.cases[0].name.as_deref(), Some("First"));
    assert_eq!(preview.projection_report.omitted_log_attributes, 1);
    assert_eq!(preview.projection_report.omitted_trace_attributes, 1);
}

#[test]
fn simple_existing_projection_has_no_omissions_or_offset_change() {
    let input = br#"<log><string key="concept:name" value="L"/><trace><string key="concept:name" value="T"/>
      <event><string key="concept:name" value="A"/><string key="lifecycle:transition" value="start"/><date key="time:timestamp" value="2026-01-01T00:00:00Z"/></event>
      </trace></log>"#;
    let preview = preview_xes(input).unwrap();
    assert!(!preview.projection_report.has_omissions());
    assert_eq!(
        preview
            .projection_report
            .timestamp_offsets_normalized_to_utc,
        0
    );
    assert_eq!(
        preview.log.cases[0].events[0].lifecycle.as_deref(),
        Some("start")
    );
}
