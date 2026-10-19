//! Atomic project-list organization; it never grants membership or moves payloads.
use super::*;
use crate::project_list::ListFolder;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProjectListView {
    #[serde(skip)]
    pub projects: Vec<Project>,
    pub revision: u64,
    pub folders: Vec<ListFolder>,
    pub project_folders: BTreeMap<String, String>,
}

pub(crate) enum ProjectListChange {
    Create {
        name: String,
        parent: Option<String>,
    },
    Rename {
        id: String,
        name: String,
    },
    Move {
        id: String,
        parent: Option<String>,
    },
    Archive {
        id: String,
        archived: bool,
    },
    Delete {
        id: String,
    },
}

pub(super) fn validate_catalog(data: &AuthData) -> Result<(), ImportError> {
    data.project_list.validate(
        &data.users.keys().cloned().collect(),
        &data.projects.keys().cloned().collect(),
    )?;
    for (project, folder) in &data.project_list.project_folders {
        let folder = &data.project_list.folders[folder];
        if data.projects[project].members.get(&folder.owner_id) != Some(&Role::Owner) {
            return Err(denied());
        }
    }
    Ok(())
}

impl Auth {
    pub(crate) fn project_list_view(
        &self,
        expected: &Actor,
        session: &str,
    ) -> Result<ProjectListView, ImportError> {
        let guard = self.inner.lock().expect("auth mutex");
        let actor = actor_from_data(&guard.data, session)?;
        if actor.id != expected.id
            || actor.project_id != expected.project_id
            || actor.role != expected.role
        {
            return Err(denied());
        }
        let accessible: std::collections::BTreeSet<String> = guard
            .data
            .projects
            .values()
            .filter(|project| project.members.contains_key(&actor.id))
            .map(|project| project.id.clone())
            .collect();
        Ok(ProjectListView {
            projects: guard
                .data
                .projects
                .values()
                .filter(|project| accessible.contains(&project.id))
                .cloned()
                .collect(),
            revision: guard.data.project_list.revision,
            folders: guard
                .data
                .project_list
                .visible_folders(&actor.id, &accessible),
            project_folders: guard
                .data
                .project_list
                .project_folders
                .iter()
                .filter(|(project, _)| accessible.contains(*project))
                .map(|(project, folder)| (project.clone(), folder.clone()))
                .collect(),
        })
    }

    pub(crate) fn change_project_list(
        &self,
        expected: &Actor,
        session: &str,
        expected_revision: u64,
        change: ProjectListChange,
    ) -> Result<String, ImportError> {
        self.update(|data| {
            let actor = require_current_writer(data, session, expected)?;
            let (id, action, parameters) = match change {
                ProjectListChange::Create { name, parent } => {
                    let id = data.project_list.create(&actor.id, &name, parent.as_deref(), expected_revision)?;
                    let normalized_name = &data.project_list.folders[&id].name;
                    let parameters = serde_json::json!({"catalog_revision":expected_revision,"folder_id":id,"parent":parent,"name_sha256":sha256(normalized_name.as_bytes()),"name_bytes":normalized_name.len()});
                    (id, "project_list_folder_created", parameters)
                }
                ProjectListChange::Rename { id, name } => {
                    data.project_list.rename(&actor.id, &id, &name, expected_revision)?;
                    let normalized_name = &data.project_list.folders[&id].name;
                    let parameters = serde_json::json!({"catalog_revision":expected_revision,"folder_id":id,"name_sha256":sha256(normalized_name.as_bytes()),"name_bytes":normalized_name.len()});
                    (id, "project_list_folder_renamed", parameters)
                }
                ProjectListChange::Move { id, parent } => {
                    let old_parent = data.project_list.folders.get(&id).map(|folder| folder.parent_id.clone());
                    data.project_list.move_folder(&actor.id, &id, parent.as_deref(), expected_revision)?;
                    let parameters = serde_json::json!({"catalog_revision":expected_revision,"folder_id":id,"old_parent":old_parent,"parent":parent});
                    (id, "project_list_folder_moved", parameters)
                }
                ProjectListChange::Archive { id, archived } => {
                    data.project_list.archive(&actor.id, &id, archived, expected_revision)?;
                    let parameters = serde_json::json!({"catalog_revision":expected_revision,"folder_id":id,"archived":archived,"projects_access_unchanged":true});
                    (id, if archived { "project_list_folder_archived" } else { "project_list_folder_restored" }, parameters)
                }
                ProjectListChange::Delete { id } => {
                    data.project_list.delete(&actor.id, &id, expected_revision)?;
                    let parameters = serde_json::json!({"catalog_revision":expected_revision,"folder_id":id,"empty_required":true,"cascade":false});
                    (id, "project_list_folder_deleted", parameters)
                }
            };
            validate_catalog(data)?;
            data.audit.append_business(&actor.id, &actor.project_id, action, vec![id.clone()], data.project_list.revision, &parameters)?;
            Ok(id)
        })
    }

