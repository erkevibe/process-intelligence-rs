use crate::{
    domain::ImportError,
    storage::{Database, sha256},
};
use argon2::{
    Argon2, PasswordHasher, PasswordVerifier,
    password_hash::{PasswordHash, SaltString},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::Mutex,
    time::{Duration, Instant},
};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Owner,
    Editor,
    Viewer,
}
impl Role {
    pub fn can_write(self) -> bool {
        self != Self::Viewer
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct User {
    pub id: String,
    pub username: String,
    pub password_hash: String,
    pub admin: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub members: BTreeMap<String, Role>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub archived: bool,
    #[serde(
        default = "initial_revision",
        skip_serializing_if = "is_initial_revision"
    )]
    pub revision: u64,
}
fn initial_revision() -> u64 {
    1
}
fn is_initial_revision(value: &u64) -> bool {
    *value == 1
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Session {
    user_id: String,
    project_id: String,
    expires: i64,
}
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthData {
    #[serde(
        default,
        skip_serializing_if = "crate::audit::ProjectAuditTrails::is_empty"
    )]
    audit: crate::audit::ProjectAuditTrails,
    users: BTreeMap<String, User>,
    projects: BTreeMap<String, Project>,
    sessions: BTreeMap<String, Session>,
}
pub(crate) fn validate_stored(value: &serde_json::Value) -> Result<(), ImportError> {
    let data: AuthData = serde_json::from_value(value.clone()).map_err(|_| denied())?;
    data.audit.validate()?;
    if data
        .audit
        .0
        .keys()
        .any(|project| !data.projects.contains_key(project))
    {
        return Err(denied());
    }
    if serde_json::to_value(&data).map_err(|_| denied())? != *value {
        return Err(denied());
    }
    for (id, user) in &data.users {
        if id != &user.id || PasswordHash::new(&user.password_hash).is_err() {
            return Err(denied());
        }
    }
    for (id, project) in &data.projects {
        if id != &project.id
            || project.revision == 0
            || project
                .members
                .keys()
                .any(|user| !data.users.contains_key(user))
        {
            return Err(denied());
        }
    }
    for session in data.sessions.values() {
        if !data.users.contains_key(&session.user_id)
            || !data.projects.contains_key(&session.project_id)
        {
            return Err(denied());
        }
    }
    Ok(())
}
struct Versioned {
    revision: u64,
    data: AuthData,
}
pub struct Auth {
    database: Database,
    inner: Mutex<Versioned>,
    attempts: Mutex<VecDeque<Instant>>,
}
#[derive(Debug, Clone)]
pub struct Actor {
    pub id: String,
    pub username: String,
    pub project_id: String,
    pub role: Role,
    pub admin: bool,
}
fn denied() -> ImportError {
    ImportError::new("access_denied", "Доступ запрещён.")
}
fn token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}
fn password_hash(password: &str) -> Result<String, ImportError> {
    if !(12..=256).contains(&password.len()) {
        return Err(ImportError::new(
            "password_policy",
            "Пароль должен содержать от 12 до 256 bytes.",
        ));
    }
    let salt = SaltString::encode_b64(uuid::Uuid::new_v4().as_bytes()).map_err(|_| denied())?;
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|v| v.to_string())
        .map_err(|_| denied())
}
impl Auth {
    pub fn open(database: Database) -> Result<Self, ImportError> {
        let (revision, data) = match database.read("auth")? {
            Some((rev, value)) => {
                validate_stored(&value)?;
                (
                    rev,
                    serde_json::from_value(value).map_err(|_| {
                        ImportError::new("auth_corrupt", "Не удалось прочитать учётные записи.")
                    })?,
                )
            }
            None => (0, AuthData::default()),
        };
        Ok(Self {
            database,
            inner: Mutex::new(Versioned { revision, data }),
            attempts: Mutex::new(VecDeque::new()),
        })
    }
    fn update<T>(
        &self,
        change: impl FnOnce(&mut AuthData) -> Result<T, ImportError>,
    ) -> Result<T, ImportError> {
        let mut guard = self.inner.lock().expect("auth mutex");
        let mut next = guard.data.clone();
        let result = change(&mut next)?;
        let revision = self.database.write(
            "auth",
            guard.revision,
            serde_json::to_value(&next).map_err(|_| denied())?,
        )?;
        guard.data = next;
        guard.revision = revision;
        Ok(result)
    }
    pub fn needs_setup(&self) -> bool {
        self.inner.lock().expect("auth mutex").data.users.is_empty()
    }
    pub fn setup(&self, username: &str, password: &str) -> Result<String, ImportError> {
        self.admit_credentials()?;
        let hash = password_hash(password)?;
        self.update(|data| {
            if !data.users.is_empty() {
                return Err(denied());
            }
            let user = create_user(data, username, hash, true)?;
            new_session(data, &user)
        })
    }
    pub fn login(&self, username: &str, password: &str) -> Result<String, ImportError> {
        self.admit_credentials()?;
        if password.len() > 256 {
            return Err(denied());
        }
        self.update(|data| {
            let user = data
                .users
                .values()
                .find(|u| u.username == username)
                .cloned()
                .ok_or_else(denied)?;
            let hash = PasswordHash::new(&user.password_hash).map_err(|_| denied())?;
            Argon2::default()
                .verify_password(password.as_bytes(), &hash)
                .map_err(|_| denied())?;
            new_session(data, &user.id)
        })
    }
    pub fn logout(&self, session: &str) -> Result<(), ImportError> {
        self.update(|d| {
            d.sessions.remove(&sha256(session.as_bytes()));
            Ok(())
        })
    }
    pub fn actor(&self, session: &str) -> Result<Actor, ImportError> {
        let data = &self.inner.lock().expect("auth mutex").data;
        actor_from_data(data, session)
    }
    /// Lock order: repository -> Auth -> database worker. No Auth callback locks
    /// repositories. Archive and revocation use this same lock as publication.
    pub(crate) fn with_write_access<T>(
        &self,
        session: &str,
        expected: &Actor,
        write: impl FnOnce() -> Result<T, ImportError>,
    ) -> Result<T, ImportError> {
        let guard = self.inner.lock().expect("auth mutex");
        let actual = actor_from_data(&guard.data, session)?;
        if actual.id != expected.id
            || actual.project_id != expected.project_id
            || actual.role != expected.role
            || !actual.role.can_write()
        {
            return Err(denied());
        }
        write()
    }
    pub(crate) fn with_view_access<T>(
        &self,
        session: &str,
        expected: &Actor,
        write: impl FnOnce() -> Result<T, ImportError>,
    ) -> Result<T, ImportError> {
        let guard = self.inner.lock().expect("auth mutex");
        let actual = actor_from_data(&guard.data, session)?;
        if actual.id != expected.id
            || actual.project_id != expected.project_id
            || actual.role != expected.role
        {
            return Err(denied());
        }
        write()
    }
    pub fn audit(&self, actor: &Actor) -> serde_json::Value {
        let guard = self.inner.lock().expect("auth mutex");
        let owner = guard
            .data
            .projects
            .get(&actor.project_id)
            .is_some_and(|p| p.members.get(&actor.id) == Some(&Role::Owner));
        let trail = if owner {
            guard
                .data
                .audit
                .0
                .get(&actor.project_id)
                .cloned()
                .unwrap_or_default()
        } else {
            crate::audit::AuditTrail::default()
        };
        serde_json::json!({"scope":"current project owner; successful auth mutations; per-project last512", "retention_capacity":crate::audit::RETAINED,"total":trail.total,"dropped":trail.total.saturating_sub(trail.entries.len() as u64),"visible_entries":trail.entries.len(),"entries":trail.entries})
    }
    pub fn rename_project(
        &self,
        actor: &Actor,
        session: &str,
        id: &str,
        name: &str,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.update(|d| {
            let current = actor_from_data(d, session)?;
            if current.id != actor.id || current.project_id != actor.project_id {
                return Err(denied());
            }
            if name.trim().is_empty() || name.len() > 200 {
                return Err(ImportError::new(
                    "project_limit",
                    "Название должно содержать 1–200 bytes.",
                ));
            }
            let project = d.projects.get_mut(id).ok_or_else(denied)?;
            if project.archived || project.members.get(&actor.id) != Some(&Role::Owner) {
                return Err(denied());
            }
            if project.revision != expected_revision {
                return Err(ImportError::new(
                    "project_conflict",
                    "Проект изменился. Обновите страницу.",
                ));
            }
            project.name = name.into();
            project.revision = project.revision.checked_add(1).ok_or_else(denied)?;
            d.audit.append(
                &actor.id,
                id,
                "project_renamed",
                vec![id.into()],
                project.revision,
            )?;
            Ok(())
        })
    }
    pub fn set_archived(
        &self,
        actor: &Actor,
        session: &str,
        id: &str,
        archived: bool,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.update(|d| {
            let current = actor_from_data(d, session)?;
            if current.id != actor.id || current.project_id != actor.project_id { return Err(denied()); }
            let project = d.projects.get(id).ok_or_else(denied)?;
            if project.members.get(&actor.id) != Some(&Role::Owner) { return Err(denied()); }
            if project.revision != expected_revision { return Err(ImportError::new("project_conflict", "Проект изменился. Обновите страницу.")); }
            if project.archived == archived { return Ok(()); }
            if archived {
                let replacement = d.projects.values().find(|p| p.id != id && !p.archived && p.members.contains_key(&actor.id)).map(|p| p.id.clone());
                if d.sessions.get(&sha256(session.as_bytes())).is_some_and(|s| s.project_id == id) && replacement.is_none() {
                    return Err(ImportError::new("project_last_active", "Сначала создайте или откройте другой доступный проект. Последний текущий проект не архивируется."));
                }
                for s in d.sessions.values_mut().filter(|s| s.project_id == id) {
                    if let Some(other) = d.projects.values().find(|p| p.id != id && !p.archived && p.members.contains_key(&s.user_id)) { s.project_id = other.id.clone(); }
                }
            }
            let project = d.projects.get_mut(id).expect("project"); project.archived = archived;
            project.revision = project.revision.checked_add(1).ok_or_else(denied)?;
            d.audit.append(&actor.id, id, if archived { "project_archived" } else { "project_restored" }, vec![id.into()], project.revision)?; Ok(())
        })
    }
    pub fn projects(&self, actor: &Actor) -> Vec<Project> {
        self.inner
            .lock()
            .expect("auth mutex")
            .data
            .projects
            .values()
            .filter(|p| p.members.contains_key(&actor.id))
            .cloned()
            .collect()
    }
    pub fn all_projects(&self) -> Vec<Project> {
        self.inner
            .lock()
            .expect("auth mutex")
            .data
            .projects
            .values()
            .cloned()
            .collect()
    }
}
fn require_current_writer(
    data: &AuthData,
    session: &str,
    expected: &Actor,
) -> Result<Actor, ImportError> {
    let actual = actor_from_data(data, session)?;
    if actual.id != expected.id
        || actual.project_id != expected.project_id
        || actual.role != expected.role
        || !actual.role.can_write()
    {
        return Err(denied());
    }
    Ok(actual)
}
fn actor_from_data(data: &AuthData, session: &str) -> Result<Actor, ImportError> {
    let session = data
        .sessions
        .get(&sha256(session.as_bytes()))
        .filter(|s| s.expires > chrono::Utc::now().timestamp())
        .ok_or_else(denied)?;
    let user = data.users.get(&session.user_id).ok_or_else(denied)?;
    let project = data.projects.get(&session.project_id).ok_or_else(denied)?;
    if project.archived {
        return Err(denied());
    }
    let role = *project.members.get(&user.id).ok_or_else(denied)?;
    Ok(Actor {
        id: user.id.clone(),
        username: user.username.clone(),
        project_id: project.id.clone(),
        role,
        admin: user.admin,
    })
}
impl Auth {
    pub fn switch(&self, session: &str, project_id: &str) -> Result<(), ImportError> {
        self.update(|d| {
            let key = sha256(session.as_bytes());
            let user_id = d.sessions.get(&key).ok_or_else(denied)?.user_id.clone();
            if !d
                .projects
                .get(project_id)
                .is_some_and(|p| !p.archived && p.members.contains_key(&user_id))
            {
                return Err(denied());
            }
            d.sessions.get_mut(&key).expect("session exists").project_id = project_id.into();
            Ok(())
        })
    }
    pub fn create_project(
        &self,
        actor: &Actor,
        session: &str,
        name: &str,
    ) -> Result<String, ImportError> {
        self.update(|d| {
            require_current_writer(d, session, actor)?;
            let id = create_project(d, &actor.id, name)?;
            d.audit
                .append(&actor.id, &id, "project_created", vec![id.clone()], 0)?;
            Ok(id)
        })
    }
    pub fn restore_project(
        &self,
        actor: &Actor,
        session: &str,
        name: &str,
        mut repository: serde_json::Value,
    ) -> Result<String, ImportError> {
        let mut guard = self.inner.lock().expect("auth mutex");
        require_current_writer(&guard.data, session, actor)?;
        let mut next = guard.data.clone();
        let id = create_project(&mut next, &actor.id, name)?;
        next.audit.append(
            &actor.id,
            &id,
            "project_backup_restored",
            vec![id.clone()],
            0,
        )?;
        if let Some(logs) = repository
            .get_mut("logs")
            .and_then(serde_json::Value::as_object_mut)
        {
            for log in logs.values_mut() {
                if let Some(log) = log.as_object_mut() {
                    log.insert("project_id".into(), serde_json::Value::String(id.clone()));
                }
            }
        }
        let versions = self.database.write_batch(vec![
            (
                "auth".into(),
                guard.revision,
                serde_json::to_value(&next).map_err(|_| denied())?,
            ),
            (format!("repository/{id}"), 0, repository),
        ])?;
        guard.data = next;
        guard.revision = versions[0];
        Ok(id)
    }
    pub fn add_user(
        &self,
        actor: &Actor,
        session: &str,
        username: &str,
        password: &str,
    ) -> Result<String, ImportError> {
        if !actor.admin {
            return Err(denied());
        }
        self.admit_credentials()?;
        let hash = password_hash(password)?;
        self.update(|d| {
            if !require_current_writer(d, session, actor)?.admin {
                return Err(denied());
            }
            let id = create_user(d, username, hash, false)?;
            d.audit.append(
                &actor.id,
                &actor.project_id,
                "user_created",
                vec![id.clone()],
                0,
            )?;
            Ok(id)
        })
    }
    pub fn grant(
        &self,
        actor: &Actor,
        session: &str,
        project_id: &str,
        username: &str,
        role: Role,
    ) -> Result<(), ImportError> {
        self.update(|d| {
            require_current_writer(d, session, actor)?;
            let user = d
                .users
                .values()
                .find(|u| u.username == username)
                .map(|u| u.id.clone())
                .ok_or_else(denied)?;
            let project = d.projects.get_mut(project_id).ok_or_else(denied)?;
            if project.members.get(&actor.id) != Some(&Role::Owner)
                || project.archived
                || role == Role::Owner
                || project.members.get(&user) == Some(&Role::Owner)
            {
                return Err(denied());
            }
            project.members.insert(user, role);
            project.revision = project.revision.checked_add(1).ok_or_else(denied)?;
            d.audit.append(
                &actor.id,
                project_id,
                "membership_changed",
                vec![project_id.into()],
                project.revision,
            )?;
            Ok(())
        })
    }
}
impl Auth {
    fn admit_credentials(&self) -> Result<(), ImportError> {
        let mut attempts = self.attempts.lock().expect("credentials mutex");
        let now = Instant::now();
        attempts.retain(|time| now.duration_since(*time) < Duration::from_secs(60));
        if attempts.len() >= 20 {
            return Err(ImportError::new(
                "credential_rate_limit",
                "Слишком много попыток входа. Подождите минуту.",
            ));
        }
        attempts.push_back(now);
        Ok(())
    }
}
fn create_user(
    data: &mut AuthData,
    username: &str,
    hash: String,
    admin: bool,
) -> Result<String, ImportError> {
    if data.users.len() >= 64
        || username.is_empty()
        || username.len() > 80
        || !username
            .chars()
            .all(|c| c.is_alphanumeric() || "_-.".contains(c))
        || data.users.values().any(|u| u.username == username)
    {
        return Err(ImportError::new(
            "username_policy",
            "Нужно уникальное имя до 80 символов: буквы, цифры, _-.",
        ));
    }
    let id = format!("user-{}", uuid::Uuid::new_v4().simple());
    data.users.insert(
        id.clone(),
        User {
            id: id.clone(),
            username: username.into(),
            password_hash: hash,
            admin,
        },
    );
    create_project(data, &id, "Мой проект")?;
    Ok(id)
}
fn create_project(data: &mut AuthData, user: &str, name: &str) -> Result<String, ImportError> {
    if data.projects.len() >= 64 || name.trim().is_empty() || name.len() > 200 {
        return Err(ImportError::new(
            "project_limit",
            "Нужно непустое название до 200 bytes; максимум 64 проекта.",
        ));
    }
    let id = format!("project-{}", uuid::Uuid::new_v4().simple());
    data.projects.insert(
        id.clone(),
        Project {
            id: id.clone(),
            name: name.into(),
            members: BTreeMap::from([(user.into(), Role::Owner)]),
            archived: false,
            revision: 1,
        },
    );
    Ok(id)
}
fn new_session(data: &mut AuthData, user: &str) -> Result<String, ImportError> {
    let now = chrono::Utc::now().timestamp();
    data.sessions.retain(|_, s| s.expires > now);
    if data.sessions.len() >= 256 {
        return Err(ImportError::new(
            "session_limit",
            "Слишком много активных сессий.",
        ));
    }
    let project = data
        .projects
        .values()
        .find(|p| !p.archived && p.members.contains_key(user))
        .ok_or_else(denied)?
        .id
        .clone();
    let token = token();
    data.sessions.insert(
        sha256(token.as_bytes()),
        Session {
            user_id: user.into(),
            project_id: project,
            expires: now + 8 * 3600,
        },
    );
    Ok(token)
}

