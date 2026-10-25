use super::*;
use std::collections::BTreeMap;

#[test]
fn explicit_full_profile_export_replays_and_refuses_numeric_forgery() {
    let (mut meta, mut artifact) = fixture();
    artifact.input.profile = Some(crate::dfg_discovery::PROFILE.into());
    artifact.input.variants = json!([{"sequence":["A","B","C"],"frequency":625}]);
    meta.profile = artifact.input.profile.clone();
    meta.method_sha256 = crate::dfg_discovery::method_sha256().into();
    (meta.model_sha256, meta.variants_sha256) = store::input_hashes(&artifact.input).unwrap();
    let report = crate::dfg_discovery::evaluate(
        &artifact.input.model,
        &artifact.input.variants,
        &mut |_| Ok(()),
    )
    .unwrap();
    assert_eq!(report["trace_count"], 625);
    meta.snapshot.state = JobState::Completed;
    let envelope = store::envelope(&meta, report);
    meta.report_sha256 = Some(crate::storage::sha256(
        &store::bytes(&envelope, store::MAX_REPORT).unwrap(),
    ));
    artifact.report = Some(envelope.clone());
    store::validate_artifact(&meta, &artifact).unwrap();
    let export = json!({"schema_version":1,"method_sha256":meta.method_sha256,"evaluation":envelope,"input":artifact.input});
    let bytes = serde_json::to_vec(&export).unwrap();
    assert_eq!(
        crate::full_log_saved::verify_any(&bytes).unwrap()["numeric_replay"],
        true
    );
    assert!(crate::bpmn_quality::saved::verify_export_bytes(&bytes).is_err());
    let mut forged = export.clone();
    forged["evaluation"]["report"]["metrics"]["fitness"]["fitness"]["log_fitness"] = json!(0.5);
    assert_eq!(
        crate::full_log_saved::verify_any(&serde_json::to_vec(&forged).unwrap())
            .unwrap_err()
            .code,
        "quality_report_mismatch"
    );
    let mut wrong_profile = artifact.clone();
    wrong_profile.input.profile = None;
    assert!(store::validate_artifact(&meta, &wrong_profile).is_err());
}

