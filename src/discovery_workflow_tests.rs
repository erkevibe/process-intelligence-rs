use super::*;
use std::collections::BTreeMap;

#[test]
fn full_profile_discovery_has_explicit_identity_and_reproducible_saved_output() {
    let (mut meta, mut artifact) = fixture();
    meta.profile = Some(crate::dfg_discovery::PROFILE.into());
    artifact.input.profile = meta.profile.clone();
    artifact.input.variants = json!([{"sequence":["A","B","C"],"frequency":625}]);
    meta.variants_sha256 = store::input_hash(&artifact.input).unwrap();
    meta.method_sha256 = store::method_for(meta.profile.as_deref()).into();
    assert_eq!(
        store::identity(&meta).algorithm,
        crate::dfg_discovery::ALGORITHM
    );
    let output = store::compute(
        &artifact.input,
        Instant::now() + Duration::from_secs(30),
        &mut |_| Ok(()),
    )
    .unwrap();
    assert!(output.tree.is_none());
    assert_eq!(output.training_report["trace_count"], 625);
    meta.snapshot.state = JobState::Completed;
    meta.output_sha256 = Some(crate::storage::sha256(
        &quality::bytes(&output, store::MAX_OUTPUT).unwrap(),
    ));
    artifact.output = Some(output);
    store::validate_artifact(&meta, &artifact).unwrap();
    store::verify_restored(&meta, &artifact, Instant::now() + Duration::from_secs(30)).unwrap();
    let mut forged = artifact.clone();
    forged.output.as_mut().unwrap().training_report["metrics"]["precision"]["scalar"] = json!(0.5);
    let mut coherent = meta.clone();
    coherent.output_sha256 = Some(crate::storage::sha256(
        &quality::bytes(forged.output.as_ref().unwrap(), store::MAX_OUTPUT).unwrap(),
    ));
    assert!(
        store::verify_restored(&coherent, &forged, Instant::now() + Duration::from_secs(30))
            .is_err()
    );
}

