//! Production durable-job caller and startup recovery against an owned database.
include!("web_sprint12_http_tests.rs");
use super::*;
use serde_json::{Value, json};

fn save(directory: &std::path::Path, name: &str, value: &Value) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(directory.join(name))
        .unwrap();
    file.write_all(&serde_json::to_vec(value).unwrap()).unwrap();
    file.sync_all().unwrap();
}

fn snapshot(client: &mut postgres::Client) -> Value {
    let mut all = serde_json::Map::new();
    client
        .batch_execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .unwrap();
    for table in [
        "pi_kv",
        "pi_projects",
        "pi_records",
        "pi_migration_v2",
        "pi_schema_migrations",
    ] {
        let rows = client.query(&format!("SELECT to_jsonb(t) FROM public.{table} t ORDER BY to_jsonb(t)::text COLLATE \"C\""), &[]).unwrap();
        all.insert(
            table.into(),
            Value::Array(rows.iter().map(|row| row.get::<_, Value>(0)).collect()),
        );
    }
    let sequence: Value = client
        .query_one("SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called) FROM public.pi_resource_sequence", &[])
        .unwrap()
        .get(0);
    all.insert("pi_resource_sequence".into(), sequence);
    let definition: Value = client.query_one("SELECT to_jsonb(s) FROM pg_sequence s WHERE seqrelid='public.pi_resource_sequence'::regclass", &[]).unwrap().get(0);
    all.insert("sequence_definition".into(), definition);
    client.batch_execute("COMMIT").unwrap();
    Value::Object(all)
}

