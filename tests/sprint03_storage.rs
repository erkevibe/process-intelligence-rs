//! Independent real PostgreSQL migration/fault contracts. Explicitly ignored unless isolated S3 env supplied.
use postgres::{Client, NoTls};
use process_intelligence_rs::storage::Database;
use serde_json::Value;
use std::{
    thread,
    time::{Duration, Instant},
};
fn scoped(var: &str, name: &str) -> String {
    let url = std::env::var(var).expect("isolated S3 DSN environment required; never print it");
    assert!(
        url.split_whitespace()
            .any(|part| part == format!("dbname={name}")),
        "wrong isolated QA database"
    );
    assert!(name.starts_with("pi_s3_"));
    url
}
fn admin(name: &str) -> Client {
    Client::connect(&scoped("QA_S3_ADMIN_URL", name), NoTls)
        .expect("private isolated admin connection failed")
}
fn snapshot(client: &mut Client) -> Vec<(String, i64, Value)> {
    client
        .query(
            "SELECT key,version,document FROM public.pi_kv ORDER BY key",
            &[],
        )
        .unwrap()
        .into_iter()
        .map(|r| (r.get(0), r.get(1), r.get(2)))
        .collect()
}
fn connect_error(url: String) -> String {
    match Database::connect(url) {
        Ok(_) => panic!("unsupported/faulted schema unexpectedly accepted"),
        Err(e) => e.code,
    }
}
#[test]
#[ignore = "actual isolated pi_s3_upgrade only; explicit migration acceptance"]
fn old_documents_unchanged_migration_and_reopen_ledger_idempotent() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_upgrade");
    let mut a = admin("pi_s3_upgrade");
    let before = snapshot(&mut a);
    assert!(before.iter().any(|r| r.0 == "auth"));
    let db = Database::connect(u.clone()).unwrap();
    db.health().unwrap();
    assert_eq!(
        snapshot(&mut a),
        before,
        "additive migration rewrote legacy documents"
    );
    let ledger: (i32, String, String, String) = {
        let r = a
            .query_one(
                "SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations",
                &[],
            )
            .unwrap();
        (r.get(0), r.get(1), r.get(2), r.get(3))
    };
    assert_eq!(ledger.0, 1);
    assert_eq!(ledger.1, "baseline_v1");
    assert_eq!(ledger.2.len(), 64);
    db.acquire_platform_lease().unwrap();
    db.acquire_platform_lease().unwrap();
    assert_eq!(connect_error(u.clone()), "app_already_running");
    drop(db);
    thread::sleep(Duration::from_millis(100));
    let reopened = Database::connect(u).unwrap();
    reopened.health().unwrap();
    let r = a
        .query_one(
            "SELECT version,name,checksum,applied_at::text FROM public.pi_schema_migrations",
            &[],
        )
        .unwrap();
    assert_eq!(
        (
            r.get::<_, i32>(0),
            r.get::<_, String>(1),
            r.get::<_, String>(2),
            r.get::<_, String>(3)
        ),
        ledger
    );
    assert_eq!(snapshot(&mut a), before);
}
#[test]
#[ignore = "actual isolated pi_s3_fault; admin test-owned transactional DDL error trigger"]
fn migration_ddl_failure_rolls_back_ledger_and_constraint() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_fault");
    let mut a = admin("pi_s3_fault");
    let before = snapshot(&mut a);
    a.batch_execute("CREATE FUNCTION public.qa_reject_alter() RETURNS event_trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'independent QA migration gate'; END$$; CREATE EVENT TRIGGER qa_migration_gate ON ddl_command_end WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION public.qa_reject_alter();").unwrap();
    let error = connect_error(u);
    assert_eq!(error, "migration_failed");
    assert_eq!(snapshot(&mut a), before);
    let r=a.query_one("SELECT to_regclass('public.pi_schema_migrations') IS NULL, NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.pi_kv'::regclass AND conname='pi_kv_positive_version')",&[]).unwrap();
    assert!(r.get::<_, bool>(0));
    assert!(r.get::<_, bool>(1));
    a.batch_execute(
        "DROP EVENT TRIGGER qa_migration_gate; DROP FUNCTION public.qa_reject_alter();",
    )
    .unwrap();
}
#[test]
#[ignore = "actual isolated pi_s3_future; supported adoption then corrupt ledger refusal"]
fn future_version_and_checksum_rejected_without_document_change() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_future");
    let mut a = admin("pi_s3_future");
    let before = snapshot(&mut a);
    drop(Database::connect(u.clone()).unwrap());
    thread::sleep(Duration::from_millis(100));
    a.execute("UPDATE public.pi_schema_migrations SET version=2", &[])
        .unwrap();
    assert_eq!(connect_error(u.clone()), "schema_unsupported");
    assert_eq!(snapshot(&mut a), before);
    assert_eq!(
        a.query_one("SELECT version FROM public.pi_schema_migrations", &[])
            .unwrap()
            .get::<_, i32>(0),
        2
    );
    a.execute(
        "UPDATE public.pi_schema_migrations SET version=1,checksum='not-the-recorded-migration'",
        &[],
    )
    .unwrap();
    assert_eq!(connect_error(u), "schema_unsupported");
    assert_eq!(snapshot(&mut a), before);
    assert_eq!(
        a.query_one("SELECT checksum FROM public.pi_schema_migrations", &[])
            .unwrap()
            .get::<_, String>(0),
        "not-the-recorded-migration"
    );
}
#[test]
#[ignore = "actual isolated pi_s3_fault; lock bound no production sleeps/flags"]
fn real_migration_lock_timeout_preserves_old_state() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_fault");
    let mut a = admin("pi_s3_fault");
    let before = snapshot(&mut a);
    let mut tx = a.transaction().unwrap();
    tx.batch_execute("LOCK TABLE public.pi_kv IN ACCESS EXCLUSIVE MODE")
        .unwrap();
    let started = Instant::now();
    let error = connect_error(u);
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_secs(8),
        "real lock was not bounded"
    );
    assert_eq!(error, "migration_failed");
    tx.rollback().unwrap();
    assert_eq!(snapshot(&mut a), before);
    assert!(
        a.query_one(
            "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
            &[]
        )
        .unwrap()
        .get::<_, bool>(0)
    );
}
#[test]
#[ignore = "actual isolated pi_s3_fault; unknown structural state never adopted"]
fn extra_check_rls_and_trigger_refused_without_ledger() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_fault");
    let mut a = admin("pi_s3_fault");
    let before = snapshot(&mut a);
    for (install, remove) in [
        (
            "ALTER TABLE pi_kv ADD CONSTRAINT qa_extra CHECK (length(key)>0)",
            "ALTER TABLE pi_kv DROP CONSTRAINT qa_extra",
        ),
        (
            "ALTER TABLE pi_kv ENABLE ROW LEVEL SECURITY",
            "ALTER TABLE pi_kv DISABLE ROW LEVEL SECURITY",
        ),
        (
            "CREATE FUNCTION qa_passthrough() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$; CREATE TRIGGER qa_extra BEFORE INSERT ON pi_kv FOR EACH ROW EXECUTE FUNCTION qa_passthrough()",
            "DROP TRIGGER qa_extra ON pi_kv; DROP FUNCTION qa_passthrough()",
        ),
    ] {
        a.batch_execute(install).unwrap();
        let error = connect_error(u.clone());
        assert_eq!(error, "schema_unsupported");
        assert_eq!(snapshot(&mut a), before);
        assert!(
            a.query_one(
                "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
                &[]
            )
            .unwrap()
            .get::<_, bool>(0)
        );
        a.batch_execute(remove).unwrap();
    }
}
#[test]
#[ignore = "actual isolated pi_s3_fault; nested unrecognized field must remain untouched after rejection"]
fn nested_unknown_repository_field_refused_without_rewrite() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_fault");
    let mut a = admin("pi_s3_fault");
    let row=a.query_one("SELECT key,document FROM pi_kv WHERE key LIKE 'repository/%' AND document->'logs' <> '{}'::jsonb LIMIT 1",&[]).unwrap();
    let key: String = row.get(0);
    let original: Value = row.get(1);
    let mut invalid = original.clone();
    let first = invalid["logs"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap()
        .clone();
    invalid["logs"][&first]["data"]
        .as_object_mut()
        .unwrap()
        .insert("qa_unknown".into(), Value::String("preserve me".into()));
    a.execute(
        "UPDATE pi_kv SET document=$2 WHERE key=$1",
        &[&key, &invalid],
    )
    .unwrap();
    let invalid_before = snapshot(&mut a);
    let error = connect_error(u);
    assert_eq!(error, "schema_unsupported");
    assert_eq!(
        snapshot(&mut a),
        invalid_before,
        "unsupported nested value was silently removed"
    );
    assert!(
        a.query_one(
            "SELECT to_regclass('public.pi_schema_migrations') IS NULL",
            &[]
        )
        .unwrap()
        .get::<_, bool>(0)
    );
    a.execute(
        "UPDATE pi_kv SET document=$2 WHERE key=$1",
        &[&key, &original],
    )
    .unwrap();
}
#[test]
#[ignore = "actual isolated pi_s3_fresh; server lock/statement/transaction bounds and no late commit"]
fn actual_server_deadlines_abort_no_late_mutation_and_fail_closed() {
    let u = scoped("QA_S3_DATABASE_URL", "pi_s3_fresh");
    let mut a = admin("pi_s3_fresh");
    let db = Database::connect(u.clone()).unwrap();
    let before = snapshot(&mut a);
    let mut lock = a.transaction().unwrap();
    lock.batch_execute("LOCK TABLE pi_kv IN ACCESS EXCLUSIVE MODE")
        .unwrap();
    let start = Instant::now();
    let err = db
        .write_batch(vec![("qa/lock".into(), 0, serde_json::json!({"value":1}))])
        .unwrap_err();
    assert_eq!(err.code, "storage_unavailable");
    assert!(start.elapsed() >= Duration::from_secs(1));
    assert!(start.elapsed() < Duration::from_secs(6));
    lock.rollback().unwrap();
    assert_eq!(snapshot(&mut a), before);
    assert_eq!(db.health().unwrap_err().code, "storage_unavailable");
    drop(db);
    thread::sleep(Duration::from_millis(100));
    let db = Database::connect(u.clone()).unwrap();
    db.health().unwrap();
    a.batch_execute("CREATE FUNCTION qa_delay() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_sleep(8); RETURN NEW; END$$; CREATE TRIGGER qa_delay BEFORE INSERT ON pi_kv FOR EACH ROW EXECUTE FUNCTION qa_delay();").unwrap();
    let start = Instant::now();
    let err = db
        .write("qa/statement", 0, serde_json::json!({"value":2}))
        .unwrap_err();
    assert_eq!(err.code, "storage_unavailable");
    assert!(start.elapsed() >= Duration::from_secs(4));
    assert!(start.elapsed() < Duration::from_secs(9));
    assert_eq!(snapshot(&mut a), before);
    assert_eq!(db.health().unwrap_err().code, "storage_unavailable");
    drop(db);
    a.batch_execute("DROP TRIGGER qa_delay ON pi_kv; DROP FUNCTION qa_delay();")
        .unwrap();
    thread::sleep(Duration::from_millis(100));
    let db = Database::connect(u.clone()).unwrap();
    a.batch_execute("CREATE FUNCTION qa_delay() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN PERFORM pg_sleep(2); RETURN NEW; END$$; CREATE TRIGGER qa_delay BEFORE INSERT ON pi_kv FOR EACH ROW EXECUTE FUNCTION qa_delay();").unwrap();
    let start = Instant::now();
    let batch = (0..8)
        .map(|i| {
            (
                format!("qa/transaction/{i}"),
                0,
                serde_json::json!({"value":i}),
            )
        })
        .collect();
    let err = db.write_batch(batch).unwrap_err();
    assert_eq!(err.code, "storage_unavailable");
    assert!(start.elapsed() >= Duration::from_secs(8));
    assert!(start.elapsed() < Duration::from_secs(15));
    assert_eq!(snapshot(&mut a), before);
    assert_eq!(db.health().unwrap_err().code, "storage_unavailable");
    drop(db);
    a.batch_execute("DROP TRIGGER qa_delay ON pi_kv; DROP FUNCTION qa_delay();")
        .unwrap();
    thread::sleep(Duration::from_millis(100));
    let reopened = Database::connect(u).unwrap();
    reopened.health().unwrap();
    assert_eq!(snapshot(&mut a), before);
}

