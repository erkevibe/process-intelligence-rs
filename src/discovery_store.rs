//! Immutable training snapshots and separately persisted discovery results.
use crate::{
    bpmn::ProcessModel,
    bpmn_quality::facade,
    domain::ImportError,
    jobs::{JobSnapshot, JobState},
    quality_store as quality,
    structured_discovery::{self, Tree},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::OnceLock,
    time::Instant,
};
pub(crate) const MAX_RETAINED: usize = 8;
pub(crate) const MAX_ARTIFACT: usize = 512 * 1024;
pub(crate) const MAX_OUTPUT: usize = 256 * 1024;
pub(crate) const ALGORITHM: &str = "structured_variants_v1";
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct TrainingIdentity {
    pub source_project_id: String,
    pub log_id: String,
    pub analysis_version: u64,
    pub source_sha256: String,
    pub variants_sha256: String,
    pub algorithm: String,
    pub method_sha256: String,
    pub job_id: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DiscoveryMeta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub snapshot: JobSnapshot,
    pub artifact_id: String,
    pub owner: String,
    pub source_project_id: String,
    pub request_key: String,
    pub form_sha256: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub retry_of: Option<String>,
    pub log_id: String,
    pub log_name: String,
    pub analysis_version: u64,
    pub source_sha256: String,
    pub variants_sha256: String,
    pub method_sha256: String,
    pub model_name: String,
    pub model_id: Option<String>,
    pub output_sha256: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DiscoveryInput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub variants: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DiscoveryOutput {
    pub model: ProcessModel,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree: Option<Tree>,
    pub exact_variant_fallbacks: usize,
    pub model_sha256: String,
    pub training_report: Value,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DiscoveryArtifact {
    pub id: String,
    pub input: DiscoveryInput,
    pub output: Option<DiscoveryOutput>,
}
pub(crate) fn corrupt() -> ImportError {
    ImportError::new(
        "discovery_corrupt",
        "Сохранённое построение повреждено или не поддерживается. Данные не изменены.",
    )
}
fn label(s: &str, max: usize) -> bool {
    s.len() <= max && !s.chars().any(char::is_control)
}
pub(crate) fn id_valid(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .is_some_and(|v| !v.is_empty() && v.len() <= 32 && v.bytes().all(|b| b.is_ascii_digit()))
}
pub(crate) fn parameters() -> Value {
    json!({"algorithm":ALGORITHM,"cut_order":"empty_repeat_xor_sequence_parallel_exact_variants","noise_filter":false,"max_activities":6,"max_traces":64,"max_events":500,"max_variants":32,"max_model_nodes":64,"max_model_flows":128,"max_recursion":16})
}
pub(crate) fn method_sha256() -> &'static str {
    static HASH: OnceLock<String> = OnceLock::new();
    HASH.get_or_init(||{let source=include_str!("structured_discovery.rs").replace("\r\n","\n");crate::storage::sha256(&serde_json::to_vec(&json!({"algorithm":ALGORITHM,"parameters":parameters(),"source":source,"quality_method":quality::method_sha256()})).expect("method JSON"))})
}
pub(crate) fn method_for(profile: Option<&str>) -> &'static str {
    if profile == Some(crate::dfg_discovery::PROFILE) {
        crate::dfg_discovery::method_sha256()
    } else {
        method_sha256()
    }
}
pub(crate) fn parameters_for(profile: Option<&str>) -> Value {
    if profile.is_none() {
        parameters()
    } else {
        json!({"algorithm":crate::dfg_discovery::ALGORITHM,"profile":crate::dfg_discovery::PROFILE,"max_traces":1000,"max_events":20000,"max_variants":256,"max_activities":32,"max_trace_events":64,"max_model_nodes":128,"max_model_flows":256,"sampling":false,"concurrency_inference":false})
    }
}
pub(crate) fn input_hash(input: &DiscoveryInput) -> Result<String, ImportError> {
    let variants = crate::dfg_discovery::variants_for(&input.variants, input.profile.as_deref())
        .map_err(|_| corrupt())?;
    let canonical: Vec<_> = variants
        .iter()
        .map(|(sequence, frequency)| json!({"sequence":sequence,"frequency":frequency}))
        .collect();
    if input.variants != json!(canonical) {
        return Err(corrupt());
    }
    Ok(crate::storage::sha256(&quality::bytes(
        &input.variants,
        1024 * 1024,
    )?))
}
pub(crate) fn identity(meta: &DiscoveryMeta) -> TrainingIdentity {
    TrainingIdentity {
        source_project_id: meta.source_project_id.clone(),
        log_id: meta.log_id.clone(),
        analysis_version: meta.analysis_version,
        source_sha256: meta.source_sha256.clone(),
        variants_sha256: meta.variants_sha256.clone(),
        algorithm: if meta.profile.as_deref() == Some(crate::dfg_discovery::PROFILE) {
            crate::dfg_discovery::ALGORITHM
        } else {
            ALGORITHM
        }
        .into(),
        method_sha256: meta.method_sha256.clone(),
        job_id: meta.snapshot.id.clone(),
    }
}
pub(crate) fn validate_identity(value: &TrainingIdentity) -> Result<(), ImportError> {
    if value.source_project_id.is_empty()
        || !label(&value.source_project_id, 128)
        || !id_valid(&value.log_id, "log-")
        || value.analysis_version == 0
        || !quality::hash_valid(&value.source_sha256)
        || !quality::hash_valid(&value.variants_sha256)
        || !matches!(
            value.algorithm.as_str(),
            ALGORITHM | crate::dfg_discovery::ALGORITHM
        )
        || !quality::hash_valid(&value.method_sha256)
        || !id_valid(&value.job_id, "job-")
    {
        return Err(corrupt());
    }
    Ok(())
}
pub(crate) fn validate_metadata(
    all: &BTreeMap<String, DiscoveryMeta>,
    receipts: &BTreeMap<String, quality::RequestReceipt>,
) -> Result<(), ImportError> {
    quality::validate_metadata(&BTreeMap::new(), receipts).map_err(|_| corrupt())?;
    if all.len() > MAX_RETAINED {
        return Err(corrupt());
    }
    let mut artifacts = BTreeSet::new();
    for (id, m) in all {
        validate_identity(&identity(m))?;
        if !crate::dfg_discovery::profile_valid(m.profile.as_deref()) {
            return Err(corrupt());
        }
        let s = &m.snapshot;
        if id != &s.id
            || !id_valid(id, "job-")
            || !id_valid(&m.artifact_id, "discovery-")
            || !artifacts.insert(&m.artifact_id)
            || m.owner.is_empty()
            || !label(&m.owner, 128)
            || quality::key_time(&m.request_key).is_none()
            || !quality::hash_valid(&m.form_sha256)
            || !label(&m.log_name, 1024)
            || !label(&m.model_name, 1024)
            || !label(&s.stage, 64)
            || (!s.is_terminal() && s.job_revision == u64::MAX)
            || s.error
                .as_ref()
                .is_some_and(|e| !label(&e.code, 128) || !label(&e.message, 4096))
        {
            return Err(corrupt());
        }
        let invalid = match s.state {
            JobState::Queued => {
                s.job_revision != 0
                    || s.stage != "queued"
                    || s.cancel_requested
                    || s.error.is_some()
            }
            JobState::Running => s.job_revision == 0 || s.cancel_requested || s.error.is_some(),
            JobState::Completed => {
                s.job_revision == 0
                    || s.stage != "completed"
                    || s.cancel_requested
                    || s.error.is_some()
                    || s.result_id.as_ref() != Some(&m.artifact_id)
                    || m.model_id.as_ref().is_none_or(|id| !id_valid(id, "model-"))
                    || m.output_sha256
                        .as_ref()
                        .is_none_or(|s| !quality::hash_valid(s))
            }
            JobState::Failed => {
                s.job_revision == 0
                    || s.error.is_none()
                    || !matches!(s.stage.as_str(), "failed" | "interrupted")
            }
            JobState::Cancelled => {
                s.job_revision == 0
                    || s.stage != "cancelled"
                    || !s.cancel_requested
                    || s.error.is_some()
            }
        };
        if invalid
            || (s.state != JobState::Completed
                && (s.result_id.is_some() || m.model_id.is_some() || m.output_sha256.is_some()))
        {
            return Err(corrupt());
        }
        if let Some(r) = receipts.get(&m.request_key)
            && (r.job_id != *id
                || r.owner != m.owner
                || r.form_sha256 != m.form_sha256
                || r.retry_of != m.retry_of)
        {
            return Err(corrupt());
        }
    }
    Ok(())
}
pub(crate) fn validate_artifact(
    meta: &DiscoveryMeta,
    a: &DiscoveryArtifact,
) -> Result<(), ImportError> {
    if a.input.profile != meta.profile
        || a.id != meta.artifact_id
        || quality::bytes(a, MAX_ARTIFACT).is_err()
        || input_hash(&a.input)? != meta.variants_sha256
    {
        return Err(corrupt());
    }
    match &a.output {
        Some(output) => {
            crate::bpmn::validate(&output.model).map_err(|_| corrupt())?;
            if meta.snapshot.state != JobState::Completed
                || output.model.nodes.len() > if meta.profile.is_some() { 128 } else { 64 }
                || output.model.flows.len() > if meta.profile.is_some() { 256 } else { 128 }
                || output.exact_variant_fallbacks > 32
                || Some(crate::storage::sha256(&quality::bytes(output, MAX_OUTPUT)?))
                    != meta.output_sha256
                || crate::storage::sha256(&quality::bytes(&output.model, 1024 * 1024)?)
                    != output.model_sha256
                || output.training_report["model_sha256"] != output.model_sha256
                || output.training_report["variants_sha256"] != meta.variants_sha256
                || output.training_report["profile"]
                    != if meta.profile.is_some() {
                        crate::dfg_discovery::PROFILE
                    } else {
                        "application_bounded_v1"
                    }
                || output.tree.is_some() != meta.profile.is_none()
                || (meta.profile.is_some() && output.exact_variant_fallbacks != 0)
            {
                return Err(corrupt());
            }
        }
        None => {
            if meta.snapshot.state == JobState::Completed {
                return Err(corrupt());
            }
        }
    }
    Ok(())
}
/// Admission already proves a complete reachable graph. Check WF soundness for
/// this particular graph; this is not a theorem about all heuristic outputs.
fn sound(
    net: &process_mining::PetriNet,
    g: &crate::bpmn_quality::state::Graph,
) -> Result<(), ImportError> {
    use process_mining::core::process_models::case_centric::petri_net::ArcType;
    let initial = net.initial_marking.as_ref().ok_or_else(corrupt)?;
    let finals = net.final_markings.as_ref().ok_or_else(corrupt)?;
    if initial.len() != 1
        || initial.values().next() != Some(&1)
        || finals.len() != 1
        || finals[0].len() != 1
        || finals[0].values().next() != Some(&1)
        || g.states.iter().flatten().any(|n| *n > 1)
    {
        return Err(ImportError::new(
            "discovery_not_sound",
            "Полученная сеть не прошла проверку корректного завершения.",
        ));
    }
    let first = initial.keys().next().ok_or_else(corrupt)?.0;
    let last = finals[0].keys().next().ok_or_else(corrupt)?.0;
    let nodes: BTreeSet<_> = net
        .places
        .keys()
        .chain(net.transitions.keys())
        .copied()
        .collect();
    let mut forward: BTreeMap<_, BTreeSet<_>> =
        nodes.iter().map(|id| (*id, BTreeSet::new())).collect();
    let mut backward = forward.clone();
    for a in &net.arcs {
        let (x, y) = match a.from_to {
            ArcType::PlaceTransition(x, y) | ArcType::TransitionPlace(x, y) => (x, y),
        };
        forward.get_mut(&x).ok_or_else(corrupt)?.insert(y);
        backward.get_mut(&y).ok_or_else(corrupt)?.insert(x);
    }
    let reach = |seed, edges: &BTreeMap<uuid::Uuid, BTreeSet<uuid::Uuid>>| {
        let mut found = BTreeSet::from([seed]);
        let mut todo = vec![seed];
        while let Some(id) = todo.pop() {
            for next in &edges[&id] {
                if found.insert(*next) {
                    todo.push(*next)
                }
            }
        }
        found
    };
    if !backward[&first].is_empty()
        || !forward[&last].is_empty()
        || reach(first, &forward) != nodes
        || reach(last, &backward) != nodes
    {
        return Err(corrupt());
    }
    let mut reverse = vec![Vec::new(); g.states.len()];
    let mut live = BTreeSet::new();
    for edge in &g.edges {
        reverse[edge.to].push(edge.from);
        live.insert(edge.transition.clone());
    }
    let mut done: BTreeSet<_> = g.final_states.iter().copied().collect();
    let mut todo: Vec<_> = done.iter().copied().collect();
    while let Some(id) = todo.pop() {
        for next in &reverse[id] {
            if done.insert(*next) {
                todo.push(*next)
            }
        }
    }
    let target: Vec<_> = g
        .places
        .iter()
        .map(|p| {
            finals[0]
                .iter()
                .find(|(id, _)| id.0.to_string() == *p)
                .map_or(0, |(_, n)| *n)
        })
        .collect();
    if done.len() != g.states.len()
        || live.len() != net.transitions.len()
        || g.states
            .iter()
            .any(|state| state != &target && state.iter().zip(&target).all(|(n, f)| n >= f))
    {
        return Err(corrupt());
    }
    Ok(())
}
pub(crate) fn compute(
    input: &DiscoveryInput,
    until: Instant,
    checkpoint: &mut dyn FnMut(&str) -> Result<(), ImportError>,
) -> Result<DiscoveryOutput, ImportError> {
    input_hash(input)?;
    if input.profile.as_deref() == Some(crate::dfg_discovery::PROFILE) {
        return compute_full(input, until, checkpoint);
    }
    let variants =
        crate::bpmn_quality::metrics::variants(&input.variants).map_err(|_| corrupt())?;
    if variants.is_empty() {
        return Err(ImportError::new(
            "no_data",
            "В журнале нет трасс для построения.",
        ));
    }
    checkpoint("discover")?;
    let mut interrupted = None;
    let discovered = structured_discovery::discover_with_control(&variants, &mut || {
        if Instant::now() >= until {
            return Err("deadline".into());
        }
        checkpoint("discover").map_err(|e| {
            let code = e.code.clone();
            interrupted = Some(e);
            code
        })
    });
    if let Some(e) = interrupted.take() {
        return Err(e);
    }
    let discovered = discovered.map_err(|code| {
        ImportError::new(&code, "Построение не выполнено в поддерживаемых пределах.")
    })?;
    checkpoint("validate")?;
    let (net, _) =
        crate::bpmn_quality::bridge::from_model(&discovered.model).map_err(|_| corrupt())?;
    let raw = quality::bytes(&net, 1024 * 1024)?;
    let graph = crate::bpmn_quality::state::admit(
        &net,
        &crate::storage::sha256(&raw),
        facade::application_limits(&Value::Null).map_err(|_| corrupt())?,
    )
    .map_err(|issue| {
        ImportError::new(
            &issue.reason,
            "Полученная модель не прошла ограниченную проверку сети.",
        )
    })?;
    sound(&net, &graph)?;
    let xml = crate::bpmn::serialize(&discovered.model).map_err(|_| corrupt())?;
    let imported = crate::bpmn::parse(xml.as_bytes()).map_err(|_| corrupt())?;
    checkpoint("training_evaluation")?;
    let report = facade::evaluate_model(
        &discovered.model,
        &input.variants,
        &Value::Null,
        &mut |stage| {
            if Instant::now() >= until {
                return Err(crate::bpmn_quality::Issue::cap("deadline"));
            }
            if let Err(e) = checkpoint(stage) {
                let issue = crate::bpmn_quality::Issue::refused(&e.code);
                interrupted = Some(e);
                return Err(issue);
            }
            Ok(())
        },
    );
    if let Some(e) = interrupted.take() {
        return Err(e);
    }
    let report = report.map_err(|issue| {
        if issue.reason == "deadline" {
            ImportError::new("discovery_limit", "Оценка достигла границы времени.")
        } else {
            corrupt()
        }
    })?;
    if report["metrics"]["fitness"]["status"] != "measured"
        || report["metrics"]["fitness"]["integer_components"]["weighted_total_cost"] != 0
    {
        return Err(ImportError::new(
            "discovery_nonfitting_training",
            "Модель не воспроизводит все обучающие трассы.",
        ));
    }
    let reimported =
        facade::evaluate_model(&imported, &input.variants, &Value::Null, &mut |stage| {
            if Instant::now() >= until {
                return Err(crate::bpmn_quality::Issue::cap("deadline"));
            }
            checkpoint(stage).map_err(|e| {
                let issue = crate::bpmn_quality::Issue::refused(&e.code);
                interrupted = Some(e);
                issue
            })
        });
    if let Some(e) = interrupted.take() {
        return Err(e);
    }
    let reimported = reimported.map_err(|issue| {
        if issue.reason == "deadline" {
            ImportError::new("discovery_limit", "Оценка достигла границы времени.")
        } else {
            corrupt()
        }
    })?;
    if report["metrics"] != reimported["metrics"] {
        return Err(corrupt());
    }
    let output = DiscoveryOutput {
        model_sha256: crate::storage::sha256(&quality::bytes(&discovered.model, 1024 * 1024)?),
        model: discovered.model,
        tree: Some(discovered.tree),
        exact_variant_fallbacks: discovered.exact_variant_fallbacks,
        training_report: report,
    };
    quality::bytes(&output, MAX_OUTPUT)?;
    Ok(output)
}
pub(crate) fn verify_restored(
    meta: &DiscoveryMeta,
    a: &DiscoveryArtifact,
    until: Instant,
) -> Result<(), ImportError> {
    validate_artifact(meta, a)?;
    if let Some(expected) = &a.output {
        if meta.method_sha256 != method_for(meta.profile.as_deref()) {
            return Err(ImportError::new(
                "discovery_method_changed",
                "Метод построения изменился; восстановление этого результата не подтверждено.",
            ));
        }
        let actual = compute(&a.input, until, &mut |_| Ok(()))?;
        if quality::bytes(&actual, MAX_OUTPUT)? != quality::bytes(expected, MAX_OUTPUT)? {
            return Err(corrupt());
        }
    }
    Ok(())
}
pub(crate) fn load_artifact(
    db: &crate::storage::Database,
    project: &str,
    m: &DiscoveryMeta,
) -> Result<std::sync::Arc<DiscoveryArtifact>, ImportError> {
    let rows = db.resource_records(project, &m.artifact_id, &["discovery"])?;
    if rows.len() != 1 || rows[0].0 != "discovery" || rows[0].1 == 0 {
        return Err(corrupt());
    }
    let a: DiscoveryArtifact = serde_json::from_value(rows[0].2.clone()).map_err(|_| corrupt())?;
    validate_artifact(m, &a)?;
    Ok(std::sync::Arc::new(a))
}
pub(crate) fn validate_full(repo: &crate::web::Repository) -> Result<(), ImportError> {
    validate_metadata(&repo.discovery_jobs, &repo.discovery_requests)?;
    let ids: BTreeSet<_> = repo
        .discovery_jobs
        .values()
        .map(|m| &m.artifact_id)
        .collect();
    if ids != repo.discovery_artifacts.keys().collect() {
        return Err(corrupt());
    }
    for m in repo.discovery_jobs.values() {
        validate_artifact(m, &repo.discovery_artifacts[&m.artifact_id])?
    }
    Ok(())
}

