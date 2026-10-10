# Sprint 03 — S3-P1

Начало 2026-10-10 11:37:57 UTC; предел 19:37:57 UTC (00:37:57 следующего дня Asia/Qyzylorda). Восемь часов включают планирование, ошибки, проверку и публикацию. Последние 90 минут (с 18:07:57 UTC) — только исправления, независимая проверка и поставка. Можно завершить раньше; новые функции после этого рубежа не добавляются.

## Состав и риск

До предложения приглашены пять фиксированных мест: Root (разработка/интеграция/Operations), Customer /root/customer, PM /root/pm_final (прежний исполнитель), независимый QA/ProcessLogAuditor /root/qa_process, отдельный TD/SkillManager /root/technical_debt. Позиции Customer, QA и TD сохранены в flw/evidence/sprint-03-*-plan.md; PM согласует требования. Голоса нужны по этой точной версии, большинство более половины пяти. Молчание не голос. Порядок FLW 0.9.4-draft; независимый QA не автор реализации.

Риск-аппетит средний для ограниченной новой функциональности, низкий для сохранности данных/прав и достоверности приёмки. Черновики не требуют повторного полного Совета; единый кандидат получает независимую проверку. Подтверждённая потеря данных, неатомарная миграция, обход доступа или ложный успех — STOP затронутой области. Рабочие R1:3000 и 0.2:3010/PG5435 сохраняются; upgrade/fault/backup выполняются только на явно изолированных QA базах и кластерах.

## Объём и владельцы

