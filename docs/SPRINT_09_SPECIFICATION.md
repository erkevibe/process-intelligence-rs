# Sprint09: аудит, постоянное удаление и управляемая очистка

PM specification, 11 октября 2026. Окно 08:55:38–16:55:38 UTC (8 часов). Это первая предметная спецификация, не принятое решение Совета и не доказательство PASS. Исходные R3-01/R3-02/R3-04 из SPRINT_08_SCOPE.md остаются неизменными. Владельцы реализации и окончательный frozen plan назначаются председателем.

## Результат для пользователя

Оператор видит, кто изменил проект или ресурс, какую политику применил и какой результат сохранился. Владелец может явно и постоянно удалить проект по согласованной политике; удаление данных не уничтожает свидетельство самого удаления. Оператор отдельно может освободить логическое место, занятое сохранёнными legacy repository-копиями, только после проверенного полного backup и восстановления в новую базу. PostgreSQL DELETE не обещает немедленно уменьшить файлы на диске.

## Неизменные условия и предлагаемые решения

| ID | Исходное условие | Предлагаемая реализация и обязательная проверка |
|---|---|---|
| R3-01 | Создать/переименовать/переместить/архивировать/восстановить проекты и папки; безопасное удаление; принадлежность, циклы, ссылки, session/current project, роли; durable restart и concurrent CAS в изолированном PG | Сохранить имеющийся lifecycle и перепроверить затронутые сценарии. Предлагается owner-only постоянное удаление с точным typed confirmation имени/ID и expected revision, отказ при несовпадении, чужом проекте, editor/viewer и конфликте. Данные, записи, retained legacy копия и ссылки удаляются одним атомарным storage command вместе с auth/session изменениями и долговечным audit survivor. Активные jobs/параллельные записи должны иметь явно согласованный безопасный отказ или атомарную развязку; не допустить воскресшего проекта через cache/job. Последний доступный current project: явный отказ до создания/выбора замены, если не реализован отдельно согласованный no-project session. Это предложения политики, а не новые исходные must-have. |
| R3-02 | Actor/project/resource/action/policy/time/результат без секретов, атомарность mutation+audit, защита подмены/чтения чужого, порядок, bounded retention/export | Назвать конечную матрицу всех существующих изменяющих бизнес-операций и политики для каждой. Новые записи имеют action-specific policy и фактический outcome; success сохраняется только в одной транзакции с результатом. Ранее сохранённые записи без policy/outcome остаются явно legacy/unknown, не получают выдуманные поля задним числом. Отказы и неизвестный COMMIT не выдаются за committed success; если bounded audit неуспехов вне scope, это явно указать и проверить отсутствие ложного success. Зафиксировать owner-only доступ к survivor удалённого проекта, retention и экспорт до реализации. Проверить 512/513, monotonic sequence, tamper/foreign refusal, backup/restart/restore и no-secret экспорт. |
| R3-04 / DISK01 | Explicit preview/backup/newrestore/offline lease; interruption/resume/rollback/full conservation | Сохранить полный S8 cleanup proposal и C01–C18 со всеми самостоятельными subcases из SPRINT_09_CLEANUP_CORPUS.md. Полный исторический архив0.3, latest normalized changes и все auth/generic данные не сокращать. Обязательны настоящие F01 до DELETE, F02 после DELETE до COMMIT, F03 успешный server COMMIT с потерянным ответом и read-only whole-state reconciliation. HTTP response-loss из S8 не заменяет F03. |

Постоянное удаление проекта и offline cleanup retained legacy строк — разные операции. Первая намеренно удаляет данные выбранного проекта по пользовательской политике; вторая обязана сохранить все normalized/auth/current данные и удалить только migration-bound legacy rows. Их audit/SQL/restore доказательства не взаимозаменяемы.

## Контракты хранения и совместимости

Текущий audit.rs содержит sequence/at/actor/project/action/resources/revision, но не policy/outcome. auth::validate_stored сейчас запрещает trail для несуществующего проекта. Project audit хранится в header, который постоянное удаление уничтожит. Поэтому survivor и backward-compatible audit decoder требуют явного проектирования; простое удаление header с его audit не закрывает R3-02.

