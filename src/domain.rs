use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub ordinal: usize,
    pub activity: String,
    pub timestamp: Option<DateTime<Utc>>,
    pub lifecycle: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Case {
    pub id: String,
    pub name: Option<String>,
    pub events: Vec<Event>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventLog {
    pub name: Option<String>,
    pub cases: Vec<Case>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Node {
    pub id: String,
    pub label: String,
    pub count: u64,
    pub start_count: u64,
    pub end_count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Edge {
    pub id: String,
    pub source: String,
    pub target: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Variant {
    pub id: String,
    pub sequence: Vec<String>,
    pub count: u64,
    pub case_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Analysis {
    pub cases: usize,
    pub events: usize,
    pub activities: usize,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    pub variants: Vec<Variant>,
    pub max_edge_frequency: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaseHighlight {
    pub node_ids: Vec<String>,
    pub edge_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GraphView {
    pub log_id: String,
    pub analysis_version: u64,
    pub view_revision: u64,
    pub min_edge_frequency: u64,
    pub max_edge_frequency: u64,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    pub selected_id: Option<String>,
    pub selected_case_id: Option<String>,
    pub case_highlight: CaseHighlight,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportError {
    pub code: String,
    pub message: String,
    pub case_index: Option<usize>,
    pub event_index: Option<usize>,
}

impl ImportError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            case_index: None,
            event_index: None,
        }
    }
}

impl std::fmt::Display for ImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for ImportError {}
