//! Bounded developer-only adapter to the real locked Rust4PM Alpha+++ miner.
//! No SplitMiner, BPMN conversion or general conformance claim.
use crate::domain::{EventLog, ImportError};
use process_mining::core::{
    PetriNet, event_data::case_centric::utils::activity_projection::EventLogActivityProjection,
    process_models::case_centric::petri_net::pnml::export_petri_net_to_pnml,
};
use process_mining::discovery::case_centric::alphappp::full::{
    AlphaPPPConfig, alphappp_discover_petri_net,
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

pub const MAX_ACTIVITIES: usize = 6;
pub const MAX_EVENTS: usize = 500;
pub const MAX_CASES: usize = 64;
pub const MAX_VARIANTS: usize = 32;

#[derive(Debug, Serialize)]
pub struct Discovery {
    pub algorithm: &'static str,
    pub library: &'static str,
    pub config: AlphaPPPConfig,
    pub cases: usize,
    pub events: usize,
    pub activities: Vec<String>,
    pub variants: Vec<(Vec<String>, u64)>,
    pub net: PetriNet,
    pub pnml: String,
}

fn refused(code: &'static str) -> ImportError {
    ImportError::new(code, "Alpha+++ developer contract rejected the input.")
}

pub fn pinned_config() -> AlphaPPPConfig {
    AlphaPPPConfig {
        balance_thresh: 1.0,
        fitness_thresh: 0.0,
        replay_thresh: 0.0,
        log_repair_skip_df_thresh_rel: 10_000.0,
        log_repair_loop_df_thresh_rel: 10_000.0,
        absolute_df_clean_thresh: 1,
        relative_df_clean_thresh: 0.0,
    }
}

pub fn discover(log: &EventLog, cancelled: &dyn Fn() -> bool) -> Result<Discovery, ImportError> {
    if cancelled() {
        return Err(refused("cancelled"));
    }
    if log.cases.is_empty() || log.cases.len() > MAX_CASES {
        return Err(refused("discovery_limit"));
    }
    let mut activities = BTreeSet::new();
    let mut variants: BTreeMap<Vec<String>, u64> = BTreeMap::new();
    let mut events = 0usize;
    for case in &log.cases {
        if cancelled() {
            return Err(refused("cancelled"));
        }
        if case.events.is_empty() {
            return Err(refused("discovery_empty"));
        }
        events = events
            .checked_add(case.events.len())
            .filter(|n| *n <= MAX_EVENTS)
            .ok_or_else(|| refused("discovery_limit"))?;
        let mut sequence = Vec::with_capacity(case.events.len());
        for event in &case.events {
            let label = &event.activity;
            if label.trim().is_empty()
                || label.len() > 200
                || label.chars().any(|c| !matches!(c as u32, 0x9 | 0xA | 0xD | 0x20..=0xD7FF | 0xE000..=0xFFFD | 0x10000..=0x10FFFF))
                || label == "__START"
                || label == "__END"
                || label.starts_with("__SILENT__")
            {
                return Err(refused("discovery_activity"));
            }
            activities.insert(label.clone());
            if activities.len() > MAX_ACTIVITIES {
                return Err(refused("discovery_limit"));
            }
            sequence.push(label.clone());
        }
        *variants.entry(sequence).or_default() += 1;
        if variants.len() > MAX_VARIANTS {
            return Err(refused("discovery_limit"));
        }
    }
    let activities: Vec<_> = activities.into_iter().collect();
    let indices = activities
        .iter()
        .enumerate()
        .map(|(i, label)| (label.clone(), i))
        .collect();
    let variants: Vec<_> = variants.into_iter().collect();
    let projection = EventLogActivityProjection {
        activities: activities.clone(),
        act_to_index: indices,
        traces: variants
            .iter()
            .map(|(sequence, count)| {
                (
                    sequence
                        .iter()
                        .map(|label| activities.binary_search(label).expect("known activity"))
                        .collect(),
                    *count,
                )
            })
            .collect(),
    };
    if cancelled() {
        return Err(refused("cancelled"));
    }
    // Upstream is synchronous and cannot be interrupted during this call.
    let config = pinned_config();
    let net = std::panic::catch_unwind(|| alphappp_discover_petri_net(&projection, config))
        .map_err(|_| refused("discovery_upstream"))?;
    if cancelled() {
        return Err(refused("cancelled"));
    }
    let mut bytes = Vec::new();
    export_petri_net_to_pnml(&net, &mut bytes).map_err(|_| refused("discovery_export"))?;
    let pnml = String::from_utf8(bytes).map_err(|_| refused("discovery_export"))?;
    Ok(Discovery {
        algorithm: "alpha+++",
        library: "process_mining@0.6.2",
        config,
        cases: log.cases.len(),
        events,
        activities,
        variants,
        net,
        pnml,
    })
}