    pub(crate) fn move_project_in_list(
        &self,
        expected: &Actor,
        session: &str,
        project_id: &str,
        destination: Option<&str>,
        expected_catalog: u64,
        expected_project: u64,
    ) -> Result<(), ImportError> {
        self.update(|data| {
            let actor = require_current_writer(data, session, expected)?;
            let project = data.projects.get(project_id).ok_or_else(denied)?;
            if project.members.get(&actor.id) != Some(&Role::Owner) { return Err(denied()); }
            if project.revision != expected_project {
                return Err(ImportError::new("project_conflict", "Проект изменился. Обновите страницу."));
            }
            let old_folder = data.project_list.project_folders.get(project_id).cloned();
            data.project_list.assign(&actor.id, project_id, destination, expected_catalog)?;
            let project = data.projects.get_mut(project_id).ok_or_else(denied)?;
            project.revision = project.revision.checked_add(1).ok_or_else(denied)?;
            let revision = project.revision;
            validate_catalog(data)?;
            data.audit.append_business(&actor.id, project_id, "project_moved", vec![project_id.into()], revision,
                &serde_json::json!({"catalog_revision":expected_catalog,"project_revision":expected_project,"old_folder":old_folder,"destination":destination,"membership_unchanged":true,"payload_unchanged":true}))?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persisted_placement_requires_project_owner_and_keeps_legacy_auth_compatible() {
        let mut data = AuthData::default();
        let owner = create_user(
            &mut data,
            "owner",
            password_hash("FolderOwnerPassword123").unwrap(),
            true,
        )
        .unwrap();
        let other = create_user(
            &mut data,
            "other",
            password_hash("FolderOtherPassword123").unwrap(),
            false,
        )
        .unwrap();
        let project = data
            .projects
            .values()
            .find(|p| p.members.get(&owner) == Some(&Role::Owner))
            .unwrap()
            .id
            .clone();
        let legacy = serde_json::to_value(&data).unwrap();
        assert!(legacy.get("project_list").is_none());
        validate_stored(&legacy).unwrap();
        let folder = data
            .project_list
            .create(&owner, "Рабочие", None, 0)
            .unwrap();
        data.project_list
            .assign(&owner, &project, Some(&folder), 1)
            .unwrap();
        validate_stored(&serde_json::to_value(&data).unwrap()).unwrap();
        let mut foreign = data.clone();
        foreign
            .project_list
            .folders
            .get_mut(&folder)
            .unwrap()
            .owner_id = other;
        assert!(validate_stored(&serde_json::to_value(&foreign).unwrap()).is_err());
        data.projects
            .get_mut(&project)
            .unwrap()
            .members
            .insert(owner, Role::Editor);
        assert!(validate_stored(&serde_json::to_value(&data).unwrap()).is_err());
    }
}