fn expected_header(before: &Value, project: &str) -> (u64, Value) {
    let found = before["pi_projects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["project_id"].as_str() == Some(project));
    found.map(|row| (row["version"].as_u64().unwrap(), row["document"].clone()))
        .unwrap_or((0, json!({"current":{},"sequence":0,"user_views":{},"durable_jobs":{},"log_ids":[],"model_ids":[]})))
}

#[expect(
    clippy::too_many_arguments,
    reason = "independent audit oracle keeps identity, payload and commit-time inputs explicit"
)]
fn verify_commit(
    before: &Value,
    after: &Value,
    project: &str,
    actor: &str,
    action: &str,
    jobs: Value,
    resources: Vec<String>,
    started: chrono::DateTime<chrono::Utc>,
    finished: chrono::DateTime<chrono::Utc>,
) -> Value {
    let (revision, mut header) = expected_header(before, project);
    if action == "job_updated" {
        for (id, input) in jobs.as_object().unwrap() {
            header["durable_jobs"][id] = input.clone();
        }
    } else {
        header["durable_jobs"] = jobs.clone();
    }
    let (_, actual) = expected_header(after, project);
    let actual_entry = actual["audit"]["entries"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    let at = actual_entry["at"].as_str().unwrap();
    let timestamp = chrono::DateTime::parse_from_rfc3339(at)
        .unwrap()
        .with_timezone(&chrono::Utc);
    assert!(
        timestamp >= started && timestamp <= finished,
        "audit timestamp outside actual commit call"
    );
    let parameters = if action == "job_updated" {
        json!({"action":action,"expected_repository_revision":revision,"resources":resources,
            "validated_action_parameters":null,"logs":[],"organization":null,"jobs":jobs,
            "models":[],"actor_current":null,"actor_views":null})
    } else {
        json!({"policy":"nonterminal_to_failed_after_restart","jobs":jobs})
    };
    let total = header["audit"]["total"].as_u64().unwrap_or(0) + 1;
    let expected_entry = json!({"sequence":total,"at":at,"actor":actor,"project":project,
        "action":action,"resources":resources,"revision":revision+1,
        "policy":{"version":1,"rule":if action=="job_updated" {"durable_job_transition_v1"}else{"restart_interrupted_job_v1"},
            "parameters_sha256":crate::storage::sha256(&serde_json::to_vec(&parameters).unwrap())},"outcome":"committed"});
    assert!(
        actual_entry == &expected_entry,
        "independently derived audit identity/policy differs"
    );
    let mut entries = header["audit"]["entries"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    entries.push(expected_entry);
    if entries.len() > 512 {
        entries.remove(0);
    }
    header["audit"] = json!({"total":total,"entries":entries});
    let mut expected = before.clone();
    let projects = expected["pi_projects"].as_array_mut().unwrap();
    if let Some(row) = projects
        .iter_mut()
        .find(|row| row["project_id"].as_str() == Some(project))
    {
        row["version"] = json!(revision + 1);
        row["document"] = header;
    } else {
        projects.push(json!({"project_id":project,"version":revision+1,"document":header}));
        projects.sort_by_key(|row| row["project_id"].as_str().unwrap().to_owned());
    }
    assert!(
        &expected == after,
        "unexpected full managed/Auth/sequence database delta"
    );
    parameters
}

#[test]
#[ignore = "requires fresh isolated S12_JOB_DATABASE_URL and private S12_JOB_EVIDENCE"]
fn actual_job_caller_per_commit_and_startup_recovery() {
    let url =
        std::env::var("S12_JOB_DATABASE_URL").expect("owned database URL required; never print");
    let directory = std::path::PathBuf::from(std::env::var("S12_JOB_EVIDENCE").unwrap());
    assert!(
        directory.is_dir() && std::fs::read_dir(&directory).unwrap().next().is_none(),
        "new private evidence directory required"
    );
    let root = AppState::open(3096, url.clone()).unwrap();
    let platform = root.platform.as_ref().unwrap().clone();
    assert!(platform.auth.needs_setup(), "fresh database required");
    let session = platform
        .auth
        .setup("s12_job_owner", "S12NativePassword123")
        .unwrap();
    let actor = platform.auth.actor(&session).unwrap();
    let mut state = platform.scope(&root, actor.clone()).unwrap();
    state.session = Some(session);
    let mut client = postgres::Client::connect(&url, postgres::NoTls).unwrap();
    let mut jobs = serde_json::Map::new();
    let stages = [
        ("job-100", JobState::Queued, "queued", 0, false, None),
        ("job-100", JobState::Running, "parse", 1, false, None),
        ("job-100", JobState::Running, "analyze", 2, false, None),
        (
            "job-100",
            JobState::Failed,
            "failed",
            3,
            false,
            Some(crate::jobs::JobError {
                code: "fixture_failed".into(),
                message: "Controlled fixture".into(),
            }),
        ),
        ("job-101", JobState::Queued, "queued", 0, false, None),
        ("job-101", JobState::Cancelled, "cancelled", 1, true, None),
        ("job-102", JobState::Running, "parse", 1, false, None),
    ];
    for (index, (id, status, stage, revision, cancel, error)) in stages.into_iter().enumerate() {
        let input = JobSnapshot {
            id: id.into(),
            state: status,
            stage: stage.into(),
            job_revision: revision,
            cancel_requested: cancel,
            result_id: None,
            error,
        };
        let before = snapshot(&mut client);
        save(&directory, &format!("commit-{index}-pre.json"), &before);
        save(
            &directory,
            &format!("commit-{index}-input.json"),
            &serde_json::to_value(&input).unwrap(),
        );
        jobs.insert(id.into(), serde_json::to_value(&input).unwrap());
        let started = chrono::Utc::now();
        persist_job(&state, &input).unwrap();
        let finished = chrono::Utc::now();
        let after = snapshot(&mut client);
        save(&directory, &format!("commit-{index}-post.json"), &after);
        let parameters = verify_commit(
            &before,
            &after,
            &actor.project_id,
            &actor.id,
            "job_updated",
            json!({id:input}),
            vec![id.into()],
            started,
            finished,
        );
        // The policy binds the affected input job; the header retains all jobs.
        save(
            &directory,
            &format!("commit-{index}-parameters.json"),
            &parameters,
        );
    }
    // A real PostgreSQL statement failure must roll back the durable job + audit
    // and must not publish the speculative repository into the application cache.
    client.batch_execute("CREATE FUNCTION public.pi_s12_refuse_job() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 's12 controlled publication refusal'; END $$; CREATE TRIGGER pi_s12_refuse_job BEFORE INSERT OR UPDATE ON public.pi_projects FOR EACH ROW EXECUTE FUNCTION public.pi_s12_refuse_job()").unwrap();
    let rejected = JobSnapshot {
        id: "job-103".into(),
        state: JobState::Queued,
        stage: "queued".into(),
        job_revision: 0,
        cancel_requested: false,
        result_id: None,
        error: None,
    };
    let before = snapshot(&mut client);
    save(&directory, "refusal-pre.json", &before);
    let cache_before = serde_json::to_value(&*state.repository.lock().unwrap()).unwrap();
    save(&directory, "refusal-cache-pre.json", &cache_before);
    let log_path = std::path::PathBuf::from(
        std::env::var("S12_JOB_PG_LOG").expect("owned PostgreSQL log required"),
    );
    let log_before = std::fs::metadata(&log_path).unwrap().len() as usize;
    let backends=client.query("SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND backend_type='client backend'",&[]).unwrap();
    assert!(
        backends.len() == 1,
        "one owned production database backend required"
    );
    let backend: i32 = backends[0].get(0);
    let result = persist_job(&state, &rejected);
    assert!(
        matches!(result,Err(ref error) if error.code=="storage_unavailable"),
        "controlled SQL failure must be returned"
    );
    let end = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let log_delta = loop {
        let bytes = std::fs::read(&log_path).unwrap();
        assert!(bytes.len() >= log_before, "owned log must not shrink");
        let delta = &bytes[log_before..];
        let text = String::from_utf8_lossy(delta);
        if text.lines().any(|line| {
            line.contains(&format!("[{backend}]"))
                && line.contains("ERROR:")
                && line.contains("s12 controlled publication refusal")
        }) {
            break delta.to_vec();
        }
        assert!(
            std::time::Instant::now() < end,
            "actual production backend refusal must appear in owned server log"
        );
        std::thread::sleep(std::time::Duration::from_millis(25));
    };
    save(
        &directory,
        "refusal-backend.json",
        &json!({"backend_pid":backend,"log_offset_before":log_before,"captured_bytes":log_delta.len(),"error_code":"storage_unavailable"}),
    );
    use std::io::Write;
    let mut log_file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(directory.join("refusal-server-log.txt"))
        .unwrap();
    log_file.write_all(&log_delta).unwrap();
    log_file.sync_all().unwrap();
    let after = snapshot(&mut client);
    save(&directory, "refusal-post.json", &after);
    assert!(
        before == after,
        "SQL refusal must conserve all managed/Auth/sequence state"
    );
    let cache_after = serde_json::to_value(&*state.repository.lock().unwrap()).unwrap();
    save(&directory, "refusal-cache-post.json", &cache_after);
    assert!(
        cache_before == cache_after,
        "failed SQL commit must not publish speculative cache"
    );
    save(
        &directory,
        "refusal-input.json",
        &serde_json::to_value(&rejected).unwrap(),
    );
    client.batch_execute("DROP TRIGGER pi_s12_refuse_job ON public.pi_projects; DROP FUNCTION public.pi_s12_refuse_job()").unwrap();
    drop(state);
    drop(platform);
    drop(root);
    let before = snapshot(&mut client);
    save(&directory, "restart-pre.json", &before);
    let input = jobs.get_mut("job-102").unwrap();
    input["state"] = json!("failed");
    input["stage"] = json!("interrupted");
    input["job_revision"] = json!(2);
    input["error"] = json!({"code":"interrupted","message":"Приложение было остановлено до подтверждения результата. Загрузите файл заново."});
    let started = chrono::Utc::now();
    let reopened = AppState::open(3096, url).unwrap();
    let finished = chrono::Utc::now();
    let after = snapshot(&mut client);
    save(&directory, "restart-post.json", &after);
    let parameters = verify_commit(
        &before,
        &after,
        &actor.project_id,
        "system",
        "jobs_interrupted_after_restart",
        Value::Object(jobs),
        vec!["job-102".into()],
        started,
        finished,
    );
    save(&directory, "restart-parameters.json", &parameters);
    drop(reopened);
}