#[test]
#[ignore = "fresh owned S36_CONTROL_DATABASE_URL pi_s36_control_test required"]
fn postgres_full_profile_cancel_revoke_and_interrupted_retry() {
    assert_eq!(
        std::env::var("S36_FULL_OWNED_FIXTURE").as_deref(),
        Ok("yes")
    );
    let url = std::env::var("S36_CONTROL_DATABASE_URL").unwrap();
    let config: postgres::Config = url.parse().unwrap();
    assert_eq!(config.get_dbname(), Some("pi_s36_control_test"));
    assert!(matches!(config.get_hosts(),[postgres::config::Host::Tcp(host)] if host=="127.0.0.1"));
    {
        let mut p = postgres::Client::connect(&url, postgres::NoTls).unwrap();
        let n: i64 = p
            .query_one(
                "SELECT count(*) FROM pg_tables WHERE schemaname='public'",
                &[],
            )
            .unwrap()
            .get(0);
        assert_eq!(n, 0);
    }
    let (session, project, completed, pending, bytes) = {
        let root = AppState::open(3147, url.clone()).unwrap();
        let p = root.platform.as_ref().unwrap().clone();
        let session = p
            .auth
            .setup("s36_owner", "S36ControlOwnerPassword123")
            .unwrap();
        let owner = p.auth.actor(&session).unwrap();
        let project = owner.project_id.clone();
        let mut s = p.scope(&root, owner.clone()).unwrap();
        s.session = Some(session.clone());
        let log = crate::domain::EventLog {
            name: None,
            warnings: vec![],
            cases: (0..625)
                .map(|i| crate::domain::Case {
                    id: format!("case-{i}"),
                    name: None,
                    events: ["A", "B", "C"]
                        .into_iter()
                        .enumerate()
                        .map(|(ordinal, activity)| crate::domain::Event {
                            ordinal,
                            activity: activity.into(),
                            timestamp: None,
                            lifecycle: None,
                        })
                        .collect(),
                })
                .collect(),
        };
        let id = crate::web::store_log(
            &s,
            log.clone(),
            crate::mining::analyze(&log),
            "Full control".into(),
            0,
            crate::storage::sha256(&serde_json::to_vec(&log).unwrap()),
            crate::csv_io::NormalizationOrder::Source,
            None,
        )
        .unwrap()
        .id
        .clone();
        let mut full = form(1);
        full.profile = Some(crate::dfg_discovery::PROFILE.into());
        let completed = run(&s, accept_new(&s, &id, &full), |_| {});
        assert_eq!(saved(&s, &completed).0.snapshot.state, JobState::Completed);
        let bytes = quality::bytes(saved(&s, &completed).1.as_ref(), store::MAX_ARTIFACT).unwrap();
        full.request_key = quality::request_key();
        let accepted = accept_new(&s, &id, &full);
        let job = accepted.launch.as_ref().unwrap().0.job.clone();
        let cancelled = run(&s, accepted, |stage| {
            if stage == "publish" {
                job.try_cancel_with(|snap| persist(&s, snap, None)).unwrap();
            }
        });
        assert_eq!(saved(&s, &cancelled).0.snapshot.state, JobState::Cancelled);
        assert!(saved(&s, &cancelled).1.output.is_none());
        assert_eq!(s.repository.lock().unwrap().model_count(), 1);
        p.auth
            .add_user(
                &owner,
                &session,
                "s36_editor",
                "S36ControlEditorPassword123",
            )
            .unwrap();
        p.auth
            .grant(
                &owner,
                &session,
                &project,
                "s36_editor",
                crate::auth::Role::Editor,
            )
            .unwrap();
        let editor_session = p
            .auth
            .login("s36_editor", "S36ControlEditorPassword123")
            .unwrap();
        p.auth.switch(&editor_session, &project).unwrap();
        let mut editor = p
            .scope(&root, p.auth.actor(&editor_session).unwrap())
            .unwrap();
        editor.session = Some(editor_session);
        full.request_key = quality::request_key();
        let accepted = accept_new(&editor, &id, &full);
        let revoked = run(&editor, accepted, |stage| {
            if stage == "publish" {
                p.auth
                    .grant(
                        &owner,
                        &session,
                        &project,
                        "s36_editor",
                        crate::auth::Role::Viewer,
                    )
                    .unwrap();
            }
        });
        assert_eq!(
            saved(&s, &revoked).0.snapshot.error.as_ref().unwrap().code,
            "access_denied"
        );
        assert!(saved(&s, &revoked).1.output.is_none());
        assert_eq!(s.repository.lock().unwrap().model_count(), 1);
        full.request_key = quality::request_key();
        let queued = accept_new(&s, &id, &full);
        let pending = queued.meta.snapshot.id.clone();
        drop(queued);
        (session, project, completed, pending, bytes)
    };
    let root = reopen(&url);
    let p = root.platform.as_ref().unwrap().clone();
    let mut s = p.scope(&root, p.auth.actor(&session).unwrap()).unwrap();
    s.session = Some(session);
    assert_eq!(s.actor.as_ref().unwrap().project_id, project);
    assert_eq!(saved(&s, &pending).0.snapshot.stage, "interrupted");
    assert!(saved(&s, &pending).1.output.is_none());
    assert_eq!(
        quality::bytes(saved(&s, &completed).1.as_ref(), store::MAX_ARTIFACT).unwrap(),
        bytes
    );
    let retried = run(
        &s,
        accept(&s, "", None, Some(&pending), &quality::request_key()).unwrap(),
        |_| {},
    );
    assert_eq!(saved(&s, &retried).0.snapshot.state, JobState::Completed);
    let repo = crate::repository_v2::load(&p.database, &project).unwrap();
    crate::platform::validate_backup(&repo).unwrap();
    println!(
        "{}",
        json!({"status":"S36_FULL_CANCEL_REVOKE_INTERRUPTED_RETRY_PASS","cases":625})
    );
}
fn input() -> DiscoveryInput {
    DiscoveryInput {
        profile: None,
        variants: json!([{"sequence":["A","B","B","C"],"frequency":10},{"sequence":["A","B","C"],"frequency":10}]),
    }
}
fn fixture() -> (DiscoveryMeta, DiscoveryArtifact) {
    let jobs = crate::jobs::JobStore::new();
    let lease = jobs.create_with_id(Some("job-1".into())).unwrap();
    let input = input();
    let m = DiscoveryMeta {
        profile: None,
        snapshot: lease.job.snapshot(),
        artifact_id: "discovery-2".into(),
        owner: "owner".into(),
        source_project_id: "project-fixture".into(),
        request_key: quality::request_key(),
        form_sha256: "a".repeat(64),
        created_at: chrono::Utc::now(),
        retry_of: None,
        log_id: "log-1".into(),
        log_name: "Обучение".into(),
        analysis_version: 1,
        source_sha256: "b".repeat(64),
        variants_sha256: store::input_hash(&input).unwrap(),
        method_sha256: store::method_sha256().into(),
        model_name: "Модель".into(),
        model_id: None,
        output_sha256: None,
    };
    (
        m,
        DiscoveryArtifact {
            id: "discovery-2".into(),
            input,
            output: None,
        },
    )
}
#[test]
fn stored_output_replay_rejects_coherent_numeric_forgery_and_bad_model_training() {
    let (mut m, mut a) = fixture();
    let output = store::compute(
        &a.input,
        Instant::now() + Duration::from_secs(30),
        &mut |_| Ok(()),
    )
    .unwrap();
    m.snapshot.state = JobState::Completed;
    m.snapshot.stage = "completed".into();
    m.snapshot.job_revision = 3;
    m.snapshot.result_id = Some(a.id.clone());
    m.model_id = Some("model-1".into());
    m.output_sha256 = Some(crate::storage::sha256(
        &quality::bytes(&output, store::MAX_OUTPUT).unwrap(),
    ));
    a.output = Some(output);
    store::validate_artifact(&m, &a).unwrap();
    store::verify_restored(&m, &a, Instant::now() + Duration::from_secs(30)).unwrap();
    let mut forged = a.clone();
    forged.output.as_mut().unwrap().training_report["metrics"]["fitness"]["fitness"]["log_fitness"] =
        json!(0.125);
    let mut declared = m.clone();
    declared.output_sha256 = Some(crate::storage::sha256(
        &quality::bytes(forged.output.as_ref().unwrap(), store::MAX_OUTPUT).unwrap(),
    ));
    store::validate_artifact(&declared, &forged).unwrap();
    assert!(
        store::verify_restored(&declared, &forged, Instant::now() + Duration::from_secs(30))
            .is_err()
    );
    let mut repo = Repository::default();
    let model = crate::platform::StoredModel {
        id: "model-1".into(),
        name: "Модель".into(),
        revision: 1,
        model: a.output.unwrap().model,
        source_log: Some(m.log_id.clone()),
        training: Some(store::identity(&m)),
    };
    repo.models.insert(model.id.clone(), Arc::new(model));
    crate::platform::validate_backup(&repo).unwrap();
    let mut bad = repo.clone();
    Arc::make_mut(bad.models.get_mut("model-1").unwrap())
        .training
        .as_mut()
        .unwrap()
        .log_id = "bad".into();
    assert!(crate::platform::validate_backup(&bad).is_err());
    let mut mismatched = repo;
    Arc::make_mut(mismatched.models.get_mut("model-1").unwrap()).source_log = Some("log-99".into());
    assert!(crate::platform::validate_backup(&mismatched).is_err());
}
#[test]
fn interrupted_recovery_and_shared_namespace_preserve_inputs() {
    let (m, a) = fixture();
    let mut h = crate::repository_v2::Header::default();
    h.discovery_jobs.insert(m.snapshot.id.clone(), m.clone());
    h.validate().unwrap();
    assert!(h.recover());
    assert_eq!(h.discovery_jobs["job-1"].snapshot.stage, "interrupted");
    assert!(!h.recover());
    assert_eq!(store::input_hash(&a.input).unwrap(), m.variants_sha256);
    let s = AppState::new(3147);
    let mut r = Repository::default();
    r.discovery_jobs.insert(m.snapshot.id.clone(), m.clone());
    let id = s.allocate_import_job(&r).unwrap();
    assert_ne!(id, "job-1");
    let (id, artifact, _) = s.allocate_job_pair(&r, "quality").unwrap();
    assert_ne!(id, "job-1");
    assert!(artifact.starts_with("quality-"));
    let mut wrong = m;
    wrong.snapshot.result_id = Some("model-1".into());
    assert!(
        store::validate_metadata(
            &BTreeMap::from([(wrong.snapshot.id.clone(), wrong)]),
            &BTreeMap::new()
        )
        .is_err()
    );
}
fn seed(s: &AppState) -> String {
    let mut log = crate::domain::EventLog {
        name: None,
        warnings: vec![],
        cases: vec![],
    };
    for (id, sequence) in [vec!["A", "B", "C"], vec!["A", "B", "B", "C"]]
        .into_iter()
        .enumerate()
    {
        log.cases.push(crate::domain::Case {
            id: format!("case-{id}"),
            name: None,
            events: sequence
                .into_iter()
                .enumerate()
                .map(|(ordinal, label)| crate::domain::Event {
                    ordinal,
                    activity: label.into(),
                    timestamp: None,
                    lifecycle: None,
                })
                .collect(),
        })
    }
    let hash = crate::storage::sha256(&serde_json::to_vec(&log).unwrap());
    crate::web::store_log(
        s,
        log.clone(),
        crate::mining::analyze(&log),
        "<img onerror=x> обучение".into(),
        0,
        hash,
        crate::csv_io::NormalizationOrder::Source,
        None,
    )
    .unwrap()
    .id
    .clone()
}
fn form(version: u64) -> SubmitForm {
    SubmitForm {
        profile: None,
        analysis_version: version,
        model_name: "<script>bad()</script> Модель".into(),
        request_key: quality::request_key(),
    }
}
fn accept_new(s: &AppState, log: &str, f: &SubmitForm) -> Accepted {
    accept(s, log, Some(f), None, &f.request_key).unwrap()
}
fn run(s: &AppState, a: Accepted, observer: impl FnMut(&str)) -> String {
    let id = a.meta.snapshot.id.clone();
    let (lease, input) = a.launch.unwrap();
    compute_job(s, lease, input, observer).unwrap();
    id
}
fn saved(s: &AppState, id: &str) -> (DiscoveryMeta, Arc<DiscoveryArtifact>) {
    let m = s.repository.lock().unwrap().discovery_jobs[id].clone();
    let a = store::load_artifact(
        &s.platform.as_ref().unwrap().database,
        &s.actor.as_ref().unwrap().project_id,
        &m,
    )
    .unwrap();
    (m, a)
}
fn remove(s: &AppState, id: &str) {
    let mut repo = s.repository.lock().unwrap();
    let m = repo.discovery_jobs[id].clone();
    let mut next = repo.clone();
    next.discovery_jobs.remove(id);
    next.discovery_artifacts.remove(&m.artifact_id);
    next.deleted_discovery_ids.insert(m.artifact_id);
    s.commit_action_resources(&mut next, "discovery_deleted", vec![id.into()])
        .unwrap();
    *repo = next;
    drop(repo);
    s.discovery_jobs.remove_terminal(id);
}
fn reopen(url: &str) -> AppState {
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        match AppState::open(3147, url.into()) {
            Ok(s) => return s,
            Err(e) if e.code == "app_already_running" && Instant::now() < until => {
                std::thread::sleep(Duration::from_millis(25))
            }
            Err(e) => panic!("reopen:{}", e.code),
        }
    }
}
#[test]
#[ignore = "fresh isolated S28_DISCOVERY_DATABASE_URL pi_s28_discovery_core and empty S28_DISCOVERY_EVIDENCE required"]
fn postgres_durable_discovery_publication_retries_revocation_and_recovery() {
    let url =
        std::env::var("S28_DISCOVERY_DATABASE_URL").expect("isolated URL required; do not print");
    assert!(url.contains("/pi_s28_discovery_core"));
    {
        let mut probe = postgres::Client::connect(&url, postgres::NoTls).unwrap();
        assert!(probe.query_one("SELECT current_database() LIKE 'pi_s28_discovery_core%' AND to_regclass('public.pi_schema_migrations') IS NULL",&[]).unwrap().get::<_,bool>(0));
    }
    let output = std::path::PathBuf::from(std::env::var("S28_DISCOVERY_EVIDENCE").unwrap());
    assert!(output.is_dir() && std::fs::read_dir(&output).unwrap().next().is_none());
    let (session, project, finished, pending, stable_bytes) = {
        let root = AppState::open(3147, url.clone()).unwrap();
        let p = root.platform.as_ref().unwrap().clone();
        let session = p
            .auth
            .setup("s28_owner", "S28DiscoveryOwnerPassword123")
            .unwrap();
        let owner = p.auth.actor(&session).unwrap();
        let project = owner.project_id.clone();
        let mut s = p.scope(&root, owner.clone()).unwrap();
        s.session = Some(session.clone());
        let log = seed(&s);
        let f = form(1);
        let first = accept_new(&s, &log, &f);
        let id = first.meta.snapshot.id.clone();
        let revision = s.repository.lock().unwrap().storage_revision;
        assert!(accept_new(&s, &log, &f).launch.is_none());
        assert_eq!(s.repository.lock().unwrap().storage_revision, revision);
        let mut conflicting = SubmitForm {
            profile: None,
            analysis_version: f.analysis_version,
            model_name: "Different".into(),
            request_key: f.request_key.clone(),
        };
        assert_eq!(
            accept(&s, &log, Some(&conflicting), None, &conflicting.request_key)
                .err()
                .unwrap()
                .code,
            "discovery_request_conflict"
        );
        conflicting.request_key = format!(
            "{}.{}",
            chrono::Utc::now().timestamp() - quality::KEY_SECONDS - 31,
            uuid::Uuid::new_v4()
        );
        assert_eq!(
            accept(&s, &log, Some(&conflicting), None, &conflicting.request_key)
                .err()
                .unwrap()
                .code,
            "discovery_request_expired"
        );
        assert_eq!(s.repository.lock().unwrap().storage_revision, revision);
        let held = s.jobs.reserve().unwrap();
        assert!(s.conversion_jobs.reserve().is_err());
        drop(held);
        let cancel = first.launch.as_ref().unwrap().0.job.clone();
        let cancelled = run(&s, first, |stage| {
            if stage == "publish" {
                cancel
                    .try_cancel_with(|snapshot| persist(&s, snapshot, None))
                    .unwrap();
            }
        });
        assert_eq!(cancelled, id);
        assert_eq!(saved(&s, &id).0.snapshot.state, JobState::Cancelled);
        assert_eq!(s.repository.lock().unwrap().model_count(), 0);
        let successful = run(&s, accept_new(&s, &log, &form(1)), |_| {});
        let (done, a) = saved(&s, &successful);
        assert_eq!(done.snapshot.state, JobState::Completed);
        assert_eq!(s.repository.lock().unwrap().model_count(), 1);
        let model = s
            .repository
            .lock()
            .unwrap()
            .get_model(&s, done.model_id.as_ref().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(model.training.as_ref().unwrap(), &store::identity(&done));
        assert_eq!(
            crate::quality_store::training_relation(
                &model,
                &project,
                &log,
                1,
                &done.source_sha256,
                &done.variants_sha256
            ),
            "training_snapshot"
        );
        std::fs::write(
            output.join("confirmed-discovery-report.json"),
            serde_json::to_vec(&json!({"metadata":done,"artifact":a})).unwrap(),
        )
        .unwrap();
        let stable_bytes = quality::bytes(a.as_ref(), store::MAX_ARTIFACT).unwrap();
        let stale = accept_new(&s, &log, &form(1));
        let stale_id = stale.meta.snapshot.id.clone();
        {
            let mut repo = s.repository.lock().unwrap();
            let mut changed = repo.get_log_base(&s, &log).unwrap().unwrap();
            changed.analysis_version += 1;
            let mut next = repo.clone();
            next.logs.insert(log.clone(), changed);
            s.commit_action_resources(&mut next, "filter_applied", vec![log.clone()])
                .unwrap();
            *repo = next;
        }
        run(&s, stale, |_| {});
        assert_eq!(
            saved(&s, &stale_id).0.snapshot.error.as_ref().unwrap().code,
            "discovery_conflict"
        );
        assert_eq!(s.repository.lock().unwrap().model_count(), 1);
        let retry_key = quality::request_key();
        let retry = accept(&s, "", None, Some(&stale_id), &retry_key).unwrap();
        let retry_id = retry.meta.snapshot.id.clone();
        remove(&s, &stale_id);
        assert!(
            accept(&s, "", None, Some(&stale_id), &retry_key)
                .unwrap()
                .launch
                .is_none()
        );
        run(&s, retry, |_| {});
        let (retried, old_input) = saved(&s, &retry_id);
        assert_eq!(retried.snapshot.state, JobState::Completed);
        assert_eq!(retried.analysis_version, 1);
        assert_eq!(s.repository.lock().unwrap().model_count(), 2);
        assert_eq!(
            store::input_hash(&old_input.input).unwrap(),
            retried.variants_sha256
        );
        remove(&s, &retry_id);
        assert_eq!(
            accept(&s, "", None, Some(&stale_id), &retry_key)
                .err()
                .unwrap()
                .code,
            "discovery_deleted"
        );
        p.auth
            .add_user(
                &owner,
                &session,
                "s28_editor",
                "S28DiscoveryMemberPassword123",
            )
            .unwrap();
        p.auth
            .grant(
                &owner,
                &session,
                &project,
                "s28_editor",
                crate::auth::Role::Editor,
            )
            .unwrap();
        let editor_session = p
            .auth
            .login("s28_editor", "S28DiscoveryMemberPassword123")
            .unwrap();
        p.auth.switch(&editor_session, &project).unwrap();
        let mut editor = p
            .scope(&root, p.auth.actor(&editor_session).unwrap())
            .unwrap();
        editor.session = Some(editor_session);
        let revoked = accept_new(&editor, &log, &form(2));
        let denied = run(&editor, revoked, |stage| {
            if stage == "publish" {
                p.auth
                    .grant(
                        &owner,
                        &session,
                        &project,
                        "s28_editor",
                        crate::auth::Role::Viewer,
                    )
                    .unwrap();
            }
        });
        assert_eq!(
            saved(&s, &denied).0.snapshot.error.as_ref().unwrap().code,
            "access_denied"
        );
        assert_eq!(s.repository.lock().unwrap().model_count(), 2);
        let queued = accept_new(&s, &log, &form(2));
        let pending = queued.meta.snapshot.id.clone();
        drop(queued);
        (session, project, successful, pending, stable_bytes)
    };
    let root = reopen(&url);
    let p = root.platform.as_ref().unwrap().clone();
    let mut s = p.scope(&root, p.auth.actor(&session).unwrap()).unwrap();
    s.session = Some(session);
    assert_eq!(s.actor.as_ref().unwrap().project_id, project);
    let (interrupted, a) = saved(&s, &pending);
    assert_eq!(interrupted.snapshot.stage, "interrupted");
    assert!(a.output.is_none());
    assert_eq!(
        quality::bytes(saved(&s, &finished).1.as_ref(), store::MAX_ARTIFACT).unwrap(),
        stable_bytes
    );
    let retried = run(
        &s,
        accept(&s, "", None, Some(&pending), &quality::request_key()).unwrap(),
        |_| {},
    );
    assert_eq!(saved(&s, &retried).0.snapshot.state, JobState::Completed);
    let materialized = crate::repository_v2::load(&p.database, &project).unwrap();
    crate::platform::validate_backup(&materialized).unwrap();
    std::fs::write(output.join("core-proof.json"),serde_json::to_vec_pretty(&json!({"status":"S28_PG_DISCOVERY_CORE_PASS","completed":finished,"recovered":pending,"retry":retried,"cases":["replay","shared_slots","cancel_at_publication","model_and_training_atomic","stale_first_submit","historical_retry","replay_after_deleted_original","revoked_at_publication","restart_interrupted","stable_completed_bytes","explicit_retry_after_restart","full_backup_replay"]})).unwrap()).unwrap();
}
