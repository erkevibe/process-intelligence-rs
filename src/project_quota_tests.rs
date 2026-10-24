use super::*;
use crate::{normalized::ProjectWrite, repository_v2::Header};
use postgres::{Client, NoTls};
use serde_json::json;

pub(crate) fn fixture(project: &str) -> crate::web::Repository {
    let backup: Value = serde_json::from_slice(include_bytes!(
        "../evidence/sprint29/api-contract/fixture-backup.json"
    ))
    .unwrap();
    let mut repo: crate::web::Repository =
        serde_json::from_value(backup["payload"].clone()).unwrap();
    for log in repo.logs.values_mut() {
        log.project_id = Some(project.into());
    }
    let input = "case_id,activity\nc,A\n";
    let jobs = crate::jobs::JobStore::new();
    let lease = jobs.create_with_id(Some("job-900010".into())).unwrap();
    repo.conversions.insert(
        "job-900010".into(),
        crate::conversion_workflow::ConversionMeta {
            snapshot: lease.job.snapshot(),
            artifact_id: "conversion-900011".into(),
            from: "csv".into(),
            to: "xes".into(),
            filename: "quota.csv".into(),
            owner: "owner".into(),
            source_sha256: crate::storage::sha256(input.as_bytes()),
            input_bytes: input.len(),
            allow_loss: false,
            report_profile: None,
            created_at: chrono::Utc::now(),
            retry_of: None,
            payload_sha256: None,
            report_sha256: None,
        },
    );
    repo.conversion_artifacts.insert(
        "conversion-900011".into(),
        std::sync::Arc::new(crate::conversion_workflow::ConversionArtifact {
            id: "conversion-900011".into(),
            input: input.into(),
            payload: None,
            report: None,
        }),
    );
    repo
}
fn commit(client: &mut Client, write: &ProjectWrite) -> Result<u64, ImportError> {
    let mut tx = client.transaction().unwrap();
    let version = normalized::write(&mut tx, write)?;
    tx.commit().unwrap();
    Ok(version)
}
fn snapshot(client: &mut Client) -> Value {
    client.query_one("SELECT json_build_object('projects',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY project_id),'[]'::json) FROM public.pi_projects t),'records',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY project_id,kind,resource_id),'[]'::json) FROM public.pi_records t),'quota',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY project_id),'[]'::json) FROM public.pi_project_quota t),'kv',(SELECT coalesce(json_agg(to_jsonb(t) ORDER BY key),'[]'::json) FROM public.pi_kv t))",&[]).unwrap().get(0)
}
fn evidence(client: &mut Client, project: &str, name: &str) -> Value {
    let used: i64 = client
        .query_one(
            "SELECT payload_used FROM public.pi_project_quota WHERE project_id=$1",
            &[&project],
        )
        .unwrap()
        .get(0);
    let rows:Vec<Value>=client.query("SELECT kind,resource_id,document FROM public.pi_records WHERE project_id=$1 ORDER BY kind,resource_id",&[&project]).unwrap().iter().map(|r|json!({"kind":r.get::<_,String>(0),"id":r.get::<_,String>(1),"document":r.get::<_,Value>(2)})).collect();
    json!({"name":name,"payload_used":used,"records":rows})
}
#[test]
#[ignore = "fresh isolated S30_QUOTA_DATABASE_URL pi_s30_quota_core required"]
fn postgres_quota_boundaries_rollback_replacement_terminal_and_concurrency() {
    let url = std::env::var("S30_QUOTA_DATABASE_URL").expect("isolated URL required");
    let mut client = Client::connect(&url, NoTls).unwrap();
    let name: String = client
        .query_one("SELECT current_database()", &[])
        .unwrap()
        .get(0);
    assert!(name.starts_with("pi_s30_quota_core"));
    assert!(
        client
            .query_one("SELECT to_regclass('public.pi_projects') IS NULL", &[])
            .unwrap()
            .get::<_, bool>(0)
    );
    crate::migrations::apply(&mut client).unwrap();
    let project = "project-quota";
    let repo = fixture(project);
    let first = crate::repository_v2::prepare(project, &repo, false).unwrap();
    assert_eq!(commit(&mut client, &first).unwrap(), 1);
    let mut proofs = vec![evidence(&mut client, project, "disabled_full_project")];
    let used = proofs[0]["payload_used"].as_u64().unwrap();
    for (suffix, allowance, success) in [
        ("minus", used - 1, false),
        ("exact", used, true),
        ("plus", used + 1, true),
    ] {
        let id = format!("project-{suffix}");
        let mut r = fixture(&id);
        r.quota_policy = Some(Policy {
            metric_version: 1,
            payload_allowance: allowance,
        });
        let w = crate::repository_v2::prepare(&id, &r, false).unwrap();
        // Project ID strings are not part of record envelope, but occur inside log records.
        let actual = w
            .puts
            .iter()
            .map(|(k, i, v)| record_cost(k, i, v).unwrap())
            .sum::<u64>();
        let mut h = Header::parse(w.metadata.clone()).unwrap();
        h.quota_policy.as_mut().unwrap().payload_allowance = if suffix == "minus" {
            actual - 1
        } else if suffix == "exact" {
            actual
        } else {
            actual + 1
        };
        let w = ProjectWrite {
            metadata: h.value().unwrap(),
            ..w
        };
        let before = snapshot(&mut client);
        let result = commit(&mut client, &w);
        assert_eq!(result.is_ok(), success);
        if !success {
            assert_eq!(result.unwrap_err().code, "project_quota");
            assert_eq!(snapshot(&mut client), before);
        } else {
            proofs.push(evidence(&mut client, &id, suffix));
        }
    }
    let mut h = Header::parse(first.metadata.clone()).unwrap();
    h.quota_policy = Some(Policy {
        metric_version: 1,
        payload_allowance: 0,
    });
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 1,
                metadata: h.value().unwrap(),
                puts: vec![],
                deletes: vec![]
            }
        )
        .unwrap(),
        2
    );
    let model = first
        .puts
        .iter()
        .find(|(k, _, _)| k == "model")
        .unwrap()
        .clone();
    let mut grown = model.clone();
    grown.2["name"] = json!(format!("{}x", model.2["name"].as_str().unwrap()));
    let before = snapshot(&mut client);
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 2,
                metadata: h.value().unwrap(),
                puts: vec![grown],
                deletes: vec![]
            }
        )
        .unwrap_err()
        .code,
        "project_quota"
    );
    assert_eq!(snapshot(&mut client), before);
    // Equal replacement and metadata-only management remain legal while over limit.
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 2,
                metadata: h.value().unwrap(),
                puts: vec![model.clone()],
                deletes: vec![]
            }
        )
        .unwrap(),
        3
    );
    let mut smaller = model.clone();
    smaller.2["name"] = json!("");
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 3,
                metadata: h.value().unwrap(),
                puts: vec![smaller],
                deletes: vec![]
            }
        )
        .unwrap(),
        4
    );
    proofs.push(evidence(
        &mut client,
        project,
        "overlimit_smaller_replacement",
    ));
    let jobs = crate::jobs::JobStore::new();
    let lease = jobs.create_with_id(Some("job-900001".into())).unwrap();
    h.durable_jobs
        .insert("job-900001".into(), lease.job.snapshot());
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 4,
                metadata: h.value().unwrap(),
                puts: vec![],
                deletes: vec![]
            }
        )
        .unwrap(),
        5
    );
    let failed = lease
        .job
        .try_fail_with("project_quota", "Квота заполнена", |s| {
            h.durable_jobs.insert(s.id.clone(), s.clone());
            commit(
                &mut client,
                &ProjectWrite {
                    project: project.into(),
                    expected: 5,
                    metadata: h.value()?,
                    puts: vec![],
                    deletes: vec![],
                },
            )?;
            Ok(())
        })
        .unwrap();
    assert_eq!(failed.state, crate::jobs::JobState::Failed);
    proofs.push(evidence(&mut client, project, "terminal_overlimit"));
    // Generic + project Batch must roll back everything when a later project exceeds quota.
    let database = storage_database(&url);
    let mut rejected = fixture("project-batch-refused");
    rejected.quota_policy = Some(Policy {
        metric_version: 1,
        payload_allowance: 0,
    });
    let before = snapshot(&mut client);
    assert_eq!(
        database
            .write_batch(vec![
                ("batch-generic-probe".into(), 0, json!({"retained":false})),
                (
                    "repository/project-batch-first".into(),
                    0,
                    serde_json::to_value(fixture("project-batch-first")).unwrap()
                ),
                (
                    "repository/project-batch-refused".into(),
                    0,
                    serde_json::to_value(rejected).unwrap()
                )
            ])
            .unwrap_err()
            .code,
        "project_quota"
    );
    assert_eq!(snapshot(&mut client), before);
    drop(database);
    // Diagnostic view makes any payload projection fail. Metadata writes must
    // use only the actual keys/versions; the entire diagnostic DDL is rolled back.
    let before_probe = snapshot(&mut client);
    {
        let mut tx = client.transaction().unwrap();
        tx.batch_execute("CREATE FUNCTION pg_temp.s30_forbid_payload(v jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $$ BEGIN RAISE EXCEPTION 's30_untouched_payload_read'; END $$; ALTER TABLE public.pi_records RENAME TO pi_records_payload_probe; CREATE VIEW public.pi_records AS SELECT project_id,kind,resource_id,version,pg_temp.s30_forbid_payload(document) AS document FROM public.pi_records_payload_probe;").unwrap();
        assert_eq!(
            normalized::write(
                &mut tx,
                &ProjectWrite {
                    project: project.into(),
                    expected: 6,
                    metadata: h.value().unwrap(),
                    puts: vec![],
                    deletes: vec![]
                }
            )
            .unwrap(),
            7
        );
        tx.rollback().unwrap();
    }
    assert_eq!(snapshot(&mut client), before_probe);
    h.model_ids.retain(|id| id != &model.1);
    h.organization = Default::default();
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 6,
                metadata: h.value().unwrap(),
                puts: vec![],
                deletes: vec![(model.0.clone(), model.1.clone())]
            }
        )
        .unwrap(),
        7
    );
    let after_delete = evidence(&mut client, project, "overlimit_delete");
    let after_delete_used = after_delete["payload_used"].as_u64().unwrap();
    proofs.push(after_delete);
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 7,
                metadata: h.value().unwrap(),
                puts: vec![],
                deletes: vec![(model.0.clone(), model.1.clone())]
            }
        )
        .unwrap(),
        8
    );
    assert_eq!(
        evidence(&mut client, project, "repeat_delete")["payload_used"],
        after_delete_used
    );
    // Two synchronized writers see the same revision; only one can publish.
    let race_project = "project-race";
    let mut race_header = Header {
        model_ids: vec![model.1.clone()],
        ..Default::default()
    };
    let race_initial = record_cost(&model.0, &model.1, &model.2).unwrap();
    let mut extra = model.clone();
    extra.1 = "model-900101".into();
    extra.2["id"] = json!(extra.1);
    let increment = record_cost(&extra.0, &extra.1, &extra.2).unwrap();
    race_header.quota_policy = Some(Policy {
        metric_version: 1,
        payload_allowance: race_initial + increment,
    });
    commit(
        &mut client,
        &ProjectWrite {
            project: race_project.into(),
            expected: 0,
            metadata: race_header.value().unwrap(),
            puts: vec![model.clone()],
            deletes: vec![],
        },
    )
    .unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
    let mut writers = vec![];
    for id in ["model-900101", "model-900102"] {
        let gate = barrier.clone();
        let url = url.clone();
        let mut header = Header::parse(race_header.value().unwrap()).unwrap();
        header.model_ids.push(id.into());
        let mut put = extra.clone();
        put.1 = id.into();
        put.2["id"] = json!(id);
        writers.push(std::thread::spawn(move || {
            let mut c = Client::connect(&url, NoTls).unwrap();
            gate.wait();
            (
                id,
                commit(
                    &mut c,
                    &ProjectWrite {
                        project: race_project.into(),
                        expected: 1,
                        metadata: header.value().unwrap(),
                        puts: vec![put],
                        deletes: vec![],
                    },
                ),
            )
        }));
    }
    barrier.wait();
    let results: Vec<_> = writers.into_iter().map(|w| w.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|(_, r)| r.is_ok()).count(), 1);
    let loser = results.iter().find(|(_, r)| r.is_err()).unwrap();
    assert_eq!(loser.1.as_ref().unwrap_err().code, "storage_conflict");
    let current: Value = client
        .query_one(
            "SELECT document FROM public.pi_projects WHERE project_id=$1",
            &[&race_project],
        )
        .unwrap()
        .get(0);
    let mut retry_header = Header::parse(current).unwrap();
    retry_header.model_ids.push(loser.0.into());
    let mut retry_put = extra.clone();
    retry_put.1 = loser.0.into();
    retry_put.2["id"] = json!(loser.0);
    let before = snapshot(&mut client);
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: race_project.into(),
                expected: 2,
                metadata: retry_header.value().unwrap(),
                puts: vec![retry_put],
                deletes: vec![]
            }
        )
        .unwrap_err()
        .code,
        "project_quota"
    );
    assert_eq!(snapshot(&mut client), before);
    proofs.push(evidence(
        &mut client,
        race_project,
        "synchronized_cas_then_quota_refusal",
    ));
    // A corrupt accounting value is not silently repaired on ordinary writes/startup.
    client
        .execute(
            "UPDATE public.pi_project_quota SET payload_used=payload_used+1 WHERE project_id=$1",
            &[&project],
        )
        .unwrap();
    let malformed = snapshot(&mut client);
    assert!(crate::migration_v6::validate_ready(&mut client).is_err());
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: project.into(),
                expected: 8,
                metadata: h.value().unwrap(),
                puts: vec![],
                deletes: vec![]
            }
        )
        .unwrap_err()
        .code,
        "quota_invalid"
    );
    assert_eq!(snapshot(&mut client), malformed);
    client
        .execute(
            "UPDATE public.pi_project_quota SET payload_used=payload_used-1 WHERE project_id=$1",
            &[&project],
        )
        .unwrap();
    crate::migration_v6::validate_ready(&mut client).unwrap();
    // Coherent administrator tampering of ledger+total is caught by full scan,
    // and by a touched-record check, even though the cached sum still agrees.
    let row = client
        .query_one(
            "SELECT payload_used,record_costs FROM public.pi_project_quota WHERE project_id=$1",
            &[&race_project],
        )
        .unwrap();
    let old_total: i64 = row.get(0);
    let old_ledger: Value = row.get(1);
    let mut forged = old_ledger.clone();
    let old_cost = forged["model"][&model.1]["cost"].as_u64().unwrap();
    forged["model"][&model.1]["cost"] = json!(old_cost + 1);
    client.execute("UPDATE public.pi_project_quota SET payload_used=$2,record_costs=$3 WHERE project_id=$1",&[&race_project,&(old_total+1),&forged]).unwrap();
    let forged_snapshot = snapshot(&mut client);
    assert!(crate::migration_v6::validate_ready(&mut client).is_err());
    let race_meta: Value = client
        .query_one(
            "SELECT document FROM public.pi_projects WHERE project_id=$1",
            &[&race_project],
        )
        .unwrap()
        .get(0);
    assert_eq!(
        commit(
            &mut client,
            &ProjectWrite {
                project: race_project.into(),
                expected: 2,
                metadata: race_meta,
                puts: vec![model.clone()],
                deletes: vec![]
            }
        )
        .unwrap_err()
        .code,
        "quota_invalid"
    );
    assert_eq!(snapshot(&mut client), forged_snapshot);
    client.execute("UPDATE public.pi_project_quota SET payload_used=$2,record_costs=$3 WHERE project_id=$1",&[&race_project,&old_total,&old_ledger]).unwrap();
    crate::migration_v6::validate_ready(&mut client).unwrap();
    let output =
        std::path::PathBuf::from(std::env::var("S30_QUOTA_EVIDENCE").expect("private output"));
    assert!(output.is_dir());
    let proof = json!({"schema_version":1,"metric":"structural_bytes_v1","header_reserve":HEADER_RESERVE,"snapshots":proofs});
    std::fs::write(
        output.join("quota-records.json"),
        serde_json::to_vec(&proof).unwrap(),
    )
    .unwrap();
    std::fs::write(output.join("quota-controls.json"),serde_json::to_vec(&json!({"status":"S30_QUOTA_CONTROLS_PASS","metadata_without_payload_projection":true,"coherent_ledger_tamper_full_scan_refused":true,"touched_payload_cost_revalidated":true,"counter_tamper_refused":true,"synchronized_cas_then_quota_refusal":true,"batch_generic_and_project_full_rollback":true,"equal_smaller_delete_allowed_overlimit":true})).unwrap()).unwrap();
}
fn storage_database(url: &str) -> crate::storage::Database {
    crate::storage::Database::connect(url.into()).unwrap()
}
