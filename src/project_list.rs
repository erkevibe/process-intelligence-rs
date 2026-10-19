//! Workspace project-list placement. This catalog grants no project access.
//! Auth supplies current-writer/ProjectOwner checks and persists mutations atomically.
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use uuid::{Uuid, Variant};

use crate::domain::ImportError;

const MAX_FOLDERS: usize = 512;
const MAX_DEPTH: usize = 64;

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Default, Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ListFolder {
    pub id: String,
    pub name: String,
    pub owner_id: String,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub archived: bool,
}

#[derive(Default, Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct ProjectListCatalog {
    pub revision: u64,
    pub folders: BTreeMap<String, ListFolder>,
    pub project_folders: BTreeMap<String, String>,
}

fn error(code: &str) -> ImportError {
    ImportError::new(
        code,
        match code {
            "project_list_conflict" => "Список проектов изменился. Обновите страницу.",
            "access_denied" => "Изменить папку может только её создатель.",
            "project_list_not_empty" => "Сначала переместите проекты и дочерние папки.",
            "project_list_no_change" => "Изменений нет.",
            _ => "Некорректная папка или расположение проекта.",
        },
    )
}

fn invalid() -> ImportError {
    error("project_list_invalid")
}

fn valid_id(id: &str) -> bool {
    Uuid::parse_str(id).is_ok_and(|uuid| {
        id.len() == 36
            && uuid.get_version_num() == 4
            && uuid.get_variant() == Variant::RFC4122
            && uuid.to_string() == id
    })
}

fn name(value: &str) -> Result<String, ImportError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 200 {
        return Err(invalid());
    }
    Ok(value.to_owned())
}

impl ProjectListCatalog {
    pub fn is_empty(&self) -> bool {
        self.revision == 0 && self.folders.is_empty() && self.project_folders.is_empty()
    }

    pub fn validate(
        &self,
        users: &BTreeSet<String>,
        projects: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.validate_structure()?;
        if self
            .folders
            .values()
            .any(|folder| !users.contains(&folder.owner_id))
            || self
                .project_folders
                .keys()
                .any(|project| !projects.contains(project))
        {
            return Err(invalid());
        }
        Ok(())
    }

    fn validate_structure(&self) -> Result<(), ImportError> {
        if self.folders.len() > MAX_FOLDERS
            || (self.revision == 0
                && (!self.folders.is_empty() || !self.project_folders.is_empty()))
        {
            return Err(invalid());
        }
        let mut siblings = BTreeSet::new();
        for (id, folder) in &self.folders {
            if !valid_id(id)
                || folder.id != *id
                || folder.owner_id.is_empty()
                || name(&folder.name)? != folder.name
                || !siblings.insert((
                    folder.owner_id.as_str(),
                    folder.parent_id.as_deref(),
                    folder.name.as_str(),
                ))
            {
                return Err(invalid());
            }
            let mut seen = BTreeSet::new();
            let mut cursor = Some(id.as_str());
            while let Some(current) = cursor {
                if !seen.insert(current) || seen.len() > MAX_DEPTH {
                    return Err(invalid());
                }
                let ancestor = self.folders.get(current).ok_or_else(invalid)?;
                if ancestor.owner_id != folder.owner_id {
                    return Err(invalid());
                }
                cursor = ancestor.parent_id.as_deref();
            }
        }
        if self
            .project_folders
            .iter()
            .any(|(project, folder)| project.is_empty() || !self.folders.contains_key(folder))
        {
            return Err(invalid());
        }
        Ok(())
    }

    fn owned(&self, owner: &str, id: &str) -> Result<&ListFolder, ImportError> {
        let folder = self.folders.get(id).ok_or_else(invalid)?;
        if folder.owner_id != owner {
            return Err(error("access_denied"));
        }
        Ok(folder)
    }

    fn destination(&self, owner: &str, parent: Option<&str>) -> Result<(), ImportError> {
        let mut cursor = parent;
        let mut depth = 0;
        while let Some(id) = cursor {
            depth += 1;
            if depth > MAX_DEPTH {
                return Err(invalid());
            }
            let folder = self.owned(owner, id)?;
            if folder.archived {
                return Err(invalid());
            }
            cursor = folder.parent_id.as_deref();
        }
        Ok(())
    }

    fn change<T>(
        &mut self,
        expected_revision: u64,
        edit: impl FnOnce(&mut Self) -> Result<T, ImportError>,
    ) -> Result<T, ImportError> {
        if self.revision != expected_revision {
            return Err(error("project_list_conflict"));
        }
        self.validate_structure()?;
        let revision = self.revision.checked_add(1).ok_or_else(invalid)?;
        let mut next = self.clone();
        let result = edit(&mut next)?;
        next.revision = revision;
        next.validate_structure()?;
        *self = next;
        Ok(result)
    }