Auth и normalized project сегодня пишутся разными command paths. Постоянное удаление должно атомарно менять обе области, сохраняя ожидаемые версии/CAS; два последовательных вызова не дают нужной гарантии. Проверить обновление in-memory auth/repository/jobs/resource caches только после подтверждённого результата и безопасное поведение при неизвестном COMMIT. Старый migration marker/retained row/sequence и дополнительные объекты обрабатываются по заранее выбранной политике, а не широким LIKE DELETE.

Старые backup/restore validators принимают конкретные auth/header формы. Любое новое поле/survivor должно пройти compatibility, migration/no-op, full stock backup/new restore и строгий unsupported downgrade. R3-03 на0.6.0 не переносится автоматически на новое изменённое хранение. Запрещено проверять это на пользовательских установках.

## Cleanup: обязательные границы

Реальная identity — system_identifier плюс database OID; равная identity/недоступные privileges отказывают. Оба application advisory lease и исключение посторонних writers обязательны; они не дают защиты от произвольного администратора и nontransactional sequence изменения. Полная managed state/value/version/ledger/marker/sequence equality проверяется с новым restore, без запуска приложения или login против verified restore. Rust source SHA и полный SQL state digest — разные hash domains. Archive/manifest/plan/confirm hashes перепроверяются перед mutation.

Лимиты остаются 10000 managed rows, 512 UTF-8 bytes key, 4 MiB plan; SQL5s/lock2s/transaction10s без увеличения ради приёмки. Exact parameterized DELETE, complete RETURNING и full expected post-state проверяются до единственного COMMIT. Неизвестный ACK сообщает cleanup_outcome_unconfirmed, не делает blind retry. Known commit с ошибкой записи receipt — отдельный результат. Empty repeat имеет zero database writes. Recovery — новый restore и явный выбор новой базы, без перезаписи source. F02/F03 test-only proxy заранее независимым образом проверяет реальные PostgreSQL protocol boundaries и не ослабляет binary/таймауты.

## Достижимые фазы восьми часов

| UTC | Фаза | Gate |
|---|---|---|
| 08:55–09:35 | Пять независимых позиций, фиксированный план, политики удаления/audit, freeze полного fixture/corpus; feasibility PostgreSQL protocol observer | Все обязательные условия и владельцы названы, destructive operations только на новых owned resources. Feasibility failure не превращается в fake fault proof. |
| 09:35–12:00 | Реализация audit/delete и отдельного cleanup module/wrapper; Root интегрирует общие storage/routes/schema | Draft cycle с meaningful tests; QA заранее готовит полные свежие fixtures и observers, не принимает свой код. |
| 12:00–14:15 | Интеграция и реальные PG сценарии: lifecycle/RBAC/CAS/audit/backup/restart; C01–C18/F01–F03/full historical rollback | Каждый обязательный subcase имеет exact input/output/full state comparison. Ошибки исправляются с повтором затронутых проверок, а не переписыванием evidence. |
| 14:15–14:40 | Runtime/package freeze | Если опасная функция не прошла обязательные gates, исключить её из кандидата или оставить criterion OPEN. Нельзя урезать corpus для полного PASS. |
| 14:40–16:55 | Независимые QA/TD, Customer, CI, public delivery, реальные новые votes и final report | Минимум90 минут независимой приёмки сохраняются; фактический финал не позже16:55:38. Exact source/exe/package/source-archive/receipt binding, старые installs неизменны. |

Восемь часов — бюджет попытки, а не гарантия трёх PASS. Ранние блокирующие условия: survivor contract и multi-domain atomic write; полный old0.3 archive доступен и восстановим; proxy действительно различает DELETE/COMMIT/ACK; unreduced corpus укладывается в исходные budgets. При STOP опасное исполнение прекращается, безопасные independent задачи продолжаются. Public final report показывает каждый пункт PASS/FAILED/OPEN/NOT-IN-RUN, без средней оценки и без заявления полного R2–R5.

## Границы ресурса и контроля

Risk appetite: минимальный риск потери пользовательских данных; высокий/критический риск новых destructive paths требует полного FLW candidate contour с независимым QA и TechnicalDebt, prospective ProcessLogAuditor. Draft edits не требуют нового совета на каждую строку. Действующие0.3–0.6.1 installations включая3066/5445 защищены: никакого login/setup/config/SQL/stop/migrate/delete/cleanup; только readonly health/identity/artifact checks. Test accounts, private raw payloads/credentials и новые явно owned clusters изолированы. Не печатать secrets в stdout, plan, audit или public evidence. Не обещать enterprise HA, arbitrary custom database recovery или physical disk shrink.
