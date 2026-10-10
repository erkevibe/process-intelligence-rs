//! Deliberately strict, non-executable BPMN subset and observed-variants baseline.
use crate::domain::{EventLog, ImportError};
use quick_xml::{NsReader, events::Event, name::ResolveResult};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const BPMN: &str = "http://www.omg.org/spec/BPMN/20100524/MODEL";
const BPMNDI: &str = "http://www.omg.org/spec/BPMN/20100524/DI";
const DC: &str = "http://www.omg.org/spec/DD/20100524/DC";
const DI: &str = "http://www.omg.org/spec/DD/20100524/DI";
pub const MAX_BYTES: usize = 1024 * 1024;
pub const MAX_NODES: usize = 1000;
pub const MAX_FLOWS: usize = 4000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProcessModel {
    pub schema_version: u32,
    pub process_id: String,
    pub name: String,
    pub nodes: Vec<ModelNode>,
    pub flows: Vec<ModelFlow>,
    pub discovery: Option<String>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NodeKind {
    Start,
    End,
    Task,
    ExclusiveGateway,
    ParallelGateway,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelNode {
    pub id: String,
    pub kind: NodeKind,
    pub label: String,
    pub x: f64,
    pub y: f64,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelFlow {
    pub id: String,
    pub source: String,
    pub target: String,
    pub waypoints: Vec<Point>,
}
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

fn invalid(message: &str) -> ImportError {
    ImportError::new("bpmn_invalid", message)
}
fn unsupported(message: &str) -> ImportError {
    ImportError::new("bpmn_unsupported", message)
}
fn limit(message: &str) -> ImportError {
    ImportError::new("bpmn_limit", message)
}

#[derive(Debug)]
struct Element {
    ns: String,
    name: String,
    attrs: BTreeMap<String, String>,
    children: Vec<Element>,
    text: String,
}
impl Element {
    fn attr(&self, key: &str) -> Result<&str, ImportError> {
        self.attrs
            .get(key)
            .map(String::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| invalid("Отсутствует обязательный атрибут BPMN."))
    }
    fn optional(&self, key: &str) -> &str {
        self.attrs.get(key).map(String::as_str).unwrap_or("")
    }
    fn check(&self, ns: &str, name: &str, attrs: &[&str]) -> Result<(), ImportError> {
        if self.ns != ns || self.name != name {
            return Err(unsupported(
                "Элемент или пространство имён не входит в поддерживаемый BPMN.",
            ));
        }
        if self.attrs.keys().any(|k| !attrs.contains(&k.as_str())) {
            return Err(unsupported(
                "Атрибут меняет неподдерживаемую семантику BPMN.",
            ));
        }
        if !self.text.trim().is_empty() {
            return Err(unsupported("Текст в этом элементе BPMN не поддерживается."));
        }
        Ok(())
    }
}

fn xml_tree(input: &[u8]) -> Result<Element, ImportError> {
    if input.len() > MAX_BYTES {
        return Err(limit("BPMN превышает 1 MiB."));
    }
    std::str::from_utf8(input).map_err(|_| invalid("BPMN должен быть в UTF-8."))?;
    let mut reader = NsReader::from_reader(input);
    reader.config_mut().check_comments = true;
    let mut stack: Vec<Element> = Vec::new();
    let mut root = None;
    let mut count = 0usize;
    let mut declared = false;
    loop {
        let (resolved, event) = reader
            .read_resolved_event()
            .map_err(|_| invalid("Повреждён XML BPMN."))?;
        let empty = matches!(&event, Event::Empty(_));
        match event {
            Event::Start(start) | Event::Empty(start) => {
                let ns = match resolved {
                    ResolveResult::Bound(ns) => std::str::from_utf8(ns.as_ref())
                        .map_err(|_| invalid("Некорректное пространство имён."))?
                        .to_owned(),
                    _ => {
                        return Err(unsupported(
                            "Для BPMN требуется объявленное пространство имён.",
                        ));
                    }
                };
                count += 1;
                if count > 25_000 || stack.len() >= 16 {
                    return Err(limit("Превышена сложность XML BPMN."));
                }
                let name = std::str::from_utf8(start.local_name().as_ref())
                    .map_err(|_| invalid("Некорректное имя XML."))?
                    .to_owned();
                let mut attrs = BTreeMap::new();
                for attr in start.attributes() {
                    let attr =
                        attr.map_err(|_| invalid("Повторный или повреждённый атрибут XML."))?;
                    let key = std::str::from_utf8(attr.key.as_ref())
                        .map_err(|_| invalid("Некорректный атрибут XML."))?;
                    if key == "xmlns" || key.starts_with("xmlns:") {
                        continue;
                    }
                    if key.contains(':') {
                        return Err(unsupported("Атрибуты расширений BPMN не поддерживаются."));
                    }
                    let value = attr
                        .decode_and_unescape_value(reader.decoder())
                        .map_err(|_| invalid("Некорректное значение атрибута."))?
                        .into_owned();
                    if !xml_text(&value) {
                        return Err(invalid("Недопустимый символ XML в атрибуте."));
                    }
                    if attrs.insert(key.to_owned(), value).is_some() {
                        return Err(invalid("Повторный атрибут XML."));
                    }
                }
                let element = Element {
                    ns,
                    name,
                    attrs,
                    children: Vec::new(),
                    text: String::new(),
                };
                if empty {
                    attach(element, &mut stack, &mut root)?;
                } else {
                    stack.push(element);
                }
            }
            Event::End(_) => {
                let element = stack.pop().ok_or_else(|| invalid("Лишнее закрытие XML."))?;
                attach(element, &mut stack, &mut root)?;
            }
            Event::Text(text) => {
                let value = text
                    .unescape()
                    .map_err(|_| invalid("Неизвестная XML-сущность."))?;
                if !xml_text(&value) {
                    return Err(invalid("Недопустимый текст XML."));
                }
                if let Some(parent) = stack.last_mut() {
                    parent.text.push_str(&value);
                } else if !value.trim().is_empty() {
                    return Err(invalid("Текст за пределами BPMN."));
                }
            }
            Event::DocType(_) | Event::CData(_) | Event::PI(_) => {
                return Err(unsupported(
                    "DTD, инструкции и CDATA BPMN не поддерживаются.",
                ));
            }
            Event::Decl(decl) => {
                if declared || root.is_some() || !stack.is_empty() {
                    return Err(invalid("XML declaration должна быть в начале."));
                }
                declared = true;
                if decl
                    .version()
                    .map_err(|_| invalid("Некорректная XML declaration."))?
                    .as_ref()
                    != b"1.0"
                {
                    return Err(unsupported("Поддерживается XML 1.0."));
                }
                if let Some(encoding) = decl.encoding()
                    && !encoding
                        .map_err(|_| invalid("Некорректная кодировка."))?
                        .eq_ignore_ascii_case(b"utf-8")
                {
                    return Err(unsupported("Поддерживается только UTF-8."));
                }
            }
            Event::Comment(_) => {}
            Event::Eof => break,
        }
    }
    if !stack.is_empty() {
        return Err(invalid("Незавершённый XML BPMN."));
    }
    root.ok_or_else(|| invalid("Пустой BPMN."))
}
fn attach(
    element: Element,
    stack: &mut [Element],
    root: &mut Option<Element>,
) -> Result<(), ImportError> {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(element);
    } else if root.replace(element).is_some() {
        return Err(invalid("BPMN должен содержать один корень."));
    }
    Ok(())
}

pub fn parse(input: &[u8]) -> Result<ProcessModel, ImportError> {
    let root = xml_tree(input)?;
    check_xml_ids(&root, &mut BTreeSet::new())?;
    root.check(
        BPMN,
        "definitions",
        &[
            "id",
            "name",
            "targetNamespace",
            "exporter",
            "exporterVersion",
        ],
    )?;
    let mut process = None;
    let mut diagram = None;
    for child in &root.children {
        match (child.ns.as_str(), child.name.as_str()) {
            (BPMN, "process") if process.is_none() => process = Some(child),
            (BPMNDI, "BPMNDiagram") if diagram.is_none() => diagram = Some(child),
            _ => {
                return Err(unsupported(
                    "Поддерживаются один process и одна диаграмма; прочая семантика отклонена.",
                ));
            }
        }
    }
    let process = process.ok_or_else(|| invalid("Нет process в BPMN."))?;
    process.check(BPMN, "process", &["id", "name", "isExecutable"])?;
    if !matches!(process.optional("isExecutable"), "" | "false" | "0") {
        return Err(unsupported("Исполняемый process не поддерживается."));
    }
    let mut model = ProcessModel {
        schema_version: 1,
        process_id: process.attr("id")?.to_owned(),
        name: process.optional("name").to_owned(),
        nodes: Vec::new(),
        flows: Vec::new(),
        discovery: None,
    };
    let mut declared_refs = Vec::new();
    for (index, child) in process.children.iter().enumerate() {
        if child.ns != BPMN {
            return Err(unsupported("Неверное пространство имён элемента process."));
        }
        let kind = match child.name.as_str() {
            "startEvent" => Some(NodeKind::Start),
            "endEvent" => Some(NodeKind::End),
            "task" => Some(NodeKind::Task),
            "exclusiveGateway" => Some(NodeKind::ExclusiveGateway),
            "parallelGateway" => Some(NodeKind::ParallelGateway),
            "sequenceFlow" => None,
            _ => return Err(unsupported("Этот тип BPMN-элемента не поддерживается.")),
        };
        if let Some(kind) = kind {
            child.check(BPMN, &child.name, &["id", "name"])?;
            let id = child.attr("id")?.to_owned();
            for reference in &child.children {
                if reference.ns != BPMN
                    || !matches!(reference.name.as_str(), "incoming" | "outgoing")
                    || !reference.attrs.is_empty()
                    || !reference.children.is_empty()
                {
                    return Err(unsupported(
                        "Event definitions и вложенная семантика не поддерживаются.",
                    ));
                }
                declared_refs.push((
                    id.clone(),
                    reference.name.clone(),
                    reference.text.trim().to_owned(),
                ));
            }
            model.nodes.push(ModelNode {
                id,
                kind,
                label: child.optional("name").to_owned(),
                x: (index % 8) as f64 * 170.0 + 80.0,
                y: (index / 8) as f64 * 110.0 + 80.0,
            });
        } else {
            child.check(
                BPMN,
                "sequenceFlow",
                &["id", "name", "sourceRef", "targetRef"],
            )?;
            if !child.children.is_empty() || !child.optional("name").is_empty() {
                return Err(unsupported(
                    "Условия и именованные sequenceFlow не входят в subset.",
                ));
            }
            model.flows.push(ModelFlow {
                id: child.attr("id")?.to_owned(),
                source: child.attr("sourceRef")?.to_owned(),
                target: child.attr("targetRef")?.to_owned(),
                waypoints: Vec::new(),
            });
        }
        if model.nodes.len() > MAX_NODES || model.flows.len() > MAX_FLOWS {
            return Err(limit("Лимит BPMN: 1000 узлов и 4000 переходов."));
        }
    }
    for (node, direction, reference) in declared_refs {
        if !model.flows.iter().any(|f| {
            f.id == reference
                && if direction == "incoming" {
                    f.target == node
                } else {
                    f.source == node
                }
        }) {
            return Err(invalid("incoming/outgoing не соответствует sequenceFlow."));
        }
    }
    if let Some(diagram) = diagram {
        read_diagram(diagram, &mut model)?;
    }
    validate(&model)?;
    Ok(model)
}

fn check_xml_ids(element: &Element, ids: &mut BTreeSet<String>) -> Result<(), ImportError> {
    if let Some(id) = element.attrs.get("id")
        && (!identifier(id) || !ids.insert(id.clone()))
    {
        return Err(invalid("Некорректный или повторный XML ID BPMN."));
    }
    for child in &element.children {
        check_xml_ids(child, ids)?;
    }
    Ok(())
}

fn read_diagram(diagram: &Element, model: &mut ProcessModel) -> Result<(), ImportError> {
    diagram.check(BPMNDI, "BPMNDiagram", &["id", "name"])?;
    if diagram.children.len() != 1 {
        return Err(invalid("Диаграмма требует одну BPMNPlane."));
    }
    let plane = &diagram.children[0];
    plane.check(BPMNDI, "BPMNPlane", &["id", "bpmnElement"])?;
    if plane.attr("bpmnElement")? != model.process_id {
        return Err(invalid("BPMNPlane относится к другому процессу."));
    }
    let mut seen = BTreeSet::new();
    for child in &plane.children {
        let reference = child.attr("bpmnElement")?;
        if !seen.insert(reference.to_owned()) {
            return Err(invalid("Повторный элемент диаграммы."));
        }
        match child.name.as_str() {
            "BPMNShape" => {
                child.check(BPMNDI, "BPMNShape", &["id", "bpmnElement"])?;
                let node = model
                    .nodes
                    .iter_mut()
                    .find(|n| n.id == reference)
                    .ok_or_else(|| invalid("Диаграмма ссылается на неизвестный узел."))?;
                if child.children.len() != 1 {
                    return Err(unsupported("BPMNShape поддерживает только Bounds."));
                }
                let bounds = &child.children[0];
                bounds.check(DC, "Bounds", &["x", "y", "width", "height"])?;
                if !bounds.children.is_empty() {
                    return Err(unsupported("Вложенные Bounds не поддерживаются."));
                }
                node.x = number(bounds, "x")?;
                node.y = number(bounds, "y")?;
                if number(bounds, "width")? <= 0.0 || number(bounds, "height")? <= 0.0 {
                    return Err(invalid("Размер узла должен быть положительным."));
                }
            }
            "BPMNEdge" => {
                child.check(BPMNDI, "BPMNEdge", &["id", "bpmnElement"])?;
                let flow = model
                    .flows
                    .iter_mut()
                    .find(|f| f.id == reference)
                    .ok_or_else(|| invalid("Диаграмма ссылается на неизвестный переход."))?;
                if child.children.len() < 2 || child.children.len() > 256 {
                    return Err(invalid("Переход требует от 2 до 256 точек."));
                }
                for point in &child.children {
                    point.check(DI, "waypoint", &["x", "y"])?;
                    if !point.children.is_empty() {
                        return Err(unsupported(
                            "Вложенная семантика waypoint не поддерживается.",
                        ));
                    }
                    flow.waypoints.push(Point {
                        x: number(point, "x")?,
                        y: number(point, "y")?,
                    });
                }
            }
            _ => return Err(unsupported("Этот элемент диаграммы не поддерживается.")),
        }
    }
    Ok(())
}
fn number(element: &Element, key: &str) -> Result<f64, ImportError> {
    let number = element
        .attr(key)?
        .parse::<f64>()
        .map_err(|_| invalid("Координата должна быть числом."))?;
    if !coordinate(number) {
        return Err(invalid("Координата вне допустимого диапазона."));
    }
    Ok(number)
}
fn coordinate(value: f64) -> bool {
    value.is_finite() && value.abs() <= 1_000_000.0
}
fn identifier(id: &str) -> bool {
    let mut chars = id.chars();
    id.len() <= 256
        && chars.next().is_some_and(|c| c == '_' || c.is_alphabetic())
        && chars.all(|c| c == '_' || c == '-' || c == '.' || c.is_alphanumeric())
}
fn xml_text(value: &str) -> bool {
    value.chars().all(|c| {
        matches!(c, '\t' | '\n' | '\r') || c >= '\u{20}' && c != '\u{fffe}' && c != '\u{ffff}'
    })
}

pub fn validate(model: &ProcessModel) -> Result<(), ImportError> {
    if model.schema_version != 1 {
        return Err(unsupported("Версия модели не поддерживается."));
    }
    if model.nodes.len() > MAX_NODES || model.flows.len() > MAX_FLOWS {
        return Err(limit("Лимит BPMN: 1000 узлов и 4000 переходов."));
    }
    if !identifier(&model.process_id) || model.name.len() > 4096 || !xml_text(&model.name) {
        return Err(invalid("Некорректное имя или ID процесса."));
    }
    let mut ids = BTreeSet::from([model.process_id.as_str()]);
    let mut nodes = BTreeMap::new();
    for node in &model.nodes {
        if !identifier(&node.id)
            || !ids.insert(&node.id)
            || node.label.len() > 4096
            || !xml_text(&node.label)
            || !coordinate(node.x)
            || !coordinate(node.y)
        {
            return Err(invalid(
                "Некорректный, повторный или слишком длинный узел BPMN.",
            ));
        }
        nodes.insert(node.id.as_str(), node);
    }
    let mut incoming: BTreeMap<&str, usize> = BTreeMap::new();
    let mut outgoing: BTreeMap<&str, usize> = BTreeMap::new();
    for flow in &model.flows {
        if !identifier(&flow.id)
            || !ids.insert(&flow.id)
            || !nodes.contains_key(flow.source.as_str())
            || !nodes.contains_key(flow.target.as_str())
        {
            return Err(invalid("Повторный ID или неизвестный конец перехода."));
        }
        if flow.waypoints.len() == 1
            || flow.waypoints.len() > 256
            || flow
                .waypoints
                .iter()
                .any(|p| !coordinate(p.x) || !coordinate(p.y))
        {
            return Err(invalid("Некорректные точки перехода."));
        }
        *incoming.entry(&flow.target).or_default() += 1;
        *outgoing.entry(&flow.source).or_default() += 1;
    }
    if !model.nodes.iter().any(|n| n.kind == NodeKind::Start)
        || !model.nodes.iter().any(|n| n.kind == NodeKind::End)
    {
        return Err(invalid("Модель требует начало и конец."));
    }
    for node in &model.nodes {
        let inc = incoming.get(node.id.as_str()).copied().unwrap_or(0);
        let out = outgoing.get(node.id.as_str()).copied().unwrap_or(0);
        let degree_valid = match node.kind {
            NodeKind::Start => inc == 0 && out > 0,
            NodeKind::End => inc > 0 && out == 0,
            _ => inc > 0 && out > 0,
        };
        if !degree_valid {
            return Err(invalid("Узел не имеет допустимых входов и выходов."));
        }
    }
    let reachable = walk(model, false);
    let ending = walk(model, true);
    if model
        .nodes
        .iter()
        .any(|n| !reachable.contains(n.id.as_str()) || !ending.contains(n.id.as_str()))
    {
        return Err(invalid(
            "Все узлы должны находиться на пути от начала к концу.",
        ));
    }
    if model
        .discovery
        .as_deref()
        .is_some_and(|d| d != "observed_variants_choice_v1")
    {
        return Err(unsupported("Неизвестный алгоритм discovery."));
    }
    Ok(())
}
fn walk(model: &ProcessModel, reverse: bool) -> BTreeSet<&str> {
    let mut seen = BTreeSet::new();
    let mut pending: Vec<&str> = model
        .nodes
        .iter()
        .filter(|n| {
            n.kind
                == if reverse {
                    NodeKind::End
                } else {
                    NodeKind::Start
                }
        })
        .map(|n| n.id.as_str())
        .collect();
    while let Some(id) = pending.pop() {
        if seen.insert(id) {
            for flow in &model.flows {
                if (if reverse {
                    flow.target.as_str()
                } else {
                    flow.source.as_str()
                }) == id
                {
                    pending.push(if reverse { &flow.source } else { &flow.target });
                }
            }
        }
    }
    seen
}
fn escape(value: &str) -> String {
    quick_xml::escape::escape(value)
        .replace('\n', "&#10;")
        .replace('\r', "&#13;")
        .replace('\t', "&#9;")
}
fn xml_kind(kind: NodeKind) -> &'static str {
    match kind {
        NodeKind::Start => "startEvent",
        NodeKind::End => "endEvent",
        NodeKind::Task => "task",
        NodeKind::ExclusiveGateway => "exclusiveGateway",
        NodeKind::ParallelGateway => "parallelGateway",
    }
}
fn fresh_id(base: &str, used: &mut BTreeSet<String>) -> String {
    let mut candidate = base.to_owned();
    let mut suffix = 0;
    while !used.insert(candidate.clone()) {
        suffix += 1;
        candidate = format!("{base}_{suffix}");
    }
    candidate
}

pub fn serialize(model: &ProcessModel) -> Result<String, ImportError> {
    validate(model)?;
    let mut used: BTreeSet<String> = model
        .nodes
        .iter()
        .map(|n| n.id.clone())
        .chain(model.flows.iter().map(|f| f.id.clone()))
        .chain([model.process_id.clone()])
        .collect();
    let definitions_id = fresh_id("Definitions", &mut used);
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<bpmn:definitions xmlns:bpmn=\"{BPMN}\" xmlns:bpmndi=\"{BPMNDI}\" xmlns:dc=\"{DC}\" xmlns:di=\"{DI}\" id=\"{definitions_id}\" targetNamespace=\"urn:process-intelligence:subset:v1\">\n<bpmn:process id=\"{}\" name=\"{}\" isExecutable=\"false\">\n",
        escape(&model.process_id),
        escape(&model.name)
    );
    for node in &model.nodes {
        xml.push_str(&format!(
            "<bpmn:{} id=\"{}\" name=\"{}\"/>\n",
            xml_kind(node.kind),
            escape(&node.id),
            escape(&node.label)
        ));
    }
    for flow in &model.flows {
        xml.push_str(&format!(
            "<bpmn:sequenceFlow id=\"{}\" sourceRef=\"{}\" targetRef=\"{}\"/>\n",
            escape(&flow.id),
            escape(&flow.source),
            escape(&flow.target)
        ));
    }
    let diagram_id = fresh_id("Diagram", &mut used);
    let plane_id = fresh_id("Plane", &mut used);
    xml.push_str(&format!("</bpmn:process>\n<bpmndi:BPMNDiagram id=\"{diagram_id}\"><bpmndi:BPMNPlane id=\"{plane_id}\" bpmnElement=\"{}\">\n", escape(&model.process_id)));
    for node in &model.nodes {
        let shape_id = fresh_id(&format!("{}_di", node.id), &mut used);
        let (width, height) = if node.kind == NodeKind::Task {
            (120, 70)
        } else {
            (45, 45)
        };
        xml.push_str(&format!("<bpmndi:BPMNShape id=\"{shape_id}\" bpmnElement=\"{}\"><dc:Bounds x=\"{}\" y=\"{}\" width=\"{width}\" height=\"{height}\"/></bpmndi:BPMNShape>\n", escape(&node.id), node.x, node.y));
    }
    for flow in &model.flows {
        if flow.waypoints.is_empty() {
            continue;
        }
        let edge_id = fresh_id(&format!("{}_di", flow.id), &mut used);
        xml.push_str(&format!(
            "<bpmndi:BPMNEdge id=\"{edge_id}\" bpmnElement=\"{}\">",
            escape(&flow.id)
        ));
        for point in &flow.waypoints {
            xml.push_str(&format!(
                "<di:waypoint x=\"{}\" y=\"{}\"/>",
                point.x, point.y
            ));
        }
        xml.push_str("</bpmndi:BPMNEdge>\n");
    }
    xml.push_str("</bpmndi:BPMNPlane></bpmndi:BPMNDiagram>\n</bpmn:definitions>\n");
    if xml.len() > MAX_BYTES {
        return Err(limit("Экспорт BPMN превышает 1 MiB."));
    }
    Ok(xml)
}

