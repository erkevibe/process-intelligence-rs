use super::{Converted, Failure, Result, require, xml, xml_chars};
use process_mining::{
    PetriNet,
    core::process_models::case_centric::petri_net::pnml::{
        export_petri_net_to_pnml, import_pnml_reader,
    },
};
use serde::{
    Deserialize, Deserializer,
    de::{MapAccess, SeqAccess, Visitor},
};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    io::Cursor,
};
use uuid::Uuid;
#[derive(Clone, Debug, serde::Serialize, PartialEq, Eq)]
pub struct Node {
    pub id: String,
    pub kind: String,
    pub label: Option<String>,
}
#[derive(Clone, Debug, serde::Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Edge {
    pub source: String,
    pub target: String,
    pub weight: u32,
}
pub type Marking = BTreeMap<String, u64>;
#[derive(Clone, Debug, serde::Serialize, PartialEq, Eq)]
pub struct Graph {
    pub nodes: BTreeMap<String, Node>,
    pub arcs: Vec<Edge>,
    pub initial: Option<Marking>,
    pub finals: Option<Vec<Marking>>,
}
// serde_json::Value alone overwrites duplicate object keys; this visitor refuses them first.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("JSON without duplicate keys")
            }
            fn visit_unit<E: serde::de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_bool<E: serde::de::Error>(self, v: bool) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_i64<E: serde::de::Error>(self, v: i64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_u64<E: serde::de::Error>(self, v: u64) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_f64<E: serde::de::Error>(self, v: f64) -> std::result::Result<Unique, E> {
                serde_json::Number::from_f64(v)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("nonfinite_json_number"))
            }
            fn visit_str<E: serde::de::Error>(self, v: &str) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_string<E: serde::de::Error>(
                self,
                v: String,
            ) -> std::result::Result<Unique, E> {
                Ok(Unique(json!(v)))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut rows = Vec::new();
                while let Some(v) = seq.next_element::<Unique>()? {
                    rows.push(v.0);
                }
                Ok(Unique(Value::Array(rows)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut result = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if result.contains_key(&key) {
                        return Err(serde::de::Error::custom("duplicate_json_key"));
                    }
                    result.insert(key, map.next_value::<Unique>()?.0);
                }
                Ok(Unique(Value::Object(result)))
            }
        }
        deserializer.deserialize_any(V)
    }
}
fn depth(value: &Value, level: usize) -> Result<()> {
    require(level <= 32, "json_depth_limit")?;
    match value {
        Value::Array(rows) => {
            for row in rows {
                depth(row, level + 1)?;
            }
        }
        Value::Object(rows) => {
            for row in rows.values() {
                depth(row, level + 1)?;
            }
        }
        _ => {}
    }
    Ok(())
}
fn object<'a>(value: &'a Value, keys: &[&str]) -> Result<&'a serde_json::Map<String, Value>> {
    let map = value
        .as_object()
        .ok_or_else(|| Failure::new("json_object_required"))?;
    require(
        map.keys().all(|key| keys.contains(&key.as_str())),
        "unknown_json_field",
    )?;
    require(
        keys.iter().all(|key| map.contains_key(*key)),
        "missing_json_field",
    )?;
    Ok(map)
}
fn string(value: &Value) -> Result<&str> {
    value
        .as_str()
        .ok_or_else(|| Failure::new("json_string_required"))
}
fn uuid(value: &str) -> Result<String> {
    Uuid::parse_str(value)
        .map(|id| id.to_string())
        .map_err(|_| Failure::new("invalid_uuid"))
}
fn label(value: Option<&str>) -> Result<Option<String>> {
    value
        .map(|v| {
            require(
                !v.is_empty()
                    && v.trim() == v
                    && !v.contains(['\r', '\n'])
                    && v.len() <= 4096
                    && xml_chars(v),
                "trim_sensitive_label",
            )?;
            Ok(v.to_owned())
        })
        .transpose()
}
fn marking(value: &Value, places: &BTreeSet<String>) -> Result<Marking> {
    let mut result = BTreeMap::new();
    for (id, n) in value
        .as_object()
        .ok_or_else(|| Failure::new("invalid_marking"))?
    {
        let id = uuid(id)?;
        require(places.contains(&id), "dangling_marking")?;
        let n = n
            .as_u64()
            .ok_or_else(|| Failure::new("invalid_marking_number"))?;
        require(result.insert(id, n).is_none(), "duplicate_marking_entry")?;
    }
    Ok(result)
}
fn from_value(value: &Value) -> Result<Graph> {
    object(
        value,
        &[
            "places",
            "transitions",
            "arcs",
            "initial_marking",
            "final_markings",
        ],
    )?;
    let mut nodes = BTreeMap::new();
    let mut places = BTreeSet::new();
    for kind in ["places", "transitions"] {
        for (id, node) in value[kind]
            .as_object()
            .ok_or_else(|| Failure::new("json_object_required"))?
        {
            object(
                node,
                if kind == "places" {
                    &["id"]
                } else {
                    &["id", "label"]
                },
            )?;
            let normalized = uuid(id)?;
            require(
                normalized == uuid(string(&node["id"])?)?,
                "node_id_mismatch",
            )?;
            let label = if kind == "places" {
                places.insert(normalized.clone());
                None
            } else if node["label"].is_null() {
                None
            } else {
                label(Some(string(&node["label"])?))?
            };
            require(
                nodes
                    .insert(
                        normalized.clone(),
                        Node {
                            id: normalized,
                            kind: if kind == "places" {
                                "place"
                            } else {
                                "transition"
                            }
                            .into(),
                            label,
                        },
                    )
                    .is_none(),
                "duplicate_node_id",
            )?;
        }
    }
    let mut arcs = Vec::new();
    let mut seen = BTreeSet::new();
    for arc in value["arcs"]
        .as_array()
        .ok_or_else(|| Failure::new("json_array_required"))?
    {
        object(arc, &["from_to", "weight"])?;
        object(&arc["from_to"], &["type", "nodes"])?;
        let ids = arc["from_to"]["nodes"]
            .as_array()
            .ok_or_else(|| Failure::new("invalid_arc"))?;
        require(ids.len() == 2, "invalid_arc")?;
        let source = uuid(string(&ids[0])?)?;
        let target = uuid(string(&ids[1])?)?;
        let first = nodes
            .get(&source)
            .ok_or_else(|| Failure::new("dangling_arc"))?;
        let last = nodes
            .get(&target)
            .ok_or_else(|| Failure::new("dangling_arc"))?;
        let expected = match (first.kind.as_str(), last.kind.as_str()) {
            ("place", "transition") => "PlaceTransition",
            ("transition", "place") => "TransitionPlace",
            _ => return Err(Failure::new("invalid_arc_partitions")),
        };
        require(arc["from_to"]["type"] == expected, "invalid_arc_partitions")?;
        let weight = arc["weight"]
            .as_u64()
            .filter(|n| *n > 0 && *n <= u32::MAX as u64)
            .ok_or_else(|| Failure::new("invalid_arc_weight"))? as u32;
        require(
            seen.insert((source.clone(), target.clone())),
            "duplicate_arc_endpoints",
        )?;
        arcs.push(Edge {
            source,
            target,
            weight,
        });
    }
    let initial = if value["initial_marking"].is_null() {
        None
    } else {
        let m = marking(&value["initial_marking"], &places)?;
        require(!m.is_empty(), "empty_initial_marking")?;
        Some(m)
    };
    let finals = if value["final_markings"].is_null() {
        None
    } else {
        let rows = value["final_markings"]
            .as_array()
            .ok_or_else(|| Failure::new("invalid_marking"))?;
        require(!rows.is_empty(), "empty_final_markings")?;
        Some(
            rows.iter()
                .map(|v| marking(v, &places))
                .collect::<Result<Vec<_>>>()?,
        )
    };
    arcs.sort();
    let graph = Graph {
        nodes,
        arcs,
        initial,
        finals,
    };
    bounds(&graph)?;
    Ok(graph)
}
fn bounds(graph: &Graph) -> Result<()> {
    let places = graph.nodes.values().filter(|n| n.kind == "place").count();
    require(
        (1..=128).contains(&places)
            && graph.nodes.len() - places <= 128
            && graph.nodes.len() <= 256
            && graph.arcs.len() <= 1024
            && graph.finals.as_ref().is_none_or(|v| v.len() <= 32),
        "net_size_limit",
    )
}
pub fn json_graph(input: &[u8]) -> Result<(PetriNet, Graph)> {
    let unique: Unique = serde_json::from_slice(input).map_err(|e| {
        Failure::new(if e.to_string().contains("duplicate_json_key") {
            "duplicate_json_key"
        } else {
            "invalid_json"
        })
    })?;
    depth(&unique.0, 0)?;
    let graph = from_value(&unique.0)?;
    let net: PetriNet =
        serde_json::from_value(unique.0).map_err(|_| Failure::new("native_petri_json_refused"))?;
    let actual = from_value(
        &serde_json::to_value(&net).map_err(|_| Failure::new("native_petri_json_serialization"))?,
    )?;
    require(actual == graph, "native_json_semantic_conservation")?;
    Ok((net, graph))
}
fn numeric(text: &str, max: u64, reason: &str) -> Result<u64> {
    require(
        !text.is_empty()
            && (text == "0" || !text.starts_with('0'))
            && text.bytes().all(|b| b.is_ascii_digit()),
        reason,
    )?;
    let n = text.parse::<u64>().map_err(|_| Failure::new(reason))?;
    require(n <= max, reason)?;
    Ok(n)
}
fn leaf_text(node: &xml::Node) -> Result<&str> {
    node.attrs_only(&[])?;
    require(node.children.is_empty(), "unsupported_pnml_construct")?;
    Ok(&node.text)
}
fn wrapped_text(node: &xml::Node) -> Result<&str> {
    node.attrs_only(&[])?;
    node.structural()?;
    require(
        node.children.len() == 1 && node.children[0].name == "text",
        "unsupported_pnml_construct",
    )?;
    leaf_text(&node.children[0])
}
fn xml_id(node: &xml::Node, key: &str) -> Result<String> {
    let id = node.attr(key)?;
    require(
        !id.is_empty()
            && id.len() <= 4096
            && id.trim() == id
            && !id.chars().any(char::is_whitespace),
        "invalid_pnml_id",
    )?;
    Ok(id.to_owned())
}
pub fn pnml_graph(input: &[u8]) -> Result<Graph> {
    let root = xml::parse(input)?;
    require(root.name == "pnml", "unsupported_pnml_construct")?;
    root.attrs_only(&[])?;
    root.structural()?;
    require(
        root.children.len() == 1 && root.children[0].name == "net",
        "unsupported_pnml_construct",
    )?;
    let net = &root.children[0];
    net.attrs_only(&["id", "type"])?;
    net.structural()?;
    let net_id = net.attr("id")?;
    require(
        !net_id.is_empty() && net_id.len() <= 4096,
        "invalid_pnml_id",
    )?;
    require(
        net.attr("type")? == "http://www.pnml.org/version-2009/grammar/pnmlcoremodel",
        "unsupported_pnml_construct",
    )?;
    let pages: Vec<_> = net.children.iter().filter(|n| n.name == "page").collect();
    require(pages.len() == 1, "unsupported_pnml_construct")?;
    require(
        net.children
            .iter()
            .all(|n| matches!(n.name.as_str(), "page" | "finalmarkings")),
        "unsupported_pnml_construct",
    )?;
    let page = pages[0];
    page.attrs_only(&["id"])?;
    page.structural()?;
    let _ = xml_id(page, "id")?;
    let mut nodes = BTreeMap::new();
    let mut initial = BTreeMap::new();
    let mut all_ids = BTreeSet::new();
    all_ids.insert(net.attr("id")?.to_owned());
    require(
        all_ids.insert(page.attr("id")?.to_owned()),
        "duplicate_xml_id",
    )?;
    for node in &page.children {
        if node.name == "arc" {
            continue;
        }
        require(
            matches!(node.name.as_str(), "place" | "transition"),
            "unsupported_pnml_construct",
        )?;
        node.attrs_only(&["id"])?;
        node.structural()?;
        let id = xml_id(node, "id")?;
        require(all_ids.insert(id.clone()), "duplicate_xml_id")?;
        let names: Vec<_> = node.children.iter().filter(|n| n.name == "name").collect();
        require(names.len() <= 1, "unsupported_pnml_construct")?;
        let name = names.first().map(|n| wrapped_text(n)).transpose()?;
        let mut node_label = None;
        if node.name == "place" {
            require(
                node.children
                    .iter()
                    .all(|n| matches!(n.name.as_str(), "name" | "initialMarking")),
                "unsupported_pnml_construct",
            )?;
            if let Some(name) = name {
                require(name == id, "unsupported_place_name")?;
            }
            let markings: Vec<_> = node
                .children
                .iter()
                .filter(|n| n.name == "initialMarking")
                .collect();
            require(markings.len() <= 1, "duplicate_marking_entry")?;
            if let Some(marking) = markings.first() {
                initial.insert(
                    id.clone(),
                    numeric(wrapped_text(marking)?, u64::MAX, "invalid_marking_number")?,
                );
            }
        } else {
            require(
                node.children
                    .iter()
                    .all(|n| matches!(n.name.as_str(), "name" | "toolspecific")),
                "unsupported_pnml_construct",
            )?;
            let markers: Vec<_> = node
                .children
                .iter()
                .filter(|n| n.name == "toolspecific")
                .collect();
            require(markers.len() <= 1, "unsupported_pnml_construct")?;
            if let Some(marker) = markers.first() {
                marker.attrs_only(&["tool", "version", "activity", "localNodeID"])?;
                marker.structural()?;
                require(
                    marker.children.is_empty()
                        && marker.attr("tool")? == "ProM"
                        && marker.attr("version")? == "6.4"
                        && marker.attr("activity")? == "$invisible$"
                        && Uuid::parse_str(marker.attr("localNodeID")?).is_ok()
                        && name == Some("Tau"),
                    "unsupported_pnml_construct",
                )?;
            } else {
                node_label = label(Some(
                    name.ok_or_else(|| Failure::new("missing_transition_label"))?,
                ))?;
            }
        }
        require(
            nodes
                .insert(
                    id.clone(),
                    Node {
                        id,
                        kind: node.name.clone(),
                        label: node_label,
                    },
                )
                .is_none(),
            "duplicate_xml_id",
        )?;
    }
    let mut arcs = Vec::new();
    let mut pairs = BTreeSet::new();
    for node in page.children.iter().filter(|n| n.name == "arc") {
        node.attrs_only(&["id", "source", "target"])?;
        node.structural()?;
        require(all_ids.insert(xml_id(node, "id")?), "duplicate_xml_id")?;
        let source = xml_id(node, "source")?;
        let target = xml_id(node, "target")?;
        let first = nodes
            .get(&source)
            .ok_or_else(|| Failure::new("dangling_arc"))?;
        let last = nodes
            .get(&target)
            .ok_or_else(|| Failure::new("dangling_arc"))?;
        require(first.kind != last.kind, "invalid_arc_partitions")?;
        require(
            node.children.len() == 1 && node.children[0].name == "inscription",
            "missing_arc_weight",
        )?;
        let weight = numeric(
            wrapped_text(&node.children[0])?,
            u32::MAX as u64,
            "invalid_arc_weight",
        )?;
        require(weight > 0, "invalid_arc_weight")?;
        require(
            pairs.insert((source.clone(), target.clone())),
            "duplicate_arc_endpoints",
        )?;
        arcs.push(Edge {
            source,
            target,
            weight: weight as u32,
        });
    }
    let final_nodes: Vec<_> = net
        .children
        .iter()
        .filter(|n| n.name == "finalmarkings")
        .collect();
    require(final_nodes.len() <= 1, "unsupported_pnml_construct")?;
    let finals = if let Some(group) = final_nodes.first() {
        group.attrs_only(&[])?;
        group.structural()?;
        require(!group.children.is_empty(), "empty_final_markings")?;
        let mut rows = Vec::new();
        for marking in &group.children {
            require(marking.name == "marking", "unsupported_pnml_construct")?;
            marking.attrs_only(&[])?;
            marking.structural()?;
            let mut row = BTreeMap::new();
            for entry in &marking.children {
                require(entry.name == "place", "unsupported_pnml_construct")?;
                entry.attrs_only(&["idref"])?;
                entry.structural()?;
                let id = xml_id(entry, "idref")?;
                require(
                    nodes.get(&id).is_some_and(|n| n.kind == "place"),
                    "dangling_marking",
                )?;
                require(
                    entry.children.len() == 1 && entry.children[0].name == "text",
                    "invalid_marking_number",
                )?;
                let n = numeric(
                    leaf_text(&entry.children[0])?,
                    u64::MAX,
                    "invalid_marking_number",
                )?;
                require(row.insert(id, n).is_none(), "duplicate_marking_entry")?;
            }
            rows.push(row);
        }
        Some(rows)
    } else {
        None
    };
    arcs.sort();
    let graph = Graph {
        nodes,
        arcs,
        initial: (!initial.is_empty()).then_some(initial),
        finals,
    };
    bounds(&graph)?;
    Ok(graph)
}
fn signature(graph: &Graph, id: &str) -> Value {
    let node = &graph.nodes[id];
    let incoming: Vec<_> = graph
        .arcs
        .iter()
        .filter(|e| e.target == id)
        .map(|e| e.weight)
        .collect();
    let outgoing: Vec<_> = graph
        .arcs
        .iter()
        .filter(|e| e.source == id)
        .map(|e| e.weight)
        .collect();
    let mut incoming = incoming;
    let mut outgoing = outgoing;
    incoming.sort_unstable();
    outgoing.sort_unstable();
    json!({"kind":node.kind,"label":node.label,"incoming":incoming,"outgoing":outgoing,"initial":graph.initial.as_ref().map(|m|m.get(id)),"finals":graph.finals.as_ref().map(|rows|rows.iter().map(|m|m.get(id)).collect::<Vec<_>>())})
}
fn renamed_marking(marking: &Marking, map: &BTreeMap<String, String>) -> Marking {
    marking
        .iter()
        .map(|(id, n)| (map[id].clone(), *n))
        .collect()
}
pub fn verify_map(source: &Graph, target: &Graph, map: &BTreeMap<String, String>) -> bool {
    if source.nodes.len() != target.nodes.len()
        || map.len() != source.nodes.len()
        || map.values().collect::<BTreeSet<_>>().len() != map.len()
    {
        return false;
    }
    for (id, node) in &source.nodes {
        let Some(mapped) = map.get(id) else {
            return false;
        };
        let Some(other) = target.nodes.get(mapped) else {
            return false;
        };
        if node.kind != other.kind || node.label != other.label {
            return false;
        }
    }
    let mut arcs: Vec<_> = source
        .arcs
        .iter()
        .map(|e| Edge {
            source: map[&e.source].clone(),
            target: map[&e.target].clone(),
            weight: e.weight,
        })
        .collect();
    arcs.sort();
    arcs == target.arcs
        && source.initial.as_ref().map(|m| renamed_marking(m, map)) == target.initial
        && source.finals.as_ref().map(|rows| {
            rows.iter()
                .map(|m| renamed_marking(m, map))
                .collect::<Vec<_>>()
        }) == target.finals
}
pub fn bijection(source: &Graph, target: &Graph) -> Result<(BTreeMap<String, String>, u64)> {
    require(
        source.nodes.len() == target.nodes.len() && source.arcs.len() == target.arcs.len(),
        "net_conservation_failed",
    )?;
    let mut candidates = Vec::new();
    for id in source.nodes.keys() {
        let sig = signature(source, id);
        let matches: Vec<String> = target
            .nodes
            .keys()
            .filter(|other| signature(target, other) == sig)
            .cloned()
            .collect();
        require(!matches.is_empty(), "net_conservation_failed")?;
        candidates.push((id.clone(), matches));
    }
    candidates.sort_by_key(|(id, rows)| (rows.len(), id.clone()));
    struct Search<'a> {
        source: &'a Graph,
        target: &'a Graph,
        candidates: &'a [(String, Vec<String>)],
        visited: u64,
    }
    impl Search<'_> {
        fn walk(
            &mut self,
            index: usize,
            map: &mut BTreeMap<String, String>,
            used: &mut BTreeSet<String>,
        ) -> Result<bool> {
            if index == self.candidates.len() {
                return Ok(verify_map(self.source, self.target, map));
            }
            let (id, rows) = &self.candidates[index];
            let id = id.clone();
            let rows = rows.clone();
            for other in rows {
                if used.contains(&other) {
                    continue;
                }
                self.visited += 1;
                if self.visited > 100000 {
                    return Err(Failure::inconclusive("bijection_search_budget"));
                }
                map.insert(id.clone(), other.clone());
                used.insert(other.clone());
                let compatible = self.source.arcs.iter().all(|edge| {
                    if let (Some(from), Some(to)) = (map.get(&edge.source), map.get(&edge.target)) {
                        self.target.arcs.iter().any(|e| {
                            &e.source == from && &e.target == to && e.weight == edge.weight
                        })
                    } else {
                        true
                    }
                });
                if compatible && self.walk(index + 1, map, used)? {
                    return Ok(true);
                }
                map.remove(&id);
                used.remove(&other);
            }
            Ok(false)
        }
    }
    let mut search = Search {
        source,
        target,
        candidates: &candidates,
        visited: 0,
    };
    let mut map = BTreeMap::new();
    require(
        search.walk(0, &mut map, &mut BTreeSet::new())?,
        "net_conservation_failed",
    )?;
    Ok((map, search.visited))
}
fn xml_locator(path: &str, attribute: Option<&str>) -> Value {
    let mut locator = json!({"syntax":"xml","path":path});
    if let Some(attribute) = attribute {
        locator["attribute"] = json!(attribute);
    }
    locator
}
fn pointer(value: &str) -> String {
    value.replace('~', "~0").replace('/', "~1")
}
type NodeLocations = BTreeMap<String, (Value, String)>;
fn json_node_locations(input: &[u8]) -> Result<NodeLocations> {
    // Called only after the strict duplicate-key/schema preflight accepted these bytes.
    let value: Value =
        serde_json::from_slice(input).map_err(|_| Failure::new("normalization_json_binding"))?;
    let mut result = BTreeMap::new();
    for group in ["places", "transitions"] {
        for (key, node) in value[group]
            .as_object()
            .ok_or_else(|| Failure::new("normalization_json_binding"))?
        {
            let actual = string(&node["id"])?;
            result.insert(
                uuid(key)?,
                (
                    json!({"syntax":"json","path":format!("/{group}/{}/id",pointer(key))}),
                    actual.to_owned(),
                ),
            );
        }
    }
    Ok(result)
}
fn xml_inventory(input: &[u8], side: &str) -> Result<(Vec<Value>, NodeLocations)> {
    let root = xml::parse(input)?;
    let mut entries = Vec::new();
    let mut locations = BTreeMap::new();
    fn walk(
        node: &xml::Node,
        parent: Option<&str>,
        grandparent: Option<&str>,
        path: &str,
        side: &str,
        entries: &mut Vec<Value>,
        locations: &mut NodeLocations,
    ) -> Result<()> {
        let field = match (node.name.as_str(), parent) {
            ("net", Some("pnml")) => Some(("net_id", Some("id"))),
            ("page", Some("net")) => Some(("page_id", Some("id"))),
            ("arc", Some("page")) => Some(("arc_id", Some("id"))),
            ("toolspecific", Some("transition")) => {
                Some(("tau_local_node_id", Some("localNodeID")))
            }
            ("text", Some("name")) if grandparent == Some("place") => {
                Some(("place_display_name", None))
            }
            _ => None,
        };
        if let Some((kind, attribute)) = field {
            let actual = match attribute {
                Some(key) => node.attr(key)?.to_owned(),
                None => node.text.clone(),
            };
            let (original, normalized, action) = if side == "source" {
                (Some(actual), None, "omitted_format_field")
            } else {
                (None, Some(actual), "generated_format_field")
            };
            entries.push(json!({"kind":kind,"side":side,
                "locator":xml_locator(path,attribute),
                "original_value":original,"normalized_value":normalized,
                "action":action}));
        }
        if parent == Some("page") && matches!(node.name.as_str(), "place" | "transition") {
            let id = node.attr("id")?.to_owned();
            require(
                locations
                    .insert(id.clone(), (xml_locator(path, Some("id")), id))
                    .is_none(),
                "normalization_node_locator_duplicate",
            )?;
        }
        let mut siblings: BTreeMap<&str, usize> = BTreeMap::new();
        for child in &node.children {
            let index = siblings.entry(&child.name).or_default();
            let child_path = format!("{path}/{}[{}]", child.name, *index);
            *index += 1;
            walk(
                child,
                Some(&node.name),
                parent,
                &child_path,
                side,
                entries,
                locations,
            )?;
        }
        Ok(())
    }
    walk(
        &root,
        None,
        None,
        "/pnml",
        side,
        &mut entries,
        &mut locations,
    )?;
    Ok((entries, locations))
}
fn normalization_inventory(
    from: &str,
    input: &[u8],
    output: &[u8],
    map: &BTreeMap<String, String>,
) -> Result<Value> {
    let (mut entries, source_locations, target_locations) = if from == "petri-json" {
        let (entries, target) = xml_inventory(output, "target")?;
        (entries, json_node_locations(input)?, target)
    } else {
        let (entries, source) = xml_inventory(input, "source")?;
        (entries, source, json_node_locations(output)?)
    };
    require(
        source_locations.len() == map.len() && target_locations.len() == map.len(),
        "normalization_full_locator_bijection",
    )?;
    for (source, target) in map {
        let (source_locator, original) = source_locations
            .get(source)
            .ok_or_else(|| Failure::new("normalization_source_locator"))?;
        let (target_locator, normalized) = target_locations
            .get(target)
            .ok_or_else(|| Failure::new("normalization_target_locator"))?;
        entries.push(json!({"kind":"node_id_bijection","side":"source_to_target",
            "locator":source_locator,"counterpart_locator":target_locator,
            "original_value":original,"normalized_value":normalized,
            "source_graph_id":source,"target_graph_id":target,
            "changed":original!=normalized,
            "action":if original==normalized{"identity_mapping"}else{"verified_id_renaming"}}));
    }
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for entry in &entries {
        *counts
            .entry(string(&entry["kind"])?.to_owned())
            .or_default() += 1;
    }
    Ok(
        json!({"schema_version":1,"xml_path_indexing":"zero_based_siblings_per_element_name",
        "json_pointer_escaping":"RFC6901 ~0 and ~1",
        "value_scope":"actual decoded XML attribute/text or JSON string values; exact lexical bytes remain SHA-bound payloads",
        "entry_count":entries.len(),"counts":counts,"entries":entries}),
    )
}
pub fn convert(from: &str, input: &[u8]) -> Result<Converted> {
    if from == "petri-json" {
        let (net, source) = json_graph(input)?;
        let mut payload = Vec::new();
        export_petri_net_to_pnml(&net, &mut payload)
            .map_err(|_| Failure::new("upstream_pnml_export_refused"))?;
        let target = pnml_graph(&payload)?;
        let map: BTreeMap<_, _> = source
            .nodes
            .keys()
            .map(|id| (id.clone(), id.clone()))
            .collect();
        require(
            verify_map(&source, &target, &map),
            "export_full_graph_conservation",
        )?;
        let inventory = normalization_inventory(from, input, &payload, &map)?;
        let kinds: Vec<_> = inventory["counts"]
            .as_object()
            .expect("inventory_counts")
            .keys()
            .collect();
        Ok(Converted {
            payload,
            extension: "pnml",
            evidence: json!({"profile":"process_mining_0.6.2_native-json-pnml-v1","source_graph":source,"target_graph":target,"node_bijection":map,"bijection_partial_assignments":0,"metadata_loss_count":0,"normalizations":kinds,"normalization_inventory":inventory,"actual_upstream_api":"export_petri_net_to_pnml","actual_inverse_conversion_not_claimed":true}),
        })
    } else {
        let source = pnml_graph(input)?;
        let net = import_pnml_reader(&mut Cursor::new(input)).map_err(|e| {
            Failure::new("upstream_pnml_import_refused")
                .detail(json!({"original_error":e.to_string()}))
        })?;
        let payload = serde_json::to_vec_pretty(&net)
            .map_err(|_| Failure::new("native_petri_json_serialization"))?;
        let (_, target) = json_graph(&payload)?;
        let (map, visited) = bijection(&source, &target)?;
        let inventory = normalization_inventory(from, input, &payload, &map)?;
        let kinds: Vec<_> = inventory["counts"]
            .as_object()
            .expect("inventory_counts")
            .keys()
            .collect();
        Ok(Converted {
            payload,
            extension: "json",
            evidence: json!({"profile":"process_mining_0.6.2_native-json-pnml-v1","source_graph":source,"target_graph":target,"node_bijection":map,"bijection_partial_assignments":visited,"metadata_loss_count":0,"normalizations":kinds,"normalization_inventory":inventory,"actual_upstream_api":"import_pnml_reader","actual_inverse_conversion_not_claimed":true}),
        })
    }
}
