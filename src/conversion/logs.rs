use super::{Converted, Failure, Result, require, xml, xml_chars};
use crate::{
    csv_io::{self, CsvMapping, NormalizationOrder},
    domain::EventLog,
    event_io,
};
use chrono::{DateTime, SecondsFormat, Utc};
use quick_xml::{
    Writer,
    events::{BytesEnd, BytesStart, Event},
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
struct CoreEvent {
    activity: String,
    timestamp: Option<String>,
    lifecycle: Option<String>,
}
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
struct CoreTrace {
    name: String,
    events: Vec<CoreEvent>,
}
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
struct Core {
    traces: Vec<CoreTrace>,
}
#[derive(Default)]
struct Inventory {
    losses: Vec<Value>,
    normalizations: Vec<Value>,
    metadata_policy_required: bool,
    format_declarations: Value,
}
fn utc_shortest(value: DateTime<Utc>) -> String {
    let mut encoded = value.to_rfc3339_opts(SecondsFormat::AutoSi, true);
    if let Some(point) = encoded.rfind('.') {
        let mut end = encoded.len() - 1;
        while end > point + 1 && encoded.as_bytes()[end - 1] == b'0' {
            end -= 1;
        }
        if end == point + 1 {
            end = point;
        }
        encoded.truncate(end);
        encoded.push('Z');
    }
    encoded
}
fn timestamp(value: &str, where_: Value, inventory: &mut Inventory) -> Result<String> {
    super::check_cancelled()?;
    // Chrono can accept additional fractional digits; reject before that parser.
    let time = value
        .split('T')
        .nth(1)
        .ok_or_else(|| Failure::new("invalid_timestamp"))?;
    if let Some((_, fraction)) = time.split_once('.') {
        let digits = fraction.bytes().take_while(u8::is_ascii_digit).count();
        require((1..=9).contains(&digits), "timestamp_precision")?;
    }
    require(time.get(6..8) != Some("60"), "invalid_timestamp")?;
    let parsed =
        DateTime::parse_from_rfc3339(value).map_err(|_| Failure::new("invalid_timestamp"))?;
    let normalized = utc_shortest(parsed.with_timezone(&Utc));
    if parsed.offset().local_minus_utc() != 0 {
        inventory.losses.push(json!({"kind":"timestamp_offset","location":where_,"original":value,"offset_seconds":parsed.offset().local_minus_utc(),"normalized":normalized}));
    } else if normalized != value {
        inventory.normalizations.push(json!({"kind":"timestamp_lexical","location":where_,"original":value,"normalized":normalized}));
    }
    Ok(normalized)
}
fn actual_core(log: &EventLog) -> Result<Core> {
    super::check_cancelled()?;
    let mut traces = Vec::new();
    for case in &log.cases {
        super::check_cancelled()?;
        let name = case
            .name
            .clone()
            .ok_or_else(|| Failure::new("trace_identity_missing"))?;
        traces.push(CoreTrace {
            name,
            events: case
                .events
                .iter()
                .map(|event| {
                    super::check_cancelled()?;
                    Ok(CoreEvent {
                        activity: event.activity.clone(),
                        timestamp: event.timestamp.map(utc_shortest),
                        lifecycle: event.lifecycle.clone(),
                    })
                })
                .collect::<Result<Vec<_>>>()?,
        });
    }
    Ok(Core { traces })
}
fn scalar(node: &xml::Node) -> Result<()> {
    super::check_cancelled()?;
    node.attrs_only(&["key", "value"])?;
    require(
        node.children.is_empty() && node.text.trim().is_empty(),
        "unsupported_xes_construct",
    )?;
    let _ = node.attr("key")?;
    let value = node.attr("value")?;
    let valid = match node.name.as_str() {
        "string" => true,
        "int" => value.parse::<i64>().is_ok(),
        "float" => value.parse::<f64>().is_ok_and(f64::is_finite),
        "boolean" => matches!(value, "true" | "false"),
        "date" => {
            let mut ignored = Inventory::default();
            timestamp(value, json!({"byte_offset":node.offset}), &mut ignored).is_ok()
        }
        _ => false,
    };
    require(valid, "invalid_scalar_metadata")
}
fn xes_scope(
    node: &xml::Node,
    scope: &str,
    trace: Option<usize>,
    event: Option<usize>,
    inventory: &mut Inventory,
) -> Result<BTreeMap<String, (String, String)>> {
    let mut fields = BTreeMap::new();
    for child in &node.children {
        super::check_cancelled()?;
        if matches!(child.name.as_str(), "trace" | "event") {
            continue;
        }
        if child.name == "global" {
            return Err(Failure::new("global_defaults_unsupported"));
        }
        if scope == "log" && matches!(child.name.as_str(), "extension" | "classifier") {
            child.structural()?;
            require(child.children.is_empty(), "unsupported_xes_construct")?;
            let fields = if child.name == "extension" {
                &["name", "prefix", "uri"][..]
            } else {
                &["name", "keys"][..]
            };
            child.attrs_only(fields)?;
            for key in fields {
                super::check_cancelled()?;
                require(!child.attr(key)?.is_empty(), "unsupported_xes_construct")?;
            }
            inventory.losses.push(json!({"kind":format!("{}_declaration",child.name),"location":{"byte_offset":child.offset},"attributes":child.attrs}));
            continue;
        }
        if scope == "event"
            && child
                .attrs
                .get("key")
                .is_some_and(|key| key == "time:timestamp")
        {
            child.attrs_only(&["key", "value"])?;
            require(
                child.children.is_empty() && child.text.trim().is_empty(),
                "unsupported_xes_construct",
            )?;
        } else {
            scalar(child)?;
        }
        let key = child.attr("key")?;
        let value = child.attr("value")?;
        require(!key.is_empty(), "invalid_scalar_metadata")?;
        require(
            fields
                .insert(key.to_owned(), (child.name.clone(), value.to_owned()))
                .is_none(),
            "duplicate_attribute_key",
        )?;
        let core = match scope {
            "trace" => key == "concept:name",
            "event" => matches!(
                key,
                "concept:name" | "time:timestamp" | "lifecycle:transition"
            ),
            _ => false,
        };
        if !core {
            inventory.losses.push(json!({"kind":"xes_scalar","scope":scope,"trace":trace,"event":event,"key":key,"type":child.name,"value":value,"location":{"byte_offset":child.offset}}));
        }
    }
    Ok(fields)
}
fn xes(input: &[u8], inventory: &mut Inventory) -> Result<(EventLog, Core)> {
    super::check_cancelled()?;
    let root = xml::parse(input)?;
    require(root.name == "log", "xes_log_required")?;
    root.attrs_only(&["xmlns", "xes.version"])?;
    root.structural()?;
    if let Some(ns) = root.attrs.get("xmlns") {
        require(
            ns == "http://www.xes-standard.org/",
            "unsupported_xml_namespace",
        )?;
    }
    if let Some(version) = root.attrs.get("xes.version") {
        require(version == "1.0", "unsupported_xes_version")?;
    }
    inventory.format_declarations = json!({"format":"xes","xes.version":{"present":root.attrs.contains_key("xes.version"),"value":root.attrs.get("xes.version")},"xmlns":{"present":root.attrs.contains_key("xmlns"),"value":root.attrs.get("xmlns")}});
    let _ = xes_scope(&root, "log", None, None, inventory)?;
    let mut traces = Vec::new();
    let mut seen = BTreeSet::new();
    let mut events = 0_usize;
    for node in root.children.iter().filter(|node| node.name == "trace") {
        super::check_cancelled()?;
        require(traces.len() < 20000, "case_limit")?;
        node.attrs_only(&[])?;
        node.structural()?;
        require(
            node.children.iter().all(|n| n.name != "trace"),
            "unsupported_xes_construct",
        )?;
        let trace_index = traces.len();
        let fields = xes_scope(node, "trace", Some(trace_index), None, inventory)?;
        let (kind, name) = fields
            .get("concept:name")
            .ok_or_else(|| Failure::new("trace_identity_missing"))?;
        require(
            kind == "string" && !name.is_empty(),
            "trace_identity_missing",
        )?;
        require(seen.insert(name.clone()), "trace_identity_duplicate")?;
        let mut trace = CoreTrace {
            name: name.clone(),
            events: Vec::new(),
        };
        for event in node.children.iter().filter(|n| n.name == "event") {
            super::check_cancelled()?;
            events += 1;
            require(events <= 100000, "event_limit")?;
            event.attrs_only(&[])?;
            event.structural()?;
            require(
                event
                    .children
                    .iter()
                    .all(|n| !matches!(n.name.as_str(), "trace" | "event")),
                "unsupported_xes_construct",
            )?;
            let index = trace.events.len();
            let location = json!({"trace":trace_index,"event":index,"byte_offset":event.offset});
            let fields = xes_scope(event, "event", Some(trace_index), Some(index), inventory)?;
            let (kind, activity) = fields
                .get("concept:name")
                .ok_or_else(|| Failure::new("missing_activity"))?;
            require(
                kind == "string" && !activity.is_empty() && activity.len() <= 4096,
                "invalid_activity",
            )?;
            let time = fields
                .get("time:timestamp")
                .map(|(kind, value)| {
                    require(kind == "date", "invalid_timestamp")?;
                    timestamp(value, location.clone(), inventory)
                })
                .transpose()?;
            let lifecycle = fields
                .get("lifecycle:transition")
                .map(|(kind, value)| {
                    require(
                        kind == "string" && !value.is_empty(),
                        "empty_lifecycle_unrepresentable",
                    )?;
                    Ok(value.clone())
                })
                .transpose()?;
            trace.events.push(CoreEvent {
                activity: activity.clone(),
                timestamp: time,
                lifecycle,
            });
        }
        require(!trace.events.is_empty(), "empty_trace_unrepresentable")?;
        traces.push(trace);
    }
    require(
        root.children.iter().all(|n| n.name != "event"),
        "unsupported_xes_construct",
    )?;
    let core = Core { traces };
    let log = event_io::parse_xes(input).map_err(|e| {
        Failure::new("production_xes_parser_refused").detail(json!({"original_error":e}))
    })?;
    require(
        actual_core(&log)? == core,
        "production_xes_semantic_disagreement",
    )?;
    Ok((log, core))
}
/// Strict record/quote boundary check before the existing csv parser can skip blank rows.
fn csv_lexical(input: &[u8]) -> Result<()> {
    super::check_cancelled()?;
    let mut index = 0;
    let mut state = 0;
    let mut record_bytes = 0_usize;
    while index < input.len() {
        super::check_cancelled()?;
        let b = input[index];
        if state == 2 {
            if b == b'"' {
                if input.get(index + 1) == Some(&b'"') {
                    index += 1;
                } else {
                    state = 3;
                }
            }
        } else if b == b'\r' || b == b'\n' {
            require(record_bytes > 0, "blank_csv_record")?;
            if b == b'\r' {
                require(input.get(index + 1) == Some(&b'\n'), "csv_lexical")?;
                index += 1;
            } else {
                return Err(Failure::new("csv_lexical"));
            }
            state = 0;
            record_bytes = 0;
            index += 1;
            continue;
        } else {
            match (state, b) {
                (0, b'"') => state = 2,
                (0, b',') => {}
                (0, _) => state = 1,
                (1, b',') | (3, b',') => state = 0,
                (1, b'"') | (3, _) => return Err(Failure::new("csv_lexical")),
                _ => {}
            }
        }
        require(
            b >= 32 || matches!(b, b'\r' | b'\n' | b'\t'),
            "csv_control_character",
        )?;
        record_bytes += 1;
        index += 1;
    }
    require(state != 2, "csv_lexical")
}
fn csv(input: &[u8], inventory: &mut Inventory) -> Result<(EventLog, Core)> {
    super::check_cancelled()?;
    csv_lexical(input)?;
    let mut reader = csv::ReaderBuilder::new().flexible(false).from_reader(input);
    let headers = reader
        .headers()
        .map_err(|_| Failure::new("csv_lexical"))?
        .clone();
    require(
        headers.iter().collect::<BTreeSet<_>>().len() == headers.len(),
        "duplicate_csv_header",
    )?;
    require(
        headers.len() >= 4
            && headers
                .iter()
                .take(4)
                .eq(["case", "activity", "timestamp", "lifecycle"]),
        "csv_core_header",
    )?;
    require(headers.iter().all(|h| !h.is_empty()), "csv_core_header")?;
    inventory.format_declarations = json!({"format":"csv","headers":headers.iter().collect::<Vec<_>>(),"delimiter":",","encoding":"UTF-8"});
    if headers.len() > 4 {
        inventory.metadata_policy_required = true;
        inventory.normalizations.push(json!({"kind":"csv_extra_columns_omitted","columns":headers.iter().skip(4).collect::<Vec<_>>()}));
    }
    let mut traces: Vec<CoreTrace> = Vec::new();
    let mut seen = BTreeSet::new();
    for (count, record) in reader.records().enumerate() {
        super::check_cancelled()?;
        let record = record.map_err(|_| Failure::new("csv_lexical"))?;
        require(count < 100000, "event_limit")?;
        let name = &record[0];
        let activity = &record[1];
        require(!name.is_empty(), "trace_identity_missing")?;
        require(
            !activity.is_empty() && activity.len() <= 4096,
            "invalid_activity",
        )?;
        require(record.iter().all(xml_chars), "xml10_character")?;
        if traces.last().is_none_or(|trace| trace.name != name) {
            require(seen.insert(name.to_owned()), "interleaved_case_rows")?;
            require(traces.len() < 20000, "case_limit")?;
            traces.push(CoreTrace {
                name: name.into(),
                events: Vec::new(),
            });
        }
        let time = if record[2].is_empty() {
            None
        } else {
            Some(timestamp(
                &record[2],
                json!({"row":count,"column":"timestamp"}),
                inventory,
            )?)
        };
        let lifecycle = (!record[3].is_empty()).then(|| record[3].to_owned());
        traces
            .last_mut()
            .expect("trace_created")
            .events
            .push(CoreEvent {
                activity: activity.into(),
                timestamp: time,
                lifecycle,
            });
        for (column, value) in record.iter().enumerate().skip(4) {
            super::check_cancelled()?;
            if !value.is_empty() {
                inventory.losses.push(json!({"kind":"csv_extra_cell","row":count,"column":&headers[column],"value":value}));
            }
        }
    }
    let mapping = CsvMapping {
        case_column: "case".into(),
        activity_column: "activity".into(),
        timestamp_column: Some("timestamp".into()),
        lifecycle_column: Some("lifecycle".into()),
        delimiter: b',',
        order: NormalizationOrder::Source,
    };
    let log = csv_io::parse_csv(input, &mapping).map_err(|e| {
        Failure::new("production_csv_parser_refused").detail(json!({"original_error":e}))
    })?;
    let core = Core { traces };
    require(
        actual_core(&log)? == core,
        "production_csv_semantic_disagreement",
    )?;
    Ok((log, core))
}
fn write_csv(core: &Core) -> Result<Vec<u8>> {
    super::check_cancelled()?;
    let mut writer = csv::WriterBuilder::new()
        .terminator(csv::Terminator::CRLF)
        .from_writer(Vec::new());
    writer
        .write_record(["case", "activity", "timestamp", "lifecycle"])
        .map_err(|_| Failure::new("csv_serialization"))?;
    for trace in &core.traces {
        super::check_cancelled()?;
        for event in &trace.events {
            super::check_cancelled()?;
            writer
                .write_record([
                    trace.name.as_str(),
                    event.activity.as_str(),
                    event.timestamp.as_deref().unwrap_or(""),
                    event.lifecycle.as_deref().unwrap_or(""),
                ])
                .map_err(|_| Failure::new("csv_serialization"))?;
        }
    }
    writer
        .into_inner()
        .map_err(|_| Failure::new("csv_serialization"))
}
fn write_xes(core: &Core) -> Result<Vec<u8>> {
    super::check_cancelled()?;
    let mut writer = Writer::new(Vec::new());
    fn start(writer: &mut Writer<Vec<u8>>, name: &str) -> Result<()> {
        super::check_cancelled()?;
        writer
            .write_event(Event::Start(BytesStart::new(name)))
            .map_err(|_| Failure::new("xes_serialization"))
    }
    fn end(writer: &mut Writer<Vec<u8>>, name: &str) -> Result<()> {
        super::check_cancelled()?;
        writer
            .write_event(Event::End(BytesEnd::new(name)))
            .map_err(|_| Failure::new("xes_serialization"))
    }
    fn attribute(writer: &mut Writer<Vec<u8>>, kind: &str, key: &str, value: &str) -> Result<()> {
        super::check_cancelled()?;
        let content = format!(
            "{kind} key=\"{}\" value=\"{}\"",
            xml::escape(key),
            xml::escape(value)
        );
        writer
            .write_event(Event::Empty(BytesStart::from_content(content, kind.len())))
            .map_err(|_| Failure::new("xes_serialization"))
    }
    writer
        .write_event(Event::Start(BytesStart::from_content(
            "log xes.version=\"1.0\" xmlns=\"http://www.xes-standard.org/\"",
            3,
        )))
        .map_err(|_| Failure::new("xes_serialization"))?;
    for trace in &core.traces {
        super::check_cancelled()?;
        start(&mut writer, "trace")?;
        attribute(&mut writer, "string", "concept:name", &trace.name)?;
        for event in &trace.events {
            super::check_cancelled()?;
            start(&mut writer, "event")?;
            attribute(&mut writer, "string", "concept:name", &event.activity)?;
            if let Some(time) = &event.timestamp {
                attribute(&mut writer, "date", "time:timestamp", time)?;
            }
            if let Some(lifecycle) = &event.lifecycle {
                attribute(&mut writer, "string", "lifecycle:transition", lifecycle)?;
            }
            end(&mut writer, "event")?;
        }
        end(&mut writer, "trace")?;
    }
    end(&mut writer, "log")?;
    Ok(writer.into_inner())
}
pub fn convert(from: &str, input: &[u8], allow: bool) -> Result<Converted> {
    super::check_cancelled()?;
    let mut inventory = Inventory::default();
    let (log, core) = if from == "xes" {
        xes(input, &mut inventory)?
    } else {
        csv(input, &mut inventory)?
    };
    if !allow && (!inventory.losses.is_empty() || inventory.metadata_policy_required) {
        let reason = if !inventory.metadata_policy_required
            && inventory
                .losses
                .iter()
                .all(|v| v["kind"] == "timestamp_offset")
        {
            "nonzero_timestamp_offset"
        } else {
            "extra_metadata"
        };
        return Err(Failure {
            status: "loss_refused".into(),
            reason: reason.into(),
            details: json!({"losses":inventory.losses,"metadata_loss_count":inventory.losses.len(),"normalizations":inventory.normalizations,"parser_warnings":log.warnings}),
        });
    }
    let payload = if from == "xes" {
        write_csv(&core)?
    } else {
        write_xes(&core)?
    };
    // Independently reparse the generated payload through the actual opposite parser.
    let mut target_inventory = Inventory::default();
    let (target_log, target_core) = if from == "xes" {
        csv(&payload, &mut target_inventory)?
    } else {
        xes(&payload, &mut target_inventory)?
    };
    require(
        target_core == core && target_inventory.losses.is_empty(),
        "target_semantic_conservation",
    )?;
    inventory.normalizations.push(json!({"kind":"format_declarations","source":inventory.format_declarations,"target":target_inventory.format_declarations,"metadata_loss_count":0}));
    let trace_count = core.traces.len();
    let event_count: usize = core.traces.iter().map(|t| t.events.len()).sum();
    Ok(Converted {
        payload,
        extension: if from == "xes" { "csv" } else { "xes" },
        evidence: json!({"profile":"flat-xes-rfc4180-four-columns-v1","reason":if !inventory.losses.is_empty(){"explicit_metadata_loss"}else if trace_count==0{"empty_log"}else{"lossless_core"},"source_core":core,"target_core":target_core,"metadata_loss_count":inventory.losses.len(),"losses":inventory.losses,"normalizations":inventory.normalizations,"format_declarations":{"source":inventory.format_declarations,"target":target_inventory.format_declarations,"metadata_loss_count":0},"trace_count":trace_count,"event_count":event_count,"source_parser_warnings":log.warnings,"target_parser_warnings":target_log.warnings,"source_parser_identities":log.cases.iter().map(|case|json!({"id":case.id,"name":case.name,"ordinals":case.events.iter().map(|event|event.ordinal).collect::<Vec<_>>()})).collect::<Vec<_>>(),"actual_inverse_conversion_not_claimed":true}),
    })
}