#[test]
#[ignore = "actual isolated pi_s3_fresh only; capacity pre-SQL acceptance"]
fn capacity_batch_refusal_is_atomic_and_does_not_poison_worker() {
    let db = Database::connect(scoped("QA_S3_DATABASE_URL", "pi_s3_fresh")).unwrap();
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let small_key = format!("qa/capacity/{suffix}/small");
    let large_key = format!("qa/capacity/{suffix}/large");
    assert!(db.read(&small_key).unwrap().is_none());
    assert!(db.read(&large_key).unwrap().is_none());
    let oversized = Value::String("X".repeat((1usize << 28) - (64 << 10) + 1));
    let error = db
        .write_batch(vec![
            (small_key.clone(), 0, serde_json::json!({"preserve":true})),
            (large_key.clone(), 0, oversized),
        ])
        .unwrap_err();
    assert_eq!(error.code, "project_capacity");
    assert!(
        db.read(&small_key).unwrap().is_none(),
        "batch partially committed before oversized document validation"
    );
    assert!(db.read(&large_key).unwrap().is_none());
    db.health().unwrap();
    assert_eq!(
        db.write(&small_key, 0, serde_json::json!({"after_refusal":true}))
            .unwrap(),
        1
    );
    assert_eq!(
        db.read(&small_key).unwrap(),
        Some((1, serde_json::json!({"after_refusal":true})))
    );
    db.health().unwrap();
}
