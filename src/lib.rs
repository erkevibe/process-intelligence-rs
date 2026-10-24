pub mod audit;
pub mod auth;
pub mod bpmn;
pub mod bpmn_quality;
mod bpmn_quality_preview;
pub mod calendar;
pub mod cleanup;
#[allow(
    clippy::chunks_exact_to_as_chunks,
    reason = "Keep the reviewed byte decoder and its source provenance stable"
)]
pub mod conversion;
mod conversion_workflow;
pub mod csv_io;
pub mod discovery;
pub mod domain;
pub mod event_io;
pub mod filters;
pub mod folders;
pub mod import_provenance;
pub mod jobs;
mod migrations;
pub mod mining;
mod platform;
mod platform_render;
pub mod project_list;
mod projection_loss;
pub mod service_preview;
pub mod storage;
pub mod web;

mod migration_v2;
mod migration_v3;
mod normalized;

mod repository_v2;
mod resource_cache;
