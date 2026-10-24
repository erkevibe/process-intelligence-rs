use super::{
    CORPUS, Issue, Limits, Result, array, bridge, bytes, fixture, integer, metrics, read, sha,
    state, text, write,
};
use process_mining::PetriNet;
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::Path};

fn new_dir(path: &Path) -> Result<()> {
    std::fs::create_dir(path).map_err(|_| Issue::refused("fresh_directory_required"))
}
fn basename(value: &str) -> Result<&str> {
    if value.is_empty() || value.contains(['/', '\\', ':']) || value == "." || value == ".." {
        return Err(Issue::refused("unsafe_artifact_name"));
    }
    Ok(value)
}
pub fn sources() -> Value {
    json!({"examples/bpmn_quality.rs":sha(include_bytes!("../bpmn_quality.rs")),"examples/quality/mod.rs":sha(include_bytes!("mod.rs")),"examples/quality/bridge.rs":sha(include_bytes!("bridge.rs")),"examples/quality/state.rs":sha(include_bytes!("state.rs")),"examples/quality/metrics.rs":sha(include_bytes!("metrics.rs")),"examples/quality/pipeline.rs":sha(include_bytes!("pipeline.rs")),"src/bpmn_quality/mod.rs":sha(include_bytes!("../../src/bpmn_quality/mod.rs")),"src/bpmn_quality/bridge.rs":sha(include_bytes!("../../src/bpmn_quality/bridge.rs")),"src/bpmn_quality/state.rs":sha(include_bytes!("../../src/bpmn_quality/state.rs")),"src/bpmn_quality/metrics.rs":sha(include_bytes!("../../src/bpmn_quality/metrics.rs")),"Cargo.lock":sha(include_bytes!("../../Cargo.lock"))})
}
fn save_net(output: &Path, id: &str, net: PetriNet, mapping: Value) -> Result<Value> {
    let encoded = serde_json::to_vec_pretty(&net).map_err(|_| Issue::refused("net_encoding"))?;
    let hash = sha(&encoded);
    let name = format!("{id}.net.json");
    write(&output.join("nets").join(&name), &encoded)?;
    let map_bytes = bytes(&mapping)?;
    let map_file = format!("{id}.map.json");
    write(&output.join("maps").join(&map_file), &map_bytes)?;
    let graph = match state::admit(&net, &hash, Limits::default()) {
        Ok(value) => json!({"status":"admitted","graph":value}),
        Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
    };
    let graph_bytes = bytes(&graph)?;
    let graph_file = format!("{id}.graph.json");
    write(&output.join("graphs").join(&graph_file), &graph_bytes)?;
    Ok(
        json!({"status":"net_saved","net_file":name,"net_sha256":hash,"net_bytes":encoded.len(),"map_file":map_file,"map_sha256":sha(&map_bytes),"graph_file":graph_file,"graph_sha256":sha(&graph_bytes),"admission_status":graph["status"],"admission_reason":graph.get("reason")}),
    )
}
pub fn prepare(corpus_path: &Path, output: &Path) -> Result<()> {
    let corpus_bytes = read(corpus_path)?;
    if sha(&corpus_bytes) != sha(CORPUS.as_bytes()) {
        return Err(Issue::refused("frozen_corpus_hash"));
    }
    let manifest = fixture();
    new_dir(output)?;
    for folder in ["nets", "graphs", "maps", "inputs"] {
        new_dir(&output.join(folder))?;
    }
    write(&output.join("inputs/corpus.json"), &corpus_bytes)?;
    let root = corpus_path
        .parent()
        .ok_or_else(|| Issue::refused("corpus_parent"))?;
    let mut artifacts = BTreeMap::new();
    for model in array(&manifest["models"])? {
        let id = text(&model["id"])?;
        basename(id)?;
        let file = basename(text(&model["file"])?)?;
        let xml = read(&root.join(file))?;
        if sha(&xml) != text(&model["sha256"])?.to_ascii_lowercase()
            || xml.len() as u64 != integer(&model["bytes"])?
        {
            return Err(Issue::refused("frozen_model_hash"));
        }
        write(&output.join("inputs").join(file), &xml)?;
        let record = match bridge::from_xml(&xml) {
            Ok((net, map)) => save_net(output, &format!("bridge-{id}"), net, map)?,
            Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
        };
        artifacts.insert(format!("bridge-{id}"),json!({"kind":"bpmn_bridge","model_id":id,"input_file":file,"input_sha256":sha(&xml),"prepared":record}));
    }
    let manual = manifest["manual_nets"]
        .as_object()
        .ok_or_else(|| Issue::refused("manual_net_catalog"))?;
    for (id, spec) in manual {
        basename(id)?;
        let record = match bridge::manual(spec) {
            Ok(net) => save_net(
                output,
                &format!("manual-{id}"),
                net,
                json!({"kind":"frozen_symbolic_manual_net","symbolic_spec":spec}),
            )?,
            Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
        };
        artifacts.insert(
            format!("manual-{id}"),
            json!({"kind":"manual_reference","manual_id":id,"prepared":record}),
        );
    }
    let bundle = json!({"schema_version":1,"phase":"prepare_only_no_fitness_or_precision","method_sha256":"8e17394b9e1e79ffd0bcda4b2a55d0454feff5b3c017b91ab8e115d11f9f974d","corpus_sha256":sha(&corpus_bytes),"sources":sources(),"artifacts":artifacts,"limits":Limits::default(),"scope":manifest["scope"],"not_acceptance":true});
    write(&output.join("bundle.json"), &bytes(&bundle)?)
}
pub fn expanded_cases(manifest: &Value) -> Result<Vec<Value>> {
    let mut result = Vec::new();
    for parent in array(&manifest["cases"])? {
        let mut main = parent.clone();
        main.as_object_mut()
            .ok_or_else(|| Issue::refused("case_object"))?
            .remove("subcases");
        if main.get("model").is_some() || main.get("manual_net").is_some() {
            result.push(main.clone());
        }
        if let Some(subcases) = parent.get("subcases") {
            for child in array(subcases)? {
                let mut row = main.clone();
                let fields = child
                    .as_object()
                    .ok_or_else(|| Issue::refused("subcase_object"))?;
                for (key, value) in fields {
                    row[key] = value.clone();
                }
                result.push(row);
            }
        }
    }
    Ok(result)
}
fn load_saved(directory: &Path, record: &Value) -> Result<PetriNet> {
    let net_bytes = read(
        &directory
            .join("nets")
            .join(basename(text(&record["net_file"])?)?),
    )?;
    if sha(&net_bytes) != text(&record["net_sha256"])? {
        return Err(Issue::refused("saved_net_hash"));
    }
    let graph_bytes = read(
        &directory
            .join("graphs")
            .join(basename(text(&record["graph_file"])?)?),
    )?;
    if sha(&graph_bytes) != text(&record["graph_sha256"])? {
        return Err(Issue::refused("saved_graph_hash"));
    }
    let map_bytes = read(
        &directory
            .join("maps")
            .join(basename(text(&record["map_file"])?)?),
    )?;
    if sha(&map_bytes) != text(&record["map_sha256"])? {
        return Err(Issue::refused("saved_map_hash"));
    }
    serde_json::from_slice(&net_bytes).map_err(|_| Issue::refused("saved_net_json"))
}
pub fn score(directory: &Path, output: &Path) -> Result<()> {
    let bundle_bytes = read(&directory.join("bundle.json"))?;
    let bundle: Value =
        serde_json::from_slice(&bundle_bytes).map_err(|_| Issue::refused("bundle_json"))?;
    if bundle["phase"] != "prepare_only_no_fitness_or_precision"
        || bundle["corpus_sha256"] != sha(CORPUS.as_bytes())
        || bundle["sources"] != sources()
    {
        return Err(Issue::refused("bundle_source_or_phase_hash"));
    }
    let copied = read(&directory.join("inputs/corpus.json"))?;
    if sha(&copied) != sha(CORPUS.as_bytes()) {
        return Err(Issue::refused("saved_corpus_hash"));
    }
    let manifest = fixture();
    let mut cases = Vec::new();
    for case in expanded_cases(&manifest)? {
        let limits = Limits::lowered(&case["test_only_lower_caps"])?;
        let mut measurements = Vec::new();
        for (kind, key) in [("bridge", "model"), ("manual", "manual_net")] {
            let Some(name) = case.get(key) else {
                continue;
            };
            let artifact_id = format!("{kind}-{}", text(name)?);
            let artifact = &bundle["artifacts"][&artifact_id];
            let record = &artifact["prepared"];
            if record["status"] != "net_saved" {
                measurements.push(json!({"kind":kind,"artifact_id":artifact_id,"result":record}));
                continue;
            }
            let net = load_saved(directory, record)?;
            let hash = text(&record["net_sha256"])?;
            let graph = match state::admit(&net, hash, limits) {
                Ok(graph) => graph,
                Err(issue) => {
                    measurements.push(json!({"kind":kind,"artifact_id":artifact_id,"net_sha256":hash,"result":issue}));
                    continue;
                }
            };
            let mut groups = Vec::new();
            for group in ["training_log", "heldout_log"] {
                let rows = case
                    .get(group)
                    .ok_or_else(|| Issue::refused("case_log_missing"))?;
                let metric = match metrics::score(&net, &graph, rows, limits) {
                    Ok(value) => value,
                    Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
                };
                groups.push(json!({"group":group,"input":rows,"metrics":metric}));
            }
            measurements.push(json!({"kind":kind,"artifact_id":artifact_id,"net_sha256":hash,"result":{"status":"admitted","graph":graph,"groups":groups}}));
        }
        cases.push(json!({"id":case["id"],"frozen_input_and_hypothesis":case,"limits":limits,"measurements":measurements}));
    }
    let result = json!({"schema_version":1,"phase":"score_saved_only_no_conversion_or_mining","bundle_sha256":sha(&bundle_bytes),"corpus_sha256":sha(CORPUS.as_bytes()),"sources":sources(),"cases":cases,"not_acceptance":true,"scope":manifest["scope"]});
    write(output, &bytes(&result)?)
}