fn fixture() -> (QualityMeta, QualityArtifact) {
    let model = crate::bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap();
    let input = QualityInput {
        profile: None,
        model,
        variants: json!([{"sequence":["A","B","C"],"frequency":1}]),
    };
    let (model_sha256, variants_sha256) = store::input_hashes(&input).unwrap();
    let jobs = crate::jobs::JobStore::new();
    let lease = jobs.create_with_id(Some("job-1".into())).unwrap();
    let m = QualityMeta {
        profile: None,
        snapshot: lease.job.snapshot(),
        artifact_id: "quality-2".into(),
        owner: "owner".into(),
        source_project_id: "project-fixture".into(),
        request_key: store::request_key(),
        form_sha256: "a".repeat(64),
        created_at: chrono::Utc::now(),
        retry_of: None,
        model_id: "model-1".into(),
        model_name: "Модель".into(),
        model_revision: 1,
        log_id: "log-1".into(),
        log_name: "Журнал".into(),
        analysis_version: 1,
        source_sha256: "b".repeat(64),
        on_construction_log: true,
        training_relation: None,
        model_sha256,
        variants_sha256,
        method_sha256: store::method_sha256().into(),
        report_sha256: None,
    };
    let a = QualityArtifact {
        id: m.artifact_id.clone(),
        input,
        report: None,
    };
    (m, a)
}
#[test]
fn immutable_quality_inputs_and_terminal_reports_are_bound_and_bounded() {
    let (mut m, mut a) = fixture();
    assert!(
        store::validate_metadata(
            &BTreeMap::from([(m.snapshot.id.clone(), m.clone())]),
            &BTreeMap::new()
        )
        .is_ok()
    );
    store::validate_artifact(&m, &a).unwrap();
    a.input.variants[0]["frequency"] = json!(2);
    assert!(store::validate_artifact(&m, &a).is_err());
    a.input.variants[0]["frequency"] = json!(1);
    let core = facade::evaluate_model(&a.input.model, &a.input.variants, &Value::Null, &mut |_| {
        Ok(())
    })
    .unwrap();
    m.snapshot.state = JobState::Completed;
    m.snapshot.stage = "completed".into();
    m.snapshot.result_id = Some(a.id.clone());
    m.snapshot.job_revision = 2;
    let report = store::envelope(&m, core);
    m.report_sha256 = Some(crate::storage::sha256(
        &store::bytes(&report, store::MAX_REPORT).unwrap(),
    ));
    a.report = Some(report);
    store::validate_artifact(&m, &a).unwrap();
    let exported=store::bytes(&json!({"schema_version":1,"method_sha256":m.method_sha256,"evaluation":a.report,"input":a.input}),store::MAX_ARTIFACT+16*1024).unwrap();
    assert_eq!(
        crate::bpmn_quality::saved::verify_export_bytes(&exported).unwrap()["status"],
        "quality_report_verified"
    );
    let mut changed: Value = serde_json::from_slice(&exported).unwrap();
    changed["evaluation"]["report"]["metrics"]["precision"]["scalar"] = json!(0.5);
    assert_eq!(
        crate::bpmn_quality::saved::verify_export_bytes(&serde_json::to_vec(&changed).unwrap())
            .unwrap_err()
            .code,
        "quality_report_mismatch"
    );
    let mut repository = Repository::default();
    repository
        .quality_jobs
        .insert(m.snapshot.id.clone(), m.clone());
    repository
        .quality_artifacts
        .insert(a.id.clone(), Arc::new(a.clone()));
    crate::platform::validate_backup(&repository).unwrap();
    let mut forged = a.clone();
    forged.report.as_mut().unwrap()["report"]["metrics"]["precision"]["scalar"] = json!(0.5);
    let mut forged_meta = m.clone();
    forged_meta.report_sha256 = Some(crate::storage::sha256(
        &store::bytes(forged.report.as_ref().unwrap(), store::MAX_REPORT).unwrap(),
    ));
    repository
        .quality_jobs
        .insert(forged_meta.snapshot.id.clone(), forged_meta);
    repository
        .quality_artifacts
        .insert(forged.id.clone(), Arc::new(forged));
    store::validate_full(&repository).unwrap();
    assert_eq!(
        crate::platform::validate_backup(&repository)
            .unwrap_err()
            .code,
        "quality_report_mismatch"
    );
    assert_eq!(
        crate::bpmn_quality::saved::verify_export_with_deadline(
            &exported,
            Instant::now() - Duration::from_secs(1)
        )
        .unwrap_err()
        .code,
        "quality_verification_limit"
    );
    a.report.as_mut().unwrap()["model_revision"] = json!(9);
    assert!(store::validate_artifact(&m, &a).is_err());
    a.report.as_mut().unwrap()["model_revision"] = json!(1);
    a.report.as_mut().unwrap()["report"]["metrics"]["precision"]["scalar"] = json!(7);
    m.report_sha256 = Some(crate::storage::sha256(
        &store::bytes(a.report.as_ref().unwrap(), store::MAX_REPORT).unwrap(),
    ));
    assert!(store::validate_artifact(&m, &a).is_err());
    assert!(store::bytes(&"x".repeat(store::MAX_REPORT), store::MAX_REPORT).is_err());
}
#[test]
fn request_receipts_are_bounded_and_expire_only_after_form_lifetime() {
    let (m, _) = fixture();
    let issued = store::key_time(&m.request_key).unwrap();
    let mut receipt = RequestReceipt {
        owner: m.owner.clone(),
        job_id: m.snapshot.id.clone(),
        form_sha256: m.form_sha256.clone(),
        expires_at: issued + store::KEY_SECONDS + 30,
        retry_of: None,
    };
    let all = BTreeMap::from([(m.snapshot.id.clone(), m.clone())]);
    store::validate_metadata(
        &all,
        &BTreeMap::from([(m.request_key.clone(), receipt.clone())]),
    )
    .unwrap();
    receipt.expires_at -= 1;
    assert!(
        store::validate_metadata(&all, &BTreeMap::from([(m.request_key.clone(), receipt)]))
            .is_err()
    );
    assert!(store::key_time("1700000000.00000000-0000-1000-8000-000000000000").is_none());
    assert!(store::key_time("1700000000.00000000-0000-4000-8000-00000000000A").is_none());
    let mut header = crate::repository_v2::Header {
        quality_jobs: all,
        ..Default::default()
    };
    assert!(header.recover());
    let recovered = &header.quality_jobs[&m.snapshot.id];
    assert_eq!(
        recovered.snapshot.error.as_ref().unwrap().code,
        "interrupted"
    );
    assert_eq!(recovered.snapshot.job_revision, m.snapshot.job_revision + 1);
    assert!(!header.recover());
}
#[test]
fn stages_are_persisted_before_publication_and_cancellation_keeps_lease() {
    let jobs = crate::jobs::JobStore::new();
    let lease = jobs.create().unwrap();
    let job = lease.job.clone();
    let queued = job.snapshot();
    assert!(
        job.try_start_with("validate", |_| Err(error("storage_unavailable", "fail")))
            .is_err()
    );
    assert_eq!(job.snapshot(), queued);
    assert!(
        job.try_start_with("validate", |s| {
            assert_eq!(s.state, JobState::Running);
            Ok(())
        })
        .unwrap()
    );
    let running = job.snapshot();
    assert!(
        job.try_set_stage_with("fitness", |_| Err(error("storage_unavailable", "fail")))
            .is_err()
    );
    assert_eq!(job.snapshot(), running);
    job.try_cancel_with(|s| {
        assert!(s.is_terminal());
        Ok(())
    })
    .unwrap();
    let mut called = false;
    job.try_set_stage_with("fitness", |_| {
        called = true;
        Ok(())
    })
    .unwrap();
    assert!(!called);
    assert_eq!(jobs.shared_slots().available_permits(), 1);
    drop(lease);
    assert_eq!(jobs.shared_slots().available_permits(), 2);
}
#[test]
fn quality_allocation_skips_retained_jobs_and_artifacts() {
    let state = AppState::new(3000);
    let (mut meta, _) = fixture();
    let mut repo = Repository::default();
    let mut existing = meta.snapshot.clone();
    existing.id = "job-1".into();
    repo.durable_jobs.insert(existing.id.clone(), existing);
    meta.snapshot.id = "job-6".into();
    meta.artifact_id = "quality-3".into();
    repo.quality_jobs.insert(meta.snapshot.id.clone(), meta);
    let (id, artifact, sequence) = state.allocate_job_pair(&repo, "quality").unwrap();
    assert_eq!(id, "job-4");
    assert_eq!(artifact, "quality-5");
    assert_eq!(sequence, 5);
    assert!(repo.quality_jobs.contains_key("job-6"));
    repo.sequence = u64::MAX - 1;
    assert_eq!(
        state.allocate_job_pair(&repo, "quality").unwrap_err().code,
        "sequence_exhausted"
    );
}

