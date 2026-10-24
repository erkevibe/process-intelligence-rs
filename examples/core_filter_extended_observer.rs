//! Observe the real production filter; do not implement selection predicates.
use process_intelligence_rs::{
    domain::EventLog,
    filters::{self, FilterSpec},
};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fs::File, io::Read, path::PathBuf};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    schema_version: u8,
    id: String,
    filter_spec: FilterSpec,
    source: EventLog,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--trusted-corpus")) {
        return Err("usage: core_filter_extended_observer --trusted-corpus FIXTURE".into());
    }
    let path = PathBuf::from(args.next().ok_or("fixture required")?);
    if args.next().is_some() {
        return Err("unexpected argument".into());
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err("fixture byte cap".into());
    }
    let input: Input = serde_json::from_slice(&bytes)?;
    if input.schema_version != 1
        || input.id.is_empty()
        || input.id.len() > 80
        || input.source.cases.len() > 100
        || input
            .source
            .cases
            .iter()
            .map(|case| case.events.len())
            .sum::<usize>()
            > 1000
        || input.filter_spec.retain_activities.len() > 100
        || input.filter_spec.remove_activities.len() > 100
    {
        return Err("trusted fixture shape/cap".into());
    }
    let ids: HashSet<_> = input.source.cases.iter().map(|case| &case.id).collect();
    if ids.len() != input.source.cases.len()
        || input.source.cases.iter().any(|case| {
            case.events
                .iter()
                .map(|event| event.ordinal)
                .collect::<HashSet<_>>()
                .len()
                != case.events.len()
        })
    {
        return Err("unique case identities and per-case event ordinals required".into());
    }
    let before = serde_json::to_vec(&input.source)?;
    let spec_before = serde_json::to_vec(&input.filter_spec)?;
    let result = filters::apply(&input.source, &input.filter_spec);
    let after = serde_json::to_vec(&input.source)?;
    let spec_after = serde_json::to_vec(&input.filter_spec)?;
    let (outcome, selected, indices, positions, error) = match result {
        Ok(selected) => {
            let mut indices = Vec::new();
            let mut positions = Vec::new();
            for case in &selected.cases {
                let index = input
                    .source
                    .cases
                    .iter()
                    .position(|original| original.id == case.id)
                    .ok_or("returned foreign case identity")?;
                let original = &input.source.cases[index];
                let event_positions = case
                    .events
                    .iter()
                    .map(|event| {
                        original
                            .events
                            .iter()
                            .position(|candidate| candidate == event)
                            .ok_or("returned event not identical to a source event")
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                indices.push(index);
                positions.push(event_positions);
            }
            (
                "filtered",
                Some(selected),
                Some(indices),
                Some(positions),
                None,
            )
        }
        Err(error) => ("refused", None, None, None, Some(error)),
    };
    println!(
        "{}",
        json!({
            "schema_version": 1, "id": input.id,
            "status": "ACTUAL_RUST_EXTENDED_FILTER_OBSERVED",
            "engine": "process_intelligence_rs::filters::apply", "engine_call_count": 1,
            "input_sha256": format!("{:x}", Sha256::digest(&bytes)),
            "outcome": outcome, "error": error, "filter_spec": input.filter_spec,
            "filter_spec_unchanged": spec_before == spec_after,
            "source_domain_before": input.source, "source_domain_after": input.source,
            "source_before_sha256": format!("{:x}", Sha256::digest(&before)),
            "source_after_sha256": format!("{:x}", Sha256::digest(&after)),
            "source_unchanged": before == after,
            "selected_source_indices": indices, "selected_event_positions": positions,
            "selected_source_log": selected,
            "scope": "Actual production filter once; source positions derived only from returned exact identities, no selection predicate or legacy export"
        })
    );
    Ok(())
}
