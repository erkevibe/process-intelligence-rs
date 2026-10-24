//! Additive historical-miner diagnostic. Native execution is supervisor-owned.
#[path = "quality/cohort.rs"]
mod cohort;
#[allow(dead_code)]
mod quality;
use std::path::Path;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    match args.get(1).and_then(|value| value.to_str()) {
        Some("prepare") if args.len() == 5 => cohort::prepare(Path::new(&args[2]), Path::new(&args[3]), Path::new(&args[4]))?,
        Some("score") if args.len() == 4 => cohort::score(Path::new(&args[2]), Path::new(&args[3]))?,
        _ => return Err("usage: bpmn_quality_cohort prepare FROZEN_COHORT PROJECTION_DIR NEW_DIR | score SAVED_DIR NEW_JSON".into()),
    }
    Ok(())
}
