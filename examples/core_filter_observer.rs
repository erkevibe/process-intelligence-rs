//! Bounded observer of the production filter on an agreed, trusted frozen corpus.
//! This does not implement a predicate or expose a new application import API.
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
    rule_literals: Vec<String>,
    source: EventLog,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--trusted-corpus")) {
        return Err("usage: core_filter_observer --trusted-corpus FIXTURE".into());
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
        || input.id.len() > 80
        || input.rule_literals.len() > 8
        || input
            .rule_literals
            .iter()
            .any(|literal| literal.len() > 4096)
        || input.source.cases.len() > 100
        || input
            .source
            .cases
            .iter()
            .map(|case| case.events.len())
            .sum::<usize>()
            > 1000
    {
        return Err("trusted fixture shape/cap".into());
    }
    let identities: HashSet<_> = input
        .source
        .cases
        .iter()
        .map(|case| case.id.as_str())
        .collect();
    if identities.len() != input.source.cases.len() {
        return Err("unique source identities required".into());
    }
    let before = serde_json::to_vec(&input.source)?;
    let mut result = input.source.clone();
    for literal in &input.rule_literals {
        result = filters::apply(
            &result,
            &FilterSpec {
                case_activity: Some(literal.clone()),
                ..FilterSpec::default()
            },
        )?;
    }
    let after = serde_json::to_vec(&input.source)?;
    let selected_source_indices: Vec<_> = result
        .cases
        .iter()
        .map(|case| {
            input
                .source
                .cases
                .iter()
                .position(|original| original.id == case.id)
                .ok_or("returned foreign identity")
        })
        .collect::<Result<_, _>>()?;
    println!(
        "{}",
        json!({
            "schema_version":1, "status":"ACTUAL_RUST_CASE_ACTIVITY_FILTER_OBSERVED", "id":input.id,
            "input_sha256":format!("{:x}", Sha256::digest(&bytes)),
            "rule_literals":input.rule_literals, "engine":"process_intelligence_rs::filters::apply",
            "source_before_sha256":format!("{:x}", Sha256::digest(&before)),
            "source_after_sha256":format!("{:x}", Sha256::digest(&after)), "source_unchanged":before == after,
            "source_domain_before":input.source, "selected_source_indices":selected_source_indices,
            "selected_source_log":result,
            "scope":"Actual production filter sequential calls; full EventLog conservation only, not rich XLog metadata or public persistence"
        })
    );
    Ok(())
}