pub fn discover(log: &EventLog) -> Result<ProcessModel, ImportError> {
    let variants: BTreeSet<Vec<String>> = log
        .cases
        .iter()
        .map(|case| {
            case.events
                .iter()
                .map(|event| event.activity.clone())
                .collect()
        })
        .collect();
    if variants.is_empty() {
        return Err(invalid("Для построения модели нужна хотя бы одна трасса."));
    }
    let task_count = variants
        .iter()
        .try_fold(0usize, |total, v| total.checked_add(v.len()))
        .ok_or_else(|| limit("Слишком много узлов."))?;
    if task_count + 4 > MAX_NODES || task_count + variants.len() + 2 > MAX_FLOWS {
        return Err(limit(
            "Наблюдённые варианты превышают лимит модели; обрезка не выполняется.",
        ));
    }
    let mut model = ProcessModel {
        schema_version: 1,
        process_id: "ObservedVariants".into(),
        name: log
            .name
            .clone()
            .unwrap_or_else(|| "Наблюдённые варианты".into()),
        nodes: vec![
            ModelNode {
                id: "Start".into(),
                kind: NodeKind::Start,
                label: "Начало".into(),
                x: 50.0,
                y: 80.0,
            },
            ModelNode {
                id: "Choice".into(),
                kind: NodeKind::ExclusiveGateway,
                label: String::new(),
                x: 200.0,
                y: 80.0,
            },
            ModelNode {
                id: "Merge".into(),
                kind: NodeKind::ExclusiveGateway,
                label: String::new(),
                x: 400.0 + variants.iter().map(Vec::len).max().unwrap_or(0) as f64 * 170.0,
                y: 80.0,
            },
            ModelNode {
                id: "End".into(),
                kind: NodeKind::End,
                label: "Конец".into(),
                x: 550.0 + variants.iter().map(Vec::len).max().unwrap_or(0) as f64 * 170.0,
                y: 80.0,
            },
        ],
        flows: Vec::new(),
        discovery: Some("observed_variants_choice_v1".into()),
    };
    add_flow(&mut model, "Start", "Choice");
    add_flow(&mut model, "Merge", "End");
    for (variant_index, activities) in variants.into_iter().enumerate() {
        let mut previous = "Choice".to_owned();
        for (event_index, activity) in activities.into_iter().enumerate() {
            let id = format!("V{variant_index}_T{event_index}");
            model.nodes.push(ModelNode {
                id: id.clone(),
                kind: NodeKind::Task,
                label: activity,
                x: 370.0 + event_index as f64 * 170.0,
                y: 80.0 + variant_index as f64 * 110.0,
            });
            add_flow(&mut model, &previous, &id);
            previous = id;
        }
        add_flow(&mut model, &previous, "Merge");
    }
    validate(&model)?;
    Ok(model)
}
fn add_flow(model: &mut ProcessModel, source: &str, target: &str) {
    model.flows.push(ModelFlow {
        id: format!("Flow{}", model.flows.len()),
        source: source.into(),
        target: target.into(),
        waypoints: Vec::new(),
    });
}
