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
    users: BTreeMap<String, User>,
    projects: BTreeMap<String, Project>,
    sessions: BTreeMap<String, Session>,
}
pub(crate) fn validate_stored(value: &serde_json::Value) -> Result<(), ImportError> {
    let data: AuthData = serde_json::from_value(value.clone()).map_err(|_| denied())?;
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
        let session = data
            .sessions
            .get(&sha256(session.as_bytes()))
            .filter(|s| s.expires > chrono::Utc::now().timestamp())
            .ok_or_else(denied)?;
        let user = data.users.get(&session.user_id).ok_or_else(denied)?;
        let project = data.projects.get(&session.project_id).ok_or_else(denied)?;
        let role = *project.members.get(&user.id).ok_or_else(denied)?;
        Ok(Actor {
            id: user.id.clone(),
            username: user.username.clone(),
            project_id: project.id.clone(),
            role,
            admin: user.admin,
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
    pub fn switch(&self, session: &str, project_id: &str) -> Result<(), ImportError> {
        self.update(|d| {
            let key = sha256(session.as_bytes());
            let user_id = d.sessions.get(&key).ok_or_else(denied)?.user_id.clone();
            if !d
                .projects
                .get(project_id)
                .is_some_and(|p| p.members.contains_key(&user_id))
            {
                return Err(denied());
            }
            d.sessions.get_mut(&key).expect("session exists").project_id = project_id.into();
            Ok(())
        })
    }
    pub fn create_project(&self, actor: &Actor, name: &str) -> Result<String, ImportError> {
        self.update(|d| create_project(d, &actor.id, name))
    }
    pub fn restore_project(
        &self,
        actor: &Actor,
        name: &str,
        mut repository: serde_json::Value,
    ) -> Result<String, ImportError> {
        let mut guard = self.inner.lock().expect("auth mutex");
        let mut next = guard.data.clone();
        let id = create_project(&mut next, &actor.id, name)?;
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
        username: &str,
        password: &str,
    ) -> Result<String, ImportError> {
        if !actor.admin {
            return Err(denied());
        }
        self.admit_credentials()?;
        let hash = password_hash(password)?;
        self.update(|d| create_user(d, username, hash, false))
    }
    pub fn grant(
        &self,
        actor: &Actor,
        project_id: &str,
        username: &str,
        role: Role,
    ) -> Result<(), ImportError> {
        self.update(|d| {
            let user = d
                .users
                .values()
                .find(|u| u.username == username)
                .map(|u| u.id.clone())
                .ok_or_else(denied)?;
            let project = d.projects.get_mut(project_id).ok_or_else(denied)?;
            if project.members.get(&actor.id) != Some(&Role::Owner)
                || role == Role::Owner
                || project.members.get(&user) == Some(&Role::Owner)
            {
                return Err(denied());
            }
            project.members.insert(user, role);
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
        .find(|p| p.members.contains_key(user))
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
