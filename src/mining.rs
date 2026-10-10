//! Deterministic DFG counts. View filtering never changes the event log.
use crate::domain::{
    Analysis, CaseHighlight, Edge, EventLog, GraphView, ImportError, Node, Variant,
};
use std::collections::BTreeMap;

pub fn analyze(log: &EventLog) -> Analysis {
    analyze_cancellable(log, &|| false).expect("non-cancellable analysis")
}

pub fn analyze_cancellable(
    log: &EventLog,
    cancelled: &dyn Fn() -> bool,
) -> Result<Analysis, ImportError> {
    let mut counts = BTreeMap::<String, (u64, u64, u64)>::new();
    let mut edges = BTreeMap::<(String, String), u64>::new();
    let mut variants = BTreeMap::<Vec<String>, Vec<String>>::new();
    let mut events = 0;
    for case in &log.cases {
        if cancelled() {
            return Err(ImportError::new("cancelled", "Обработка отменена."));
        }
        let sequence: Vec<String> = case.events.iter().map(|e| e.activity.clone()).collect();
        events += sequence.len();
        for activity in &sequence {
            if cancelled() {
                return Err(ImportError::new("cancelled", "Обработка отменена."));
            }
            counts.entry(activity.clone()).or_default().0 += 1;
        }
        if let Some(first) = sequence.first() {
            counts.entry(first.clone()).or_default().1 += 1;
        }
        if let Some(last) = sequence.last() {
            counts.entry(last.clone()).or_default().2 += 1;
        }
        for pair in sequence.windows(2) {
            *edges.entry((pair[0].clone(), pair[1].clone())).or_default() += 1;
        }
        variants.entry(sequence).or_default().push(case.id.clone());
    }
    let nodes: Vec<Node> = counts
        .into_iter()
        .enumerate()
        .map(|(i, (label, (count, start_count, end_count)))| Node {
            id: format!("activity-{i}"),
            label,
            count,
            start_count,
            end_count,
        })
        .collect();
    let ids: BTreeMap<&str, &str> = nodes
        .iter()
        .map(|n| (n.label.as_str(), n.id.as_str()))
        .collect();
    let edges: Vec<Edge> = edges
        .into_iter()
        .enumerate()
        .map(|(i, ((source, target), count))| Edge {
            id: format!("edge-{i}"),
            source: ids[source.as_str()].into(),
            target: ids[target.as_str()].into(),
            count,
        })
        .collect();
    let max_edge_frequency = edges.iter().map(|e| e.count).max().unwrap_or(0);
    let mut variants: Vec<Variant> = variants
        .into_iter()
        .map(|(sequence, case_ids)| Variant {
            id: String::new(),
            count: case_ids.len() as u64,
            sequence,
            case_ids,
        })
        .collect();
    variants.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.sequence.cmp(&b.sequence))
    });
    for (i, variant) in variants.iter_mut().enumerate() {
        variant.id = format!("variant-{i}");
    }
    if cancelled() {
        return Err(ImportError::new("cancelled", "Обработка отменена."));
    }
    Ok(Analysis {
        cases: log.cases.len(),
        events,
        activities: nodes.len(),
        nodes,
        edges,
        variants,
        max_edge_frequency,
    })
}

pub fn graph_view(
    analysis: &Analysis,
    log_id: &str,
    analysis_version: u64,
    view_revision: u64,
    threshold: u64,
    selected_id: Option<String>,
) -> Result<GraphView, ImportError> {
    if threshold == 0 || threshold > analysis.max_edge_frequency.saturating_add(1).max(1) {
        return Err(ImportError::new(
            "invalid_threshold",
            "Порог должен быть целым числом в допустимом диапазоне.",
        ));
    }
    let edges: Vec<Edge> = analysis
        .edges
        .iter()
        .filter(|e| e.count >= threshold)
        .cloned()
        .collect();
    let selected_id = selected_id.filter(|id| {
        analysis.nodes.iter().any(|n| &n.id == id) || edges.iter().any(|e| &e.id == id)
    });
    Ok(GraphView {
        log_id: log_id.into(),
        analysis_version,
        view_revision,
        min_edge_frequency: threshold,
        max_edge_frequency: analysis.max_edge_frequency,
        nodes: analysis.nodes.clone(),
        edges,
        selected_id,
        selected_case_id: None,
        case_highlight: CaseHighlight {
            node_ids: Vec::new(),
            edge_ids: Vec::new(),
        },
    })
}
