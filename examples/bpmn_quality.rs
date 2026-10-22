//! Separate diagnostic prepare and score processes; native execution is supervisor-owned.
mod quality;
use std::path::Path;
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    match args.get(1).and_then(|value| value.to_str()) {
        Some("prepare") if args.len() == 4 => {
            quality::pipeline::prepare(Path::new(&args[2]), Path::new(&args[3]))?
        }
        Some("score") if args.len() == 4 => {
            quality::pipeline::score(Path::new(&args[2]), Path::new(&args[3]))?
        }
        _ => return Err(
            "usage: bpmn_quality prepare FROZEN_CORPUS NEW_DIR | score SAVED_DIR NEW_RESULT_JSON"
                .into(),
        ),
    }
    Ok(())
}
