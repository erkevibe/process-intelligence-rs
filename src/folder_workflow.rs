//! Small organization snapshots; heavy resource payloads are never materialized.
use super::*;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct FolderForm {
    revision: u64,
    #[serde(default)]
    name: String,
    #[serde(default)]
    parent: String,
    #[serde(default)]
    resource: String,
    #[serde(default)]
    folder: String,
}
pub(super) async fn folders_page(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let a = actor(&state)?;
        let repo = state.repository.lock().expect("repository");
        let summaries = platform(&state)?
            .database
            .resource_summaries(&a.project_id)?;
        let resources: Vec<_> = summaries
            .into_iter()
            .map(|(_, id, name, _)| (id, name))
            .collect();
        Ok(render::folders(
            &repo.organization,
            repo.storage_revision,
            &resources,
            a.role.can_write(),
        ))
    })
    .await
    {
        Ok(html) => page("Папки проекта", html),
        Err(e) => response_error(e),
    }
}
pub(super) async fn folders_json(Workspace(state): Workspace) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        let repo = state.repository.lock().expect("repository");
        Ok(json!({"revision":repo.storage_revision,"organization":repo.organization,"resources":repo.resource_catalog()}))
    }).await { Ok(data) => Json(data).into_response(), Err(e) => response_error(e) }
}
async fn change(
    state: AppState,
    revision: u64,
    action: &'static str,
    resources: Vec<String>,
    mutation: impl FnOnce(
        &mut crate::folders::Organization,
        &std::collections::BTreeSet<String>,
    ) -> Result<(), ImportError>
    + Send
    + 'static,
) -> Response {
    match blocking(move || {
        state.validate_resource_actor()?;
        if !actor(&state)?.role.can_write() {
            return Err(failure("access_denied", "Требуются права редактора."));
        }
        let mut repo = state.repository.lock().expect("repository");
        if repo.storage_revision != revision {
            return Err(failure(
                "storage_conflict",
                "Проект изменился. Обновите страницу папок.",
            ));
        }
        let catalog = repo.resource_catalog();
        let mut next = repo.clone();
        mutation(&mut next.organization, &catalog)?;
        state.commit_action_resources(&mut next, action, resources)?;
        *repo = next;
        Ok(())
    })
    .await
    {
        Ok(()) => redirect("/folders"),
        Err(e) => response_error(e),
    }
}
pub(super) async fn folder_create(
    Workspace(state): Workspace,
    Form(form): Form<FolderForm>,
) -> Response {
    let id = format!("folder-{}", uuid::Uuid::new_v4());
    change(
        state,
        form.revision,
        "folder_created",
        vec![id.clone()],
        move |org, catalog| {
            org.create(
                &id,
                &form.name,
                (!form.parent.is_empty()).then_some(form.parent.as_str()),
                catalog,
            )
        },
    )
    .await
}
pub(super) async fn folder_rename(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<FolderForm>,
) -> Response {
    change(
        state,
        form.revision,
        "folder_renamed",
        vec![id.clone()],
        move |org, catalog| org.rename(&id, &form.name, catalog),
    )
    .await
}
pub(super) async fn folder_move(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<FolderForm>,
) -> Response {
    change(
        state,
        form.revision,
        "folder_moved",
        vec![id.clone()],
        move |org, catalog| {
            org.move_folder(
                &id,
                (!form.parent.is_empty()).then_some(form.parent.as_str()),
                catalog,
            )
        },
    )
    .await
}
pub(super) async fn folder_delete(
    Workspace(state): Workspace,
    Path(id): Path<String>,
    Form(form): Form<FolderForm>,
) -> Response {
    change(
        state,
        form.revision,
        "folder_deleted",
        vec![id.clone()],
        move |org, catalog| org.delete_empty(&id, catalog),
    )
    .await
}
pub(super) async fn folder_assign(
    Workspace(state): Workspace,
    Form(form): Form<FolderForm>,
) -> Response {
    let resources = vec![form.resource.clone()];
    change(
        state,
        form.revision,
        "resource_moved",
        resources,
        move |org, catalog| {
            org.assign(
                &form.resource,
                (!form.folder.is_empty()).then_some(form.folder.as_str()),
                catalog,
            )
        },
    )
    .await
}
