//! Bounded, project-relative folder metadata. Authorization, durable repository
//! CAS and supplying the current project's catalog belong to the caller.
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use uuid::{Uuid, Variant};

use crate::domain::ImportError;

pub const MAX_FOLDERS: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Folder {
    pub name: String,
    #[serde(default)]
    pub parent: Option<String>,
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Organization {
    pub folders: BTreeMap<String, Folder>,
    pub assignments: BTreeMap<String, String>,
}

fn failure(code: &str, message: &str) -> ImportError {
    ImportError::new(code, message)
}

fn valid_id(id: &str) -> bool {
    let Some(value) = id.strip_prefix("folder-") else {
        return false;
    };
    if value.len() != 36 {
        return false;
    }
    let Ok(uuid) = Uuid::parse_str(value) else {
        return false;
    };
    uuid.get_version_num() == 4
        && uuid.get_variant() == Variant::RFC4122
        && value == uuid.to_string()
}

fn normalized_name(name: &str) -> Result<String, ImportError> {
    let name = name.trim();
    if name.is_empty() || name.len() > 200 {
        return Err(failure(
            "folder_policy",
            "Название папки должно содержать от1до200bytes UTF-8 после удаления пробелов по краям.",
        ));
    }
    Ok(name.to_owned())
}

impl Organization {
    pub fn is_empty(&self) -> bool {
        self.folders.is_empty() && self.assignments.is_empty()
    }

    pub fn validate(&self, catalog: &BTreeSet<String>) -> Result<(), ImportError> {
        if self.folders.len() > MAX_FOLDERS {
            return Err(failure(
                "folder_policy",
                "В проекте разрешено не более128папок.",
            ));
        }
        if self.assignments.len() > catalog.len() {
            return Err(failure(
                "folder_resource",
                "Назначение ссылается на ресурс вне проекта.",
            ));
        }
        let mut sibling_names = BTreeSet::new();
        for (id, folder) in &self.folders {
            if !valid_id(id)
                || folder.name.is_empty()
                || folder.name.len() > 200
                || folder.name.trim() != folder.name
            {
                return Err(failure(
                    "folder_policy",
                    "Некорректный идентификатор или название папки.",
                ));
            }
            if let Some(parent) = &folder.parent
                && (parent == id || !self.folders.contains_key(parent))
            {
                return Err(failure(
                    "folder_parent",
                    "Родитель папки отсутствует в проекте или совпадает с самой папкой.",
                ));
            }
            if !sibling_names.insert((folder.parent.as_deref(), folder.name.as_str())) {
                return Err(failure(
                    "folder_duplicate",
                    "У этого родителя уже есть папка с таким названием.",
                ));
            }
        }
        // At most128nodes, bounded iterative traversal, never recursive input.
        for id in self.folders.keys() {
            let mut seen = BTreeSet::new();
            let mut current = Some(id.as_str());
            while let Some(node) = current {
                if !seen.insert(node) {
                    return Err(failure("folder_cycle", "Перемещение создаёт цикл папок."));
                }
                current = self
                    .folders
                    .get(node)
                    .and_then(|folder| folder.parent.as_deref());
            }
        }
        for (resource, folder) in &self.assignments {
            if resource.is_empty() || resource.len() > 128 || !catalog.contains(resource) {
                return Err(failure(
                    "folder_resource",
                    "Назначение ссылается на ресурс вне текущего проекта.",
                ));
            }
            if !self.folders.contains_key(folder) {
                return Err(failure(
                    "folder_missing",
                    "Назначенная папка отсутствует в проекте.",
                ));
            }
        }
        Ok(())
    }

    fn mutate(
        &mut self,
        catalog: &BTreeSet<String>,
        edit: impl FnOnce(&mut Self) -> Result<(), ImportError>,
    ) -> Result<(), ImportError> {
        self.validate(catalog)?;
        let mut next = self.clone();
        edit(&mut next)?;
        next.validate(catalog)?;
        *self = next;
        Ok(())
    }

    pub fn create(
        &mut self,
        id: &str,
        name: &str,
        parent: Option<&str>,
        catalog: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.mutate(catalog, |next| {
            if next.folders.contains_key(id) {
                return Err(failure(
                    "folder_duplicate",
                    "Идентификатор папки уже существует.",
                ));
            }
            if !valid_id(id) {
                return Err(failure(
                    "folder_policy",
                    "Некорректный идентификатор папки.",
                ));
            }
            if let Some(parent) = parent
                && (parent == id || !next.folders.contains_key(parent))
            {
                return Err(failure(
                    "folder_parent",
                    "Родитель папки отсутствует в проекте или совпадает с самой папкой.",
                ));
            }
            next.folders.insert(
                id.to_owned(),
                Folder {
                    name: normalized_name(name)?,
                    parent: parent.map(str::to_owned),
                },
            );
            Ok(())
        })
    }

    pub fn rename(
        &mut self,
        id: &str,
        name: &str,
        catalog: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.mutate(catalog, |next| {
            let folder = next
                .folders
                .get_mut(id)
                .ok_or_else(|| failure("folder_missing", "Папка отсутствует в проекте."))?;
            folder.name = normalized_name(name)?;
            Ok(())
        })
    }

    pub fn move_folder(
        &mut self,
        id: &str,
        parent: Option<&str>,
        catalog: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.mutate(catalog, |next| {
            if let Some(parent) = parent
                && (parent == id || !next.folders.contains_key(parent))
            {
                return Err(failure(
                    "folder_parent",
                    "Родитель папки отсутствует в проекте или совпадает с самой папкой.",
                ));
            }
            let folder = next
                .folders
                .get_mut(id)
                .ok_or_else(|| failure("folder_missing", "Папка отсутствует в проекте."))?;
            folder.parent = parent.map(str::to_owned);
            Ok(())
        })
    }

    pub fn delete_empty(
        &mut self,
        id: &str,
        catalog: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.mutate(catalog, |next| {
            if !next.folders.contains_key(id) {
                return Err(failure("folder_missing", "Папка отсутствует в проекте."));
            }
            if next
                .folders
                .values()
                .any(|folder| folder.parent.as_deref() == Some(id))
                || next.assignments.values().any(|folder| folder == id)
            {
                return Err(failure(
                    "folder_not_empty",
                    "Сначала переместите ресурсы и дочерние папки.",
                ));
            }
            next.folders.remove(id);
            Ok(())
        })
    }

    pub fn assign(
        &mut self,
        resource: &str,
        folder: Option<&str>,
        catalog: &BTreeSet<String>,
    ) -> Result<(), ImportError> {
        self.mutate(catalog, |next| {
            if resource.is_empty() || resource.len() > 128 || !catalog.contains(resource) {
                return Err(failure(
                    "folder_resource",
                    "Ресурс не принадлежит текущему проекту.",
                ));
            }
            if let Some(folder) = folder {
                if !next.folders.contains_key(folder) {
                    return Err(failure("folder_missing", "Папка отсутствует в проекте."));
                }
                next.assignments
                    .insert(resource.to_owned(), folder.to_owned());
            } else {
                next.assignments.remove(resource);
            }
            Ok(())
        })
    }
}
