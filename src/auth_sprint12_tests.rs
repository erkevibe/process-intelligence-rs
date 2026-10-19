//! Native PostgreSQL tests of the production authorization publication guard.
//! These do not claim to hold an HTTP request at its final instruction.
use super::*;
use std::sync::{Arc, mpsc};

#[test]
#[ignore = "requires a fresh isolated S12_AUTH_DATABASE_URL"]
fn actual_switch_and_revocation_serialize_with_publication() {
    let db = Database::connect(
        std::env::var("S12_AUTH_DATABASE_URL")
            .expect("fresh isolated database required; never print its URL"),
    )
    .unwrap();
    let auth = Arc::new(Auth::open(db.clone()).unwrap());
    assert!(auth.needs_setup(), "fresh database required");
    let owner_session = auth.setup("s12_owner", "S12NativePassword123").unwrap();
    let owner = auth.actor(&owner_session).unwrap();
    let replacement = auth
        .create_project(&owner, &owner_session, "Replacement")
        .unwrap();
    auth.add_user(&owner, &owner_session, "s12_editor", "S12NativePassword123")
        .unwrap();
    auth.grant(
        &owner,
        &owner_session,
        &owner.project_id,
        "s12_editor",
        Role::Editor,
    )
    .unwrap();
    let editor_session = auth.login("s12_editor", "S12NativePassword123").unwrap();
    auth.switch(&editor_session, &owner.project_id).unwrap();
    let editor = auth.actor(&editor_session).unwrap();

    // Both mutations use the same actual Auth mutex as the final write gate.
    for (label, session, actor) in [
        ("revoke", editor_session.clone(), editor.clone()),
        ("switch", owner_session.clone(), owner.clone()),
    ] {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let writer_auth = auth.clone();
        let writer_db = db.clone();
        let writer_session = session.clone();
        let writer_actor = actor.clone();
        let key = format!("s12/guard/{label}/before");
        let writer_key = key.clone();
        let writer = std::thread::spawn(move || {
            writer_auth.with_write_access(&writer_session, &writer_actor, || {
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
                writer_db.write(&writer_key, 0, serde_json::json!({"committed":true}))
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(
            auth.inner.try_lock().is_err(),
            "production guard must remain held"
        );
        let changer_auth = auth.clone();
        let changer_owner = owner.clone();
        let changer_session = owner_session.clone();
        let changer_replacement = replacement.clone();
        let (started_tx, started_rx) = mpsc::channel();
        let (finished_tx, finished_rx) = mpsc::channel();
        let changer = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            let result = if label == "revoke" {
                changer_auth.grant(
                    &changer_owner,
                    &changer_session,
                    &changer_owner.project_id,
                    "s12_editor",
                    Role::Viewer,
                )
            } else {
                changer_auth.switch(&changer_session, &changer_replacement)
            };
            finished_tx.send(()).unwrap();
            result
        });
        started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        assert!(
            matches!(
                finished_rx.recv_timeout(Duration::from_millis(100)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ),
            "mutation must not finish under publication guard"
        );
        release_tx.send(()).unwrap();
        assert!(
            writer.join().unwrap().is_ok(),
            "admitted earlier write must commit"
        );
        changer.join().unwrap().unwrap();
        if label == "revoke" {
            assert!(auth.actor(&editor_session).unwrap().role == Role::Viewer);
        } else {
            assert!(auth.actor(&owner_session).unwrap().project_id == replacement);
        }
        assert!(
            db.read(&key).unwrap().is_some(),
            "earlier publication must persist"
        );

        // Reverse order: after actual mutation, a captured actor cannot enter closure.
        let before = db.read("auth").unwrap();
        let mut closure_entered = false;
        let late = auth.with_write_access(&session, &actor, || {
            closure_entered = true;
            db.write(
                &format!("s12/guard/{label}/after"),
                0,
                serde_json::json!(true),
            )
        });
        assert!(
            matches!(late, Err(ref error) if error.code == "access_denied"),
            "stale actor must receive authorization refusal"
        );
        assert!(
            !closure_entered,
            "refusal must happen before database callback"
        );
        assert!(
            db.read(&format!("s12/guard/{label}/after"))
                .unwrap()
                .is_none()
        );
        assert!(
            db.read("auth").unwrap() == before,
            "refusal must preserve full Auth state"
        );
    }
}

#[test]
#[ignore = "requires a fresh isolated S12_DELETE_DATABASE_URL"]
fn actual_publication_then_archive_delete_and_no_resurrection() {
    let db = Database::connect(
        std::env::var("S12_DELETE_DATABASE_URL")
            .expect("fresh owned database required; never print URL"),
    )
    .unwrap();
    let auth = Arc::new(Auth::open(db.clone()).unwrap());
    assert!(auth.needs_setup(), "fresh database required");
    let session = auth
        .setup("s12_delete_owner", "S12NativePassword123")
        .unwrap();
    let actor = auth.actor(&session).unwrap();
    auth.create_project(&actor, &session, "Writable replacement")
        .unwrap();
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let writer_auth = auth.clone();
    let writer_actor = actor.clone();
    let writer_session = session.clone();
    let writer_db = db.clone();
    let writer = std::thread::spawn(move || {
        writer_auth.with_write_access(&writer_session,&writer_actor,||{
        entered_tx.send(()).unwrap();release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        writer_db.write_project(crate::normalized::ProjectWrite{
            project:writer_actor.project_id.clone(),expected:0,
            metadata:serde_json::json!({"current":{},"sequence":0,"user_views":{},"durable_jobs":{},"log_ids":[],"model_ids":[]}),
            puts:vec![],deletes:vec![],
        })
    })
    });
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(
        auth.inner.try_lock().is_err(),
        "actual publication guard must be held"
    );
    let archive_auth = auth.clone();
    let archive_actor = actor.clone();
    let archive_session = session.clone();
    let (started_tx, started_rx) = mpsc::channel();
    let (finished_tx, finished_rx) = mpsc::channel();
    let archiver = std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        let result = archive_auth.set_archived(
            &archive_actor,
            &archive_session,
            &archive_actor.project_id,
            true,
            1,
        );
        finished_tx.send(()).unwrap();
        result
    });
    started_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(
        matches!(
            finished_rx.recv_timeout(Duration::from_millis(100)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ),
        "archive must not complete while earlier publication guard is held"
    );
    release_tx.send(()).unwrap();
    writer.join().unwrap().unwrap();
    archiver.join().unwrap().unwrap();
    assert!(
        db.project_header(&actor.project_id).unwrap().is_some(),
        "earlier acknowledged publication exists"
    );
    let current = auth.actor(&session).unwrap();
    assert!(
        current.project_id != actor.project_id,
        "archive selects writable replacement"
    );
    let preview = auth
        .deletion_preview(&current, &session, &actor.project_id)
        .unwrap();
    auth.delete_project(
        &current,
        &session,
        &actor.project_id,
        ProjectDeletionConfirmation {
            id: &actor.project_id,
            phrase: "УДАЛИТЬ",
            revision: preview.revision,
            digest: &preview.digest,
        },
    )
    .unwrap();
    assert!(!auth.all_projects().iter().any(|p| p.id == actor.project_id));
    assert!(db.project_header(&actor.project_id).unwrap().is_none());
    assert!(db.record_keys(&actor.project_id).unwrap().is_empty());
    let mut sql = postgres::Client::connect(
        &std::env::var("S12_DELETE_DATABASE_URL").unwrap(),
        postgres::NoTls,
    )
    .unwrap();
    let legacy_rows: i64 = sql
        .query_one(
            "SELECT count(*) FROM public.pi_kv WHERE key=$1",
            &[&format!("repository/{}", actor.project_id)],
        )
        .unwrap()
        .get(0);
    assert!(
        legacy_rows == 0,
        "no legacy repository row may survive typed deletion"
    );
    let before = db.read("auth").unwrap();
    let mut entered = false;
    let refused=auth.with_write_access(&session,&actor,||{
        entered=true;
        db.write_project(crate::normalized::ProjectWrite{
            project:actor.project_id.clone(),expected:0,
            metadata:serde_json::json!({"current":{},"sequence":0,"user_views":{},"durable_jobs":{},"log_ids":[],"model_ids":[]}),
            puts:vec![],deletes:vec![],
        })
    });
    assert!(matches!(refused,Err(ref error) if error.code=="access_denied"));
    assert!(
        !entered,
        "captured actor must be rejected before resurrection callback"
    );
    assert!(
        db.read("auth").unwrap() == before,
        "refusal preserves complete Auth"
    );
    assert!(db.project_header(&actor.project_id).unwrap().is_none());
    // Deletion requires prior archiving: this proves the enforced compound order,
    // not an impossible writable actor inside an already archived project.
}
