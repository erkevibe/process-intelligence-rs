# Спринт 03: сравнение, восстановление, BPMN

**Спринт завершён; 0.3.0 опубликована и независимо проверена.** Начало 10 октября 2026,11:37:57 UTC; предел19:37:57 UTC. Ошибки, проверка и публикация входят в восемь часов. [Неизменённый план](SPRINT_03_PLAN.md), [независимая матрица A01–A12](../flw/evidence/sprint-03-qa-final-report.md), [заключение TD](../flw/evidence/sprint-03-td-final-report.md), [решение Совета](../flw/evidence/sprint-03-final-council.md). A01–A12 приняты в выбранных границах. Независимая проверка поставки завершилась 14:01:25 UTC, через 2 часа 23 минуты после начала; оставшийся бюджет не использован для расширения объёма. [Отдельное заключение QA о поставке](../flw/evidence/sprint-03-qa-delivery.md).

## Что получилось

| Приоритет | Фактический результат |
|---|---|
| Сравнение | Шесть фиксированных XES-примеров с SHA и независимыми ручными counts/variants/DFG. Неизменённый LogParser.getSimpleLog(String) закреплённого ApromoreCore реально выполнен; cases/activities/variants совпали с точным Rust EXE. |
| Миграции | Schema v1/version/name/checksum полного SQL, singleton до DDL, атомарные DDL+ledger. Fresh/распознанная0.2/reopen; future/checksum/неизвестная структура отклоняются без изменений. |
| Обновление0.2 | Новая восстановленная копия сначала запущена принятым старым EXE и получила сессию; затем точный B38 впервые мигрировал её. Все auth/repository/generic строки/версии/полные хеши, прежняя сессия, IDs, exports, XML, параметры и два одноимённых журнала сохранились. Реальная пользовательская0.2 не обновлялась. |
| Восстановление | Настоящий kill до commit миграции оставил старые документы без частичного ledger; reopen мигрировал базу. Immediate crash своего PostgreSQL до/после commit дал none либо complete-new. Custom dump/NEW restore сохранил auth/schema/данные; corrupt/existing-target контролируемо отклонены. |
| Задачи и сбои | Queued и реально наблюдавшаяся Running после kill восстановились Failed/interrupted/null. Completed linkage, cancel, malformed import и повторный restart сохраняют terminal snapshots/IDs/revisions. Реальные SQL deadlines/connectionfault дают failclosed до явного reopen, без автоматического mutation retry. |
| Windows | Свежий точный native PowerShell5 пакет, staged resume/same credentials, существующая роль/отсутствующая БД, unknown/missing/ambiguous config без reset. Первый аккаунт/login, manual graph/export проверены. |
| BPMN | Добавление/удаление task/sequenceFlow, подписи/координаты, текущие поля при Save, защищённые start/end/gateways, серверные graph/revision/access guards; XML re-import, backup/restore и restart сохранили модель. |

Oracle — узкий настоящий Java-компонент через внешний адаптер, не Portal, не полный XES importer и не Split Miner. Events/DFG проверены вручную отдельно; legacy raw_total_events=-1 сохранён. Timestamp/lifecycle normalization, fitness/precision и общая совместимость не заявлены. [Происхождение и воспроизведение](ORACLE.md).

## Точные исходники и проверки

| Идентификатор | Значение |
|---|---|
| Runtime source | a0b4f6989825de47c48d1d6ab8e1cedbac19c017 |
| Frozen source archive SHA256 | 22521535CB4CB329AB636207C8F0017AAC8A8A7D9455784153C347022A8F8139 |
| Windows EXE SHA256 | B38A6193EB6C3D7BCE6F1F4E75F6BE619AE626FD8CBB8F9BB23CD3E08D190A3A |
| Windows ZIP SHA256 | DBC095FA57E1721A83181FE8B6CA1834DC0D568B761D4A90787D47C7CEC97E84 |
| ZIP/manifest | 56411489байт/1663файла |

Независимо проверены227 source files и1663 файла свежей распаковки. Пять provenance negatives на приватных копиях отклонили неверный commit/version, dirty source, изменённый EXE/frozen asset; оригинальные bytes не менялись. В ZIP документы остаются снимком a0b4; финальные documentation commits/merge/tag отделяются от compiled source.

