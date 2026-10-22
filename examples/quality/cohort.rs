//! A separate cohort pipeline; the frozen general bridge and metrics are unchanged.
use crate::quality::{
    Issue, Limits, Result, array, bridge, bytes, integer, metrics, read, sha, state, text, write,
};
use process_mining::PetriNet;
use serde_json::{Value, json};
use std::{collections::BTreeSet, path::Path};
pub const COHORT: &str = include_str!("../../fixtures/quality-miner/corpus.json");
fn name(value: &Value) -> Result<&str> {
    let value = text(value)?;
    if value.is_empty() || value.contains(['/', '\\', ':']) || value == "." || value == ".." {
        return Err(Issue::refused("unsafe_cohort_filename"));
    }
    Ok(value)
}
fn json_read(path: &Path) -> Result<(Vec<u8>, Value)> {
    let data = read(path)?;
    let value = serde_json::from_slice(&data).map_err(|_| Issue::refused("cohort_json"))?;
    Ok((data, value))
}
fn exact_hash(data: &[u8], expected: &Value) -> Result<()> {
    if sha(data) != text(expected)?.to_ascii_lowercase() {
        return Err(Issue::refused("cohort_artifact_hash"));
    }
    Ok(())
}
pub fn sources() -> Value {
    json!({"base":crate::quality::pipeline::sources(),
        "examples/bpmn_quality_cohort.rs":sha(include_bytes!("../bpmn_quality_cohort.rs")),
        "examples/quality/cohort.rs":sha(include_bytes!("cohort.rs")),
        "tools/sprint19/quality-miner-project.py":sha(include_bytes!("../../tools/sprint19/quality-miner-project.py")),
        "tools/sprint19/schema-hint.py":sha(include_bytes!("../../tools/sprint19/schema-hint.py")),
        "tools/sprint19/quality-di.py":sha(include_bytes!("../../tools/sprint19/quality-di.py"))})
}
/// Independently check exact raw byte subtraction, not replacement XML assertions.
pub fn reconstruct(raw: &[u8], report: &Value) -> Result<Vec<u8>> {
    exact_hash(raw, &report["original_sha256"])?;
    if integer(&report["original_bytes"])? != raw.len() as u64
        || report["projection_status"] != "projected"
    {
        return Err(Issue::refused("projection_original_length_or_status"));
    }
    let mut output = Vec::new();
    let mut cursor = 0;
    for span in array(&report["removed_spans"])? {
        let start = usize::try_from(integer(&span["byte_start"])?)
            .map_err(|_| Issue::refused("span_index"))?;
        let length = usize::try_from(integer(&span["byte_length"])?)
            .map_err(|_| Issue::refused("span_length"))?;
        let end = start
            .checked_add(length)
            .ok_or_else(|| Issue::refused("span_overflow"))?;
        if length == 0 || start < cursor || end > raw.len() {
            return Err(Issue::refused("projection_span_bounds"));
        }
        exact_hash(&raw[start..end], &span["subtree_sha256"])?;
        if raw[start..end] != *text(&span["raw_utf8"])?.as_bytes() {
            return Err(Issue::refused("projection_span_lexeme"));
        }
        output.extend_from_slice(&raw[cursor..start]);
        cursor = end;
    }
    output.extend_from_slice(&raw[cursor..]);
    exact_hash(&output, &report["projected_sha256"])?;
    if integer(&report["projected_bytes"])? != output.len() as u64 {
        return Err(Issue::refused("projection_output_length"));
    }
    Ok(output)
}
fn checked_projection(folder: &Path, row: &Value, key: &str) -> Result<Vec<u8>> {
    let data = read(
        &folder
            .join("projection")
            .join(name(&row[format!("{key}_file")])?),
    )?;
    exact_hash(&data, &row[format!("{key}_sha256")])?;
    Ok(data)
}
/// The historical cohort has fixed original bytes and only these exact inert lexemes.
/// Rehashed external receipts cannot choose other deletions or omit an annotation.
pub fn cohort_spans(raw: &[u8], report: &Value, needle: &[u8], expected_count: u64) -> Result<()> {
    let positions: Vec<usize> = raw
        .windows(needle.len())
        .enumerate()
        .filter_map(|(index, value)| (value == needle).then_some(index))
        .collect();
    let spans = array(&report["removed_spans"])?;
    if positions.len() as u64 != expected_count || spans.len() != positions.len() {
        return Err(Issue::refused("cohort_exact_inert_span_count"));
    }
    for (span, index) in spans.iter().zip(positions) {
        if integer(&span["byte_start"])? != index as u64
            || integer(&span["byte_length"])? != needle.len() as u64
            || text(&span["raw_utf8"])?.as_bytes() != needle
        {
            return Err(Issue::refused("cohort_exact_inert_span_lexeme"));
        }
    }
    Ok(())
}
fn save_net(output: &Path, id: &str, net: PetriNet, map: Value) -> Result<Value> {
    let data = bytes(&net)?;
    let hash = sha(&data);
    let net_file = format!("{id}.net.json");
    let map_file = format!("{id}.map.json");
    let graph_file = format!("{id}.graph.json");
    write(&output.join("nets").join(&net_file), &data)?;
    let map_data = bytes(&map)?;
    write(&output.join("maps").join(&map_file), &map_data)?;
    let graph = match state::admit(&net, &hash, Limits::default()) {
        Ok(value) => json!({"status":"admitted","graph":value}),
        Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
    };
    let graph_data = bytes(&graph)?;
    write(&output.join("graphs").join(&graph_file), &graph_data)?;
    Ok(
        json!({"status":"net_saved","net_file":net_file,"net_sha256":hash,
        "map_file":map_file,"map_sha256":sha(&map_data),"graph_file":graph_file,
        "graph_sha256":sha(&graph_data),"admission_status":graph["status"],"admission_reason":graph.get("reason")}),
    )
}
pub fn prepare(corpus_path: &Path, projection_dir: &Path, output: &Path) -> Result<()> {
    let corpus_bytes = read(corpus_path)?;
    if sha(&corpus_bytes) != sha(COHORT.as_bytes()) {
        return Err(Issue::refused("frozen_miner_cohort_hash"));
    }
    let corpus: Value = serde_json::from_str(COHORT).expect("frozen_cohort");
    let (projection_bytes, projection) = json_read(&projection_dir.join("projection.json"))?;
    if projection["phase"] != "cohort_projection_only_no_converter"
        || projection["cohort_sha256"] != sha(&corpus_bytes)
        || projection["sources"]["tools/sprint19/schema-hint.py"]
            != sources()["tools/sprint19/schema-hint.py"]
        || projection["sources"]["tools/sprint19/quality-di.py"]
            != sources()["tools/sprint19/quality-di.py"]
        || projection["sources"]["tools/sprint19/quality-miner-project.py"]
            != sources()["tools/sprint19/quality-miner-project.py"]
    {
        return Err(Issue::refused("cohort_projection_source_or_phase"));
    }
    let projected_rows = array(&projection["cases"])?;
    let cases = array(&corpus["cases"])?;
    if cases.len() != 8 || projected_rows.len() != 8 {
        return Err(Issue::refused("eight_cohort_rows_required"));
    }
    let ids: BTreeSet<_> = projected_rows
        .iter()
        .map(|row| row["id"].as_str())
        .collect();
    if ids.len() != 8 || ids.contains(&None) {
        return Err(Issue::refused("unique_cohort_ids"));
    }
    std::fs::create_dir(output).map_err(|_| Issue::refused("fresh_directory_required"))?;
    for folder in ["inputs", "projection", "nets", "maps", "graphs"] {
        std::fs::create_dir(output.join(folder))
            .map_err(|_| Issue::refused("fresh_subdirectory_required"))?;
    }
    write(&output.join("inputs/corpus.json"), &corpus_bytes)?;
    write(&output.join("projection.json"), &projection_bytes)?;
    let root = corpus_path
        .parent()
        .ok_or_else(|| Issue::refused("cohort_parent"))?;
    let mut artifacts = serde_json::Map::new();
    for case in cases {
        let id = name(&case["id"])?;
        let row = projected_rows
            .iter()
            .find(|row| row["id"] == case["id"])
            .ok_or_else(|| Issue::refused("cohort_row_missing"))?;
        if row["source_input"] != case["source_input"]
            || row["carried_actual_outcome"] != case["carried_actual_outcome"]
            || row["trace_lineage_verified"] != true
        {
            return Err(Issue::refused("cohort_lineage_binding"));
        }
        let source = &case["source_input"];
        let xes = read(&root.join(text(&source["file"])?))?;
        exact_hash(&xes, &source["sha256"])?;
        let copied_xes = read(
            &projection_dir
                .join("inputs")
                .join(name(&row["source_xes_file"])?),
        )?;
        if copied_xes != xes || xes.len() as u64 != integer(&source["bytes"])? {
            return Err(Issue::refused("source_xes_copy"));
        }
        write(&output.join("inputs").join(format!("{id}.xes")), &xes)?;
        // Frozen QA-checked ordered trace lineage, not an inferred held-out group.
        let traces = array(&source["traces"])?;
        if traces.len() as u64 != integer(&source["trace_count"])?
            || !source["heldout_log"].is_null()
        {
            return Err(Issue::refused("trace_count_or_heldout"));
        }
        let weighted = metrics::variants(&source["training_log"])?;
        let mut observed = std::collections::BTreeMap::new();
        let mut events = 0_u64;
        for (index, trace) in traces.iter().enumerate() {
            if integer(&trace["source_trace_index"])? != index as u64 {
                return Err(Issue::refused("trace_index"));
            }
            let sequence: Vec<String> = array(&trace["sequence"])?
                .iter()
                .map(|v| text(v).map(str::to_owned))
                .collect::<Result<_>>()?;
            if integer(&trace["event_count"])? != sequence.len() as u64 {
                return Err(Issue::refused("trace_event_count"));
            }
            events += sequence.len() as u64;
            *observed.entry(sequence).or_insert(0_u64) += 1;
        }
        if observed != weighted || events != integer(&source["event_count"])? {
            return Err(Issue::refused("training_trace_frequency_binding"));
        }
        let prepared = if case["raw_bpmn"].is_null() {
            if row["status"] != "carried_algorithm_exception" {
                return Err(Issue::refused("empty_log_outcome_changed"));
            }
            json!({"status":"carried_algorithm_exception","exception":case["carried_actual_outcome"]["exception"]})
        } else {
            let raw = read(&root.join(name(&case["raw_bpmn"]["file"])?))?;
            exact_hash(&raw, &case["raw_bpmn"]["sha256"])?;
            if raw != read(&projection_dir.join("inputs").join(name(&row["raw_file"])?))? {
                return Err(Issue::refused("original_raw_copy"));
            }
            exact_hash(&raw, &row["raw_sha256"])?;
            write(&output.join("inputs").join(format!("{id}.raw.bpmn")), &raw)?;
            if id == "self-loop" {
                if row["status"] != "raw_compatibility_refused"
                    || row["category"] != "quality_unsupported_standard_loop_before_both_converters"
                {
                    return Err(Issue::refused("standard_loop_guard_missing"));
                }
                json!({"status":"quality_unsupported_semantics","reason":"quality_unsupported_standard_loop_before_both_converters"})
            } else {
                if row["status"] != "projected_pending_strict_prepare" {
                    return Err(Issue::refused("unexpected_projection_refusal"));
                }
                let hint_data = checked_projection(projection_dir, row, "hint")?;
                let hint_report_data = checked_projection(projection_dir, row, "hint_report")?;
                let hint_report: Value = serde_json::from_slice(&hint_report_data)
                    .map_err(|_| Issue::refused("hint_report_json"))?;
                let projected = checked_projection(projection_dir, row, "projected")?;
                let di_report_data = checked_projection(projection_dir, row, "di_report")?;
                let di_report: Value = serde_json::from_slice(&di_report_data)
                    .map_err(|_| Issue::refused("di_report_json"))?;
                cohort_spans(&raw,&hint_report,b"xsi:schemaLocation=\"http://www.omg.org/spec/BPMN/20100524/MODEL BPMN20.xsd\"",1)?;
                cohort_spans(
                    &hint_data,
                    &di_report,
                    b"<bpmndi:BPMNLabel/>",
                    integer(&case["static_features"]["bpmnlabel_DI_count"])?,
                )?;
                if reconstruct(&raw, &hint_report)? != hint_data
                    || reconstruct(&hint_data, &di_report)? != projected
                    || hint_report["semantic_map"] != di_report["semantic_map"]
                {
                    return Err(Issue::refused("two_stage_projection_conservation"));
                }
                for key in ["hint", "hint_report", "projected", "di_report"] {
                    let data = checked_projection(projection_dir, row, key)?;
                    write(
                        &output
                            .join("projection")
                            .join(name(&row[format!("{key}_file")])?),
                        &data,
                    )?;
                }
                match bridge::from_xml(&projected) {
                    Ok((net, map)) => save_net(output, id, net, map)?,
                    Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
                }
            }
        };
        artifacts.insert(id.to_owned(),json!({"id":id,"source_input":source,"carried_actual_outcome":case["carried_actual_outcome"],"projection":row,"prepared":prepared}));
    }
    let bundle = json!({"schema_version":1,"phase":"miner_prepare_only_no_fitness_or_precision","cohort_sha256":sha(&corpus_bytes),"projection_sha256":sha(&projection_bytes),"sources":sources(),"artifacts":artifacts,"limits":Limits::default(),"not_acceptance":true});
    write(&output.join("bundle.json"), &bytes(&bundle)?)
}
pub fn score(directory: &Path, output: &Path) -> Result<()> {
    let (bundle_bytes, bundle) = json_read(&directory.join("bundle.json"))?;
    if bundle["phase"] != "miner_prepare_only_no_fitness_or_precision"
        || bundle["cohort_sha256"] != sha(COHORT.as_bytes())
        || bundle["sources"] != sources()
    {
        return Err(Issue::refused("saved_cohort_source_or_phase"));
    }
    exact_hash(
        &read(&directory.join("inputs/corpus.json"))?,
        &bundle["cohort_sha256"],
    )?;
    exact_hash(
        &read(&directory.join("projection.json"))?,
        &bundle["projection_sha256"],
    )?;
    let corpus: Value = serde_json::from_str(COHORT).expect("frozen_cohort");
    let mut rows = Vec::new();
    for case in array(&corpus["cases"])? {
        let id = name(&case["id"])?;
        let artifact = &bundle["artifacts"][id];
        let record = &artifact["prepared"];
        if artifact["source_input"] != case["source_input"] {
            return Err(Issue::refused("saved_training_lineage"));
        }
        if record["status"] != "net_saved" || record["admission_status"] != "admitted" {
            rows.push(json!({"id":id,"result":record}));
            continue;
        }
        let data = read(&directory.join("nets").join(name(&record["net_file"])?))?;
        exact_hash(&data, &record["net_sha256"])?;
        for (folder, key) in [("maps", "map"), ("graphs", "graph")] {
            exact_hash(
                &read(
                    &directory
                        .join(folder)
                        .join(name(&record[format!("{key}_file")])?),
                )?,
                &record[format!("{key}_sha256")],
            )?;
        }
        let net: PetriNet =
            serde_json::from_slice(&data).map_err(|_| Issue::refused("saved_net_json"))?;
        let result = match state::admit(&net, text(&record["net_sha256"])?, Limits::default()) {
            Ok(graph) => match metrics::score(
                &net,
                &graph,
                &case["source_input"]["training_log"],
                Limits::default(),
            ) {
                Ok(value) => {
                    json!({"status":"admitted","graph":graph,"groups":[{"group":"training_log","input":case["source_input"]["training_log"],"metrics":value}]})
                }
                Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
            },
            Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
        };
        rows.push(json!({"id":id,"net_sha256":record["net_sha256"],"result":result}));
    }
    write(
        output,
        &bytes(
            &json!({"schema_version":1,"phase":"miner_score_saved_only_no_conversion_or_mining","bundle_sha256":sha(&bundle_bytes),"cohort_sha256":sha(COHORT.as_bytes()),"sources":sources(),"cases":rows,"not_acceptance":true}),
        )?,
    )
}