#[cfg(test)]
mod sprint08_contracts {
    use super::*;
    #[test]
    fn old_project_json_is_unchanged_and_current_session_checks_fail_closed() {
        let old = serde_json::json!({"id":"p","name":"old","members":{"u":"owner"}});
        let project: Project = serde_json::from_value(old.clone()).unwrap();
        assert_eq!(serde_json::to_value(&project).unwrap(), old);
        let mut data = AuthData::default();
        data.users.insert(
            "u".into(),
            User {
                id: "u".into(),
                username: "u".into(),
                password_hash: String::new(),
                admin: true,
            },
        );
        data.projects.insert("p".into(), project);
        data.sessions.insert(
            sha256(b"session"),
            Session {
                user_id: "u".into(),
                project_id: "p".into(),
                expires: chrono::Utc::now().timestamp() + 60,
            },
        );
        let captured = actor_from_data(&data, "session").unwrap();
        assert!(require_current_writer(&data, "session", &captured).is_ok());
        data.projects
            .get_mut("p")
            .unwrap()
            .members
            .insert("u".into(), Role::Viewer);
        assert_eq!(
            require_current_writer(&data, "session", &captured)
                .unwrap_err()
                .code,
            "access_denied"
        );
        data.projects
            .get_mut("p")
            .unwrap()
            .members
            .insert("u".into(), Role::Owner);
        data.projects.get_mut("p").unwrap().archived = true;
        assert!(require_current_writer(&data, "session", &captured).is_err());
        data.projects.get_mut("p").unwrap().archived = false;
        data.sessions.clear();
        assert!(require_current_writer(&data, "session", &captured).is_err());
    }

