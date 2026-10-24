//! Shared bounded BPMN quality computations; file/corpus pipelines remain diagnostic adapters.
pub mod bridge;
pub mod facade;
pub mod metrics;
pub mod state;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
pub type Result<T> = std::result::Result<T, Issue>;

#[derive(Debug, Clone, Serialize)]
pub struct Issue {
    pub status: String,
    pub reason: String,
    pub details: Value,
}
impl Issue {
    pub fn refused(reason: &str) -> Self {
        Self {
            status: "refused".into(),
            reason: reason.into(),
            details: Value::Null,
        }
    }
    pub fn cap(reason: &str) -> Self {
        Self {
            status: "inconclusive".into(),
            reason: reason.into(),
            details: Value::Null,
        }
    }
    pub fn unsupported(reason: &str) -> Self {
        Self {
            status: "quality_unsupported_semantics".into(),
            reason: reason.into(),
            details: Value::Null,
        }
    }
    pub fn with(mut self, details: Value) -> Self {
        self.details = details;
        self
    }
}
impl std::fmt::Display for Issue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{}", self.status, self.reason)
    }
}
impl std::error::Error for Issue {}
pub fn array(value: &Value) -> Result<&Vec<Value>> {
    value
        .as_array()
        .ok_or_else(|| Issue::refused("expected_array"))
}
pub fn text(value: &Value) -> Result<&str> {
    value
        .as_str()
        .ok_or_else(|| Issue::refused("expected_string"))
}
pub fn integer(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .ok_or_else(|| Issue::refused("expected_integer"))
}
pub fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn status(reason: &str) -> Value {
    json!({"status":reason,"scalar":null})
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Limits {
    pub nodes: usize,
    pub arcs: usize,
    pub markings: usize,
    pub fitness: usize,
    pub prefix: usize,
    pub tau: usize,
    pub equivalence: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            nodes: 128,
            arcs: 256,
            markings: 10000,
            fitness: 100000,
            prefix: 100000,
            tau: 10000,
            equivalence: 10000,
        }
    }
}
impl Limits {
    pub fn lowered(value: &Value) -> Result<Self> {
        let mut limits = Self::default();
        if let Some(map) = value.as_object() {
            for (name, raw) in map {
                let count =
                    usize::try_from(integer(raw)?).map_err(|_| Issue::refused("cap_integer"))?;
                let target = match name.as_str() {
                    "reachable_markings" => &mut limits.markings,
                    "fitness_search_states" => &mut limits.fitness,
                    "prefix_search_states" => &mut limits.prefix,
                    "tau_closure_markings" => &mut limits.tau,
                    "equivalence_subset_pairs" => &mut limits.equivalence,
                    _ => return Err(Issue::refused("unknown_cap")),
                };
                if count == 0 || count > *target {
                    return Err(Issue::refused("cap_not_lowering"));
                }
                *target = count;
            }
        }
        Ok(limits)
    }
}