fn event_log() -> crate::domain::EventLog {
    crate::domain::EventLog {
        name: None,
        warnings: vec![],
        cases: vec![crate::domain::Case {
            id: "case-1".into(),
            name: None,
            events: ["A", "B", "C"]
                .into_iter()
                .enumerate()
                .map(|(ordinal, label)| crate::domain::Event {
                    ordinal,
                    activity: label.into(),
                    timestamp: None,
                    lifecycle: None,
                })
                .collect(),
        }],
    }
}
fn seed(state: &AppState) -> (String, String) {
    let log = event_log();
    let source_sha = crate::storage::sha256(&serde_json::to_vec(&log).unwrap());
    let log_id = crate::web::store_log(
        state,
        log.clone(),
        crate::mining::analyze(&log),
        "<img onerror=x> журнал".into(),
        0,
        source_sha,
        crate::csv_io::NormalizationOrder::Source,
        None,
    )
    .unwrap()
    .id
    .clone();
    let model_id = crate::platform::insert_model(
        state,
        crate::bpmn::parse(include_bytes!("../fixtures/quality/linear.bpmn")).unwrap(),
        "<script>bad()</script> модель".into(),
        Some(log_id.clone()),
    )
    .unwrap();
    (log_id, model_id)
}
fn submission(log: &str, revision: u64) -> SubmitForm {
    SubmitForm {
        profile: None,
        log_id: log.into(),
        revision,
        request_key: store::request_key(),
    }
}
fn completed(state: &AppState, id: &str) -> (QualityMeta, Arc<QualityArtifact>) {
    let meta = state.repository.lock().unwrap().quality_jobs[id].clone();
    let project = &state.actor.as_ref().unwrap().project_id;
    let artifact =
        store::load_artifact(&state.platform.as_ref().unwrap().database, project, &meta).unwrap();
    (meta, artifact)
}
fn run_accepted(state: &AppState, accepted: Accepted, observer: impl FnMut(&str)) -> String {
    let id = accepted.meta.snapshot.id.clone();
    let (lease, input) = accepted.launch.expect("new acceptance");
    compute_job(state, lease, input, observer).unwrap();
    id
}
fn delete_saved(state: &AppState, id: &str) {
    let mut repo = state.repository.lock().unwrap();
    let m = repo.quality_jobs[id].clone();
    assert!(m.snapshot.is_terminal());
    let mut next = repo.clone();
    next.quality_jobs.remove(id);
    next.quality_artifacts.remove(&m.artifact_id);
    next.deleted_quality_ids.insert(m.artifact_id);
    state
        .commit_action_resources(&mut next, "quality_deleted", vec![id.into()])
        .unwrap();
    *repo = next;
    drop(repo);
    state.quality_jobs.remove_terminal(id);
}
fn reopen(url: &str) -> AppState {
    let until = Instant::now() + Duration::from_secs(5);
    loop {
        match AppState::open(3147, url.into()) {
            Ok(state) => return state,
            Err(e) if e.code == "app_already_running" && Instant::now() < until => {
                std::thread::sleep(Duration::from_millis(25))
            }
            Err(e) => panic!("reopen: {}", e.code),
        }
    }
}

