//! Validated application entry point. No filesystem or caller-supplied graph.
use super::{Issue, Limits, Result, bridge, metrics, sha, state};
use crate::bpmn::{self, ProcessModel};
use serde::Serialize;
use serde_json::{Value, json};
use std::io::{self, Write};

pub const MAX_REPORT_BYTES: usize = 64 * 1024;
const MAX_MODEL_BYTES: usize = 1024 * 1024;

struct BoundedBytes {
    bytes: Vec<u8>,
    limit: usize,
}
impl Write for BoundedBytes {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            return Err(io::Error::other("quality_serialized_size_limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
fn bounded(value: &impl Serialize, limit: usize, reason: &str) -> Result<Vec<u8>> {
    let mut writer = BoundedBytes {
        bytes: Vec::new(),
        limit,
    };
    serde_json::to_writer(&mut writer, value).map_err(|_| Issue::refused(reason))?;
    Ok(writer.bytes)
}

/// Validate borrowed rows before the diagnostic variant adapter allocates labels.
pub fn validate_rows(rows: &Value) -> Result<()> {
    let rows = rows
        .as_array()
        .ok_or_else(|| Issue::refused("expected_array"))?;
    if rows.len() > 64 {
        return Err(Issue::refused("evaluation_log_limit"));
    }
    let (mut traces, mut events) = (0u64, 0u64);
    let mut unique = std::collections::BTreeSet::new();
    for row in rows {
        let object = row
            .as_object()
            .ok_or_else(|| Issue::refused("expected_variant"))?;
        if object.len() != 2
            || !object.contains_key("sequence")
            || !object.contains_key("frequency")
        {
            return Err(Issue::refused("variant_fields"));
        }
        let sequence = row["sequence"]
            .as_array()
            .ok_or_else(|| Issue::refused("expected_array"))?;
        let frequency = row["frequency"]
            .as_u64()
            .ok_or_else(|| Issue::refused("expected_integer"))?;
        if !(1..=64).contains(&frequency) || sequence.len() > 64 {
            return Err(Issue::refused("evaluation_variant_limit"));
        }
        let mut labels = Vec::with_capacity(sequence.len());
        for label in sequence {
            let label = label
                .as_str()
                .ok_or_else(|| Issue::refused("expected_string"))?;
            if label.is_empty() || label.len() > 200 {
                return Err(Issue::refused("evaluation_variant_limit"));
            }
            labels.push(label);
        }
        traces += frequency;
        events += frequency * sequence.len() as u64;
        unique.insert(labels);
        if traces > 64 || events > 500 || unique.len() > 32 {
            return Err(Issue::refused("evaluation_log_limit"));
        }
    }
    Ok(())
}

/// Application profile is deliberately smaller than the historical diagnostic profile.
/// Nonmeasurement on this profile is not evidence of an invalid BPMN model.
pub fn application_limits(lowered: &Value) -> Result<Limits> {
    if !lowered.is_null() && !lowered.is_object() {
        return Err(Issue::refused("expected_caps_object"));
    }
    if lowered.as_object().is_some_and(|map| {
        map.values()
            .any(|value| value.as_u64().is_some_and(|count| count > 1000))
    }) {
        return Err(Issue::refused("cap_not_lowering"));
    }
    let mut limits = Limits::lowered(lowered)?;
    limits.markings = limits.markings.min(1000);
    limits.fitness = limits.fitness.min(1000);
    limits.prefix = limits.prefix.min(1000);
    limits.tau = limits.tau.min(1000);
    limits.equivalence = limits.equivalence.min(1000);
    Ok(limits)
}

pub fn evaluate_xml(xml: &[u8], rows: &Value, lowered: &Value) -> Result<Value> {
    if xml.len() > MAX_MODEL_BYTES {
        return Err(Issue::refused("evaluation_model_limit"));
    }
    let model = bpmn::parse(xml).map_err(|error| Issue::refused(&error.code))?;
    evaluate_model(&model, rows, lowered, &mut |_| Ok(()))
}

/// Cooperative checkpoints run between bounded phases and each precision prefix.
/// A single upstream alignment is bounded by states, not asynchronously interruptible.
pub fn evaluate_model(
    model: &ProcessModel,
    rows: &Value,
    lowered: &Value,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    evaluate_model_inner(model, rows, lowered, checkpoint).map_err(|mut issue| {
        // Low-level admission errors can contain a large partial marking graph.
        // Application errors retain the classification, never diagnostic witnesses.
        issue.details = Value::Null;
        if bounded(&issue, MAX_REPORT_BYTES, "quality_error_limit").is_err() {
            Issue::refused("quality_error_limit")
        } else {
            issue
        }
    })
}

fn evaluate_model_inner(
    model: &ProcessModel,
    rows: &Value,
    lowered: &Value,
    checkpoint: &mut impl FnMut(&str) -> Result<()>,
) -> Result<Value> {
    checkpoint("validate")?;
    if model.nodes.len() > 128 || model.flows.len() > 256 {
        return Err(Issue::refused("evaluation_model_limit"));
    }
    let model_bytes = bounded(model, MAX_MODEL_BYTES, "evaluation_model_limit")?;
    validate_rows(rows)?;
    let limits = application_limits(lowered)?;
    let variants = metrics::variants(rows)?;
    let canonical_variants: Vec<_> = variants
        .iter()
        .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
        .collect();
    let input_bytes = bounded(&canonical_variants, MAX_MODEL_BYTES, "evaluation_log_limit")?;
    checkpoint("bridge")?;
    let (net, _) = bridge::from_model(model)?;
    // serde_json's default object map is ordered; serialize that value rather than a HashMap.
    let net_value = serde_json::to_value(&net).map_err(|_| Issue::refused("net_serialization"))?;
    let net_bytes = bounded(&net_value, MAX_MODEL_BYTES, "evaluation_model_limit")?;
    let net_sha = sha(&net_bytes);
    checkpoint("markings")?;
    let graph = state::admit(&net, &net_sha, limits)?;
    checkpoint("fitness")?;
    let fitness = metrics::fitness(&net, &variants, limits);
    checkpoint("precision")?;
    let mut interrupted = false;
    let mut checked = |stage: &str| {
        let result = checkpoint(stage);
        interrupted |= result.is_err();
        result
    };
    let precision_result =
        metrics::precision_compact(&graph, &variants, &fitness, limits, &mut checked);
    let precision = match precision_result {
        Ok(mut value) => {
            value
                .as_object_mut()
                .expect("metric_object")
                .remove("prefixes");
            value
        }
        Err(issue) if interrupted => return Err(issue),
        Err(issue) => serde_json::to_value(issue).expect("serializable_issue"),
    };
    let mut compact_fitness = json!({"status":fitness["status"]});
    for key in ["reason", "fitness", "integer_components", "costs", "scalar"] {
        if let Some(value) = fitness.get(key) {
            compact_fitness[key] = value.clone();
        }
    }
    let report = json!({
        "schema_version":1,"profile":"application_bounded_v1",
        "model_identity_kind":"canonical_model_json_sha256",
        "model_sha256":sha(&model_bytes),"net_sha256":net_sha,
        "variants_sha256":sha(&input_bytes),"limits":limits,
        "trace_count":variants.values().sum::<u64>(),"variant_count":variants.len(),
        "metrics":{"fitness":compact_fitness,"precision":precision,"simplicity":metrics::simplicity(&net)},
        "evaluation_policy":"log_evaluation_does_not_establish_training_independence"
    });
    bounded(&report, MAX_REPORT_BYTES, "quality_report_limit")?;
    checkpoint("complete")?;
    Ok(report)
}
