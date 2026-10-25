use process_intelligence_rs::{bpmn, bpmn_quality, dfg_discovery};
use std::{
    fs,
    path::Path,
    time::{Duration, Instant},
};
fn read(path: &str) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let bytes = fs::read(path)?;
    if bytes.len() > 1024 * 1024 {
        return Err("input byte limit".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        return Err("full_log_holdout TRAIN_JSON CONTROL_JSON NEW_EMPTY_DIR".into());
    }
    let train = read(&args[1])?;
    let out = Path::new(&args[3]);
    if !out.is_dir() || fs::read_dir(out)?.next().is_some() {
        return Err("new empty output required".into());
    }
    let start = Instant::now();
    let until = start + Duration::from_secs(60);
    let mut check = |_: &str| {
        if Instant::now() < until {
            Ok(())
        } else {
            Err(bpmn_quality::Issue::cap("deadline"))
        }
    };
    let model = dfg_discovery::discover(&train, &mut check)?;
    let train_report = dfg_discovery::evaluate(&model, &train, &mut check)?;
    fs::write(out.join("model.bpmn"), bpmn::serialize(&model)?)?;
    // Control input is deliberately read only after construction.
    let control = read(&args[2])?;
    let control_report = dfg_discovery::evaluate(&model, &control, &mut check)?;
    let report = serde_json::json!({"status":"full_log_holdout_evaluated","held_out_supplied_to_miner":false,"training":train_report,"control":control_report,"method_sha256":dfg_discovery::method_sha256()});
    fs::write(
        out.join("holdout-report.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("{}", report);
    Ok(())
}
