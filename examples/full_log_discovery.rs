use process_intelligence_rs::{bpmn, dfg_discovery};
use std::{
    fs,
    path::Path,
    time::{Duration, Instant},
};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("full_log_discovery VARIANTS_JSON NEW_EMPTY_DIR".into());
    }
    let input = fs::read(&args[1])?;
    if input.len() > 1024 * 1024 {
        return Err("input byte limit".into());
    }
    let rows = serde_json::from_slice(&input)?;
    let output = Path::new(&args[2]);
    if !output.is_dir() || fs::read_dir(output)?.next().is_some() {
        return Err("new empty output directory required".into());
    }
    let start = Instant::now();
    let until = start + Duration::from_secs(60);
    let mut checkpoint = |_: &str| {
        if Instant::now() >= until {
            Err(process_intelligence_rs::bpmn_quality::Issue::cap(
                "deadline",
            ))
        } else {
            Ok(())
        }
    };
    let model = dfg_discovery::discover(&rows, &mut checkpoint)?;
    fs::write(
        output.join("model.json"),
        serde_json::to_vec_pretty(&model)?,
    )?;
    let xml = bpmn::serialize(&model)?;
    fs::write(output.join("model.bpmn"), &xml)?;
    let imported = bpmn::parse(xml.as_bytes())?;
    let report = dfg_discovery::evaluate(&model, &rows, &mut checkpoint)?;
    let roundtrip = dfg_discovery::evaluate(&imported, &rows, &mut checkpoint)?;
    assert_eq!(report["metrics"], roundtrip["metrics"]);
    fs::write(
        output.join("report.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!(
        "{}",
        serde_json::json!({"status":"full_log_evaluated","nodes":model.nodes.len(),"flows":model.flows.len(),"seconds":start.elapsed().as_secs_f64(),"report":report})
    );
    Ok(())
}
