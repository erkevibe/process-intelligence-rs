//! Project-bound preview and confirmed import.
use super::*;
pub(super) async fn xes_form(Workspace(_state): Workspace) -> Response {
    page("Проверить XES", render::xes_upload())
}
pub(super) async fn xes_preview(Workspace(state): Workspace, multipart: Multipart) -> Response {
    let uploads = match state.uploads.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другие файлы уже загружаются.")),
    };
    let cpu = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже обрабатывается.")),
    };
    let upload = read_upload(multipart, 20 * 1024 * 1024).await;
    let result = match upload {
        Ok((bytes, filename, fields)) if fields.is_empty() => blocking(move || {
            let _uploads = uploads; let _cpu = cpu;
            let a = actor(&state)?; let p = platform(&state)?;
            let raw = String::from_utf8(bytes).map_err(|_| failure("invalid_utf8", "XES должен быть в UTF-8."))?;
            let preview = crate::service_preview::preview_xes(raw.as_bytes())?;
            if preview.changes.len() > crate::import_provenance::MAX_ACTIONS { return Err(failure("preview_action_limit", "Более 200 000 изменений: предварительный импорт отклонён. Строгий импорт доступен отдельно.")); }
            let token = uuid::Uuid::new_v4().to_string(); let now = chrono::Utc::now().timestamp();
            let html = render::xes_preview(&token, &preview, &sha256(raw.as_bytes()), &filename);
            let mut pending = p.pending_xes.lock().expect("XES previews");
            pending.retain(|_, v| v.expires > now || matches!(v.status, PreviewStatus::Confirming | PreviewStatus::Uncertain));
            if pending.values().filter(|v| v.raw.is_some()).count() >= 2 || pending.len() >= 64 { return Err(failure("preview_limit", "Два исходника уже ожидают подтверждения. Отмените прежний просмотр или подождите пять минут.")); }
            pending.insert(token, PendingXes { raw: Some(Arc::new(raw)), filename, user: a.id, project: a.project_id, expires: now + 300, status: PreviewStatus::Ready });
            Ok(html)
        }).await,
        Ok(_) => Err(failure("upload_field", "Для предварительного просмотра нужен только файл XES.")), Err(e) => Err(e),
    };
    match result {
        Ok(html) => page("Изменения перед импортом", html),
        Err(e) => response_error(e),
    }
}
fn matching_preview<'a>(
    pending: &'a BTreeMap<String, PendingXes>,
    token: &str,
    a: &Actor,
) -> Result<&'a PendingXes, ImportError> {
    pending
        .get(token)
        .filter(|v| {
            v.user == a.id
                && v.project == a.project_id
                && v.expires > chrono::Utc::now().timestamp()
        })
        .ok_or_else(|| {
            failure(
                "preview_expired",
                "Просмотр истёк или недоступен в этом проекте. Загрузите файл заново.",
            )
        })
}
pub(super) async fn xes_report(Workspace(state): Workspace, Path(token): Path<String>) -> Response {
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже обрабатывается.")),
    };
    match blocking(move || {
        let _permit = permit; let a = actor(&state)?; let p = platform(&state)?;
        let raw = { let pending = p.pending_xes.lock().expect("XES previews"); matching_preview(&pending, &token, &a)?.raw.clone().ok_or_else(|| failure("preview_used", "Импорт завершён; откройте историю журнала."))? };
        let preview = crate::service_preview::preview_xes(raw.as_bytes())?;
        Ok(json!({"policy":preview.policy,"source_sha256":sha256(raw.as_bytes()),"source_cases":preview.source_cases,"source_events":preview.source_events,"fully_filtered":preview.fully_filtered,"changes":preview.changes}))
    }).await { Ok(report) => Json(report).into_response(), Err(e) => response_error(e) }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct XesConfirm {
    token: String,
    #[serde(default)]
    consent: String,
}
pub(super) async fn xes_cancel(
    Workspace(state): Workspace,
    Form(form): Form<XesConfirm>,
) -> Response {
    let a = match actor(&state) {
        Ok(a) => a,
        Err(e) => return response_error(e),
    };
    let p = match platform(&state) {
        Ok(p) => p,
        Err(e) => return response_error(e),
    };
    let mut pending = p.pending_xes.lock().expect("XES previews");
    let entry = match matching_preview(&pending, &form.token, &a) {
        Ok(v) => v,
        Err(e) => return response_error(e),
    };
    if !matches!(entry.status, PreviewStatus::Ready) {
        return response_error(failure(
            "preview_conflict",
            "Подтверждение уже началось. Отмена не принята.",
        ));
    }
    pending.remove(&form.token);
    redirect("/logs")
}
pub(super) async fn xes_import(
    Workspace(state): Workspace,
    Form(form): Form<XesConfirm>,
) -> Response {
    if form.consent != "yes" {
        return response_error(failure(
            "confirmation_required",
            "Подтвердите сохранение результата с указанными изменениями.",
        ));
    }
    let permit = match state.cpu.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return response_error(failure("busy", "Другой журнал уже обрабатывается.")),
    };
    match blocking(move || {
        let _permit = permit; let a = actor(&state)?; let p = platform(&state)?;
        let (raw, filename) = {
            let mut pending = p.pending_xes.lock().expect("XES previews"); let entry = matching_preview(&pending, &form.token, &a)?;
            match &entry.status {
                PreviewStatus::Completed(id) => return Ok(id.clone()),
                PreviewStatus::Confirming => return Err(failure("preview_conflict", "Подтверждение уже выполняется.")),
                PreviewStatus::Uncertain => return Err(failure("confirmation_uncertain", "Запись не подтверждена. Повтор заблокирован: перезапустите приложение и проверьте список журналов и историю импорта.")),
                PreviewStatus::Ready => (),
            }
            let raw = entry.raw.clone().ok_or_else(|| failure("preview_expired", "Исходник недоступен."))?;
            let filename = entry.filename.clone(); pending.get_mut(&form.token).expect("matching entry").status = PreviewStatus::Confirming; (raw, filename)
        };
        let result: Result<String, ImportError> = (|| {
            let started = Instant::now(); let preview = crate::service_preview::preview_xes(raw.as_bytes())?;
            let provenance = crate::import_provenance::ImportProvenance::capture(raw.as_ref().clone(), &preview, a.id, a.project_id, form.token.clone())?;
            let analysis = analyze(&preview.log);
            let log = crate::web::store_log_with_provenance(&state, preview.log, analysis, filename, started.elapsed().as_millis(), provenance.source_sha256.clone(), NormalizationOrder::Source, None, Some(Arc::new(provenance)))?;
            Ok(log.id)
        })();
        let mut pending = p.pending_xes.lock().expect("XES previews"); let entry = pending.get_mut(&form.token).expect("reserved entry");
        match &result {
            Ok(id) => { entry.status = PreviewStatus::Completed(id.clone()); entry.raw = None; entry.expires = chrono::Utc::now().timestamp() + 300; }
            Err(e) if matches!(e.code.as_str(), "storage_unavailable" | "storage_busy") => { entry.status = PreviewStatus::Uncertain; entry.raw = None; }
            Err(_) => entry.status = PreviewStatus::Ready,
        }
        result
    }).await { Ok(id) => redirect(&format!("/logs/{id}")), Err(e) => response_error(e) }
}
pub(super) async fn original_xes(Workspace(state): Workspace, Path(id): Path<String>) -> Response {
    match blocking(move || {
        let log = state
            .repository
            .lock()
            .expect("repository")
            .get_log(&state, &id)?
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let provenance = log.provenance.ok_or_else(|| {
            failure(
                "original_unavailable",
                "Для прежнего импорта исходный файл не сохранялся; доступен хеш и экспорт анализа.",
            )
        })?;
        Ok(provenance.original_utf8.clone())
    })
    .await
    {
        Ok(raw) => {
            let mut r = raw.into_response();
            r.headers_mut().insert(
                header::CONTENT_TYPE,
                "application/xml; charset=utf-8".parse().expect("type"),
            );
            r.headers_mut().insert(
                header::CONTENT_DISPOSITION,
                "attachment; filename=\"original.xes\""
                    .parse()
                    .expect("disposition"),
            );
            r
        }
        Err(e) => response_error(e),
    }
}
pub(super) async fn import_history(
    Workspace(state): Workspace,
    Path(id): Path<String>,
) -> Response {
    match blocking(move || {
        let log = state.repository.lock().expect("repository").get_log(&state, &id)?.ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let p = log.provenance.ok_or_else(|| failure("history_unavailable", "Для прежнего импорта подробная история не сохранялась."))?;
        Ok(json!({"schema_version":p.schema_version,"operation_id":p.operation_id,"actor_id":p.actor_id,"origin_project_id":p.origin_project_id,"confirmed_at":p.confirmed_at,"policy":p.policy,"source_sha256":p.source_sha256,"source_cases":p.source_cases,"source_events":p.source_events,"actions":p.actions}))
    }).await { Ok(value) => Json(value).into_response(), Err(e) => response_error(e) }
}
pub(super) async fn import_history_view(
    Workspace(state): Workspace,
    Path(id): Path<String>,
) -> Response {
    match blocking(move || {
        let current_project = actor(&state)?.project_id;
        let log = state
            .repository
            .lock()
            .expect("repository")
            .get_log(&state, &id)?
            .ok_or_else(|| failure("not_found", "Журнал не найден."))?;
        let provenance = log.provenance.ok_or_else(|| {
            failure(
                "history_unavailable",
                "Для прежнего импорта подробная история не сохранялась.",
            )
        })?;
        Ok(render::import_history(&id, &current_project, &provenance))
    })
    .await
    {
        Ok(html) => page("История импорта", html),
        Err(e) => response_error(e),
    }
}
