# Storage v2: contract and offline upgrade

Version0.4 uses pi_projects(project_id,version,document) and pi_records(project_id,kind,resource_id,version,document). Composite primary key prevents collisions between restored projects. Kinds: log_state/log_data/log_source/log_analysis/model. Project header contains current,sequence,user_views,durable_jobs,log_ids,model_ids. All child records indexed in header must exist and no extra records may exist. Each record is independently bounded by the existing conservative JSONB estimator; aggregate project JSONB limit no longer applies. Count/import limits unchanged:8retainedlogs,64models,100000events/20000cases/20MiBinput. Accepted jobs keep reserved metadata capacity and persist before publishing terminal states.

Changed-only writes compare immutable Arc payload identity and small log-state fields. Model payloads use Arc::make_mut only for a changed model. Project revision CAS and affected child writes/deletes execute in one transaction; result/current/completed-job link is part of that transaction. Source, filtered data and analysis are separate so calendar/view/task/model edits do not rewrite unrelated heavy payloads. This does not remove full-project payload cache after first access; first-load memory remains measured bounded debt. Startup loads schema, auth, project headers/record keys and recovers interrupted jobs, not all heavy payloads. Payload loading validates strict nested DTOs, ownership, links and log/filter/analysis/calendar/selection semantics before exposing project.

## Offline migration

Normal recognized0.3(schema1) startup returns migration_required with no DDL. Migration is explicit executable --migrate-storage, private PI_DATABASE_URL loaded only by trusted launcher. Packaged tools/migrate-storage.ps1 verifies full manifest, current-user-only private config and backup SHA/bytes before running exact bundled EXE. No bootstrap/reset/re-init or automatic secret recreation.

Recommended operator path: keep original0.3 working directory/database; create database-level custom dump; independently restore/check in a NEW isolated database using database-backup.ps1; stop the app using that copy; invoke migration helper against that copy; after completion start0.4 with the copy's private configuration and verify access/exports. Existing deployed user databases are not migrated by Sprint04 delivery. Restartold0.3 with preserved original database/config for rollback; oldbinary on migrated schema is unsupported. Restore requires new pi_restore_* target; no existing-target overwrite.

Explicit migration holds application advisory lease throughout. Runtime15sreply and perSQL5s/lock2s/transaction10s remain unchanged; offline total duration is not constrained to15s. CPU strict legacy validation/digests happen outside short SQLtransactions. Authorized known shadow tables may be created before a malformed project is found; original pi_kv/auth/generic/legacy rows and ledger1 remain unchanged. Each known staged project binds sourceversion/fullcanonicalSHA/schemaDDLchecksum. Existing staged headers/records must equal expected originals exactly or migration refuses without reset. Record commits are resumable. Final source digests are rechecked outside transaction, then a short SHARE table lock blocks concurrent inserts/updates/deletes while key sets, auth presence and source versions are rechecked under row locks; only global atomic ledger2 publication enables app readiness. Versioned managed writers/exclusive application lease define concurrency contract; arbitrary administrator SQL bypassing version increments is outside it.

Old pi_kv repository rows are retained unchanged as inert migration references. V2 runtime reservedlegacy read/write is rejected; normal new storage never updates them. Original retained storage consumes disk; separate verified cleanup is future work. Unknown stage/schema/checksum/future version refuses; preserve logs, staged records and original backup, fix cause before resume. A controlled refusal is not completed migration. Successfulrepeat migration validates supported schema/checksums and returns without rewriting records.

## Performance acceptance

FixedS4-P1: three matched optimizedreadyruns <=15s each; three small model/view/job mutations <=5s each; candidate maximumstartupappWorkingSet <= baseline three-run max. Baseline from unchanged full old0.3 corpus: proper100mstarget collector actual134.68–136.16ms intervals, startup13.33304/13.20268/13.64531s, appWorkingSet max2107166720bytes. Report sampleinterval, ownprocess identity, warm/cold conditions and lifetimePeak distinct. SharedPGsamples include unrelatedworkload and cannot certify exclusiveaggregate. Firstprojectload/import/export and cachegrowth measured separately; no general64maxprojects/eightworstlogs/RSS/HA claim.

The same unreduced six-log large project and same100000-event17200026-byte input must complete under new perrecord storage with oldfullhashes unchanged. Actual interruption tests must cover stage and final publication boundaries. Final exact frozen package/independentQA/TD/Council/CI/publicanonymoushash and oldinstallationpreservation remain mandatory.

## Пошаговый запуск восстановленной копии

Проверенный в этой поставке путь резервирования, восстановления и offline migration использует PowerShell7.6.5 (`pwsh`). Чистый Start проверен отдельно в Windows PowerShell5.1 (`powershell`). Полная backup-цепочка в5.1 на этом стенде не подтверждена: проверочные процессы не начали выполнение; это не заменяется успешным результатом7. Никакие средства защиты не отключались. Если PowerShell7 отсутствует, установите его по [официальной инструкции Microsoft](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows); это дополнительное требование для проверенного эксплуатационного пути, а не скрытая смена версии приложения.

Сохраните исходную установку0.3 целиком. В её каталоге сделайте новый backup и сохраните его manifest:

```powershell
pwsh -NoProfile -File tools/database-backup.ps1 -Mode Backup -BackupFile .local/backups/before04.dump
```

Распакуйте0.4 в другой каталог. В дальнейших командах3104/5550 — примеры свободных HTTP/PostgreSQL портов; используйте один и тот же выбранный PostgreSQL порт на всех шагах. В новом каталоге:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup-postgres.ps1 -Port 5550
```

Скопируйте только before04.dump и before04.dump.manifest.json из исходной установки в новый защищённый .local/backups. Не копируйте один старый private config в пустую новую установку: конфигурация привязана к исходному кластеру, а backup восстанавливается с новыми локальными credentials. Не переносите старый PGDATA вручную. Далее в новом каталоге:

```powershell
pwsh -NoProfile -File tools/database-backup.ps1 -Mode Restore -BackupFile .local/backups/before04.dump -TargetDatabase pi_restore_before04
pwsh -NoProfile -File tools/migrate-storage.ps1 -BackupFile .local/backups/before04.dump -Database pi_restore_before04
powershell -NoProfile -ExecutionPolicy Bypass -File Start.ps1 -Port 3104 -PostgresPort 5550 -Database pi_restore_before04
```

Сначала проверяйте доступ и полный экспорт восстановленной копии; сохраняйте первоначальную установку для возврата. В восстановленной базе войдите прежней учётной записью, новый первый аккаунт не создаётся. Повторный Start использует те же Database/PostgresPort/HTTPPort. Эти команды описывают предусмотренный путь; его независимая проверка относится к отчёту спринта, инструкция сама по себе не является PASS.
