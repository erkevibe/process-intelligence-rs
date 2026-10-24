//! Bounded native structured-variants experiment; training data only.
#[path = "structured/miner.rs"]
mod structured;
use process_intelligence_rs::{
    bpmn::{self, ProcessModel},
    bpmn_quality::{self as quality, Issue, facade, state},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
    time::Instant,
};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Weighted {
    trace: Vec<String>,
    count: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn variants(traces: &[&[&str]]) -> structured::Variants {
        let mut rows = structured::Variants::new();
        for trace in traces {
            *rows
                .entry(trace.iter().map(|s| s.to_string()).collect())
                .or_default() += 1;
        }
        rows
    }
    fn report(model: &ProcessModel, traces: &[&[&str]]) -> Value {
        let data = Value::Array(
            traces
                .iter()
                .map(|trace| json!({"sequence":trace,"frequency":1}))
                .collect(),
        );
        let value = evaluate(model, &data);
        assert_eq!(value["status"], "evaluated");
        value["report"].clone()
    }
    #[test]
    fn empty_case_and_optional_activity_are_distinct_from_no_training_cases() {
        let tau = structured::discover(&variants(&[&[]])).unwrap();
        assert_eq!(tau.tree, structured::Tree::Tau);
        let optional = structured::discover(&variants(&[&[], &["A"]])).unwrap();
        let scored = report(&optional.model, &[&[], &["A"]]);
        assert_eq!(scored["metrics"]["fitness"]["fitness"]["log_fitness"], 1.0);
        let xml = bpmn::serialize(&tau.model).unwrap();
        let imported = bpmn::parse(xml.as_bytes()).unwrap();
        assert_eq!(
            report(&tau.model, &[&[]])["metrics"],
            report(&imported, &[&[]])["metrics"]
        );
        assert!(structured::discover(&structured::Variants::new()).is_err());
    }
    #[test]
    fn unseen_parallel_permutations_fit_but_missing_mandatory_task_does_not() {
        let training = variants(&[
            &["A", "B", "C", "E", "D"],
            &["A", "C", "E", "B", "D"],
            &["A", "E", "B", "C", "D"],
        ]);
        let discovered = structured::discover(&training).unwrap();
        assert_eq!(discovered.exact_variant_fallbacks, 0);
        let score = report(
            &discovered.model,
            &[
                &["A", "B", "E", "C", "D"],
                &["A", "C", "B", "E", "D"],
                &["A", "E", "C", "B", "D"],
            ],
        );
        assert_eq!(score["metrics"]["fitness"]["fitness"]["log_fitness"], 1.0);
        let missing = report(&discovered.model, &[&["A", "B", "D"]]);
        assert!(
            missing["metrics"]["fitness"]["fitness"]["log_fitness"]
                .as_f64()
                .unwrap()
                < 1.0
        );
    }
    #[test]
    fn unseen_cycle_repetitions_survive_xml_roundtrip_and_unknown_label_is_nonfitting() {
        let training = variants(&[
            &["A", "B", "C", "D"],
            &["A", "B", "C", "B", "C", "D"],
            &["A", "E", "D"],
        ]);
        let discovered = structured::discover(&training).unwrap();
        let control: &[&[&str]] = &[&["A", "B", "C", "B", "C", "B", "C", "D"], &["A", "E", "D"]];
        let score = report(&discovered.model, control);
        assert_eq!(score["metrics"]["fitness"]["fitness"]["log_fitness"], 1.0);
        let xml = bpmn::serialize(&discovered.model).unwrap();
        let imported = bpmn::parse(xml.as_bytes()).unwrap();
        assert_eq!(score["metrics"], report(&imported, control)["metrics"]);
        let unknown = report(&discovered.model, &[&["A", "Q", "D"]]);
        assert_eq!(
            unknown["metrics"]["precision"]["status"],
            "requires_fitting_log"
        );
        assert!(unknown["metrics"]["precision"]["scalar"].is_null());
    }
    #[test]
    fn deterministic_input_order_and_early_resource_bounds() {
        let one = variants(&[&["A", "B", "D"], &["A", "C", "D"]]);
        let two = variants(&[&["A", "C", "D"], &["A", "B", "D"]]);
        assert_eq!(
            structured::discover(&one).unwrap().model,
            structured::discover(&two).unwrap().model
        );
        let seven = variants(&[&["A", "B", "C", "D", "E", "F", "G"]]);
        assert_eq!(
            structured::discover(&seven).unwrap_err(),
            "structured_input_bounds"
        );
        let mut over = one;
        over.insert(vec!["A".into()], 65);
        assert_eq!(
            structured::discover(&over).unwrap_err(),
            "structured_input_bounds"
        );
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    id: String,
    train: Vec<Weighted>,
    held_out: Vec<Weighted>,
    #[serde(default)]
    diagnostic_only: Vec<Weighted>,
}
fn read(path: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut raw = Vec::new();
    fs::File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut raw)?;
    if raw.len() > 1024 * 1024 {
        return Err("input exceeds 1MiB".into());
    }
    Ok(raw)
}
fn rows(values: &[Weighted]) -> Value {
    Value::Array(
        values
            .iter()
            .map(|r| json!({"sequence":r.trace,"frequency":r.count}))
            .collect(),
    )
}
struct Output<'a> {
    path: &'a Path,
    used: usize,
    count: usize,
}
impl Output<'_> {
    fn raw(&mut self, name: &str, raw: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
        self.used += raw.len();
        self.count += 1;
        if raw.len() > 8 * 1024 * 1024 || self.used > 16 * 1024 * 1024 || self.count > 16 {
            return Err("output budget".into());
        }
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.path.join(name))?
            .write_all(raw)?;
        Ok(())
    }
    fn json(
        &mut self,
        name: &str,
        value: &impl serde::Serialize,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.raw(name, &serde_json::to_vec(value)?)
    }
}
fn evaluate(model: &ProcessModel, rows: &Value) -> Value {
    let started = Instant::now();
    match facade::evaluate_model(model, rows, &Value::Null, &mut |_| {
        if started.elapsed().as_secs() >= 30 {
            Err(Issue::cap("experiment_deadline"))
        } else {
            Ok(())
        }
    }) {
        Ok(v) => json!({"status":"evaluated","report":v}),
        Err(e) => json!({"status":"not_evaluated","issue":e}),
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("miner_structured CASE_JSON NEW_EMPTY_DIR".into());
    }
    let input_raw = read(&args[1])?;
    let input: Input = serde_json::from_slice(&input_raw)?;
    let train = rows(&input.train);
    let held = rows(&input.held_out);
    let diagnostic = rows(&input.diagnostic_only);
    for rows in [&train, &held, &diagnostic] {
        facade::validate_rows(rows)?;
    }
    let path = Path::new(&args[2]);
    if !path.is_dir() || fs::read_dir(path)?.next().is_some() {
        return Err("new empty output required".into());
    }
    let mut out = Output {
        path,
        used: 0,
        count: 0,
    };
    out.json("train.json", &train)?;
    out.json("held-out.json", &held)?;
    out.json("diagnostic-only.json", &diagnostic)?;
    if input.train.is_empty() {
        out.json("result.json", &json!({"schema_version":1,"case":input.id,"algorithm":"structured_variants_v1","input_sha256":quality::sha(&input_raw),"held_out_supplied_to_miner":false,"status":"no_data"}))?;
        return Ok(());
    }
    let mut variants = structured::Variants::new();
    for row in &input.train {
        *variants.entry(row.trace.clone()).or_default() += row.count;
    }
    let started = Instant::now();
    let discovered = match structured::discover(&variants) {
        Ok(value) => value,
        Err(reason) => {
            out.json("result.json", &json!({"schema_version":1,"case":input.id,"algorithm":"structured_variants_v1","input_sha256":quality::sha(&input_raw),"held_out_supplied_to_miner":false,"status":"not_modelled","issue":{"reason":reason}}))?;
            return Ok(());
        }
    };
    let discovery_ns = started.elapsed().as_nanos();
    out.json("tree.json", &discovered.tree)?;
    let fallback_count = discovered.exact_variant_fallbacks;
    let model = discovered.model;
    out.json("model.json", &model)?;
    let xml = bpmn::serialize(&model)?;
    out.raw("model.bpmn", xml.as_bytes())?;
    let imported = bpmn::parse(xml.as_bytes())?;
    out.json("reimported-model.json", &imported)?;
    let mut result = json!({"schema_version":1,"case":input.id,"algorithm":"structured_variants_v1","input_sha256":quality::sha(&input_raw),"discovery_nanos":discovery_ns,"exact_variant_fallbacks":fallback_count,"model_sha256":quality::sha(&serde_json::to_vec(&model)?),"application_profile":1000,"held_out_supplied_to_miner":false});
    match quality::bridge::from_model(&model) {
        Err(e) => {
            result["status"] = json!("not_admitted");
            result["issue"] = serde_json::to_value(e)?;
        }
        Ok((net, _)) => {
            let raw = serde_json::to_vec(&serde_json::to_value(&net)?)?;
            out.raw("bpmn-net.json", &raw)?;
            match state::admit(
                &net,
                &quality::sha(&raw),
                facade::application_limits(&Value::Null)?,
            ) {
                Err(e) => {
                    result["status"] = json!("not_admitted");
                    result["issue"] = serde_json::to_value(e)?;
                }
                Ok(graph) => {
                    out.json("bpmn-graph.json", &graph)?;
                    result["reachable_states"] = json!(graph.states.len());
                    let training = evaluate(&model, &train);
                    let control = evaluate(&model, &held);
                    let reimported = evaluate(&imported, &held);
                    result["export_reimport_status_identical"] = json!(
                        control["status"] == reimported["status"]
                            && control["issue"] == reimported["issue"]
                    );
                    result["export_reimport_metrics_identical"] = if control["status"]
                        == "evaluated"
                        && reimported["status"] == "evaluated"
                    {
                        json!(control["report"]["metrics"] == reimported["report"]["metrics"])
                    } else {
                        Value::Null
                    };
                    result["training"] = training;
                    result["held_out"] = control;
                    result["reimported_held_out"] = reimported;
                    if !input.diagnostic_only.is_empty() {
                        result["diagnostic_only"] = evaluate(&model, &diagnostic);
                    }
                    result["status"] = json!("modelled");
                }
            }
        }
    }
    out.json("result.json", &result)?;
    println!(
        "{}",
        json!({"status":result["status"],"case":result["case"]})
    );
    Ok(())
}