    #[test]
    #[ignore = "requires fresh isolated S8_QA_AUTH_DATABASE_URL; controlled actual database archive/publication ordering"]
    fn actual_archive_publication_gate_serializes_and_refuses_late_worker() {
        use std::sync::{Arc, mpsc};
        let url = std::env::var("S8_QA_AUTH_DATABASE_URL")
            .expect("isolated fresh QA DB required; never print URL");
        let db = Database::connect(url).unwrap();
        let auth = Arc::new(Auth::open(db.clone()).unwrap());
        assert!(auth.needs_setup(), "test requires a fresh owned database");
        let session = auth.setup("s8_gate_owner", "S8GatePassword123").unwrap();
        let captured = auth.actor(&session).unwrap();
        auth.create_project(&captured, &session, "Replacement")
            .unwrap();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let write_auth = auth.clone();
        let write_session = session.clone();
        let write_actor = captured.clone();
        let write_db = db.clone();
        let worker = std::thread::spawn(move || {
            write_auth.with_write_access(&write_session, &write_actor, || {
                entered_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                write_db.write(
                    "s8/gate-before-archive",
                    0,
                    serde_json::json!({"committed":true}),
                )
            })
        });
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // The actual shared guard cannot be obtained while the database write gate is held.
        assert!(auth.inner.try_lock().is_err());
        let archive_auth = auth.clone();
        let archive_actor = captured.clone();
        let archive_session = session.clone();
        let archiver = std::thread::spawn(move || {
            archive_auth.set_archived(
                &archive_actor,
                &archive_session,
                &archive_actor.project_id,
                true,
                1,
            )
        });
        release_tx.send(()).unwrap();
        assert_eq!(worker.join().unwrap().unwrap(), 1);
        archiver.join().unwrap().unwrap();
        assert_eq!(
            db.read("s8/gate-before-archive").unwrap().unwrap().1,
            serde_json::json!({"committed":true})
        );
        let (ready_tx, ready_rx) = mpsc::channel();
        let (start_tx, start_rx) = mpsc::channel();
        let late_auth = auth.clone();
        let late_session = session.clone();
        let late_actor = captured.clone();
        let late_db = db.clone();
        let late = std::thread::spawn(move || {
            ready_tx.send(()).unwrap();
            start_rx.recv_timeout(Duration::from_secs(5)).unwrap();
            late_auth.with_write_access(&late_session, &late_actor, || {
                late_db.write("s8/gate-after-archive", 0, serde_json::json!(true))
            })
        });
        ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        start_tx.send(()).unwrap();
        assert_eq!(late.join().unwrap().unwrap_err().code, "access_denied");
        assert!(db.read("s8/gate-after-archive").unwrap().is_none());
        let current = auth.actor(&session).unwrap();
        assert_ne!(current.project_id, captured.project_id);
        auth.logout(&session).unwrap();
        assert!(
            auth.create_project(&current, &session, "Forbidden")
                .is_err()
        );
        assert!(
            auth.add_user(&current, &session, "forbidden", "S8GatePassword123")
                .is_err()
        );
        assert!(
            auth.grant(
                &current,
                &session,
                &current.project_id,
                "s8_gate_owner",
                Role::Editor
            )
            .is_err()
        );
        assert!(
            auth.restore_project(&current, &session, "Forbidden", serde_json::json!({}))
                .is_err()
        );
    }
}