    pub fn create(
        &mut self,
        owner: &str,
        folder_name: &str,
        parent: Option<&str>,
        expected_revision: u64,
    ) -> Result<String, ImportError> {
        self.change(expected_revision, |next| {
            if owner.is_empty() || next.folders.len() >= MAX_FOLDERS {
                return Err(invalid());
            }
            next.destination(owner, parent)?;
            let id = loop {
                let candidate = Uuid::new_v4().to_string();
                if !next.folders.contains_key(&candidate) {
                    break candidate;
                }
            };
            next.folders.insert(
                id.clone(),
                ListFolder {
                    id: id.clone(),
                    name: name(folder_name)?,
                    owner_id: owner.into(),
                    parent_id: parent.map(str::to_owned),
                    archived: false,
                },
            );
            Ok(id)
        })
    }

    pub fn rename(
        &mut self,
        owner: &str,
        id: &str,
        folder_name: &str,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.change(expected_revision, |next| {
            next.owned(owner, id)?;
            let folder_name = name(folder_name)?;
            if next.folders.get(id).ok_or_else(invalid)?.name == folder_name {
                return Err(error("project_list_no_change"));
            }
            next.folders.get_mut(id).ok_or_else(invalid)?.name = folder_name;
            Ok(())
        })
    }

    pub fn move_folder(
        &mut self,
        owner: &str,
        id: &str,
        parent: Option<&str>,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.change(expected_revision, |next| {
            if next.owned(owner, id)?.parent_id.as_deref() == parent {
                return Err(error("project_list_no_change"));
            }
            next.destination(owner, parent)?;
            next.folders.get_mut(id).ok_or_else(invalid)?.parent_id = parent.map(str::to_owned);
            Ok(())
        })
    }

    pub fn archive(
        &mut self,
        owner: &str,
        id: &str,
        archived: bool,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.change(expected_revision, |next| {
            if next.owned(owner, id)?.archived == archived {
                return Err(error("project_list_no_change"));
            }
            next.folders.get_mut(id).ok_or_else(invalid)?.archived = archived;
            Ok(())
        })
    }

    pub fn delete(
        &mut self,
        owner: &str,
        id: &str,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.change(expected_revision, |next| {
            next.owned(owner, id)?;
            if next
                .folders
                .values()
                .any(|folder| folder.parent_id.as_deref() == Some(id))
                || next.project_folders.values().any(|folder| folder == id)
            {
                return Err(error("project_list_not_empty"));
            }
            next.folders.remove(id);
            Ok(())
        })
    }

    /// Auth must separately check the project's Owner and existence. Moving to
    /// root never requires ownership of the previous folder.
    pub fn assign(
        &mut self,
        owner: &str,
        project_id: &str,
        folder: Option<&str>,
        expected_revision: u64,
    ) -> Result<(), ImportError> {
        self.change(expected_revision, |next| {
            if owner.is_empty() || project_id.is_empty() {
                return Err(invalid());
            }
            if next.project_folders.get(project_id).map(String::as_str) == folder {
                return Err(error("project_list_no_change"));
            }
            next.destination(owner, folder)?;
            if let Some(folder) = folder {
                next.project_folders
                    .insert(project_id.into(), folder.into());
            } else {
                next.project_folders.remove(project_id);
            }
            Ok(())
        })
    }

    pub fn remove_project(&mut self, project_id: &str) -> Result<bool, ImportError> {
        self.validate_structure()?;
        if !self.project_folders.contains_key(project_id) {
            return Ok(false);
        }
        self.change(self.revision, |next| {
            next.project_folders.remove(project_id);
            Ok(true)
        })
    }

