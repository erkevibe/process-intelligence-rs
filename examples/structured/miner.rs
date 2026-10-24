//! Own bounded structured-variant heuristic. Not SplitMiner or a full IM port.
use process_intelligence_rs::bpmn::{self, ModelFlow, ModelNode, NodeKind, ProcessModel};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub type Variants = BTreeMap<Vec<String>, u64>;
#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(tag = "operator", content = "children", rename_all = "snake_case")]
pub enum Tree {
    Tau,
    Task(String),
    Sequence(Vec<Tree>),
    Choice(Vec<Tree>),
    Parallel(Vec<Tree>),
    Repeat(Box<Tree>),
}
#[derive(Debug, Serialize)]
pub struct Result {
    pub model: ProcessModel,
    pub tree: Tree,
    pub exact_variant_fallbacks: usize,
}
fn sequence(values: Vec<Tree>) -> Tree {
    let mut flat = Vec::new();
    for value in values {
        match value {
            Tree::Tau => {}
            Tree::Sequence(children) => flat.extend(children),
            other => flat.push(other),
        }
    }
    match flat.len() {
        0 => Tree::Tau,
        1 => flat.pop().unwrap(),
        _ => Tree::Sequence(flat),
    }
}
fn branch(values: Vec<Tree>, parallel: bool) -> Tree {
    let mut flat = BTreeSet::new();
    for value in values {
        match value {
            Tree::Parallel(children) if parallel => flat.extend(children),
            Tree::Choice(children) if !parallel => flat.extend(children),
            Tree::Tau if parallel => {}
            other => {
                flat.insert(other);
            }
        }
    }
    let mut values: Vec<_> = flat.into_iter().collect();
    match values.len() {
        0 => Tree::Tau,
        1 => values.pop().unwrap(),
        _ => {
            if parallel {
                Tree::Parallel(values)
            } else {
                Tree::Choice(values)
            }
        }
    }
}
fn components(labels: &[String], linked: impl Fn(usize, usize) -> bool) -> Vec<BTreeSet<String>> {
    let mut seen = BTreeSet::new();
    let mut groups = Vec::new();
    for seed in 0..labels.len() {
        if !seen.insert(seed) {
            continue;
        }
        let mut todo = vec![seed];
        let mut group = BTreeSet::new();
        while let Some(a) = todo.pop() {
            group.insert(labels[a].clone());
            for b in 0..labels.len() {
                if !seen.contains(&b) && linked(a, b) {
                    seen.insert(b);
                    todo.push(b)
                }
            }
        }
        groups.push(group)
    }
    groups
}
fn project(variants: &Variants, labels: &BTreeSet<String>, include_empty: bool) -> Variants {
    let mut result = Variants::new();
    for (trace, count) in variants {
        let selected: Vec<_> = trace
            .iter()
            .filter(|s| labels.contains(*s))
            .cloned()
            .collect();
        if include_empty || !selected.is_empty() {
            *result.entry(selected).or_default() += count
        }
    }
    result
}
fn build(
    variants: &Variants,
    depth: usize,
    fallbacks: &mut usize,
) -> std::result::Result<Tree, String> {
    if depth > 16 {
        return Err("structured_recursion_limit".into());
    }
    if variants.len() == 1 && variants.contains_key(&Vec::new()) {
        return Ok(Tree::Tau);
    }
    if variants.contains_key(&Vec::new()) {
        let nonempty = variants
            .iter()
            .filter(|(s, _)| !s.is_empty())
            .map(|(s, n)| (s.clone(), *n))
            .collect();
        return Ok(branch(
            vec![Tree::Tau, build(&nonempty, depth + 1, fallbacks)?],
            false,
        ));
    }
    let labels: Vec<_> = variants
        .keys()
        .flatten()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if labels.is_empty() {
        return Ok(Tree::Tau);
    }
    let first = variants.keys().next().ok_or("empty_variants")?;
    for width in 1..=first.len() {
        if !first.len().is_multiple_of(width) {
            continue;
        }
        let word = &first[..width];
        if variants
            .keys()
            .all(|s| s.len().is_multiple_of(width) && s.chunks(width).all(|part| part == word))
        {
            let body = sequence(word.iter().cloned().map(Tree::Task).collect());
            return Ok(if variants.keys().any(|s| s.len() > width) {
                Tree::Repeat(Box::new(body))
            } else {
                body
            });
        }
    }
    let index: BTreeMap<_, _> = labels
        .iter()
        .enumerate()
        .map(|(i, s)| (s.clone(), i))
        .collect();
    let n = labels.len();
    let mut co = vec![vec![false; n]; n];
    let mut follows = co.clone();
    let mut reach = co.clone();
    for trace in variants.keys() {
        for (i, a) in trace.iter().enumerate() {
            for b in &trace[i + 1..] {
                co[index[a]][index[b]] = true;
                co[index[b]][index[a]] = true;
                follows[index[a]][index[b]] = true
            }
        }
        for pair in trace.windows(2) {
            reach[index[&pair[0]]][index[&pair[1]]] = true
        }
    }
    let xor = components(&labels, |a, b| co[a][b]);
    if xor.len() > 1 {
        return Ok(branch(
            xor.iter()
                .map(|g| build(&project(variants, g, false), depth + 1, fallbacks))
                .collect::<std::result::Result<_, _>>()?,
            false,
        ));
    }
    for k in 0..n {
        for a in 0..n {
            for b in 0..n {
                reach[a][b] |= reach[a][k] && reach[k][b]
            }
        }
    }
    let scc = components(&labels, |a, b| reach[a][b] && reach[b][a]);
    if scc.len() > 1 {
        // Merge incomparable SCCs; only a strict total order of blocks is a cut.
        let names: Vec<_> = (0..scc.len()).map(|i| i.to_string()).collect();
        let merged = components(&names, |a, b| {
            let x = index[scc[a].first().unwrap()];
            let y = index[scc[b].first().unwrap()];
            !reach[x][y] && !reach[y][x]
        });
        let mut blocks: Vec<BTreeSet<String>> = merged
            .iter()
            .map(|g| {
                g.iter()
                    .flat_map(|s| scc[s.parse::<usize>().unwrap()].iter().cloned())
                    .collect()
            })
            .collect();
        let before = |a: &BTreeSet<String>, b: &BTreeSet<String>| {
            a.iter().all(|x| {
                b.iter()
                    .all(|y| reach[index[x]][index[y]] && !reach[index[y]][index[x]])
            })
        };
        if blocks.len() > 1
            && (0..blocks.len()).all(|a| {
                (a + 1..blocks.len())
                    .all(|b| before(&blocks[a], &blocks[b]) || before(&blocks[b], &blocks[a]))
            })
        {
            let snapshot = blocks.clone();
            blocks.sort_by_key(|g| snapshot.iter().filter(|other| before(other, g)).count());
            return Ok(sequence(
                blocks
                    .iter()
                    .map(|g| build(&project(variants, g, true), depth + 1, fallbacks))
                    .collect::<std::result::Result<_, _>>()?,
            ));
        }
    }
    let parallel = components(&labels, |a, b| !follows[a][b] || !follows[b][a]);
    if parallel.len() > 1 {
        return Ok(branch(
            parallel
                .iter()
                .map(|g| build(&project(variants, g, true), depth + 1, fallbacks))
                .collect::<std::result::Result<_, _>>()?,
            true,
        ));
    }
    *fallbacks += 1;
    Ok(branch(
        variants
            .keys()
            .map(|s| sequence(s.iter().cloned().map(Tree::Task).collect()))
            .collect(),
        false,
    ))
}
#[derive(Default)]
struct Builder {
    nodes: Vec<ModelNode>,
    flows: Vec<ModelFlow>,
}
impl Builder {
    fn node(&mut self, kind: NodeKind, label: String) -> std::result::Result<String, String> {
        if self.nodes.len() >= 64 {
            return Err("structured_model_node_limit".into());
        }
        let i = self.nodes.len();
        let id = format!("n{i}");
        self.nodes.push(ModelNode {
            id: id.clone(),
            kind,
            label,
            x: 100. + (i % 8) as f64 * 170.,
            y: 100. + (i / 8) as f64 * 130.,
            dimensions: None,
        });
        Ok(id)
    }
    fn flow(&mut self, a: &str, b: &str) -> std::result::Result<(), String> {
        if self.flows.len() >= 128 {
            return Err("structured_model_flow_limit".into());
        }
        self.flows.push(ModelFlow {
            id: format!("f{}", self.flows.len()),
            source: a.into(),
            target: b.into(),
            label: String::new(),
            waypoints: vec![],
        });
        Ok(())
    }
    fn fragment(&mut self, tree: &Tree) -> std::result::Result<(String, String), String> {
        match tree {
            Tree::Task(label) => {
                let id = self.node(NodeKind::Task, label.clone())?;
                Ok((id.clone(), id))
            }
            Tree::Tau => {
                let id = self.node(NodeKind::ExclusiveGateway, String::new())?;
                Ok((id.clone(), id))
            }
            Tree::Sequence(children) => {
                let mut first: Option<String> = None;
                let mut previous: Option<String> = None;
                for child in children {
                    let (a, b) = self.fragment(child)?;
                    if let Some(p) = previous {
                        self.flow(&p, &a)?
                    } else {
                        first = Some(a)
                    }
                    previous = Some(b)
                }
                Ok((
                    first.ok_or("empty_sequence")?,
                    previous.ok_or("empty_sequence")?,
                ))
            }
            Tree::Choice(children) | Tree::Parallel(children) => {
                let kind = if matches!(tree, Tree::Parallel(_)) {
                    NodeKind::ParallelGateway
                } else {
                    NodeKind::ExclusiveGateway
                };
                let a = self.node(kind, String::new())?;
                let b = self.node(kind, String::new())?;
                for child in children {
                    if matches!(child, Tree::Tau) {
                        self.flow(&a, &b)?
                    } else {
                        let (x, y) = self.fragment(child)?;
                        self.flow(&a, &x)?;
                        self.flow(&y, &b)?
                    }
                }
                Ok((a, b))
            }
            Tree::Repeat(body) => {
                let a = self.node(NodeKind::ExclusiveGateway, String::new())?;
                let b = self.node(NodeKind::ExclusiveGateway, String::new())?;
                let (x, y) = self.fragment(body)?;
                self.flow(&a, &x)?;
                self.flow(&y, &b)?;
                self.flow(&b, &a)?;
                Ok((a, b))
            }
        }
    }
}
pub fn discover(variants: &Variants) -> std::result::Result<Result, String> {
    if variants.is_empty() || variants.len() > 32 {
        return Err("structured_variant_limit".into());
    }
    let mut count = 0u64;
    let mut events = 0u64;
    let mut labels = BTreeSet::new();
    for (trace, frequency) in variants {
        if *frequency == 0 || *frequency > 64 || trace.len() > 64 {
            return Err("structured_input_bounds".into());
        }
        count += frequency;
        events += frequency * trace.len() as u64;
        for label in trace {
            if label.trim().is_empty() || label.len() > 200 {
                return Err("structured_activity".into());
            }
            labels.insert(label);
        }
    }
    if count > 64 || events > 500 || labels.len() > 6 {
        return Err("structured_input_bounds".into());
    }
    let mut fallbacks = 0;
    let tree = build(variants, 0, &mut fallbacks)?;
    let mut builder = Builder::default();
    let start = builder.node(NodeKind::Start, "Начало".into())?;
    let end = builder.node(NodeKind::End, "Конец".into())?;
    let (a, b) = builder.fragment(&tree)?;
    builder.flow(&start, &a)?;
    builder.flow(&b, &end)?;
    let model = ProcessModel {
        schema_version: 1,
        process_id: "structured_variants_v1".into(),
        name: "Структурные варианты v1".into(),
        nodes: builder.nodes,
        flows: builder.flows,
        discovery: None,
    };
    bpmn::validate(&model).map_err(|e| format!("{}: {}", e.code, e.message))?;
    Ok(Result {
        model,
        tree,
        exact_variant_fallbacks: fallbacks,
    })
}
