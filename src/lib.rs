pub mod audit;
pub mod auth;
pub mod bpmn;
pub mod bpmn_quality;
mod bpmn_quality_preview;
pub mod calendar;
pub mod cleanup;
pub mod configuration;
#[allow(
    clippy::chunks_exact_to_as_chunks,
    reason = "Keep the reviewed byte decoder and its source provenance stable"
)]
pub mod conversion;
mod conversion_workflow;
pub mod csv_io;
pub mod csv_performance;
pub mod dfg_discovery;
pub mod discovery;
mod discovery_store;
mod discovery_workflow;
pub mod domain;
pub mod event_io;
pub mod filters;
pub mod folders;
mod full_log_bridge;
pub mod full_log_saved;
pub mod import_provenance;
pub mod jobs;
mod migrations;
pub mod mining;
mod platform;
mod platform_render;
pub mod project_list;
mod project_quota;
mod projection_loss;
mod quality_store;
mod quality_workflow;
pub mod service_preview;
pub mod storage;
pub mod structured_discovery;
pub mod web;

mod migration_v2;
mod migration_v3;
mod migration_v4;
mod migration_v5;
mod migration_v6;
mod normalized;

mod repository_v2;
mod resource_cache;

#[cfg(test)]
mod quota_workflow_tests;

#[cfg(test)]
mod public_origin_tests;

#[cfg(test)]
mod full_log_http_tests;