    /// Return only folder metadata; never return assignments, project IDs or
    /// sibling counts. Stored catalogs must already have passed validate.
    pub fn visible_folders(
        &self,
        user_id: &str,
        accessible_project_ids: &BTreeSet<String>,
    ) -> Vec<ListFolder> {
        let mut visible = self
            .folders
            .iter()
            .filter(|(_, folder)| folder.owner_id == user_id)
            .map(|(id, _)| id.clone())
            .collect::<BTreeSet<_>>();
        for project in accessible_project_ids {
            let mut cursor = self.project_folders.get(project).map(String::as_str);
            let mut visited = BTreeSet::new();
            while let Some(id) = cursor {
                if !visited.insert(id) || visited.len() > MAX_DEPTH {
                    break;
                }
                let Some(folder) = self.folders.get(id) else {
                    break;
                };
                visible.insert(id.into());
                cursor = folder.parent_id.as_deref();
            }
        }
        visible
            .into_iter()
            .filter_map(|id| self.folders.get(&id).cloned())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn code<T>(result: Result<T, ImportError>) -> String {
        match result {
            Ok(_) => panic!("expected refusal"),
            Err(error) => error.code,
        }
    }

    fn set(values: &[&str]) -> BTreeSet<String> {
        values.iter().map(|value| (*value).into()).collect()
    }

    #[test]
    fn stale_foreign_cycles_and_duplicates_are_atomic() {
        let mut catalog = ProjectListCatalog::default();
        let root = catalog.create("alice", "Root", None, 0).unwrap();
        let child = catalog.create("alice", "Child", Some(&root), 1).unwrap();
        let before = catalog.clone();
        assert_eq!(
            code(catalog.rename("alice", &root, "Other", 1)),
            "project_list_conflict"
        );
        assert_eq!(
            code(catalog.rename("bob", &root, "Other", 2)),
            "access_denied"
        );
        assert_eq!(
            code(catalog.create("bob", "Other", Some(&root), 2)),
            "access_denied"
        );
        assert_eq!(
            code(catalog.move_folder("alice", &root, Some(&child), 2)),
            "project_list_invalid"
        );
        assert_eq!(
            code(catalog.create("alice", " Root ", None, 2)),
            "project_list_invalid"
        );
        assert_eq!(catalog, before);
        catalog.create("bob", "Root", None, 2).unwrap();
        catalog
            .validate(&set(&["alice", "bob"]), &set(&[]))
            .unwrap();
    }

    #[test]
    fn archive_blocks_destinations_but_allows_project_escape_and_safe_delete() {
        let mut catalog = ProjectListCatalog::default();
        let root = catalog.create("alice", "Root", None, 0).unwrap();
        let child = catalog.create("alice", "Child", Some(&root), 1).unwrap();
        catalog.assign("alice", "project", Some(&child), 2).unwrap();
        assert_eq!(
            code(catalog.delete("alice", &child, 3)),
            "project_list_not_empty"
        );
        catalog.archive("alice", &root, true, 3).unwrap();
        let before = catalog.clone();
        assert_eq!(
            code(catalog.assign("alice", "other", Some(&child), 4)),
            "project_list_invalid"
        );
        assert_eq!(
            code(catalog.create("alice", "Blocked", Some(&child), 4)),
            "project_list_invalid"
        );
        assert_eq!(catalog, before);
        catalog
            .validate(&set(&["alice"]), &set(&["project"]))
            .unwrap();
        // The ProjectOwner need not be the previous folder's creator to escape.
        catalog.assign("bob", "project", None, 4).unwrap();
        catalog.delete("alice", &child, 5).unwrap();
        catalog.delete("alice", &root, 6).unwrap();
        assert!(!catalog.is_empty());
    }

    #[test]
    fn no_op_and_overflow_do_not_advance_revision() {
        let mut catalog = ProjectListCatalog::default();
        let root = catalog.create("alice", "Root", None, 0).unwrap();
        let before = catalog.clone();
        assert_eq!(
            code(catalog.rename("alice", &root, " Root ", 1)),
            "project_list_no_change"
        );
        assert_eq!(
            code(catalog.move_folder("alice", &root, None, 1)),
            "project_list_no_change"
        );
        assert_eq!(
            code(catalog.archive("alice", &root, false, 1)),
            "project_list_no_change"
        );
        assert_eq!(
            code(catalog.assign("alice", "project", None, 1)),
            "project_list_no_change"
        );
        assert_eq!(catalog, before);
        assert!(!catalog.remove_project("missing").unwrap());
        assert_eq!(catalog, before);
        catalog.revision = u64::MAX;
        let before = catalog.clone();
        assert_eq!(
            code(catalog.rename("alice", &root, "Changed", u64::MAX)),
            "project_list_invalid"
        );
        assert_eq!(catalog, before);
    }

    #[test]
    fn visibility_includes_only_own_and_accessible_ancestors() {
        let mut catalog = ProjectListCatalog::default();
        let root = catalog.create("alice", "Root", None, 0).unwrap();
        let leaf = catalog
            .create("alice", "Shared path", Some(&root), 1)
            .unwrap();
        let sibling = catalog
            .create("alice", "Secret sibling", Some(&root), 2)
            .unwrap();
        let own = catalog.create("bob", "Own empty", None, 3).unwrap();
        catalog.assign("alice", "shared", Some(&leaf), 4).unwrap();
        catalog
            .assign("alice", "secret", Some(&sibling), 5)
            .unwrap();
        let visible = catalog.visible_folders("bob", &set(&["shared"]));
        assert_eq!(
            visible
                .iter()
                .map(|f| f.id.clone())
                .collect::<BTreeSet<_>>(),
            set(&[&root, &leaf, &own])
        );
        assert!(!visible.iter().any(|f| f.id == sibling));
        assert_eq!(catalog.visible_folders("unknown", &set(&[])), vec![]);
    }

    #[test]
    fn strict_decode_and_external_links_are_validated() {
        assert!(serde_json::from_str::<ProjectListCatalog>(r#"{"extra":true}"#).is_err());
        assert!(
            serde_json::from_str::<ListFolder>(
                r#"{"id":"x","name":"n","owner_id":"u","extra":true}"#
            )
            .is_err()
        );
        let mut catalog = ProjectListCatalog::default();
        let id = catalog.create("alice", "  Имя  ", None, 0).unwrap();
        assert_eq!(catalog.folders[&id].name, "Имя");
        catalog.assign("alice", "project", Some(&id), 1).unwrap();
        assert!(catalog.validate(&set(&[]), &set(&["project"])).is_err());
        assert!(catalog.validate(&set(&["alice"]), &set(&[])).is_err());
        let raw = serde_json::to_value(&catalog).unwrap();
        assert!(raw["folders"][&id].get("archived").is_none());
        let decoded: ProjectListCatalog = serde_json::from_value(raw).unwrap();
        assert_eq!(decoded, catalog);
        assert!(catalog.remove_project("project").unwrap());
        assert_eq!(catalog.revision, 3);
        catalog.folders.get_mut(&id).unwrap().parent_id = Some(id.clone());
        assert!(catalog.validate(&set(&["alice"]), &set(&[])).is_err());
    }

    #[test]
    fn depth_and_utf8_bounds_refuse_without_discarding_state() {
        let mut catalog = ProjectListCatalog::default();
        let mut parent = None;
        for n in 0..MAX_DEPTH {
            parent = Some(
                catalog
                    .create("alice", &format!("Level {n}"), parent.as_deref(), n as u64)
                    .unwrap(),
            );
        }
        let before = catalog.clone();
        assert_eq!(
            code(catalog.create("alice", "Too deep", parent.as_deref(), MAX_DEPTH as u64)),
            "project_list_invalid"
        );
        assert_eq!(
            code(catalog.create("alice", &"я".repeat(101), None, MAX_DEPTH as u64)),
            "project_list_invalid"
        );
        assert_eq!(catalog, before);
    }

    #[test]
    fn storage_rejects_noncanonical_ids_missing_links_and_zero_revision_content() {
        let mut catalog = ProjectListCatalog::default();
        let id = catalog.create("alice", "Root", None, 0).unwrap();
        let users = set(&["alice"]);
        let projects = set(&[]);
        let mut bad = catalog.clone();
        bad.revision = 0;
        assert!(bad.validate(&users, &projects).is_err());
        let mut bad = catalog.clone();
        let upper = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
        let mut folder = bad.folders.remove(&id).unwrap();
        folder.id = upper.into();
        bad.folders.insert(upper.into(), folder);
        assert!(bad.validate(&users, &projects).is_err());
        let mut bad = catalog.clone();
        bad.folders.get_mut(&id).unwrap().parent_id = Some(Uuid::new_v4().to_string());
        assert!(bad.validate(&users, &projects).is_err());
        let mut bad = catalog.clone();
        bad.project_folders
            .insert("project".into(), Uuid::new_v4().to_string());
        assert!(bad.validate(&users, &set(&["project"])).is_err());
        catalog.delete("alice", &id, 1).unwrap();
        catalog.validate(&users, &projects).unwrap();
        assert!(!catalog.is_empty());
    }

    #[test]
    fn folder_capacity_refusal_preserves_all_existing_folders() {
        let mut catalog = ProjectListCatalog::default();
        for n in 0..MAX_FOLDERS {
            catalog
                .create("alice", &format!("Folder {n}"), None, n as u64)
                .unwrap();
        }
        let before = catalog.clone();
        assert_eq!(
            code(catalog.create("alice", "Overflow", None, MAX_FOLDERS as u64)),
            "project_list_invalid"
        );
        assert_eq!(catalog, before);
    }
}
