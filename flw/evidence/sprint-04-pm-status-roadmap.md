# Sprint04 — предварительный статус и ближайшие шаги

PM /root/pm_final, отдельное существующее место. Принятый S4-P1 неизменен. Root сообщает draft PR4/source8ba187a; перечисленные ниже исполнения относятся к указанным **draft attempts**, не автоматически к этому HEAD или будущему frozen EXE. Read-only review документов и доступных report summaries; не новый QA-run и не final vote. Source/docs не изменялись.

## Что показали черновые проверки

| Результат | Наблюдаемое доказательство | Граница |
|---|---|---|
| Миграция нормализовала записи | normalized-full-values01.json:10 проектов,94 ожидаемых/фактических records,0 mismatches, ledger2 | Draft mapping, ещё не final interruption/restore/publication proof |
| Старт по metadata | candidate-startup-draft03:1985.36/1911.67/1889.17ms; accepted0.3 baseline:13333.04/13202.68/13645.31ms | Предварительные matched measurements; полный финальный identity/sampling/RSS review обязателен, не общая speed/scale гарантия |
| Малые изменения не пишут heavy logs | mutation-perf-candidate01:3 view/3 model writes и3 accepted100k cancellations сохраняют все18 original heavy-record versions/fullhashes | Draft actual checks; repeated5s gates/final CAS/rollback/terminal faults ещё требуют exact acceptance |
| Прежний отказ по общему размеру устранён | capacity-draft03-01: SAME17200026-byte100k input/SAME cumulative6logs→Completed seventhlog;24 oldrecords versions/fullhashes unchanged, export100k/health200 | Draft actual result, не уменьшение input/corpus; individual/count limits остаются |

View samples165–176ms, model8–12ms, jobadmission159–177ms, cancel7–9ms указаны отдельно в draft report; число не распространяется на fulllargeproject firstload. AppWorkingSet samples имеют собственные поля; sharedPG samples включают другие66 hostprocesses в первом sample, поэтому не exclusive QA aggregateRSS. Baseline startup max2,107,166,720bytes — записанное исходное измерение, не готовая оценка выигранной памяти.

## До приёмки

1. Завершить actual final-publication barrier/concurrentmanaged insertion и kill/resume/rollback на сохранённой копии. TD MIGFINAL01 source finding не считать закрытым одним текстом новой SHARE-lock: нужны независимые реальные fault proofs.
2. Проверить exact copied0.3 first adoption/session/full values, corruption/schema/stage negatives, cross-record atomicjobterminal/CAS/isolation, DBbackup/newrestore.
3. Зафиксировать candidate; повторить заранее утверждённые3-run readiness<=15s, mutations<=5s иstartupWorkingSet<=baseline max. Отдельно показать firstload/export/import/cachegrowth, sampling иPG scope. Unchanged big corpus иsourcehashes не сокращать.
4. Fresh exact Windows package/native operator flow/provenance, browser/restart иregressions; independent QA/TD, новая точная Councilresolution.
5. Finalhead CI/merge/tag, только exact ZIP, actual anonymous download hash/bytes и postpublication preservation old3000/3010/3030 перед COMPLETE. Deadline22:57:49UTC, protected90min с21:27:49UTC неизменны; новые features не добавлять.

## Проверка операторской инструкции

Текущий docs/STORAGE_V2.md теперь содержит законченный правильный маршрут: **исходный0.3 backup → отдельный новый0.4 cluster → dump+manifest в защищённую новую.local → Restore в NEW pi_restore_before04 → explicit migrate-storage -Database pi_restore_before04 → Start с теми же Database/PostgresPort**. HTTP/PG ports названы свободными примерами, originalinstallation сохраняется. Запрещён перенос одного oldprivateconfig/PGDATA в пустую newinstallation; restoredlogin использует прежнюю учётную запись, новый firstaccount не предлагается. Это закрывает предыдущую PM documentation-target ambiguity. Предусмотренная инструкция сама по себе не native PASS: exact helperchain QA ещё обязан исполнить.

## Рекомендация для окончательного отчёта Root

До проверки писать «черновые проверки показали», после неё — только exact accepted source/EXE/ZIP и фактические финальные числа/статусы. Не переносить draft timings на финальный runtime и не умножать maxratio в headline «ускорили всё». Если A01–A10 пройдут, описать cause-specific SCALE01 улучшение: metadata startup и delta writes; cachewholeproject после firstaccess/RSS/максимум64 проектов остаются отдельными ограничениями. Затем roadmap: bounded per-resource lazy loading/cache eviction иsame-dataRSS/fault benchmarks, контролируемая cleanup retained legacy сbackup, дальше fullXES/timeoracle/discoveryquality/BPMN по выбранным user scenarios. Full enterprise/Apromore не объявлять завершёнными.

Customer получил отдельный PM источник девяти фактических эмоциональных перспектив в sprint-04-pm-flow-review.md через team message; это не дополнительные места/голоса и не опрос чувств пользователя.
