//! Read-only reference oracle for ORIGINAL full C2 recovery HTTP captures.
//! No DB/network/process/filesystem writes. Uses the SAME pinned library primitives
//! for graph/calendar/BPMN, not an independently implemented mining/BPMN algorithm.
use process_intelligence_rs::{
    bpmn, calendar,
    domain::{Analysis, EventLog},
    mining,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
};
type R<T> = Result<T, Box<dyn std::error::Error>>;
const GIB: u64 = 1 << 30;
const BODY: u64 = 256 << 20;
fn check(ok: bool, code: &'static str) -> R<()> {
    if ok { Ok(()) } else { Err(code.into()) }
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn no_reparse(path: &Path) -> R<()> {
    let m = fs::symlink_metadata(path)?;
    check(!m.file_type().is_symlink(), "symlink_refused")?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        check(m.file_attributes() & 0x400 == 0, "reparse_refused")?;
    }
    Ok(())
}
fn bounded(path: &Path, cap: u64) -> R<Vec<u8>> {
    no_reparse(path)?;
    let f = File::open(path)?;
    let m = f.metadata()?;
    check(m.is_file() && m.len() <= cap, "file_cap")?;
    let mut b = Vec::new();
    f.take(cap + 1).read_to_end(&mut b)?;
    check(b.len() as u64 == m.len(), "file_changed_or_cap")?;
    Ok(b)
}
fn text<'a>(v: &'a Value, key: &str) -> R<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| "required_string".into())
}
fn num(v: &Value, key: &str) -> R<u64> {
    v.get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| "required_u64".into())
}
fn field<'a>(v: &'a Value, key: &str) -> R<&'a Value> {
    v.get(key).ok_or_else(|| "required_field".into())
}
fn opt_string(v: &Value, key: &str) -> R<Option<String>> {
    match field(v, key)? {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s.clone())),
        _ => Err("optional_string".into()),
    }
}
fn equal(a: &Value, b: &Value) -> R<()> {
    check(a == b, "complete_json_contract_mismatch")
}
fn exact_bytes(actual: &[u8], expected: &[u8]) -> R<()> {
    check(actual == expected, "exact_reference_bytes")
}
fn body_contract(bytes: &[u8], expected_len: u64, expected_sha: &str) -> R<()> {
    check(
        expected_len <= BODY
            && bytes.len() as u64 == expected_len
            && expected_sha.len() == 64
            && expected_sha.bytes().all(|c| c.is_ascii_hexdigit())
            && digest(bytes).eq_ignore_ascii_case(expected_sha),
        "body_hash_or_length",
    )
}
fn pairing(
    actual_project: &str,
    actual_id: &str,
    expected_project: &str,
    expected_id: &str,
) -> R<()> {
    check(
        actual_project == expected_project && actual_id == expected_id,
        "actor_project_resource_pairing",
    )
}
#[derive(Default)]
struct LogParts {
    parts: BTreeMap<String, Value>,
}
struct Input {
    logs: BTreeMap<(String, String), LogParts>,
    models: BTreeMap<(String, String), Value>,
    projects: BTreeMap<String, Value>,
    auth: Value,
    rows: usize,
    legacy: usize,
}
fn sql_input(path: &Path, expected_sha: &str, expected_bytes: u64) -> R<Input> {
    check(
        expected_sha.len() == 64
            && expected_sha.bytes().all(|b| b.is_ascii_hexdigit())
            && (600_000_000..=GIB).contains(&expected_bytes),
        "input_native_binding",
    )?;
    no_reparse(path)?;
    let f = File::open(path)?;
    check(
        f.metadata()?.len() == expected_bytes,
        "input_initial_length",
    )?;
    let mut reader = BufReader::new(f);
    let mut hash = Sha256::new();
    let mut bytes = 0u64;
    let mut result = Input {
        logs: BTreeMap::new(),
        models: BTreeMap::new(),
        projects: BTreeMap::new(),
        auth: Value::Null,
        rows: 0,
        legacy: 0,
    };
    let mut unique = BTreeSet::new();
    loop {
        let mut raw = Vec::new();
        let n = reader.by_ref().take(BODY + 1).read_until(b'\n', &mut raw)?;
        if n == 0 {
            break;
        }
        check(
            n as u64 <= BODY && raw.last() == Some(&b'\n'),
            "SQL_line_cap_or_missing_LF",
        )?;
        hash.update(&raw);
        bytes += n as u64;
        check(bytes <= GIB, "SQL_total_cap")?;
        let row: Value = serde_json::from_slice(&raw)?;
        let a = row.as_array().ok_or("SQL_array")?;
        let tag = a.first().and_then(Value::as_str).ok_or("SQL_tag")?;
        let key = match tag {
            "kv" => {
                check(a.len() == 4, "kv_shape")?;
                let k = a[1].as_str().ok_or("kv_key")?;
                check(
                    a[2].as_str()
                        .is_some_and(|s| s.parse::<u64>().is_ok_and(|n| n > 0)),
                    "kv_version",
                )?;
                if k.starts_with("repository/") {
                    result.legacy += 1;
                }
                if k == "auth" {
                    check(result.auth.is_null(), "duplicate_auth")?;
                    result.auth = a[3].clone();
                }
                json!([tag, k])
            }
            "project" => {
                check(a.len() == 4, "project_shape")?;
                let p = a[1].as_str().ok_or("project_id")?.to_owned();
                check(
                    result.projects.insert(p.clone(), a[3].clone()).is_none(),
                    "duplicate_project",
                )?;
                json!([tag, p])
            }
            "record" => {
                check(a.len() == 6, "record_shape")?;
                let p = a[1].as_str().ok_or("record_project")?.to_owned();
                let kind = a[2].as_str().ok_or("record_kind")?;
                let id = a[3].as_str().ok_or("record_id")?.to_owned();
                match kind {
                    "log_state" | "log_data" | "log_analysis" | "log_source" => {
                        check(
                            result
                                .logs
                                .entry((p.clone(), id.clone()))
                                .or_default()
                                .parts
                                .insert(kind.into(), a[5].clone())
                                .is_none(),
                            "duplicate_log_part",
                        )?;
                    }
                    "model" => {
                        check(
                            result
                                .models
                                .insert((p.clone(), id.clone()), a[5].clone())
                                .is_none(),
                            "duplicate_model",
                        )?;
                    }
                    _ => return Err("unknown_record_kind".into()),
                };
                json!([tag, p, kind, id])
            }
            "marker" => {
                check(a.len() == 2, "marker_shape")?;
                json!([tag, field(&a[1], "project_id")?])
            }
            "ledger" => {
                check(a.len() == 2, "ledger_shape")?;
                json!([tag, field(&a[1], "version")?])
            }
            "sequence" | "sequence_definition" => json!([tag]),
            _ => return Err("unknown_SQL_tag".into()),
        };
        check(
            unique.insert(serde_json::to_string(&key)?),
            "duplicate_SQL_row",
        )?;
        result.rows += 1;
        check(result.rows <= 130, "SQL_rows_cap")?;
    }
    check(
        bytes == expected_bytes
            && format!("{:x}", hash.finalize()).eq_ignore_ascii_case(expected_sha),
        "whole_SQL_sha_length",
    )?;
    check(
        result.rows == 130
            && result.legacy == 10
            && result.logs.len() == 20
            && result.models.len() == 14
            && result.auth.is_object(),
        "full_original_corpus_counts",
    )?;
    for log in result.logs.values() {
        check(log.parts.len() == 4, "four_normalized_log_kinds")?;
    }
    Ok(result)
}
fn expected_export(input: &Input, project: &str, id: &str, actor: &str) -> R<Value> {
    let log = input
        .logs
        .get(&(project.into(), id.into()))
        .ok_or("missing_log")?;
    let state = &log.parts["log_state"];
    check(
        text(state, "id")? == id && text(state, "project_id")? == project,
        "stored_log_identity",
    )?;
    let data: EventLog = serde_json::from_value(log.parts["log_data"].clone())?;
    let analysis: Analysis = serde_json::from_value(log.parts["log_analysis"].clone())?;
    let source = &log.parts["log_source"];
    let provenance = if source.get("source_envelope_version").is_some() {
        let o = source.as_object().ok_or("source_envelope_object")?;
        check(
            o.len() == 3
                && source["source_envelope_version"] == 1
                && o.contains_key("source")
                && o.contains_key("provenance"),
            "source_envelope_shape",
        )?;
        let _: EventLog = serde_json::from_value(source["source"].clone())?;
        let p: process_intelligence_rs::import_provenance::ImportProvenance =
            serde_json::from_value(source["provenance"].clone())?;
        json!({"schema_version":p.schema_version,"policy":p.policy,"operation_id":p.operation_id,"actor_id":p.actor_id,"origin_project_id":p.origin_project_id,"confirmed_at":p.confirmed_at,"source_cases":p.source_cases,"source_events":p.source_events,"actions":p.actions,"source_sha256":p.source_sha256})
    } else {
        let _: EventLog = serde_json::from_value(source.clone())?;
        Value::Null
    };
    check(
        state.get("provenance").is_none(),
        "state_provenance_collision",
    )?;
    let header = input
        .projects
        .get(project)
        .ok_or("missing_project_header")?;
    let view = header
        .get("user_views")
        .and_then(|v| v.get(actor))
        .and_then(|v| v.get(id));
    let threshold = if let Some(v) = view {
        num(v, "threshold")?
    } else {
        num(state, "threshold")?
    };
    let selected = opt_string(view.unwrap_or(state), "selected")?;
    let selected_case = opt_string(view.unwrap_or(state), "selected_case")?;
    let revision = if let Some(v) = view {
        num(v, "revision")?
    } else {
        num(state, "view_revision")?
    };
    let mut graph = mining::graph_view(
        &analysis,
        id,
        num(state, "analysis_version")?,
        revision,
        threshold,
        selected,
    )
    .map_err(|_| "graph_reference_refused")?;
    let chosen = selected_case
        .as_deref()
        .and_then(|id| data.cases.iter().find(|c| c.id == id));
    // Exact reference projection from web::case_projection, including BTree order.
    if let Some(case) = chosen {
        graph.selected_case_id = Some(case.id.clone());
        let ids: BTreeMap<_, _> = graph
            .nodes
            .iter()
            .map(|n| (n.label.as_str(), n.id.as_str()))
            .collect();
        let nodes: BTreeSet<_> = case
            .events
            .iter()
            .filter_map(|e| ids.get(e.activity.as_str()).copied())
            .collect();
        let pairs: BTreeSet<_> = case
            .events
            .windows(2)
            .filter_map(|p| {
                Some((
                    *ids.get(p[0].activity.as_str())?,
                    *ids.get(p[1].activity.as_str())?,
                ))
            })
            .collect();
        let highlighted_nodes = nodes.into_iter().map(str::to_owned).collect();
        let highlighted_edges = graph
            .edges
            .iter()
            .filter(|e| pairs.contains(&(e.source.as_str(), e.target.as_str())))
            .map(|e| e.id.clone())
            .collect();
        graph.case_highlight.node_ids = highlighted_nodes;
        graph.case_highlight.edge_ids = highlighted_edges;
    }
    let cal: calendar::CalendarSpec = serde_json::from_value(field(state, "calendar")?.clone())?;
    let business:Vec<Value>=data.cases.iter().map(|case|{
        let times:Vec<_>=case.events.iter().filter_map(|e|e.timestamp).collect();
        if times.is_empty()||times.len()!=case.events.len(){return json!({"case_id":case.id,"status":"unverified","reason":"missing_timestamps"});}
        let start=*times.iter().min().expect("nonempty");let end=*times.iter().max().expect("nonempty");
        match calendar::business_millis(start,end,&cal){Ok(ms)=>json!({"case_id":case.id,"status":"computed","start":start,"end":end,"business_millis":ms}),Err(e)=>json!({"case_id":case.id,"status":"unverified","reason":e.code})}
    }).collect();
    let filters: process_intelligence_rs::filters::FilterSpec =
        serde_json::from_value(field(state, "filters")?.clone())?;
    let order: process_intelligence_rs::csv_io::NormalizationOrder =
        serde_json::from_value(field(state, "order")?.clone())?;
    let mut expected = json!({"schema_version":1,"log_id":id,"name":text(state,"filename")?,"analysis_version":num(state,"analysis_version")?,"view_revision":revision,
        "parameters":{"min_edge_frequency":threshold,"order":order,"lifecycle":"each-event","filters":filters,"calendar":cal},
        "source_sha256":text(state,"source_sha256")?,"project_id":project,"import_history":provenance,"business_durations":business,
        "analysis":analysis,"view":graph,"warnings":data.warnings,"elapsed_ms":field(state,"elapsed_ms")?,"selected_case":chosen,"compatibility":{"apromore":"unverified"}});
    if let Some(v) = state.get("created_at") {
        let s = v.as_str().ok_or("created_at_not_string")?;
        check(s.len() <= 64, "created_at_bound")?;
        let date = chrono::DateTime::parse_from_rfc3339(s)?.with_timezone(&chrono::Utc);
        expected["created_at"] = json!(date);
    }
    Ok(expected)
}
fn model_reference(value: &Value, id: &str) -> R<(Value, Vec<u8>)> {
    let o = value.as_object().ok_or("model_object")?;
    check(
        o.len() == 5
            && ["id", "name", "revision", "model", "source_log"]
                .iter()
                .all(|k| o.contains_key(*k))
            && text(value, "id")? == id
            && num(value, "revision")? > 0,
        "stored_model_shape",
    )?;
    let model: bpmn::ProcessModel = serde_json::from_value(field(value, "model")?.clone())?;
    let xml = bpmn::serialize(&model).map_err(|_| "BPMN_reference_refused")?;
    Ok((value.clone(), xml.into_bytes()))
}
fn run_http(input: &Input, out: &Path) -> R<Value> {
    no_reparse(out)?;
    check(out.is_dir(), "HTTP_output_directory")?;
    let witness: Value = serde_json::from_slice(&bounded(
        &out.join("full-http-private-witness.json"),
        4 << 20,
    )?)?;
    check(
        text(&witness, "status")? == "FULL_RECOVERY_HTTP_CAPTURED_PENDING_DELTA",
        "HTTP_witness_status",
    )?;
    let mut actors = BTreeMap::<String, String>::new();
    for (role, username) in [
        ("owner", "qa_owner"),
        ("editor", "qa_editor"),
        ("viewer", "qa_viewer"),
        ("foreign", "qa_other"),
    ] {
        let users: Vec<_> = input.auth["users"]
            .as_object()
            .ok_or("Auth_users")?
            .values()
            .filter(|u| u["username"] == username)
            .collect();
        check(users.len() == 1, "fixture_actor_unique")?;
        let id = text(users[0], "id")?.to_owned();
        let matches = witness["logins"]
            .as_array()
            .ok_or("witness_logins")?
            .iter()
            .filter(|l| l["role"] == role && l["actor_id"] == id)
            .count();
        check(matches == 1, "actor_actual_login_binding")?;
        actors.insert(role.into(), id);
    }
    let mut names = BTreeSet::new();
    let mut bodies = BTreeSet::new();
    let mut total = 0usize;
    for entry in fs::read_dir(out)? {
        let entry = entry?;
        let name = entry
            .file_name()
            .to_str()
            .ok_or("HTTP_filename_UTF8")?
            .to_owned();
        if let Some(tail) = name.strip_prefix("recovery-http-") {
            no_reparse(&entry.path())?;
            check(entry.file_type()?.is_file(), "HTTP_regular_file")?;
            if tail.ends_with(".json") {
                check(names.insert(name), "duplicate_HTTP_metadata")?;
            } else if tail.ends_with(".body") {
                check(bodies.insert(name), "duplicate_HTTP_body")?;
            } else {
                return Err("unexpected_HTTP_artifact".into());
            }
        }
    }
    check(
        !names.is_empty() && names.len() <= 512 && names.len() == bodies.len(),
        "HTTP_metadata_body_count",
    )?;
    let mut contexts = BTreeMap::<String, String>::new();
    let mut logged = BTreeSet::new();
    let mut seen_logs = BTreeSet::new();
    let mut seen_models = BTreeSet::new();
    let mut pending: Option<(String, String, String, Vec<u8>)> = None;
    for (offset, name) in names.iter().enumerate() {
        let expected_name = format!("recovery-http-{:04}.json", offset + 1);
        check(*name == expected_name, "HTTP_contiguous_order")?;
        let meta: Value = serde_json::from_slice(&bounded(&out.join(name), 1 << 20)?)?;
        let basename = name.strip_suffix(".json").ok_or("HTTP_suffix")?;
        let body_name = format!("{basename}.body");
        check(bodies.remove(&body_name), "HTTP_missing_body")?;
        let bytes = bounded(&out.join(body_name), BODY)?;
        body_contract(&bytes, num(&meta, "bytes")?, text(&meta, "sha256")?)?;
        total = total
            .checked_add(bytes.len())
            .ok_or("HTTP_total_overflow")?;
        check(total as u64 <= GIB, "HTTP_total_cap")?;
        let route = text(&meta, "route")?;
        let method = text(&meta, "method")?;
        let status = num(&meta, "status")?;
        check(status == num(&meta, "expected")?, "HTTP_expected_status")?;
        let role = meta.get("actor").and_then(Value::as_str);
        let parts: Vec<_> = route.split('/').collect();
        if pending.is_some() {
            check(
                parts.len() == 4 && parts[1] == "models" && parts[3] == "export",
                "model_pair_must_be_immediately_following",
            )?;
        }
        if route == "/health" {
            check(
                method == "GET" && status == 200 && role.is_none(),
                "health_contract",
            )?;
            let v: Value = serde_json::from_slice(&bytes)?;
            check(v["version"] == "0.7.3", "health_version")?;
        } else if route == "/login" {
            let role = role.ok_or("login_role")?;
            check(
                method == "POST"
                    && status == 303
                    && actors.contains_key(role)
                    && logged.insert(role.to_owned()),
                "four_distinct_logins",
            )?;
        } else if parts.len() == 4 && parts[1] == "projects" && parts[3] == "open" {
            let role = role.ok_or("open_role")?;
            check(
                method == "POST" && logged.contains(role),
                "open_after_login",
            )?;
            let actor = actors.get(role).ok_or("unknown_role")?;
            let p = input.auth["projects"]
                .get(parts[2])
                .ok_or("open_unknown_project")?;
            let allowed = p["archived"] != true && p["members"].get(actor).is_some();
            check(
                status == if allowed { 303 } else { 403 },
                "independent_open_RBAC",
            )?;
            if allowed {
                contexts.insert(role.into(), parts[2].into());
            }
        } else if parts.len() == 4 && parts[1] == "logs" && parts[3] == "export" {
            check(pending.is_none(), "model_pair_interrupted")?;
            let role = role.ok_or("log_actor")?;
            check(
                method == "GET" && status == 200 && logged.contains(role),
                "log_HTTP_contract",
            )?;
            let project = contexts.get(role).ok_or("log_project_context")?;
            let key = (project.clone(), parts[2].to_owned());
            check(seen_logs.insert(key.clone()), "duplicate_log_export")?;
            let expected = expected_export(
                input,
                project,
                parts[2],
                actors.get(role).ok_or("log_actor_ID")?,
            )?;
            let actual: Value = serde_json::from_slice(&bytes)?;
            equal(&actual, &expected)?;
            pairing(
                text(&actual, "project_id")?,
                text(&actual, "log_id")?,
                project,
                parts[2],
            )?;
        } else if parts.len() == 4 && parts[1] == "models" && parts[3] == "json" {
            check(pending.is_none(), "model_pair_interrupted")?;
            let role = role.ok_or("model_actor")?;
            check(
                method == "GET" && status == 200 && logged.contains(role),
                "model_JSON_HTTP",
            )?;
            let project = contexts.get(role).ok_or("model_project_context")?;
            let key = (project.clone(), parts[2].into());
            check(seen_models.insert(key.clone()), "duplicate_model_JSON")?;
            let value = input.models.get(&key).ok_or("missing_stored_model")?;
            let (expected, xml) = model_reference(value, parts[2])?;
            equal(&serde_json::from_slice::<Value>(&bytes)?, &expected)?;
            pending = Some((role.into(), project.clone(), parts[2].into(), xml));
        } else if parts.len() == 4 && parts[1] == "models" && parts[3] == "export" {
            let (actor, project, id, expected) = pending.take().ok_or("BPMN_without_model_JSON")?;
            check(
                method == "GET" && status == 200 && role == Some(actor.as_str()),
                "BPMN_actor_pair",
            )?;
            pairing(
                contexts.get(&actor).ok_or("BPMN_context")?,
                parts[2],
                &project,
                &id,
            )?;
            exact_bytes(&bytes, &expected)?;
        } else {
            return Err("HTTP_route_not_allowed".into());
        }
    }
    check(
        bodies.is_empty()
            && logged.len() == 4
            && pending.is_none()
            && seen_logs.len() == 20
            && seen_models.len() == 14,
        "complete_HTTP_coverage",
    )?;
    check(
        seen_logs == input.logs.keys().cloned().collect()
            && seen_models == input.models.keys().cloned().collect(),
        "all_original_resources_covered",
    )?;
    Ok(
        json!({"status":"FULL_ORIGINAL_C2_ALL_EXPORT_FIELDS_AND_BPMN_REFERENCE_MATCH_PENDING_QA_TD","SQL_rows":input.rows,"legacy_repository_rows":input.legacy,"log_exports":seen_logs.len(),"model_JSON_BPMN_pairs":seen_models.len(),"HTTP_responses":names.len(),"HTTP_bytes":total,"reference_basis":"same pinned public Rust graph/calendar/BPMN primitives plus source-copied projection/whitelist; not independent BPMN algorithm","limits":["Native caller/SHA/ACL/closed capture/compiled library/source provenance independently required","Does not replace whole Auth/session/version delta oracle or grant write-RBAC/C08/R3 acceptance"]}),
    )
}
fn self_test() -> R<Value> {
    let expected = json!({"analysis":{"cases":1},"view":{"case_highlight":{"node_ids":["n1"]}},"business_durations":[{"case_id":"c1","business_millis":12}],"import_history":null});
    equal(&expected, &expected)?;
    let mut count = 0;
    let mut extra = expected.clone();
    extra["extra"] = json!(true);
    check(equal(&extra, &expected).is_err(), "selftest_extra_field")?;
    count += 1;
    let mut missing = expected.clone();
    missing
        .as_object_mut()
        .ok_or("selftest_object")?
        .remove("analysis");
    check(
        equal(&missing, &expected).is_err(),
        "selftest_missing_field",
    )?;
    count += 1;
    let mut nested = expected.clone();
    nested["view"]["case_highlight"]["node_ids"] = json!([]);
    check(equal(&nested, &expected).is_err(), "selftest_nested_view")?;
    count += 1;
    let mut cal = expected.clone();
    cal["business_durations"][0]["business_millis"] = json!(13);
    check(equal(&cal, &expected).is_err(), "selftest_calendar")?;
    count += 1;
    let b = b"original";
    body_contract(b, b.len() as u64, &digest(b))?;
    check(
        body_contract(b"tampered", b.len() as u64, &digest(b)).is_err(),
        "selftest_body_hash",
    )?;
    count += 1;
    check(
        body_contract(b, 99, &digest(b)).is_err(),
        "selftest_metadata_length",
    )?;
    count += 1;
    check(
        pairing("p2", "m1", "p1", "m1").is_err(),
        "selftest_project_pair",
    )?;
    count += 1;
    check(
        pairing("p1", "m2", "p1", "m1").is_err(),
        "selftest_resource_pair",
    )?;
    count += 1;
    exact_bytes(b"<bpmn/>", b"<bpmn/>")?;
    check(
        exact_bytes(b"<bpmn/>", b"<bpmn />").is_err(),
        "selftest_BPMN_bytes",
    )?;
    count += 1;
    let mut prov = expected.clone();
    prov["import_history"] = json!({"original_utf8":"must not leak"});
    check(equal(&prov, &expected).is_err(), "selftest_provenance")?;
    count += 1;
    Ok(
        json!({"status":"PURE_HELPER_NEGATIVE_SELF_TESTS_COMPLETED","negative_checks":count,"limits":"Pure comparison-helper checks only; not full fixture/native/runtime or parser-fuzz proof"}),
    )
}
fn run() -> R<Value> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() == 2 && args[1] == "--self-test" {
        return self_test();
    }
    check(args.len() == 5, "usage_SQL_SHA_BYTES_HTTPDIR")?;
    let bytes = args[3].parse::<u64>()?;
    let input = sql_input(Path::new(&args[1]), &args[2], bytes)?;
    run_http(&input, &PathBuf::from(&args[4]))
}
fn main() {
    match run() {
        Ok(value) => println!("{value}"),
        Err(_) => {
            eprintln!("recovery_export_oracle_refused");
            std::process::exit(1)
        }
    }
}
