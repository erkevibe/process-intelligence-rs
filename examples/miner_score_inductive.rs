//! Score a separately projected real miner model; no discovery or source rewrite.
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
    if args.len() != 4 {
        return Err("miner_score_inductive CASE_JSON PROJECTED_MODEL_JSON NEW_EMPTY_DIR".into());
    }
    let input_raw = read(&args[1])?;
    let model_raw = read(&args[2])?;
    let input: Input = serde_json::from_slice(&input_raw)?;
    let model: ProcessModel = serde_json::from_slice(&model_raw)?;
    bpmn::validate(&model)?;
    let train = rows(&input.train);
    let held = rows(&input.held_out);
    let diagnostic = rows(&input.diagnostic_only);
    for rows in [&train, &held, &diagnostic] {
        facade::validate_rows(rows)?;
    }
    let path = Path::new(&args[3]);
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
    out.json("model.json", &model)?;
    let xml = bpmn::serialize(&model)?;
    out.raw("model.bpmn", xml.as_bytes())?;
    let imported = bpmn::parse(xml.as_bytes())?;
    out.json("reimported-model.json", &imported)?;
    let mut result = json!({"schema_version":1,"case":input.id,"algorithm":"pm4py-inductive-im","input_sha256":quality::sha(&input_raw),"projected_model_input_sha256":quality::sha(&model_raw),"model_sha256":quality::sha(&serde_json::to_vec(&model)?),"application_profile":1000,"held_out_supplied_to_miner":false});
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