1. Root + PM: до 45 минут после принятия плана проверить реальный headless oracle выбранного ApromoreCore SHA bbf24dfd43e72d6992392465f875a4367cbe792b. Узкий настоящий компонент допустим с точным названием/ограничениями; полный Portal не обязателен. PM владеет tools/oracle/*, fixtures/oracle/*, docs/ORACLE.md и частным .local/sprint03/oracle. Чужой LGPL-код не копируется в MIT runtime: отдельный приватный checkout, ссылки/хеши/лицензии. Фиксируются runtime/dependencies, входы, параметры и фактические outputs. Если не запущен в лимит — зафиксировать BLOCKED/UNVERIFIED сравнение, не выдавать ручной эталон за Apromore; продуктовая поставка честно частичная по oracle.
2. Root: шесть малых фиксированных примеров (обычный выбор вариантов, повтор/self-loop, пустая трасса, Unicode, lifecycle, tie/reversed timestamp). Независимые ручные counts/variants/DFG и отдельное настоящее сравнение, если oracle запущен. Сравнивать по labels, не внутренним IDs; каждое расхождение сохранять. Полная совместимость и качество miner не заявляются.
3. Root: PostgreSQL schema v1 — одна аддитивная миграция: журнал version/name/checksum/applied_at плюс существующие pi_kv/sequence без переписывания документов. Singleton lease ДО любого DDL; атомарный DDL+ledger, проверка ожидаемой старой структуры и поддерживаемых документов; future/checksum/неизвестная структура отклоняются до записи. Повтор идемпотентен. Upgrade существующей 0.2 — только в копии с полным DB-level backup и проверенным restore. Downgrade не поддерживается как операция: старый 0.2 не имеет gate; возврат через сохранённую старую БД/backup, не запуск старого бинарника на upgraded DB.
4. Root: session-local connect<=5s, statement<=5s, lock<=2s, transaction<=10s; bounded admission и ожидание ответа<=15s. Потеря соединения/неясный исход commit блокирует данный экземпляр до явного reopen; нет автоматического повторения mutation. Timeout сам по себе не доказывает rollback. Все сообщения без паролей/URL; фиксируется конкретная граница гарантии.
5. Root: bootstrap staging приватных credentials/config ДО initdb, безопасное возобновление только распознанного своего состояния. Unknown/missing secrets при существующем кластере — контролируемый отказ с инструкцией, без удаления/переинициализации. Rerun после разных прерываний не регенерирует пароли. Полный native PS5 cold Start и role-present/database-missing сохраняются.
6. Root: DB-level backup/restore помощник или документированный исполняемый сценарий pg_dump/pg_restore в новую отдельную БД; включает auth/schema, не project JSON. Actual isolated restore проверяется. Crash/WAL, migration rollback, interrupted jobs, потеря lease/lock проверяются QA на своих процессах. Восстановление jobs остаётся идемпотентным по проекту; общая startup-транзакция всех проектов не обещается.
7. Root: после operational критериев — добавить/удалить обычную BPMN task и sequenceFlow, существующие start/end/gateways неизменны. Ограниченный structural editing API+canvas/forms, canonical validation, CAS revision, viewer запрет, stale409, XML round trip/backup/restart. Без произвольной BPMN-семантики. Если operational обязательные пункты требуют резерв, BPMN не реализуется и итог явно частичный по этой строке.

## Приёмка

| ID | Критерий и доказательство |
|---|---|
| S3-A01 | Фиксированный corpus с SHA/параметрами и независимыми ручными counts/variants/DFG, Rust реальные результаты |
| S3-A02 | Реальный выбранный legacy component output и сравнение по сценариям; при невозможности BLOCKED/UNVERIFIED, без parity credit |
| S3-A03 | Изолированная реальная 0.2 БД с users/roles/sessions/два одноимённых logs/models/params/jobs; upgrade сохраняет полные документы/IDs/exports кроме объявленного interrupted recovery |
| S3-A04 | Schema v1 checksum ledger, fresh/adoption/reopen idem; singleton перед DDL, concurrent denied |
| S3-A05 | Реальный migration rollback/kill до commit; future/checksum/unknown schema отказ без изменения прежней БД |
| S3-A06 | Own isolated PG crash до/после commit: old либо complete-new, нет смешанной записи; WAL restart/DB-level restore реально проверены |
| S3-A07 | Реальный app kill при queued/running, interrupted failed/null и второй restart без новой revision; completed linkage и isolation сохранены |
| S3-A08 | Реальные lock/connection faults ограничены; известный abort не пишет; ambiguous outcome честно failclosed, без auto mutation retry |
| S3-A09 | Fresh native PS5 bootstrap + прерывания staged/before-final + unknown/missing config controlled fail без reset + role/database rerun |
| S3-A10 | BPMN task/flow add/remove, malformed/capacity/access/stale negative, browser save/XML/reload/backup round trip; если отложен — PARTIAL |
| S3-A11 | Регрессии прежних обычных/реальных PG тестов, exact-source fmt/clippy, браузер и свежая Windows упаковка |
| S3-A12 | Независимый QA/TD, coverage stdout/stderr/init/PG/migration/test/CI, точный frozen source/EXE/ZIP и публичный download hash; working user/R1 preserved |

Operational S3-A03–09 обязательны для принятия изменений хранения. Непройденный пункт блокирует affected release. A02 может оказаться BLOCKED, A10 PARTIAL: это не переписывание критериев задним числом и не полное завершение выбранной цели. Все статусы показываются отдельно. Никакой production upgrade без доказательства в изоляции; текущая пользовательская БД остаётся на 0.2, новая 0.3 поставляется отдельно.

## Порядок и резерв

План/Совет и oracle gate ~45–60min; storage/bootstrap draft ~150min параллельно с oracle; independent integration/faults ~90min; BPMN до75min только после operational; reserve30min; final90min. При суммарном выходе за бюджет уменьшается новая функциональность, а не проверки сохранности. Root пишет implementation, PM oracle harness, QA независимые проверки, TD аудит; общие файлы имеют одного владельца. Raw logs/private dumps в .local с защищённым ACL, публично безопасные summaries/hashes. Каждая дорогостоящая попытка сохраняет отдельный stdout/stderr и фактический exit, без перезаписи предыдущего failure.