fn compute_full(
    input: &DiscoveryInput,
    until: Instant,
    checkpoint: &mut dyn FnMut(&str) -> Result<(), ImportError>,
) -> Result<DiscoveryOutput, ImportError> {
    let mut interrupted = None;
    let mut check = |stage: &str| {
        if Instant::now() >= until {
            return Err(crate::bpmn_quality::Issue::cap("deadline"));
        }
        checkpoint(stage).map_err(|e| {
            let code = e.code.clone();
            interrupted = Some(e);
            crate::bpmn_quality::Issue::refused(&code)
        })
    };
    let computed = (|| {
        let model = crate::dfg_discovery::discover(&input.variants, &mut check)?;
        let report = crate::dfg_discovery::evaluate(&model, &input.variants, &mut check)?;
        if report["metrics"]["fitness"]["integer_components"]["weighted_total_cost"] != 0 {
            return Err(crate::bpmn_quality::Issue::refused(
                "discovery_nonfitting_training",
            ));
        }
        let xml = crate::bpmn::serialize(&model)
            .map_err(|e| crate::bpmn_quality::Issue::refused(&e.code))?;
        let imported = crate::bpmn::parse(xml.as_bytes())
            .map_err(|e| crate::bpmn_quality::Issue::refused(&e.code))?;
        let replay = crate::dfg_discovery::evaluate(&imported, &input.variants, &mut check)?;
        if report["metrics"] != replay["metrics"] {
            return Err(crate::bpmn_quality::Issue::refused(
                "discovery_roundtrip_mismatch",
            ));
        }
        Ok((model, report))
    })();
    if let Some(e) = interrupted {
        return Err(e);
    }
    let (model, report) = computed.map_err(|e: crate::bpmn_quality::Issue| {
        ImportError::new(&e.reason, "Полная модель не прошла ограниченную проверку.")
    })?;
    let output = DiscoveryOutput {
        model_sha256: crate::storage::sha256(&quality::bytes(&model, 1024 * 1024)?),
        model,
        tree: None,
        exact_variant_fallbacks: 0,
        training_report: report,
    };
    quality::bytes(&output, MAX_OUTPUT)?;
    Ok(output)
}