#[test]
#[ignore = "fresh isolated S26_QUALITY_DATABASE_URL (pi_s26_quality_core) and empty S26_QUALITY_EVIDENCE required"]
fn postgres_durable_acceptance_cancellation_revocation_recovery_and_receipts() {
    let url =
        std::env::var("S26_QUALITY_DATABASE_URL").expect("isolated URL required; do not print");
    assert!(url.contains("/pi_s26_quality_core"));
    {
        let mut probe = postgres::Client::connect(&url, postgres::NoTls).unwrap();
        let name: String = probe
            .query_one("SELECT current_database()", &[])
            .unwrap()
            .get(0);
        assert!(name.starts_with("pi_s26_quality_core"));
        assert!(
            probe
                .query_one(
                    "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
                    &[]
                )
                .unwrap()
                .get::<_, bool>(0)
        );
    }
    let output = std::path::PathBuf::from(std::env::var("S26_QUALITY_EVIDENCE").unwrap());
    assert!(output.is_dir() && std::fs::read_dir(&output).unwrap().next().is_none());
    let (
        session,
        project,
        complete_id,
        interrupted_id,
        original_form,
        report_bytes,
        model_id,
        log_id,
    ) = {
        let root = AppState::open(3147, url.clone()).unwrap();
        let platform = root.platform.as_ref().unwrap().clone();
        assert!(platform.auth.needs_setup());
        let session = platform
            .auth
            .setup("s26_owner", "S26QualityOwnerPassword123")
            .unwrap();
        let actor = platform.auth.actor(&session).unwrap();
        let project = actor.project_id.clone();
        let mut state = platform.scope(&root, actor.clone()).unwrap();
        state.session = Some(session.clone());
        let (log_id, model_id) = seed(&state);
        // A restored header can contain IDs ahead of a fresh DB sequence.
        // Import allocation must skip other job kinds, without replacing them.
        {
            let marker = state.next_id(0).unwrap();
            let mut restored = state.repository.lock().unwrap().clone();
            let (mut retained, _) = fixture();
            retained.snapshot.id = format!("job-{}", marker + 1);
            restored
                .quality_jobs
                .insert(retained.snapshot.id.clone(), retained.clone());
            let mut import = retained.snapshot.clone();
            import.id = format!("job-{}", marker + 2);
            restored.durable_jobs.insert(import.id.clone(), import);
            assert_eq!(
                state.allocate_import_job(&restored).unwrap(),
                format!("job-{}", marker + 3)
            );
            assert!(restored.quality_jobs.contains_key(&retained.snapshot.id));
        }
        let form = submission(&log_id, 1);
        let first = accept(&state, &model_id, &form, None).unwrap();
        let first_id = first.meta.snapshot.id.clone();
        let revision = state.repository.lock().unwrap().storage_revision;
        let replay = accept(&state, &model_id, &form, None).unwrap();
        assert!(replay.launch.is_none());
        assert_eq!(replay.meta.snapshot.id, first_id);
        assert_eq!(state.repository.lock().unwrap().storage_revision, revision);
        let mut different = form.clone();
        different.revision += 1;
        assert_eq!(
            accept(&state, &model_id, &different, None)
                .err()
                .unwrap()
                .code,
            "quality_request_conflict"
        );
        let occupied = state.jobs.create().unwrap();
        assert_eq!(
            accept(&state, &model_id, &submission(&log_id, 1), None)
                .err()
                .unwrap()
                .code,
            "job_queue_full"
        );
        assert_eq!(state.repository.lock().unwrap().storage_revision, revision);
        drop(occupied);
        run_accepted(&state, first, |_| {});
        let (meta, saved) = completed(&state, &first_id);
        assert_eq!(meta.snapshot.state, JobState::Completed);
        assert_eq!(
            saved.report.as_ref().unwrap()["report"]["metrics"]["fitness"]["fitness"]["log_fitness"],
            1.0
        );
        let report_bytes = store::bytes(saved.report.as_ref().unwrap(), store::MAX_REPORT).unwrap();
        let raw=store::bytes(&json!({"schema_version":1,"method_sha256":meta.method_sha256,"evaluation":saved.report,"input":saved.input}),store::MAX_ARTIFACT+16*1024).unwrap();
        std::fs::write(output.join("confirmed-report.json"), raw).unwrap();
        // Cancellation is committed before a queued worker can start.
        let queued_form = submission(&log_id, 1);
        let queued = accept(&state, &model_id, &queued_form, None).unwrap();
        let queued_id = queued.meta.snapshot.id.clone();
        state
            .quality_jobs
            .get(&queued_id)
            .unwrap()
            .try_cancel_with(|s| persist(&state, s, None))
            .unwrap();
        assert_eq!(state.jobs.shared_slots().available_permits(), 1);
        run_accepted(&state, queued, |_| {});
        assert_eq!(
            completed(&state, &queued_id).0.snapshot.state,
            JobState::Cancelled
        );
        // Cancellation wins at the publication fence after the calculation.
        let publishing = accept(&state, &model_id, &submission(&log_id, 1), None).unwrap();
        let cancelled_id = publishing.meta.snapshot.id.clone();
        let job = state.quality_jobs.get(&cancelled_id).unwrap();
        run_accepted(&state, publishing, |stage| {
            if stage == "publish" {
                job.try_cancel_with(|s| persist(&state, s, None)).unwrap();
            }
        });
        assert_eq!(
            completed(&state, &cancelled_id).0.snapshot.state,
            JobState::Cancelled
        );
        assert!(completed(&state, &cancelled_id).1.report.is_none());
        let retry_form = submission(&log_id, 1);
        let retry_key = retry_form.request_key.clone();
        let child = accept(&state, &model_id, &retry_form, Some(&queued_id)).unwrap();
        let child_id = run_accepted(&state, child, |_| {});
        delete_saved(&state, &queued_id);
        assert_eq!(
            retry_replay(&state, &queued_id, &retry_key)
                .unwrap()
                .unwrap()
                .snapshot
                .id,
            child_id
        );
        assert_eq!(
            retry_replay(&state, "job-999", &retry_key)
                .err()
                .unwrap()
                .code,
            "quality_request_conflict"
        );
        delete_saved(&state, &child_id);
        assert_eq!(
            retry_replay(&state, &queued_id, &retry_key)
                .err()
                .unwrap()
                .code,
            "quality_deleted"
        );
        assert_eq!(
            accept(&state, &model_id, &queued_form, None)
                .err()
                .unwrap()
                .code,
            "quality_deleted"
        );
        // Accepted immutable input cannot publish under a changed live revision.
        let changing = accept(&state, &model_id, &submission(&log_id, 1), None).unwrap();
        let conflict_id = changing.meta.snapshot.id.clone();
        run_accepted(&state, changing, |stage| {
            if stage == "publish" {
                let mut repo = state.repository.lock().unwrap();
                let mut model = (*repo.get_model(&state, &model_id).unwrap().unwrap()).clone();
                model.revision += 1;
                let mut next = repo.clone();
                next.models.insert(model_id.clone(), Arc::new(model));
                state
                    .commit_action_resources(&mut next, "model_saved", vec![model_id.clone()])
                    .unwrap();
                *repo = next;
            }
        });
        let (conflict, artifact) = completed(&state, &conflict_id);
        assert_eq!(
            conflict.snapshot.error.as_ref().unwrap().code,
            "quality_conflict"
        );
        assert!(artifact.report.is_none());
        assert_eq!(
            accept(
                &state,
                &model_id,
                &submission(&log_id, 1),
                Some(&conflict_id)
            )
            .err()
            .unwrap()
            .code,
            "quality_conflict"
        );
        // Revocation prevents result publication, but internal failure is durable.
        platform
            .auth
            .add_user(
                &actor,
                &session,
                "s26_editor",
                "S26QualityMemberPassword123",
            )
            .unwrap();
        platform
            .auth
            .grant(
                &actor,
                &session,
                &project,
                "s26_editor",
                crate::auth::Role::Editor,
            )
            .unwrap();
        let editor_session = platform
            .auth
            .login("s26_editor", "S26QualityMemberPassword123")
            .unwrap();
        platform.auth.switch(&editor_session, &project).unwrap();
        let editor_actor = platform.auth.actor(&editor_session).unwrap();
        assert_eq!(editor_actor.project_id, project);
        let mut editor = platform.scope(&root, editor_actor).unwrap();
        editor.session = Some(editor_session);
        let revoked = accept(&editor, &model_id, &submission(&log_id, 2), None).unwrap();
        let revoked_id = revoked.meta.snapshot.id.clone();
        run_accepted(&editor, revoked, |stage| {
            if stage == "fitness" {
                platform
                    .auth
                    .grant(
                        &actor,
                        &session,
                        &project,
                        "s26_editor",
                        crate::auth::Role::Viewer,
                    )
                    .unwrap();
            }
        });
        let (denied, saved) = completed(&state, &revoked_id);
        assert_eq!(
            denied.snapshot.error.as_ref().unwrap().code,
            "access_denied"
        );
        assert!(saved.report.is_none());
        let mut expired = submission(&log_id, 2);
        expired.request_key = format!(
            "{}.{}",
            chrono::Utc::now().timestamp() - store::KEY_SECONDS - 1,
            uuid::Uuid::new_v4()
        );
        assert_eq!(
            accept(&state, &model_id, &expired, None)
                .err()
                .unwrap()
                .code,
            "quality_request_expired"
        );
        // Persist a queued job but drop its lease to model a process exit.
        let interrupted = accept(&state, &model_id, &submission(&log_id, 2), None).unwrap();
        let interrupted_id = interrupted.meta.snapshot.id.clone();
        // Archive switches this session to another project. Deletion must still
        // count the accepted quality job in the archived project's header.
        let fallback = platform
            .auth
            .create_project(&actor, &session, "S26 deletion fallback")
            .unwrap();
        let revision = platform
            .auth
            .all_projects()
            .into_iter()
            .find(|p| p.id == project)
            .unwrap()
            .revision;
        platform
            .auth
            .set_archived(&actor, &session, &project, true, revision)
            .unwrap();
        let fallback_actor = platform.auth.actor(&session).unwrap();
        assert_eq!(fallback_actor.project_id, fallback);
        let preview = platform
            .auth
            .deletion_preview(&fallback_actor, &session, &project)
            .unwrap();
        assert_eq!(preview.active_jobs, 1);
        let refused = platform
            .auth
            .delete_project(
                &fallback_actor,
                &session,
                &project,
                crate::auth::ProjectDeletionConfirmation {
                    id: &project,
                    phrase: "УДАЛИТЬ",
                    revision: preview.revision,
                    digest: &preview.digest,
                },
            )
            .unwrap_err();
        assert_eq!(refused.code, "project_jobs_active");
        platform
            .auth
            .set_archived(&fallback_actor, &session, &project, false, preview.revision)
            .unwrap();
        platform.auth.switch(&session, &project).unwrap();
        drop(interrupted);
        assert_eq!(state.jobs.shared_slots().available_permits(), 2);
        (
            session,
            project,
            first_id,
            interrupted_id,
            form,
            report_bytes,
            model_id,
            log_id,
        )
    };
    let root = reopen(&url);
    let platform = root.platform.as_ref().unwrap().clone();
    let actor = platform.auth.actor(&session).unwrap();
    assert_eq!(actor.project_id, project);
    let mut state = platform.scope(&root, actor).unwrap();
    state.session = Some(session);
    let (complete, saved) = completed(&state, &complete_id);
    assert_eq!(complete.snapshot.state, JobState::Completed);
    assert_eq!(
        store::bytes(saved.report.as_ref().unwrap(), store::MAX_REPORT).unwrap(),
        report_bytes
    );
    let (interrupted, saved) = completed(&state, &interrupted_id);
    assert_eq!(interrupted.snapshot.state, JobState::Failed);
    assert_eq!(
        interrupted.snapshot.error.as_ref().unwrap().code,
        "interrupted"
    );
    assert_eq!(interrupted.snapshot.job_revision, 1);
    assert!(saved.report.is_none());
    let replay = accept(&state, &model_id, &original_form, None).unwrap();
    assert!(replay.launch.is_none());
    assert_eq!(replay.meta.snapshot.id, complete_id);
    let retried = accept(
        &state,
        &model_id,
        &submission(&log_id, 2),
        Some(&interrupted_id),
    )
    .unwrap();
    let retry_id = run_accepted(&state, retried, |_| {});
    assert_eq!(
        completed(&state, &retry_id).0.snapshot.state,
        JobState::Completed
    );
    let full = crate::repository_v2::load(&platform.database, &project).unwrap();
    store::validate_full(&full).unwrap();
    let json = serde_json::to_value(&full).unwrap();
    let (header, records) = crate::normalized::split_repository(&project, json.clone()).unwrap();
    assert_eq!(
        crate::normalized::join_repository(&project, header, records).unwrap(),
        json
    );
    std::fs::write(output.join("proof.json"),serde_json::to_vec_pretty(&json!({"status":"DURABLE_QUALITY_CORE_PASS","idempotent_replay":true,"mismatched_replay_refused":true,"cancelled_publication_refused":true,"revision_conflict":true,"revocation_failure_durable":true,"restart_report_bytes_identical":true,"interrupted_retry_completed":true,"deleted_key_cannot_recreate":true,"repository_roundtrip":true,"physical_browser_claimed":false})).unwrap()).unwrap();
}