Frozen ordinary60PASS/10realPG явно ignored; отдельно независимые S3realPG8+S2realPG2 всеPASS. BPMN15 browser/API+1XML+6backup/restart/access; strict upgrade3PASS. Native Start: первые3 проверки и отдельная continuation2PASS, настоящий graph3nodes/4edges и export4cases/10events/3activities.

Исправленный pushCI38054672102 действительно проверил a0b4, PR38054674511 — generated merge b1d18b79d67943e4c88fe8683ed4054b76c8c58c. fmt/clippy/60ordinary/release/ephemeral health PASS; realPG/Windows/crash CI не запускал. Финальный PR head1a3a проверен push38057295858/PR38057298912; merge и tag08cc456ff20fce0a54b172105ce1450021e353da проверены main38057618123/tag38057663276. Все эти CI успешны. Полный anonymous download SHA/bytes независимо совпал. [Финальный CI audit](../flw/evidence/sprint-03-ci-audit-final.md), [main/tag audit](../flw/evidence/sprint-03-ci-audit-late.md). [CI audit](../flw/evidence/sprint-03-ci-audit-corrected.md).

## Ошибки и границы

Независимые проверки обнаружили native File.Replace ошибку, terminal publication до durable commit и JSONB overflow при принятом100000-event импорте в накопленный шестижурнальный проект. Кандидат89/B6D/D35 отклонён и не опубликован. Исправления получили новые регрессии/QA/TD и отдельные точные решения Совета; failure logs сохранены.

Capacity guard до SQL использует нижний payload/admission budget266272768байт и верхний268369920для принятых jobs/recovery;2MiB оставлены для ограниченного terminal metadata. SAME полный накопленный проект/SAME100000events/17200026bytes на точном B38 дал durable Failed/project_capacity/null, прежние шесть полных хешей, health/export200, дальнейшую запись модели/cancel/restart. Oversized batch не записал ни одну часть и не закрыл worker. Reserve exhaustion не выполнен; восемь журналов — потолок количества, не любых размеров.

SCALE01 HIGH OPEN: whole-project clones/typed validation всех документов внутри10s startup transaction. Исторический debug reopen около153MB действительно failed timeout; тот же несокращённый corpus открылся в optimized сборке, нынешний cumulative прошёл exact final checks. Все64проекта/максимальный aggregate/RSS/debugstartup/worst concurrency не сертифицированы. Следующий эксплуатационный приоритет — отдельные записи logs/models, убрать полные копии/тяжёлую startup transaction, измерить время/RSS и развить versioned migrations. [Роадмап](ROADMAP.md).

Точное before-final bootstrap состояние реконструировано и resumed0 с прежними credentials: это не actual kill финального установщика. Ранний реальный File.Replace fault остаётся историческим mechanism proof. PG crash — immediate process stop, не physical powerloss/HA. Dump не включает глобальные роли/private config; возврат к0.2 через прежнюю БД/backup, не oldEXE поверх upgradedDB. [Восстановление](DATABASE_RECOVERY.md).

Coverage:170 доступныхQA/init/PG full-file fingerprints+2supplement и24CI, required assertion/failure contexts отдельно. Не полная семантическая сертификация каждого исторического shellstream. Cross-DB cookie, route/default-submit selector, environment/collector failures retained; missing/reusedstderr/tool-only и invalidRootinventory01 не объявлены completePASS. FLW поймал реальные дефекты до публикации; следующий процесс — дешёвый preflight/immutable attempt manifest, без неизменённых дорогих local reruns ради docs.

## Пользовательская поставка

Отдельная принятая установка0.3 работает на http://localhost:3030/PG5437 без QAаккаунта; пользователь создаёт свою первую учётную запись. R1:3000/0.2:3010 сохранены. Повторный запуск из установленного каталога: powershell -NoProfile -ExecutionPolicy Bypass -File Start.ps1 -Port 3030 -PostgresPort 5437. Полный публичный ZIP независимо скачан и проверен, postpublication read-only проверки установок прошли. [Релиз](https://github.com/erkevibe/process-intelligence-rs/releases/tag/v0.3.0), [факты поставки](../flw/evidence/sprint-03-delivery.md).

Полные R2–R5, enterprise readiness, исполнение BPMN, весь перенос Apromore и HA остаются следующими этапами. Совет принял bounded artifact пятью голосами из пяти; обязательные условия поставки выполнены. Это не подменяет принятие реальным пользователем.
